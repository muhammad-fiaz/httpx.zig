//! TLS 1.3 server over TCP with ALPN dispatch (RFC 8446).
//!
//! Accepts TCP connections, performs a complete TLS 1.3 server handshake
//! with SNI parsing, ALPN negotiation, and record-level encryption, then
//! dispatches to the appropriate HTTP handler based on the negotiated
//! protocol.
//!
//! This module ties together:
//!   - TLS record layer (record.zig) — AEAD encrypt/decrypt
//!   - TLS handshake engine (engine.zig) — key schedule, Finished
//!   - ALPN negotiation (alpn.zig) — protocol selection
//!   - Config (config.zig) — certificate chain, private key, SNI map
//!   - TCP socket (sockets/tcp.zig) — transport
//!
//! Thread-safety: one connection = one TlsServerConn, not shared.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

const engine_mod = @import("engine.zig");
const handshake_mod = @import("handshake.zig");
const record_mod = @import("record.zig");
const alpn_mod = @import("alpn.zig");
const config_mod = @import("config.zig");
const session_mod = @import("session.zig");
const cert_mod = @import("certificate.zig");
const verify_mod = @import("verify.zig");
const trustStoreMod = @import("trustStore.zig");
const clock_mod = @import("../../common/clock.zig");
const address_mod = @import("../../net/address.zig");
const tcp = @import("../../sockets/tcp.zig");

// Errors

pub const Error = error{
    TlsHandshakeFailed,
    TlsRecordError,
    TlsAlertSent,
    TlsFatalAlert,
    TlsCloseNotify,
    TlsProtocolViolation,
    TlsUnsupportedSni,
    AcceptFailed,
    IoError,
    OutOfMemory,
    BufferTooSmall,
    MissingCertificate,
    ClientCertificateRequired,
    ClientCertificateInvalid,
    SequenceOverflow,
    RecordTooLarge,
    InvalidKeyLength,
    InvalidIvLength,
};

// TLS server connection (post-handshake)

/// Represents a completed TLS server connection ready for application data.
pub const TlsServerConn = struct {
    socket: *tcp.Socket,
    allocator: Allocator,

    /// Negotiated ALPN protocol.
    alpn: ?alpn_mod.Protocol,

    /// SNI hostname from ClientHello, if any.
    sni: ?[]const u8,

    /// True when this connection resumed via PSK (abbreviated flight:
    /// no Certificate/CertificateVerify was exchanged).
    resumed: bool = false,

    /// Application traffic keys for encrypt/decrypt.
    appKeys: engine_mod.DerivedKeys,

    /// Sequence numbers for application records.
    txSeq: u64 = 0,
    rxSeq: u64 = 0,

    /// Write buffer for outgoing encrypted records.
    writeBuf: []u8,

    /// Read buffer for incoming encrypted records.
    readBuf: []u8,

    /// Leftover plaintext from a previous read (partial record).
    /// Owned copy in `leftoverBuf` — never a slice of a stack buffer.
    leftoverBuf: [record_mod.maxRecordPlaintext + 1]u8 = undefined,
    leftoverLen: usize = 0,
    leftover: []const u8 = &.{},

    pub fn deinit(self: *TlsServerConn) void {
        self.allocator.free(self.writeBuf);
        self.allocator.free(self.readBuf);
        if (self.sni) |hostname| self.allocator.free(hostname);
    }

    /// Encrypt and send application data.
    pub fn writeAll(self: *TlsServerConn, plaintext: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < plaintext.len) {
            const chunkLen = @min(plaintext.len - offset, record_mod.maxRecordPlaintext);
            const encoded = try record_mod.encodeRecord(
                .application_data,
                plaintext[offset..][0..chunkLen],
                self.txSeq,
                self.appKeys.serverKeySlice(),
                &self.appKeys.serverIv,
                self.appKeys.cipher,
            );
            self.socket.writeAll(encoded.bytes[0..encoded.len]) catch return error.IoError;
            self.txSeq +%= 1;
            offset += chunkLen;
        }
    }

    /// Read and decrypt one record worth of application data.
    /// Returns the decrypted plaintext (valid until next readAll call).
    pub fn read(self: *TlsServerConn, buf: []u8) Error!usize {
        if (self.leftoverLen > 0) {
            const n = @min(self.leftoverLen, buf.len);
            @memcpy(buf[0..n], self.leftoverBuf[0..n]);
            const remain = self.leftoverLen - n;
            if (remain > 0) std.mem.copyForwards(u8, self.leftoverBuf[0..remain], self.leftoverBuf[n..][0..remain]);
            self.leftoverLen = remain;
            self.leftover = self.leftoverBuf[0..self.leftoverLen];
            return n;
        }

        // Read record header (5 bytes)
        var hdr_buf: [5]u8 = undefined;
        var totalRead: usize = 0;
        while (totalRead < 5) {
            const n = self.socket.read(hdr_buf[totalRead..]) catch return error.IoError;
            if (n == 0) return 0; // peer closed
            totalRead += n;
        }

        // TLS 1.3 records use the TLS 1.2 legacy version on the wire.
        if (hdr_buf[1] != 0x03 or hdr_buf[2] != 0x03) return error.TlsRecordError;

        const record_len: usize = (@as(usize, hdr_buf[3]) << 8) | hdr_buf[4];
        const tag_len = self.appKeys.cipher.tagLen();
        if (record_len < tag_len or
            record_len > record_mod.maxRecordPlaintext + 1 + tag_len)
        {
            return error.TlsRecordError;
        }

        // Read record body
        var wire_buf: [record_mod.maxRecordWire]u8 = undefined;
        @memcpy(wire_buf[0..5], &hdr_buf);
        totalRead = 0;
        while (totalRead < record_len) {
            const n = self.socket.read(wire_buf[5 + totalRead ..][0 .. record_len - totalRead]) catch return error.IoError;
            if (n == 0) return error.TlsRecordError;
            totalRead += n;
        }

        // Check content type
        const contentTypeByte = wire_buf[0];
        if (contentTypeByte != @intFromEnum(record_mod.ContentType.application_data)) {
            if (contentTypeByte == @intFromEnum(record_mod.ContentType.alert)) {
                // Try to decrypt to read alert description
                var decrypt_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
                const result = record_mod.decodeRecord(
                    wire_buf[0..][0 .. 5 + record_len],
                    &decrypt_buf,
                    self.rxSeq,
                    self.appKeys.clientKeySlice(),
                    &self.appKeys.clientIv,
                    self.appKeys.cipher,
                ) catch return error.TlsFatalAlert;
                if (result.plaintext.len >= 2) {
                    const alert = handshake_mod.Alert.decode(.{ result.plaintext[0], result.plaintext[1] });
                    if (alert.description == .close_notify) return error.TlsCloseNotify;
                }
                return error.TlsFatalAlert;
            }
            return error.TlsRecordError;
        }

        // Decrypt application record
        var decrypt_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
        const result = record_mod.decodeRecord(
            wire_buf[0..][0 .. 5 + record_len],
            &decrypt_buf,
            self.rxSeq,
            self.appKeys.clientKeySlice(),
            &self.appKeys.clientIv,
            self.appKeys.cipher,
        ) catch return error.TlsRecordError;
        self.rxSeq +%= 1;

        const n = @min(result.plaintext.len, buf.len);
        @memcpy(buf[0..n], result.plaintext[0..n]);
        if (n < result.plaintext.len) {
            const rest = result.plaintext[n..];
            @memcpy(self.leftoverBuf[0..rest.len], rest);
            self.leftoverLen = rest.len;
            self.leftover = self.leftoverBuf[0..self.leftoverLen];
        } else {
            self.leftoverLen = 0;
            self.leftover = &.{};
        }
        return n;
    }
};

// TLS server listener

/// SNI-based certificate selector. Maps hostname → certificate identity.
pub const CertSelector = struct {
    ctx: ?*anyopaque = null,
    select: *const fn (ctx: ?*anyopaque, hostname: ?[]const u8) ?CertIdentity,
};

pub const CertIdentity = struct {
    certChainPem: []const u8,
    privateKeyPem: []const u8,
};

/// Configuration for the TLS server.
pub const TlsServerConfig = struct {
    allocator: Allocator,

    /// Default certificate (used when SNI doesn't match any specific cert).
    defaultIdentity: ?CertIdentity = null,

    /// SNI certificate selector (optional; falls back to defaultIdentity).
    certSelector: ?CertSelector = null,

    /// ALPN protocols in server preference order (TCP: no h3, QUIC handles h3 separately).
    alpnProtocols: []const alpn_mod.Protocol = &alpn_mod.DEFAULT_TCP_PREFERENCE,

    /// Mutual TLS mode: request and enforce client certificates.
    clientAuth: config_mod.ClientAuthMode = .disabled,
    /// PEM bundle (or file path) of CAs trusted for client certificates.
    clientCaPem: ?[]const u8 = null,
    /// Ticket keys for TLS 1.3 session resumption (stateless NST issue
    /// + PSK-accept on offer). Null disables resumption entirely: no
    /// tickets are sent and PSK offers fall back to full handshakes.
    ticketKeys: ?session_mod.TicketKeys = null,
    /// Lifetime (seconds) stamped into issued session tickets.
    ticketLifetimeSecs: u32 = 7200,

    pub fn init(allocator: Allocator) TlsServerConfig {
        return .{ .allocator = allocator };
    }
};

/// TLS server that wraps TCP + TLS handshake.
pub const TlsServer = struct {
    config: TlsServerConfig,

    pub fn init(config: TlsServerConfig) TlsServer {
        return .{ .config = config };
    }

    /// Perform TLS 1.3 server handshake on an accepted TCP connection.
    ///
    /// This reads the ClientHello, extracts SNI, performs ALPN negotiation,
    /// derives keys via the TLS 1.3 key schedule, and sends the full server
    /// flight (ServerHello + EncryptedExtensions + Certificate +
    /// CertificateVerify + Finished) as plaintext records.
    pub fn handshake(self: *TlsServer, io: std.Io, socket: *tcp.Socket) !TlsServerConn {
        return self.handshakeBuffered(io, socket, &.{});
    }

    /// Perform TLS 1.3 server handshake on an accepted TCP connection,
    /// accepting any pre-read bytes from initial buffer peek.
    pub fn handshakeBuffered(self: *TlsServer, io: std.Io, socket: *tcp.Socket, initial: []const u8) !TlsServerConn {
        const a = self.config.allocator;

        var engine = engine_mod.Engine.initServer(a, .{});
        defer engine.deinit();
        engine.ticketKeys = self.config.ticketKeys;

        // Read the ClientHello frame (record or raw handshake framing).
        // `initial` bytes (peeked by the listener for protocol dispatch)
        // are prepended to the first frame read only.
        var readBuf: [16384]u8 = undefined;
        var hello = try readHelloFrame(socket, &readBuf, initial);
        try engine.processClientHello(readBuf[hello.offset..][0 .. 4 + hello.bodyLen]);

        // Missing (EC)DHE share: HelloRetryRequest once (RFC 8446 4.1.4),
        // then read the retried hello and continue with it. A second
        // shareless hello fails inside `produceHelloRetryRequest`.
        var chBody = readBuf[hello.offset + 4 ..][0..hello.bodyLen];
        if (!engine_mod.Engine.clientHelloHasShare(chBody)) {
            const hrr = try engine.produceHelloRetryRequest();
            defer a.free(hrr);
            try writePlaintextHandshakeRecord(socket, hrr);
            hello = try readHelloFrame(socket, &readBuf, &.{});
            try engine.processClientHello(readBuf[hello.offset..][0 .. 4 + hello.bodyLen]);
            chBody = readBuf[hello.offset + 4 ..][0..hello.bodyLen];
        }

        // Parse the (final) ClientHello body for SNI and ALPN.
        var parsed_ch = try parseClientHelloExtensions(a, chBody);
        defer parsed_ch.alpnProtocols.deinit(a);

        // PSK resumption offer: verified silently, selected or ignored.
        // Never fails the handshake — worst case is a full handshake.
        // Skipped under mutual TLS: an abbreviated flight carries no
        // CertificateRequest, so resumed connections would bypass client
        // certificate authentication entirely.
        const now_ms: u64 = @intCast(clock_mod.millisNow());
        const full_ch = readBuf[hello.offset..][0 .. 4 + hello.bodyLen];
        if (self.config.clientAuth == .disabled) {
            _ = engine.selectPsk(full_ch, now_ms);
        }

        // Store SNI in engine
        if (parsed_ch.sni) |sni| {
            engine.negotiatedAlpn = null; // will be set during ALPN processing
            _ = sni; // stored via engine
        }

        // Select certificate
        const identity = self.resolveIdentity(parsed_ch.sni) orelse return error.MissingCertificate;
        if (identity.certChainPem.len == 0 or identity.privateKeyPem.len == 0)
            return error.MissingCertificate;

        // Server produces flight (negotiates cipher/key-share from the
        // ClientHello when no secret was preset). Mutual TLS inserts a
        // CertificateRequest between EE and Certificate (transcript-safe).
        if (self.config.clientAuth != .disabled) {
            engine.requestClientCert = true;
        }
        var flight = try engine.produceServerFlight(
            chBody,
            identity.certChainPem,
            identity.privateKeyPem,
            self.config.alpnProtocols,
            parsed_ch.alpnProtocols.items,
        );
        defer flight.deinit(a);

        // ServerHello is the final plaintext handshake message. The remaining
        // flight is carried in TLS 1.3 encrypted handshake records.
        try writePlaintextHandshakeRecord(socket, flight.serverHello);
        // Middlebox-compatibility ChangeCipherSpec (RFC 8446 Section 5.4):
        // optional on the wire, but several client stacks only switch into
        // the handshake cipher state after seeing it. Harmless to peers
        // that ignore it; required for interop with those that gate on it.
        try writeChangeCipherSpec(socket);
        const hsKeys = engine.hsKeys orelse return error.TlsHandshakeFailed;
        var hs_seq: u64 = 0;
        try writeEncryptedHandshakeRecord(socket, flight.encryptedExtensions, hsKeys, &hs_seq);
        if (flight.certificateRequest) |cr| {
            try writeEncryptedHandshakeRecord(socket, cr, hsKeys, &hs_seq);
        }
        // Abbreviated (PSK-resumed) flights carry no Certificate or
        // CertificateVerify: empty flight parts are never sent.
        if (flight.certificate.len > 0) {
            try writeEncryptedHandshakeRecord(socket, flight.certificate, hsKeys, &hs_seq);
        }
        if (flight.certificateVerify.len > 0) {
            try writeEncryptedHandshakeRecord(socket, flight.certificateVerify, hsKeys, &hs_seq);
        }
        try writeEncryptedHandshakeRecord(socket, flight.finished, hsKeys, &hs_seq);

        // Derive application keys
        // Application keys were derived at the end of produceServerFlight
        const apKeys = engine.apKeys orelse return error.TlsHandshakeFailed;

        // Consume the client's Finished (plus any middlebox-compat CCS
        // records): the first client handshake record, verified against the
        // transcript. Reads are exact-size so pipelined application bytes
        // are never over-consumed. With mutual TLS this becomes the full
        // Certificate [+ CertificateVerify] + Finished flight instead —
        // except on abbreviated (PSK) flights, where no CertificateRequest
        // was sent and the client answers with Finished directly.
        {
            const fin_keys = engine.hsKeys orelse return error.TlsHandshakeFailed;
            if (self.config.clientAuth != .disabled and engine.resumptionPsk == null) {
                try self.verifyClientFlight(io, socket, &engine, fin_keys);
            } else {
                var finished_ok = false;
                while (!finished_ok) {
                    var hdr: [5]u8 = undefined;
                    var have: usize = 0;
                    while (have < 5) {
                        const n = socket.read(hdr[have..]) catch return error.IoError;
                        if (n == 0) return error.TlsHandshakeFailed;
                        have += n;
                    }
                    if (hdr[0] == @intFromEnum(record_mod.ContentType.change_cipher_spec)) {
                        const skip_len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                        var skipped: usize = 0;
                        var tmp: [64]u8 = undefined;
                        while (skipped < skip_len) {
                            const want = @min(tmp.len, skip_len - skipped);
                            const n = socket.read(tmp[0..want]) catch return error.IoError;
                            if (n == 0) return error.TlsHandshakeFailed;
                            skipped += n;
                        }
                        continue;
                    }
                    if (hdr[0] != @intFromEnum(record_mod.ContentType.application_data)) {
                        return error.TlsHandshakeFailed;
                    }
                    const rec_len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                    if (rec_len < fin_keys.cipher.tagLen() or
                        rec_len > record_mod.maxRecordPlaintext + 1 + fin_keys.cipher.tagLen())
                    {
                        return error.TlsHandshakeFailed;
                    }
                    var wire: [record_mod.maxRecordWire]u8 = undefined;
                    @memcpy(wire[0..5], &hdr);
                    var got: usize = 0;
                    while (got < rec_len) {
                        const n = socket.read(wire[5 + got ..][0 .. rec_len - got]) catch return error.IoError;
                        if (n == 0) return error.TlsHandshakeFailed;
                        got += n;
                    }
                    var plain_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
                    const dec = record_mod.decodeRecord(
                        wire[0..][0 .. 5 + rec_len],
                        &plain_buf,
                        0,
                        fin_keys.clientKeySlice(),
                        &fin_keys.clientIv,
                        fin_keys.cipher,
                    ) catch return error.TlsHandshakeFailed;
                    if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
                    try engine.verifyClientFinished(dec.plaintext);
                    finished_ok = true;
                }
            }
        }

        // Session ticket (RFC 8446 Section 4.6.1): issued exactly once per
        // full handshake when ticket keys are configured — never on
        // abbreviated handshakes (the client already holds a ticket) and
        // never with early-data extensions (0-RTT stays unimplemented).
        // The ticket record uses application traffic keys at sequence 0,
        // so the returned connection starts its application sequence at 1.
        var ap_tx_seq: u64 = 0;
        if (self.config.ticketKeys != null and engine.resumptionPsk == null) {
            const master = try engine.deriveResumptionMaster();
            const nst_msg = try engine.produceNewSessionTicket(
                master,
                engine.selectedSuite,
                self.config.ticketLifetimeSecs,
                now_ms,
            );
            defer a.free(nst_msg);
            const nst_enc = try record_mod.encodeRecord(
                .handshake,
                nst_msg,
                ap_tx_seq,
                apKeys.serverKeySlice(),
                &apKeys.serverIv,
                apKeys.cipher,
            );
            ap_tx_seq += 1;
            socket.writeAll(nst_enc.bytes[0..nst_enc.len]) catch return error.IoError;
        }

        // Allocate read/write buffers for application records
        const writeBuf = try a.alloc(u8, record_mod.maxRecordWire);
        errdefer a.free(writeBuf);
        const read_buf_app = try a.alloc(u8, record_mod.maxRecordWire);
        errdefer a.free(read_buf_app);

        const sni_copy = if (parsed_ch.sni) |hostname| try a.dupe(u8, hostname) else null;
        errdefer if (sni_copy) |hostname| a.free(hostname);

        return .{
            .socket = socket,
            .allocator = a,
            .alpn = if (engine.negotiatedAlpn) |a_name| alpn_mod.Protocol.fromWire(a_name) else null,
            .sni = sni_copy,
            .appKeys = apKeys,
            .resumed = engine.resumptionPsk != null,
            .txSeq = ap_tx_seq,
            .writeBuf = writeBuf,
            .readBuf = read_buf_app,
        };
    }

    /// Verifies the mutual-TLS client flight: Certificate [+ CertificateVerify]
    /// + Finished, decrypted from handshake records and checked against the
    /// transcript. Policy: `.required` rejects a missing certificate; any
    /// presented chain must anchor in `clientCaPem` with a valid P-256
    /// signature; Finished always binds the transcript. Fails closed.
    fn verifyClientFlight(
        self: *TlsServer,
        io: std.Io,
        socket: *tcp.Socket,
        engine: *engine_mod.Engine,
        hs_keys: engine_mod.DerivedKeys,
    ) !void {
        const a = self.config.allocator;
        var hs_buf = std.ArrayList(u8).empty;
        defer hs_buf.deinit(a);

        var split: ?ClientFlightSplit = null;
        var guard: usize = 0;
        var rx_seq: u64 = 0;
        while (split == null) {
            guard += 1;
            if (guard > 32 or hs_buf.items.len > 1 << 20) return error.TlsHandshakeFailed;
            if (hs_buf.items.len >= 1 and hs_buf.items[0] != @intFromEnum(handshake_mod.HandshakeType.certificate)) {
                return error.TlsHandshakeFailed;
            }
            try readClientHandshakeRecord(socket, hs_keys, &rx_seq, &hs_buf, a);
            split = splitClientFlight(hs_buf.items);
        }
        const sp = split.?;

        var presented = try engine.processClientCertificate(hs_buf.items[sp.cert_off..sp.cert_end]);
        defer presented.deinit();
        if (presented.ders.len == 0) {
            if (self.config.clientAuth == .required) return error.ClientCertificateRequired;
        } else {
            const ca_pem = self.config.clientCaPem orelse return error.ClientCertificateInvalid;
            var store = trustStoreMod.TrustStore.init(a, io);
            defer store.deinit();
            // Pre-validate CA blocks structurally: malformed operator
            // configuration must fail closed, never panic downstream.
            var search_from: usize = 0;
            var blocks: usize = 0;
            while (std.mem.indexOfPos(u8, ca_pem, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
                const der = cert_mod.decodePemBlock(a, ca_pem[idx..], "CERTIFICATE") catch return error.ClientCertificateInvalid;
                defer a.free(der);
                if (!cert_mod.checkDerStructure(der)) return error.ClientCertificateInvalid;
                blocks += 1;
                search_from = idx + 26;
            }
            if (blocks == 0) return error.ClientCertificateInvalid;
            store.addCertPem(ca_pem) catch return error.ClientCertificateInvalid;
            if (store.count() == 0) return error.ClientCertificateInvalid;
            // Borrowed view: ownership of the DER bytes stays with `presented`.
            const chain = cert_mod.CertificateChain{ .certs = presented.ders, .allocator = a };
            const now_sec: i64 = @divFloor(clock_mod.millisNow(), 1000);
            verify_mod.verifyCertificateChain(chain, &store, null, now_sec) catch return error.ClientCertificateInvalid;
            try engine.processClientCertificateVerify(hs_buf.items[sp.cv_off..sp.cv_end], presented.ders[0]);
        }
        try engine.verifyClientFinished(hs_buf.items[sp.fin_off..sp.fin_end]);
    }

    const ClientFlightSplit = struct {
        cert_off: usize,
        cert_end: usize,
        cv_off: usize,
        cv_end: usize,
        fin_off: usize,
        fin_end: usize,
        empty_cert: bool,
    };

    /// Splits a reassembled client flight into Certificate [+ CV] + Finished.
    /// Returns null while more handshake bytes are needed.
    fn splitClientFlight(buf: []const u8) ?ClientFlightSplit {
        const cert_type = @intFromEnum(handshake_mod.HandshakeType.certificate);
        const cv_type = @intFromEnum(handshake_mod.HandshakeType.certificate_verify);
        const fin_type = @intFromEnum(handshake_mod.HandshakeType.finished);
        if (buf.len < 4 or buf[0] != cert_type) return null;
        const cert_len: usize = (@as(usize, buf[1]) << 16) | (@as(usize, buf[2]) << 8) | buf[3];
        if (buf.len < 4 + cert_len) return null;
        const cert_end = 4 + cert_len;
        // Empty certificate message: context(1) + list(3) with zero entries.
        const empty_cert = cert_len == 4;
        var pos = cert_end;
        var cv_off: usize = 0;
        var cv_end: usize = 0;
        if (!empty_cert) {
            if (buf.len < pos + 4 or buf[pos] != cv_type) return null;
            const cv_len: usize = (@as(usize, buf[pos + 1]) << 16) | (@as(usize, buf[pos + 2]) << 8) | buf[pos + 3];
            if (buf.len < pos + 4 + cv_len) return null;
            cv_off = pos;
            cv_end = pos + 4 + cv_len;
            pos = cv_end;
        }
        if (buf.len < pos + 4 or buf[pos] != fin_type) return null;
        const fin_len: usize = (@as(usize, buf[pos + 1]) << 16) | (@as(usize, buf[pos + 2]) << 8) | buf[pos + 3];
        if (buf.len < pos + 4 + fin_len) return null;
        return .{
            .cert_off = 0,
            .cert_end = cert_end,
            .cv_off = cv_off,
            .cv_end = cv_end,
            .fin_off = pos,
            .fin_end = pos + 4 + fin_len,
            .empty_cert = empty_cert,
        };
    }

    /// Reads one handshake record (skipping middlebox CCS), decrypts it
    /// with the client handshake keys, and appends the plaintext.
    /// Record sequence numbers start at 0 for the first encrypted client
    /// record and increment per record (CCS carries no sequence).
    fn readClientHandshakeRecord(
        socket: *tcp.Socket,
        hs_keys: engine_mod.DerivedKeys,
        rx_seq: *u64,
        out: *std.ArrayList(u8),
        a: Allocator,
    ) !void {
        while (true) {
            var hdr: [5]u8 = undefined;
            var have: usize = 0;
            while (have < 5) {
                const n = socket.read(hdr[have..]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                have += n;
            }
            if (hdr[0] == @intFromEnum(record_mod.ContentType.change_cipher_spec)) {
                const skip_len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                var skipped: usize = 0;
                var tmp: [64]u8 = undefined;
                while (skipped < skip_len) {
                    const want = @min(tmp.len, skip_len - skipped);
                    const n = socket.read(tmp[0..want]) catch return error.IoError;
                    if (n == 0) return error.TlsHandshakeFailed;
                    skipped += n;
                }
                continue;
            }
            if (hdr[0] != @intFromEnum(record_mod.ContentType.application_data)) {
                return error.TlsHandshakeFailed;
            }
            const rec_len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
            if (rec_len < hs_keys.cipher.tagLen() or
                rec_len > record_mod.maxRecordPlaintext + 1 + hs_keys.cipher.tagLen())
            {
                return error.TlsHandshakeFailed;
            }
            var wire: [record_mod.maxRecordWire]u8 = undefined;
            @memcpy(wire[0..5], &hdr);
            var got: usize = 0;
            while (got < rec_len) {
                const n = socket.read(wire[5 + got ..][0 .. rec_len - got]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                got += n;
            }
            var plain_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = record_mod.decodeRecord(
                wire[0..][0 .. 5 + rec_len],
                &plain_buf,
                rx_seq.*,
                hs_keys.clientKeySlice(),
                &hs_keys.clientIv,
                hs_keys.cipher,
            ) catch return error.TlsHandshakeFailed;
            rx_seq.* += 1;
            if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
            try out.appendSlice(a, dec.plaintext);
            return;
        }
    }

    fn writePlaintextHandshakeRecord(socket: *tcp.Socket, message: []const u8) !void {
        if (message.len > std.math.maxInt(u16)) return error.TlsHandshakeFailed;
        var header: [5]u8 = .{ 0x16, 0x03, 0x03, 0, 0 };
        std.mem.writeInt(u16, header[3..5], @intCast(message.len), .big);
        try socket.writeAll(&header);
        try socket.writeAll(message);
    }

    /// Middlebox-compatibility ChangeCipherSpec record (RFC 8446 Section 5.4):
    /// a single 0x01 payload in its own record. Sending it is optional, but
    /// several client stacks only enter the handshake cipher state after
    /// observing it; peers that ignore it are unaffected.
    fn writeChangeCipherSpec(socket: *tcp.Socket) !void {
        try socket.writeAll(&.{ 0x14, 0x03, 0x03, 0x00, 0x01, 0x01 });
    }

    fn writeEncryptedHandshakeRecord(socket: *tcp.Socket, message: []const u8, keys: engine_mod.DerivedKeys, seq: *u64) !void {
        const encoded = try record_mod.encodeRecord(.handshake, message, seq.*, keys.serverKeySlice(), &keys.serverIv, keys.cipher);
        try socket.writeAll(encoded.bytes[0..encoded.len]);
        seq.* +%= 1;
    }

    /// Reads one complete ClientHello frame into `buf`: either a TLS
    /// record wrapping exactly one ClientHello, or a raw handshake
    /// message. `initial` bytes are prepended (peeked protocol-dispatch
    /// bytes, first frame only). Returns the message offset and body
    /// length; the full message is `buf[offset..][0..4+bodyLen]`.
    fn readHelloFrame(socket: *tcp.Socket, buf: []u8, initial: []const u8) !struct { offset: usize, bodyLen: u24 } {
        var totalRead: usize = 0;
        if (initial.len > 0) {
            const take = @min(initial.len, buf.len);
            @memcpy(buf[0..take], initial[0..take]);
            totalRead = take;
        }
        while (totalRead < 5) {
            const n = socket.read(buf[totalRead..]) catch return error.IoError;
            if (n == 0) return error.TlsHandshakeFailed;
            totalRead += n;
        }
        if (buf[0] == @intFromEnum(record_mod.ContentType.handshake)) {
            // Standard framed TLS Record: [0]=0x16, [1..2]=version,
            // [3..4]=record_len, [5..]=handshake.
            const record_len = std.mem.readInt(u16, buf[3..5], .big);
            const total_needed = 5 + @as(usize, record_len);
            if (total_needed > buf.len) return error.TlsHandshakeFailed;
            while (totalRead < total_needed) {
                const n = socket.read(buf[totalRead..]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                totalRead += n;
            }
            if (buf[5] != @intFromEnum(handshake_mod.HandshakeType.client_hello)) {
                return error.TlsHandshakeFailed;
            }
            const body_len: u24 = @as(u24, @intCast(buf[6])) << 16 |
                @as(u24, @intCast(buf[7])) << 8 |
                @as(u24, @intCast(buf[8]));
            if (body_len > max_handshake_body or 5 + 4 + body_len > totalRead) return error.TlsHandshakeFailed;
            return .{ .offset = 5, .bodyLen = body_len };
        } else if (buf[0] == @intFromEnum(handshake_mod.HandshakeType.client_hello)) {
            // Raw Handshake framing without record layer.
            const body_len: u24 = @as(u24, @intCast(buf[1])) << 16 |
                @as(u24, @intCast(buf[2])) << 8 |
                @as(u24, @intCast(buf[3]));
            if (body_len > max_handshake_body) return error.TlsHandshakeFailed;
            while (totalRead < 4 + body_len) {
                const n = socket.read(buf[totalRead..]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                totalRead += n;
            }
            return .{ .offset = 0, .bodyLen = body_len };
        } else {
            return error.TlsHandshakeFailed;
        }
    }

    fn resolveIdentity(self: *const TlsServer, sni: ?[]const u8) ?CertIdentity {
        if (self.config.certSelector) |sel| {
            return sel.select(sel.ctx, sni);
        }
        return self.config.defaultIdentity;
    }
};

// ClientHello parsing helpers

const max_handshake_body = 1 << 14;

const ParsedClientHello = struct {
    sni: ?[]const u8 = null,
    alpnProtocols: std.ArrayList([]const u8),
};

/// Parse extensions from a ClientHello body to extract SNI and ALPN.
fn parseClientHelloExtensions(allocator: Allocator, body: []const u8) !ParsedClientHello {
    if (body.len < 34) return error.TlsHandshakeFailed;

    // ClientHello body layout (matching our encoder):
    //   [0..2]   client_version
    //   [2..34]  random
    //   [34]       legacy_session_id_length (u8)
    //   [35..]     legacy_session_id
    //   [...]      cipher suites, compression methods, extensions
    var pos: usize = 34; // skip client_version(2) + random(32)

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const session_id_len = body[pos];
    pos += 1;
    const session_end = std.math.add(usize, pos, session_id_len) catch return error.TlsHandshakeFailed;
    if (session_end > body.len) return error.TlsHandshakeFailed;
    pos += session_id_len;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const cs_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2 + cs_len;

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const comp_len = body[pos];
    pos += 1 + comp_len;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const ext_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2;
    const ext_end = std.math.add(usize, pos, ext_len) catch return error.TlsHandshakeFailed;
    if (ext_end > body.len) return error.TlsHandshakeFailed;

    var result = ParsedClientHello{
        .alpnProtocols = std.ArrayList([]const u8).empty,
    };
    errdefer result.alpnProtocols.deinit(allocator);

    while (pos + 4 <= ext_end) {
        const ext_type = std.mem.readInt(u16, body[pos..][0..2], .big);
        const ext_data_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
        pos += 4;
        const dataEnd = std.math.add(usize, pos, ext_data_len) catch return error.TlsHandshakeFailed;
        if (dataEnd > ext_end) return error.TlsHandshakeFailed;

        if (ext_type == @intFromEnum(handshake_mod.ExtensionType.server_name)) {
            result.sni = try parseSniExtension(body[pos..][0..ext_data_len]);
        } else if (ext_type == @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation)) {
            result.alpnProtocols = try parseAlpnExtension(allocator, body[pos..][0..ext_data_len]);
        }

        pos = dataEnd;
    }

    if (pos != ext_end) return error.TlsHandshakeFailed;

    return result;
}

/// Parse the serverName extension to extract the hostname.
fn parseSniExtension(data: []const u8) !?[]const u8 {
    if (data.len < 5) return error.TlsHandshakeFailed;
    // list length (2 bytes), then at least one entry
    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
    const list_end = std.math.add(usize, 2, list_len) catch return null;
    if (list_len < 3 or list_end != data.len) return error.TlsHandshakeFailed;

    // name type (1 byte) + name length (2 bytes)
    const name_type = data[2];
    if (name_type != 0) return error.TlsHandshakeFailed; // only host_name type
    const nameLen: usize = (@as(usize, data[3]) << 8) | data[4];
    const name_end = std.math.add(usize, 5, nameLen) catch return null;
    if (name_end != list_end) return error.TlsHandshakeFailed;

    return data[5..][0..nameLen];
}

/// Parse the ALPN extension to extract the list of offered protocol names.
fn parseAlpnExtension(allocator: Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);
    if (data.len < 2) return error.TlsHandshakeFailed;
    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
    if (list_len != data.len - 2) return error.TlsHandshakeFailed;
    var pos: usize = 2;
    const list_end = 2 + list_len;
    while (pos < list_end) {
        if (pos + 1 > list_end) return error.TlsHandshakeFailed;
        const nameLen = data[pos];
        pos += 1;
        if (nameLen == 0 or pos + nameLen > list_end) return error.TlsHandshakeFailed;
        try result.append(allocator, data[pos..][0..nameLen]);
        pos += nameLen;
    }
    if (pos != list_end) return error.TlsHandshakeFailed;
    return result;
}

// Tests

test "tls server handshake processes client hello" {
    const a = std.testing.allocator;

    // Create a client that produces a ClientHello
    var client = engine_mod.Engine.initClient(a, .{});
    const ch = try client.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);

    try std.testing.expectEqual(@as(u8, 0x01), ch[0]);

    // Process it through a server engine
    var server_engine = engine_mod.Engine.initServer(a, .{});
    try server_engine.processClientHello(ch);
    try std.testing.expectEqual(engine_mod.Engine.State.client_hello_received, server_engine.state);
}

test "alpn negotiation in server config" {
    const cfg = TlsServerConfig{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 3), cfg.alpnProtocols.len);
    try std.testing.expectEqual(alpn_mod.Protocol.h2, cfg.alpnProtocols[0]);
    try std.testing.expectEqual(alpn_mod.Protocol.@"http/1.1", cfg.alpnProtocols[1]);
    try std.testing.expectEqual(alpn_mod.Protocol.@"http/1.0", cfg.alpnProtocols[2]);
}

test "ClientHello SNI parsing" {
    const a = std.testing.allocator;

    var client = engine_mod.Engine.initClient(a, .{});
    const ch = try client.produceClientHelloWithSni(&.{"h2"}, &.{}, "example.com");
    defer a.free(ch);

    // Parse the ClientHello body for extensions
    var parsed = try parseClientHelloExtensions(a, ch[4..]);
    defer parsed.alpnProtocols.deinit(a);
    try std.testing.expect(parsed.sni != null);
    try std.testing.expectEqualStrings("example.com", parsed.sni.?);
}

test "TLS extension parsers reject malformed SNI and ALPN" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TlsHandshakeFailed, parseSniExtension(&.{ 0, 3, 0, 0, 1 }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseSniExtension(&.{ 0, 5, 0, 0, 1, 'x', 0 }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseAlpnExtension(a, &.{ 0, 3, 2, 'h' }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseAlpnExtension(a, &.{ 0, 2, 0, 'x' }));
}
test "clienthello single-entry alpn offer parses back" {
    const a = std.testing.allocator;
    var eng = engine_mod.Engine.initClient(a, .{});
    defer eng.deinit();
    const ch = try eng.produceClientHelloWithSni(&.{"h2"}, &.{}, null);
    defer a.free(ch);
    var parsed = try parseClientHelloExtensions(a, ch[4..]);
    defer parsed.alpnProtocols.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), parsed.alpnProtocols.items.len);
    try std.testing.expectEqualStrings("h2", parsed.alpnProtocols.items[0]);
}

test "server without certificate fails fast with MissingCertificate" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    // No defaultIdentity and no selector: unusable server by construction.
    var server = TlsServer.init(.{ .allocator = a });

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *TlsServer, out: *anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.handshakeBuffered(io2, &sock, &.{})) |conn| {
                var c = conn;
                c.deinit();
                out.* = error.UnexpectedSuccess;
            } else |err| {
                out.* = err;
            }
        }
    };
    var result: anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    // Client side: real engine-produced ClientHello over loopback.
    var client_sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer client_sock.close();
    var client_engine = engine_mod.Engine.initClient(a, .{});
    defer client_engine.deinit();
    const ch = try client_engine.produceClientHello(&.{"http/1.1"}, &.{});
    defer a.free(ch);
    try client_sock.writeAll(ch);

    th.join();
    // Fail-fast BEFORE any Certificate/CertificateVerify flight is emitted.
    try std.testing.expect(result == error.MissingCertificate);
}

// Scripted native-TLS client for mutual-TLS loopback tests: drives a real
// engine through record-layer I/O over TCP (no std-TLS client involved,
// since it cannot present client certificates).

const MtlsScript = struct {
    sock: tcp.Socket,
    eng: engine_mod.Engine,
    hs_rx_seq: u64 = 0,
    hs_tx_seq: u64 = 0,
    ap_tx_seq: u64 = 0,
    ap_rx_seq: u64 = 0,
    allocator: Allocator,

    fn dial(a: Allocator, io: std.Io, port: u16) !MtlsScript {
        var sock = try tcp.connect(io, "127.0.0.1", port);
        errdefer sock.close();
        var eng = engine_mod.Engine.initClient(a, .{});
        errdefer eng.deinit();
        const ch = try eng.produceClientHello(&.{}, &.{});
        defer a.free(ch);
        // Raw handshake framing (accepted by the server alongside records).
        try sock.writeAll(ch);
        return .{ .sock = sock, .eng = eng, .allocator = a };
    }

    fn deinit(self: *MtlsScript) void {
        self.eng.deinit();
        self.sock.close();
    }

    fn readRecord(self: *MtlsScript) !struct { typ: u8, body: []u8 } {
        var hdr: [5]u8 = undefined;
        var have: usize = 0;
        while (have < 5) {
            const n = try self.sock.read(hdr[have..]);
            if (n == 0) return error.TlsHandshakeFailed;
            have += n;
        }
        const len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
        if (len > record_mod.maxRecordWire) return error.TlsHandshakeFailed;
        const body = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(body);
        var got: usize = 0;
        while (got < len) {
            const n = try self.sock.read(body[got..]);
            if (n == 0) return error.TlsHandshakeFailed;
            got += n;
        }
        return .{ .typ = hdr[0], .body = body };
    }

    /// Reads the server flight (SH plaintext, CCS, then handshake records),
    /// processes it through the engine, and stops after server Finished.
    fn readServerFlight(self: *MtlsScript) !void {
        var hs_buf = std.ArrayList(u8).empty;
        defer hs_buf.deinit(self.allocator);
        var saw_fin = false;
        while (!saw_fin) {
            const rec = try self.readRecord();
            defer self.allocator.free(rec.body);
            if (rec.typ == @intFromEnum(record_mod.ContentType.change_cipher_spec)) continue;
            if (rec.typ == @intFromEnum(record_mod.ContentType.handshake)) {
                // Plaintext ServerHello (first flight message).
                try self.eng.processServerHello(rec.body);
                continue;
            }
            if (rec.typ != @intFromEnum(record_mod.ContentType.application_data)) return error.TlsHandshakeFailed;
            const hs_keys = self.eng.hsKeys orelse return error.TlsHandshakeFailed;
            var wire = std.ArrayList(u8).empty;
            defer wire.deinit(self.allocator);
            try wire.appendSlice(self.allocator, &.{ rec.typ, 0x03, 0x03 });
            var lb: [2]u8 = undefined;
            std.mem.writeInt(u16, &lb, @intCast(rec.body.len), .big);
            try wire.appendSlice(self.allocator, &lb);
            try wire.appendSlice(self.allocator, rec.body);
            var plain_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = try record_mod.decodeRecord(
                wire.items,
                &plain_buf,
                self.hs_rx_seq,
                hs_keys.serverKeySlice(),
                &hs_keys.serverIv,
                hs_keys.cipher,
            );
            self.hs_rx_seq += 1;
            if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
            try hs_buf.appendSlice(self.allocator, dec.plaintext);
            // Dispatch complete handshake messages in order.
            while (true) {
                if (hs_buf.items.len < 4) break;
                const t = hs_buf.items[0];
                const blen: usize = (@as(usize, hs_buf.items[1]) << 16) | (@as(usize, hs_buf.items[2]) << 8) | hs_buf.items[3];
                if (hs_buf.items.len < 4 + blen) break;
                const msg = hs_buf.items[0 .. 4 + blen];
                const ee = @intFromEnum(handshake_mod.HandshakeType.encrypted_extensions);
                const cr = @intFromEnum(handshake_mod.HandshakeType.certificate_request);
                const cert = @intFromEnum(handshake_mod.HandshakeType.certificate);
                const cv = @intFromEnum(handshake_mod.HandshakeType.certificate_verify);
                const fin = @intFromEnum(handshake_mod.HandshakeType.finished);
                if (t == ee) {
                    try self.eng.processEncryptedExtensions(msg);
                } else if (t == cr) {
                    try self.eng.processCertificateRequest(msg);
                } else if (t == cert) {
                    try self.eng.processCertificate(msg);
                } else if (t == cv) {
                    try self.eng.processCertificateVerify(msg);
                } else if (t == fin) {
                    try self.eng.processFinished(msg);
                    saw_fin = true;
                } else return error.TlsHandshakeFailed;
                // Drop the consumed prefix.
                const rest = hs_buf.items.len - (4 + blen);
                std.mem.copyForwards(u8, hs_buf.items[0..rest], hs_buf.items[4 + blen ..]);
                hs_buf.items.len = rest;
            }
        }
    }

    fn sendHandshake(self: *MtlsScript, msg: []const u8) !void {
        const hs_keys = self.eng.hsKeys orelse return error.TlsHandshakeFailed;
        const enc = try record_mod.encodeRecord(
            .handshake,
            msg,
            self.hs_tx_seq,
            hs_keys.clientKeySlice(),
            &hs_keys.clientIv,
            hs_keys.cipher,
        );
        self.hs_tx_seq += 1;
        try self.sock.writeAll(enc.bytes[0..enc.len]);
    }

    /// Sends the client flight: Certificate (+ CV when non-empty) + Finished.
    fn sendClientFlight(self: *MtlsScript, ders: []const []const u8, key_pem: ?[]const u8) !void {
        const cert = try self.eng.produceClientCertificate(ders);
        defer self.allocator.free(cert);
        try self.sendHandshake(cert);
        if (ders.len > 0) {
            const cv = try self.eng.produceClientCertificateVerify(key_pem.?);
            defer self.allocator.free(cv);
            try self.sendHandshake(cv);
        }
        const fin = try self.eng.produceClientFinished();
        defer self.allocator.free(fin);
        try self.sendHandshake(fin);
    }

    /// Application-data ping under 1-RTT keys; returns the peer reply.
    fn appPing(self: *MtlsScript, send_text: []const u8) ![]u8 {
        const ap = self.eng.apKeys orelse return error.TlsHandshakeFailed;
        const enc = try record_mod.encodeRecord(
            .application_data,
            send_text,
            self.ap_tx_seq,
            ap.clientKeySlice(),
            &ap.clientIv,
            ap.cipher,
        );
        self.ap_tx_seq += 1;
        try self.sock.writeAll(enc.bytes[0..enc.len]);

        const rec = try self.readRecord();
        defer self.allocator.free(rec.body);
        if (rec.typ != @intFromEnum(record_mod.ContentType.application_data)) return error.TlsHandshakeFailed;
        var wire = std.ArrayList(u8).empty;
        defer wire.deinit(self.allocator);
        try wire.appendSlice(self.allocator, &.{ rec.typ, 0x03, 0x03 });
        var lb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lb, @intCast(rec.body.len), .big);
        try wire.appendSlice(self.allocator, &lb);
        try wire.appendSlice(self.allocator, rec.body);
        var plain_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
        const dec = try record_mod.decodeRecord(
            wire.items,
            &plain_buf,
            self.ap_rx_seq,
            ap.serverKeySlice(),
            &ap.serverIv,
            ap.cipher,
        );
        self.ap_rx_seq += 1;
        if (dec.contentType != .application_data) return error.TlsHandshakeFailed;
        if (dec.plaintext.len == 0) return error.TlsHandshakeFailed;
        // decodeRecord already strips padding and the trailing content byte.
        return self.allocator.dupe(u8, dec.plaintext);
    }
};

const mtls_cert_pem = @embedFile("testdata/localhost_cert.pem");
const mtls_key_pem = @embedFile("testdata/localhost_key.pem");

fn mtlsTestServer(a: Allocator, auth: config_mod.ClientAuthMode, ca_pem: ?[]const u8) TlsServer {
    return TlsServer.init(.{
        .allocator = a,
        .defaultIdentity = .{ .certChainPem = mtls_cert_pem, .privateKeyPem = mtls_key_pem },
        .clientAuth = auth,
        .clientCaPem = ca_pem,
    });
}

test "mtls required accepts valid client certificate over loopback" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = mtlsTestServer(a, .required, mtls_cert_pem);

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *TlsServer, out: *?anyerror, got: *[32]u8, got_len: *usize) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            var conn = srv.handshake(io2, &sock) catch |e| {
                out.* = e;
                return;
            };
            defer conn.deinit();
            var buf: [64]u8 = undefined;
            const n = conn.read(&buf) catch |e| {
                out.* = e;
                return;
            };
            @memcpy(got[0..n], buf[0..n]);
            got_len.* = n;
            conn.writeAll("mtls-pong") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    var got: [32]u8 = undefined;
    var got_len: usize = 0;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result, &got, &got_len });

    var cli = try MtlsScript.dial(a, ctx.io, port);
    defer cli.deinit();
    try cli.readServerFlight();
    try std.testing.expectEqual(engine_mod.Engine.State.handshakeComplete, cli.eng.state);

    var chain = try cert_mod.parseCertificateChainPem(a, mtls_cert_pem);
    defer chain.deinit();
    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    var ci: usize = 0;
    while (chain.get(ci)) |c| : (ci += 1) {
        try ders.append(a, c.rawDer());
    }
    try cli.sendClientFlight(ders.items, mtls_key_pem);

    const reply = try cli.appPing("mtls-ping");
    defer a.free(reply);
    try std.testing.expectEqualStrings("mtls-pong", reply);

    th.join();
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("mtls-ping", got[0..got_len]);
}

test "mtls required rejects missing client certificate" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = mtlsTestServer(a, .required, mtls_cert_pem);

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *TlsServer, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.handshake(io2, &sock)) |conn| {
                var c = conn;
                c.deinit();
                out.* = error.UnexpectedSuccess;
            } else |e| {
                out.* = e;
            }
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var cli = try MtlsScript.dial(a, ctx.io, port);
    defer cli.deinit();
    try cli.readServerFlight();
    // Empty certificate + Finished, no CertificateVerify.
    try cli.sendClientFlight(&.{}, null);

    th.join();
    try std.testing.expect(result.? == error.ClientCertificateRequired);
}

test "mtls required rejects misconfigured client CA" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const bad_ca = "-----BEGIN CERTIFICATE-----\nbm90LWEtdmFsaWQtY2VydA==\n-----END CERTIFICATE-----\n";
    var server = mtlsTestServer(a, .required, bad_ca);

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *TlsServer, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.handshake(io2, &sock)) |conn| {
                var c = conn;
                c.deinit();
                out.* = error.UnexpectedSuccess;
            } else |e| {
                out.* = e;
            }
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var cli = try MtlsScript.dial(a, ctx.io, port);
    defer cli.deinit();
    try cli.readServerFlight();

    var chain = try cert_mod.parseCertificateChainPem(a, mtls_cert_pem);
    defer chain.deinit();
    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    var ci: usize = 0;
    while (chain.get(ci)) |c| : (ci += 1) {
        try ders.append(a, c.rawDer());
    }
    try cli.sendClientFlight(ders.items, mtls_key_pem);

    th.join();
    try std.testing.expect(result.? == error.ClientCertificateInvalid);
}

test "mtls optional allows missing client certificate" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = mtlsTestServer(a, .optional, mtls_cert_pem);

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *TlsServer, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            var conn = srv.handshake(io2, &sock) catch |e| {
                out.* = e;
                return;
            };
            defer conn.deinit();
            // Drain the client ping first so close() never resets with
            // unread data in the receive buffer.
            var buf: [64]u8 = undefined;
            _ = conn.read(&buf) catch |e| {
                out.* = e;
                return;
            };
            conn.writeAll("opt-ok") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var cli = try MtlsScript.dial(a, ctx.io, port);
    defer cli.deinit();
    try cli.readServerFlight();
    try cli.sendClientFlight(&.{}, null);

    const reply = try cli.appPing("opt-ping");
    defer a.free(reply);
    try std.testing.expectEqualStrings("opt-ok", reply);

    th.join();
    try std.testing.expect(result == null);
}
