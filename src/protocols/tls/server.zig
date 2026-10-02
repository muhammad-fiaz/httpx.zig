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
//! Public entry point: `Server` (see below). It owns allocator, IO,
//! configuration, the validated default identity and mTLS trust for its
//! lifetime and hands out `Connection` values borrowing the peer socket.
//! The handshake engine, records and crypto stay internal.
//!
//! Thread-safety: a `Server` is safe for concurrent `accept` calls.
//! Shared state is immutable after `init`; every handshake uses strictly
//! per-connection state. One connection = one `Connection`, not shared.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

const engineMod = @import("engine.zig");
const handshakeMod = @import("handshake.zig");
const recordMod = @import("record.zig");
const alpnMod = @import("alpn.zig");
const configMod = @import("config.zig");
const sessionMod = @import("session.zig");
const certMod = @import("certificate.zig");
const keyMod = @import("key.zig");
const verifyMod = @import("verify.zig");
const trustStoreMod = @import("trustStore.zig");
const fsMod = @import("../../utils/fs.zig");
const clockMod = @import("../../common/clock.zig");
const addressMod = @import("../../net/address.zig");
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

// TLS server listener

/// SNI-based certificate selector. Maps hostname → certificate identity.
/// Reads a PEM buffer or file path (paths lack a PEM header).
fn loadPemOrFile(allocator: Allocator, pemOrPath: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, pemOrPath, "-----BEGIN") != null) {
        return allocator.dupe(u8, pemOrPath);
    }
    return fsMod.readFileLimited(allocator, pemOrPath, 10 * 1024 * 1024);
}

/// Validates a server identity once at startup: chain parses and the
/// private key parses (fail fast instead of mid-handshake).
fn validateIdentity(allocator: Allocator, certPemOrPath: []const u8, keyPemOrPath: []const u8) !void {
    const certData = try loadPemOrFile(allocator, certPemOrPath);
    defer allocator.free(certData);
    var chain = try certMod.parseCertificateChainPem(allocator, certData);
    defer chain.deinit();
    if (chain.count() == 0) return error.MissingCertificate;
    const keyData = try loadPemOrFile(allocator, keyPemOrPath);
    defer {
        std.crypto.secureZero(u8, keyData);
        allocator.free(keyData);
    }
    const parsedKey = try keyMod.parsePrivateKeyPem(allocator, keyData);
    std.crypto.secureZero(u8, parsedKey.der);
    allocator.free(parsedKey.der);
}

/// Adds CA PEM blocks to a store with structural pre-validation:
/// malformed operator configuration fails closed, never panics downstream.
fn addCaPemChecked(allocator: Allocator, store: *trustStoreMod.TrustStore, caPem: []const u8) !void {
    var searchFrom: usize = 0;
    var blocks: usize = 0;
    while (std.mem.indexOfPos(u8, caPem, searchFrom, "-----BEGIN CERTIFICATE-----")) |idx| {
        const der = certMod.decodePemBlock(allocator, caPem[idx..], "CERTIFICATE") catch return error.ClientCertificateInvalid;
        defer allocator.free(der);
        if (!certMod.checkDerStructure(der)) return error.ClientCertificateInvalid;
        blocks += 1;
        searchFrom = idx + 26;
    }
    if (blocks == 0) return error.ClientCertificateInvalid;
    store.addCertPem(caPem) catch return error.ClientCertificateInvalid;
}

/// TLS server owner: allocator, IO, configuration, validated default
/// identity and mTLS trust, retained for the server's lifetime.
///
/// The default identity is parsed and validated once here (fail fast at
/// startup, never mid-handshake); per-handshake flight building reuses
/// the configured PEMs. Safe for concurrent `accept`: shared state is
/// immutable after `init`.
pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    /// mTLS client-CA trust, parsed once at `init` when client auth is
    /// enabled with `clientCaPem`. Borrowed by handshakes.
    clientTrust: ?trustStoreMod.TrustStore = null,
    /// Bounded replay defense cache for 0-RTT early data.
    replayCache: ?sessionMod.ReplayCache = null,

    pub const CertSelector = struct {
        ctx: ?*anyopaque = null,
        select: *const fn (ctx: ?*anyopaque, hostname: ?[]const u8) ?CertIdentity,
    };

    pub const CertIdentity = struct {
        certChainPem: []const u8,
        privateKeyPem: []const u8,
    };

    /// Configuration for the TLS server.
    pub const Config = struct {
        /// Default certificate (PEM string or file path). Used when SNI
        /// doesn't match any selector identity. Both must be set for the
        /// server to complete handshakes (validated once at `init`).
        certificatePem: ?[]const u8 = null,
        /// Default private key (PEM string or file path).
        privateKeyPem: ?[]const u8 = null,

        /// SNI certificate selector (optional; falls back to the default
        /// identity above).
        certSelector: ?CertSelector = null,

        /// ALPN protocols in server preference order (TCP: no h3, QUIC
        /// handles h3 separately).
        alpn: []const alpnMod.Protocol = &alpnMod.DEFAULT_TCP_PREFERENCE,

        /// Mutual TLS mode: request and enforce client certificates.
        clientAuth: configMod.ClientAuthMode = .disabled,
        /// PEM bundle (or file path) of CAs trusted for client
        /// certificates. Parsed once at `init` when mTLS is enabled.
        clientCaPem: ?[]const u8 = null,
        /// Ticket keys for TLS 1.3 session resumption (stateless NST issue
        /// + PSK-accept on offer). Null disables resumption entirely: no
        /// tickets are sent and PSK offers fall back to full handshakes.
        ticketKeys: ?sessionMod.TicketKeys = null,
        /// Lifetime (seconds) stamped into issued session tickets.
        ticketLifetimeSecs: u32 = 7200,
        /// Maximum early data allowance in bytes. 0 disables early data (safe default).
        maxEarlyData: u32 = 0,
        /// Replay window capacity for bounded replay defense.
        replayWindowCapacity: u32 = 1024,
        /// Whether the listener accepts cleartext HTTP on the TLS port
        /// (dispatch behavior, not cryptography). Defaults to false
        /// (strict HTTPS: plain HTTP gets 400 Bad Request).
        allowPlainHttp: bool = false,
    };

    pub const Connection = struct {
        socket: *tcp.Socket,
        allocator: Allocator,

        /// Negotiated ALPN protocol.
        alpn: ?alpnMod.Protocol,

        /// SNI hostname from ClientHello, if any.
        sni: ?[]const u8,

        /// True when this connection resumed via PSK (abbreviated flight:
        /// no Certificate/CertificateVerify was exchanged).
        resumed: bool = false,

        /// Application traffic keys for encrypt/decrypt.
        appKeys: engineMod.DerivedKeys,

        /// Sequence numbers for application records.
        txSeq: u64 = 0,
        rxSeq: u64 = 0,

        /// Write buffer for outgoing encrypted records.
        writeBuf: []u8,

        /// Read buffer for incoming encrypted records.
        readBuf: []u8,

        /// Leftover plaintext from a previous read (partial record).
        /// Owned copy in `leftoverBuf` — never a slice of a stack buffer.
        leftoverBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined,
        leftoverLen: usize = 0,
        leftover: []const u8 = &.{},

        pub fn deinit(self: *Connection) void {
            self.allocator.free(self.writeBuf);
            self.allocator.free(self.readBuf);
            if (self.sni) |hostname| self.allocator.free(hostname);
        }

        /// Encrypt and send application data.
        pub fn writeAll(self: *Connection, plaintext: []const u8) Error!void {
            var offset: usize = 0;
            while (offset < plaintext.len) {
                const chunkLen = @min(plaintext.len - offset, recordMod.maxRecordPlaintext);
                const encoded = try recordMod.encodeRecord(
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
        pub fn read(self: *Connection, buf: []u8) Error!usize {
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
            var hdrBuf: [5]u8 = undefined;
            var totalRead: usize = 0;
            while (totalRead < 5) {
                const n = self.socket.read(hdrBuf[totalRead..]) catch return error.IoError;
                if (n == 0) return 0; // peer closed
                totalRead += n;
            }

            // TLS 1.3 records use the TLS 1.2 legacy version on the wire.
            if (hdrBuf[1] != 0x03 or hdrBuf[2] != 0x03) return error.TlsRecordError;

            const recordLen: usize = (@as(usize, hdrBuf[3]) << 8) | hdrBuf[4];
            const tagLen = self.appKeys.cipher.tagLen();
            if (recordLen < tagLen or
                recordLen > recordMod.maxRecordPlaintext + 1 + tagLen)
            {
                return error.TlsRecordError;
            }

            // Read record body
            var wireBuf: [recordMod.maxRecordWire]u8 = undefined;
            @memcpy(wireBuf[0..5], &hdrBuf);
            totalRead = 0;
            while (totalRead < recordLen) {
                const n = self.socket.read(wireBuf[5 + totalRead ..][0 .. recordLen - totalRead]) catch return error.IoError;
                if (n == 0) return error.TlsRecordError;
                totalRead += n;
            }

            // Check content type
            const contentTypeByte = wireBuf[0];
            if (contentTypeByte != @intFromEnum(recordMod.ContentType.application_data)) {
                if (contentTypeByte == @intFromEnum(recordMod.ContentType.alert)) {
                    // Try to decrypt to read alert description
                    var decryptBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
                    const result = recordMod.decodeRecord(
                        wireBuf[0..][0 .. 5 + recordLen],
                        &decryptBuf,
                        self.rxSeq,
                        self.appKeys.clientKeySlice(),
                        &self.appKeys.clientIv,
                        self.appKeys.cipher,
                    ) catch return error.TlsFatalAlert;
                    if (result.plaintext.len >= 2) {
                        const alert = handshakeMod.Alert.decode(.{ result.plaintext[0], result.plaintext[1] });
                        if (alert.description == .closeNotify) return error.TlsCloseNotify;
                    }
                    return error.TlsFatalAlert;
                }
                return error.TlsRecordError;
            }

            // Decrypt application record
            var decryptBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
            const result = recordMod.decodeRecord(
                wireBuf[0..][0 .. 5 + recordLen],
                &decryptBuf,
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

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Server {
        var self = Server{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
        errdefer self.deinit();
        // Fail fast: a misconfigured identity or CA bundle surfaces here,
        // not on the first inbound connection.
        if (config.certificatePem != null and config.privateKeyPem != null) {
            try validateIdentity(allocator, config.certificatePem.?, config.privateKeyPem.?);
        }
        if (config.clientAuth != .disabled) {
            if (config.clientCaPem) |pem| {
                var store = trustStoreMod.TrustStore.init(allocator, io);
                errdefer store.deinit();
                try addCaPemChecked(allocator, &store, pem);
                if (store.count() == 0) return error.ClientCertificateInvalid;
                self.clientTrust = store;
            }
        }
        if (config.maxEarlyData > 0) {
            self.replayCache = sessionMod.ReplayCache.init(allocator, config.replayWindowCapacity);
        }
        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.clientTrust) |*store| {
            store.deinit();
            self.clientTrust = null;
        }
        if (self.replayCache) |*rc| {
            rc.deinit();
            self.replayCache = null;
        }
        self.* = undefined;
    }

    /// Accept a TLS 1.3 connection on an already-accepted TCP socket.
    /// Returns an owned `Connection` borrowing `socket`.
    ///
    /// Reads the ClientHello, extracts SNI, performs ALPN negotiation,
    /// derives keys via the TLS 1.3 key schedule, and sends the full server
    /// flight (ServerHello + EncryptedExtensions + Certificate +
    /// CertificateVerify + Finished) as plaintext records.
    pub fn accept(self: *Server, socket: *tcp.Socket) !Connection {
        return self.acceptBuffered(socket, &.{});
    }

    /// Accept with pre-read bytes from an initial buffer peek.
    pub fn acceptBuffered(self: *Server, socket: *tcp.Socket, initial: []const u8) !Connection {
        const a = self.allocator;

        var engine = engineMod.Engine.initServer(self.io, a, .{});
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
        if (!engineMod.Engine.clientHelloHasShare(chBody)) {
            const hrr = try engine.produceHelloRetryRequest();
            defer a.free(hrr);
            try writePlaintextHandshakeRecord(socket, hrr);
            hello = try readHelloFrame(socket, &readBuf, &.{});
            try engine.processClientHello(readBuf[hello.offset..][0 .. 4 + hello.bodyLen]);
            chBody = readBuf[hello.offset + 4 ..][0..hello.bodyLen];
        }

        // Parse the (final) ClientHello body for SNI and ALPN.
        var parsedCh = try parseClientHelloExtensions(a, chBody);
        defer parsedCh.alpnProtocols.deinit(a);

        // PSK resumption offer: verified silently, selected or ignored.
        // Never fails the handshake — worst case is a full handshake.
        // Skipped under mutual TLS: an abbreviated flight carries no
        // CertificateRequest, so resumed connections would bypass client
        // certificate authentication entirely.
        const nowMs: u64 = @intCast(clockMod.millisNow());
        const fullCh = readBuf[hello.offset..][0 .. 4 + hello.bodyLen];
        if (self.config.clientAuth == .disabled) {
            if (self.config.maxEarlyData > 0) {
                engine.maxEarlyData = self.config.maxEarlyData;
                if (self.replayCache) |*rc| {
                    engine.replayCache = rc;
                }
            }
            _ = engine.selectPsk(fullCh, nowMs);
        }

        // Store SNI in engine
        if (parsedCh.sni) |sni| {
            engine.negotiatedAlpn = null; // will be set during ALPN processing
            _ = sni; // stored via engine
        }

        // Select certificate
        const identity = self.resolveIdentity(parsedCh.sni) orelse return error.MissingCertificate;
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
            self.config.alpn,
            parsedCh.alpnProtocols.items,
            null, // TCP never carries QUIC transport parameters
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
        var hsSeq: u64 = 0;
        try writeEncryptedHandshakeRecord(socket, flight.encryptedExtensions, hsKeys, &hsSeq);
        if (flight.certificateRequest) |cr| {
            try writeEncryptedHandshakeRecord(socket, cr, hsKeys, &hsSeq);
        }
        // Abbreviated (PSK-resumed) flights carry no Certificate or
        // CertificateVerify: empty flight parts are never sent.
        if (flight.certificate.len > 0) {
            try writeEncryptedHandshakeRecord(socket, flight.certificate, hsKeys, &hsSeq);
        }
        if (flight.certificateVerify.len > 0) {
            try writeEncryptedHandshakeRecord(socket, flight.certificateVerify, hsKeys, &hsSeq);
        }
        try writeEncryptedHandshakeRecord(socket, flight.finished, hsKeys, &hsSeq);

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
            const finKeys = engine.hsKeys orelse return error.TlsHandshakeFailed;
            if (self.config.clientAuth != .disabled and engine.resumptionPsk == null) {
                try self.verifyClientFlight(socket, &engine, finKeys);
            } else {
                var finishedOk = false;
                while (!finishedOk) {
                    var hdr: [5]u8 = undefined;
                    var have: usize = 0;
                    while (have < 5) {
                        const n = socket.read(hdr[have..]) catch return error.IoError;
                        if (n == 0) return error.TlsHandshakeFailed;
                        have += n;
                    }
                    if (hdr[0] == @intFromEnum(recordMod.ContentType.change_cipher_spec)) {
                        const skipLen: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                        var skipped: usize = 0;
                        var tmp: [64]u8 = undefined;
                        while (skipped < skipLen) {
                            const want = @min(tmp.len, skipLen - skipped);
                            const n = socket.read(tmp[0..want]) catch return error.IoError;
                            if (n == 0) return error.TlsHandshakeFailed;
                            skipped += n;
                        }
                        continue;
                    }
                    if (hdr[0] != @intFromEnum(recordMod.ContentType.application_data)) {
                        return error.TlsHandshakeFailed;
                    }
                    const recLen: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                    if (recLen < finKeys.cipher.tagLen() or
                        recLen > recordMod.maxRecordPlaintext + 1 + finKeys.cipher.tagLen())
                    {
                        return error.TlsHandshakeFailed;
                    }
                    var wire: [recordMod.maxRecordWire]u8 = undefined;
                    @memcpy(wire[0..5], &hdr);
                    var got: usize = 0;
                    while (got < recLen) {
                        const n = socket.read(wire[5 + got ..][0 .. recLen - got]) catch return error.IoError;
                        if (n == 0) return error.TlsHandshakeFailed;
                        got += n;
                    }
                    var plainBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
                    const dec = recordMod.decodeRecord(
                        wire[0..][0 .. 5 + recLen],
                        &plainBuf,
                        0,
                        finKeys.clientKeySlice(),
                        &finKeys.clientIv,
                        finKeys.cipher,
                    ) catch return error.TlsHandshakeFailed;
                    if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
                    try engine.verifyClientFinished(dec.plaintext);
                    finishedOk = true;
                }
            }
        }

        // Session ticket (RFC 8446 Section 4.6.1): issued exactly once per
        // full handshake when ticket keys are configured — never on
        // abbreviated handshakes (the client already holds a ticket).
        // Carries early-data extension with maxEarlyData when configured.
        // The ticket record uses application traffic keys at sequence 0,
        // so the returned connection starts its application sequence at 1.
        var apTxSeq: u64 = 0;
        if (self.config.ticketKeys != null and engine.resumptionPsk == null) {
            const master = try engine.deriveResumptionMaster();
            const nstMsg = try engine.produceNewSessionTicket(
                master,
                engine.selectedSuite,
                self.config.ticketLifetimeSecs,
                nowMs,
            );
            defer a.free(nstMsg);
            const nstEnc = try recordMod.encodeRecord(
                .handshake,
                nstMsg,
                apTxSeq,
                apKeys.serverKeySlice(),
                &apKeys.serverIv,
                apKeys.cipher,
            );
            apTxSeq += 1;
            socket.writeAll(nstEnc.bytes[0..nstEnc.len]) catch return error.IoError;
        }

        // Allocate read/write buffers for application records
        const writeBuf = try a.alloc(u8, recordMod.maxRecordWire);
        errdefer a.free(writeBuf);
        const readBufApp = try a.alloc(u8, recordMod.maxRecordWire);
        errdefer a.free(readBufApp);

        const sniCopy = if (parsedCh.sni) |hostname| try a.dupe(u8, hostname) else null;
        errdefer if (sniCopy) |hostname| a.free(hostname);

        return .{
            .socket = socket,
            .allocator = a,
            .alpn = if (engine.negotiatedAlpn) |aName| alpnMod.Protocol.fromWire(aName) else null,
            .sni = sniCopy,
            .appKeys = apKeys,
            .resumed = engine.resumptionPsk != null,
            .txSeq = apTxSeq,
            .writeBuf = writeBuf,
            .readBuf = readBufApp,
        };
    }

    /// Verifies the mutual-TLS client flight: Certificate [+ CertificateVerify]
    /// + Finished, decrypted from handshake records and checked against the
    /// transcript. Policy: `.required` rejects a missing certificate; any
    /// presented chain must anchor in `clientCaPem` with a valid P-256
    /// signature; Finished always binds the transcript. Fails closed.
    fn verifyClientFlight(
        self: *Server,
        socket: *tcp.Socket,
        engine: *engineMod.Engine,
        hsKeys: engineMod.DerivedKeys,
    ) !void {
        const a = self.allocator;
        var hsBuf = std.ArrayList(u8).empty;
        defer hsBuf.deinit(a);

        var split: ?ClientFlightSplit = null;
        var guard: usize = 0;
        var rxSeq: u64 = 0;
        while (split == null) {
            guard += 1;
            if (guard > 32 or hsBuf.items.len > 1 << 20) return error.TlsHandshakeFailed;
            if (hsBuf.items.len >= 1 and hsBuf.items[0] != @intFromEnum(handshakeMod.HandshakeType.certificate)) {
                return error.TlsHandshakeFailed;
            }
            try readClientHandshakeRecord(socket, hsKeys, &rxSeq, &hsBuf, a);
            split = splitClientFlight(hsBuf.items);
        }
        const sp = split.?;

        var presented = try engine.processClientCertificate(hsBuf.items[sp.certOff..sp.certEnd]);
        defer presented.deinit();
        if (presented.ders.len == 0) {
            if (self.config.clientAuth == .required) return error.ClientCertificateRequired;
        } else {
            // Trust was parsed and validated once at init; a server that
            // requests client certificates without trust fails closed here.
            // The store is read-only after init (concurrent verifies share it).
            const store = if (self.clientTrust) |*s| s else return error.ClientCertificateInvalid;
            // Borrowed view: ownership of the DER bytes stays with `presented`.
            const chain = certMod.CertificateChain{ .certs = presented.ders, .allocator = a };
            const nowSec: i64 = @divFloor(clockMod.millisNow(), 1000);
            verifyMod.verifyCertificateChain(chain, store, null, nowSec) catch return error.ClientCertificateInvalid;
            try engine.processClientCertificateVerify(hsBuf.items[sp.cvOff..sp.cvEnd], presented.ders[0]);
        }
        try engine.verifyClientFinished(hsBuf.items[sp.finOff..sp.finEnd]);
    }

    const ClientFlightSplit = struct {
        certOff: usize,
        certEnd: usize,
        cvOff: usize,
        cvEnd: usize,
        finOff: usize,
        finEnd: usize,
        emptyCert: bool,
    };

    /// Splits a reassembled client flight into Certificate [+ CV] + Finished.
    /// Returns null while more handshake bytes are needed.
    fn splitClientFlight(buf: []const u8) ?ClientFlightSplit {
        const certType = @intFromEnum(handshakeMod.HandshakeType.certificate);
        const cvType = @intFromEnum(handshakeMod.HandshakeType.certificate_verify);
        const finType = @intFromEnum(handshakeMod.HandshakeType.finished);
        if (buf.len < 4 or buf[0] != certType) return null;
        const certLen: usize = (@as(usize, buf[1]) << 16) | (@as(usize, buf[2]) << 8) | buf[3];
        if (buf.len < 4 + certLen) return null;
        const certEnd = 4 + certLen;
        // Empty certificate message: context(1) + list(3) with zero entries.
        const emptyCert = certLen == 4;
        var pos = certEnd;
        var cvOff: usize = 0;
        var cvEnd: usize = 0;
        if (!emptyCert) {
            if (buf.len < pos + 4 or buf[pos] != cvType) return null;
            const cvLen: usize = (@as(usize, buf[pos + 1]) << 16) | (@as(usize, buf[pos + 2]) << 8) | buf[pos + 3];
            if (buf.len < pos + 4 + cvLen) return null;
            cvOff = pos;
            cvEnd = pos + 4 + cvLen;
            pos = cvEnd;
        }
        if (buf.len < pos + 4 or buf[pos] != finType) return null;
        const finLen: usize = (@as(usize, buf[pos + 1]) << 16) | (@as(usize, buf[pos + 2]) << 8) | buf[pos + 3];
        if (buf.len < pos + 4 + finLen) return null;
        return .{
            .certOff = 0,
            .certEnd = certEnd,
            .cvOff = cvOff,
            .cvEnd = cvEnd,
            .finOff = pos,
            .finEnd = pos + 4 + finLen,
            .emptyCert = emptyCert,
        };
    }

    /// Reads one handshake record (skipping middlebox CCS), decrypts it
    /// with the client handshake keys, and appends the plaintext.
    /// Record sequence numbers start at 0 for the first encrypted client
    /// record and increment per record (CCS carries no sequence).
    fn readClientHandshakeRecord(
        socket: *tcp.Socket,
        hsKeys: engineMod.DerivedKeys,
        rxSeq: *u64,
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
            if (hdr[0] == @intFromEnum(recordMod.ContentType.change_cipher_spec)) {
                const skipLen: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
                var skipped: usize = 0;
                var tmp: [64]u8 = undefined;
                while (skipped < skipLen) {
                    const want = @min(tmp.len, skipLen - skipped);
                    const n = socket.read(tmp[0..want]) catch return error.IoError;
                    if (n == 0) return error.TlsHandshakeFailed;
                    skipped += n;
                }
                continue;
            }
            if (hdr[0] != @intFromEnum(recordMod.ContentType.application_data)) {
                return error.TlsHandshakeFailed;
            }
            const recLen: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
            if (recLen < hsKeys.cipher.tagLen() or
                recLen > recordMod.maxRecordPlaintext + 1 + hsKeys.cipher.tagLen())
            {
                return error.TlsHandshakeFailed;
            }
            var wire: [recordMod.maxRecordWire]u8 = undefined;
            @memcpy(wire[0..5], &hdr);
            var got: usize = 0;
            while (got < recLen) {
                const n = socket.read(wire[5 + got ..][0 .. recLen - got]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                got += n;
            }
            var plainBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = recordMod.decodeRecord(
                wire[0..][0 .. 5 + recLen],
                &plainBuf,
                rxSeq.*,
                hsKeys.clientKeySlice(),
                &hsKeys.clientIv,
                hsKeys.cipher,
            ) catch return error.TlsHandshakeFailed;
            rxSeq.* += 1;
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

    fn writeEncryptedHandshakeRecord(socket: *tcp.Socket, message: []const u8, keys: engineMod.DerivedKeys, seq: *u64) !void {
        const encoded = try recordMod.encodeRecord(.handshake, message, seq.*, keys.serverKeySlice(), &keys.serverIv, keys.cipher);
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
        if (buf[0] == @intFromEnum(recordMod.ContentType.handshake)) {
            // Standard framed TLS Record: [0]=0x16, [1..2]=version,
            // [3..4]=recordLen, [5..]=handshake.
            const recordLen = std.mem.readInt(u16, buf[3..5], .big);
            const totalNeeded = 5 + @as(usize, recordLen);
            if (totalNeeded > buf.len) return error.TlsHandshakeFailed;
            while (totalRead < totalNeeded) {
                const n = socket.read(buf[totalRead..]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                totalRead += n;
            }
            if (buf[5] != @intFromEnum(handshakeMod.HandshakeType.client_hello)) {
                return error.TlsHandshakeFailed;
            }
            const bodyLen: u24 = @as(u24, @intCast(buf[6])) << 16 |
                @as(u24, @intCast(buf[7])) << 8 |
                @as(u24, @intCast(buf[8]));
            if (bodyLen > maxHandshakeBody or 5 + 4 + bodyLen > totalRead) return error.TlsHandshakeFailed;
            return .{ .offset = 5, .bodyLen = bodyLen };
        } else if (buf[0] == @intFromEnum(handshakeMod.HandshakeType.client_hello)) {
            // Raw Handshake framing without record layer.
            const bodyLen: u24 = @as(u24, @intCast(buf[1])) << 16 |
                @as(u24, @intCast(buf[2])) << 8 |
                @as(u24, @intCast(buf[3]));
            if (bodyLen > maxHandshakeBody) return error.TlsHandshakeFailed;
            while (totalRead < 4 + bodyLen) {
                const n = socket.read(buf[totalRead..]) catch return error.IoError;
                if (n == 0) return error.TlsHandshakeFailed;
                totalRead += n;
            }
            return .{ .offset = 0, .bodyLen = bodyLen };
        } else {
            return error.TlsHandshakeFailed;
        }
    }

    fn resolveIdentity(self: *const Server, sni: ?[]const u8) ?CertIdentity {
        if (self.config.certSelector) |sel| {
            if (sel.select(sel.ctx, sni)) |id| return id;
        }
        const certPem = self.config.certificatePem orelse return null;
        const keyPem = self.config.privateKeyPem orelse return null;
        return .{ .certChainPem = certPem, .privateKeyPem = keyPem };
    }
};

// ClientHello parsing helpers

const maxHandshakeBody = 1 << 14;

const ParsedClientHello = struct {
    sni: ?[]const u8 = null,
    alpnProtocols: std.ArrayList([]const u8),
};

/// Parse extensions from a ClientHello body to extract SNI and ALPN.
fn parseClientHelloExtensions(allocator: Allocator, body: []const u8) !ParsedClientHello {
    if (body.len < 34) return error.TlsHandshakeFailed;

    // ClientHello body layout (matching our encoder):
    //   [0..2]   clientVersion
    //   [2..34]  random
    //   [34]       legacySessionIdLength (u8)
    //   [35..]     legacySessionId
    //   [...]      cipher suites, compression methods, extensions
    var pos: usize = 34; // skip clientVersion(2) + random(32)

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const sessionIdLen = body[pos];
    pos += 1;
    const sessionEnd = std.math.add(usize, pos, sessionIdLen) catch return error.TlsHandshakeFailed;
    if (sessionEnd > body.len) return error.TlsHandshakeFailed;
    pos += sessionIdLen;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const csLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2 + csLen;

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const compLen = body[pos];
    pos += 1 + compLen;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const extLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2;
    const extEnd = std.math.add(usize, pos, extLen) catch return error.TlsHandshakeFailed;
    if (extEnd > body.len) return error.TlsHandshakeFailed;

    var result = ParsedClientHello{
        .alpnProtocols = std.ArrayList([]const u8).empty,
    };
    errdefer result.alpnProtocols.deinit(allocator);

    while (pos + 4 <= extEnd) {
        const extType = std.mem.readInt(u16, body[pos..][0..2], .big);
        const extDataLen: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
        pos += 4;
        const dataEnd = std.math.add(usize, pos, extDataLen) catch return error.TlsHandshakeFailed;
        if (dataEnd > extEnd) return error.TlsHandshakeFailed;

        if (extType == @intFromEnum(handshakeMod.ExtensionType.server_name)) {
            result.sni = try parseSniExtension(body[pos..][0..extDataLen]);
        } else if (extType == @intFromEnum(handshakeMod.ExtensionType.application_layer_protocol_negotiation)) {
            result.alpnProtocols = try parseAlpnExtension(allocator, body[pos..][0..extDataLen]);
        }

        pos = dataEnd;
    }

    if (pos != extEnd) return error.TlsHandshakeFailed;

    return result;
}

/// Parse the serverName extension to extract the hostname.
fn parseSniExtension(data: []const u8) !?[]const u8 {
    if (data.len < 5) return error.TlsHandshakeFailed;
    // list length (2 bytes), then at least one entry
    const listLen: usize = (@as(usize, data[0]) << 8) | data[1];
    const listEnd = std.math.add(usize, 2, listLen) catch return null;
    if (listLen < 3 or listEnd != data.len) return error.TlsHandshakeFailed;

    // name type (1 byte) + name length (2 bytes)
    const nameType = data[2];
    if (nameType != 0) return error.TlsHandshakeFailed; // only hostName type
    const nameLen: usize = (@as(usize, data[3]) << 8) | data[4];
    const nameEnd = std.math.add(usize, 5, nameLen) catch return null;
    if (nameEnd != listEnd) return error.TlsHandshakeFailed;

    return data[5..][0..nameLen];
}

/// Parse the ALPN extension to extract the list of offered protocol names.
fn parseAlpnExtension(allocator: Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);
    if (data.len < 2) return error.TlsHandshakeFailed;
    const listLen: usize = (@as(usize, data[0]) << 8) | data[1];
    if (listLen != data.len - 2) return error.TlsHandshakeFailed;
    var pos: usize = 2;
    const listEnd = 2 + listLen;
    while (pos < listEnd) {
        if (pos + 1 > listEnd) return error.TlsHandshakeFailed;
        const nameLen = data[pos];
        pos += 1;
        if (nameLen == 0 or pos + nameLen > listEnd) return error.TlsHandshakeFailed;
        try result.append(allocator, data[pos..][0..nameLen]);
        pos += nameLen;
    }
    if (pos != listEnd) return error.TlsHandshakeFailed;
    return result;
}

// Tests

test "tls server handshake processes client hello" {
    const a = std.testing.allocator;

    // Create a client that produces a ClientHello
    var client = engineMod.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
    const ch = try client.produceClientHello(&.{"h2"}, &.{}, null, null);
    defer a.free(ch);

    try std.testing.expectEqual(@as(u8, 0x01), ch[0]);

    // Process it through a server engine
    var serverEngine = engineMod.Engine.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{});
    try serverEngine.processClientHello(ch);
    try std.testing.expectEqual(engineMod.Engine.State.clientHelloReceived, serverEngine.state);
}

test "alpn negotiation in server config" {
    const cfg = Server.Config{};
    try std.testing.expectEqual(@as(usize, 3), cfg.alpn.len);
    try std.testing.expectEqual(alpnMod.Protocol.h2, cfg.alpn[0]);
    try std.testing.expectEqual(alpnMod.Protocol.@"http/1.1", cfg.alpn[1]);
    try std.testing.expectEqual(alpnMod.Protocol.@"http/1.0", cfg.alpn[2]);
}

test "ClientHello SNI parsing" {
    const a = std.testing.allocator;

    var client = engineMod.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
    const ch = try client.produceClientHello(&.{"h2"}, &.{}, "example.com", null);
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
    var eng = engineMod.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
    defer eng.deinit();
    const ch = try eng.produceClientHello(&.{"h2"}, &.{}, null, null);
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

    // No identity and no selector: unusable server by construction.
    var server = try Server.init(a, ctx.io, .{});
    defer server.deinit();

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *Server, out: *anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.acceptBuffered(&sock, &.{})) |conn| {
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
    var clientSock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer clientSock.close();
    var clientEngine = engineMod.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
    defer clientEngine.deinit();
    const ch = try clientEngine.produceClientHello(&.{"http/1.1"}, &.{}, null, null);
    defer a.free(ch);
    try clientSock.writeAll(ch);

    th.join();
    // Fail-fast BEFORE any Certificate/CertificateVerify flight is emitted.
    try std.testing.expect(result == error.MissingCertificate);
}

// Scripted native-TLS client for mutual-TLS loopback tests: drives a real
// engine through record-layer I/O over TCP (no std-TLS client involved,
// since it cannot present client certificates).

const MtlsScript = struct {
    sock: tcp.Socket,
    eng: engineMod.Engine,
    hsRxSeq: u64 = 0,
    hsTxSeq: u64 = 0,
    apTxSeq: u64 = 0,
    apRxSeq: u64 = 0,
    allocator: Allocator,

    fn dial(a: Allocator, io: std.Io, port: u16) !MtlsScript {
        var sock = try tcp.connect(io, "127.0.0.1", port);
        errdefer sock.close();
        var eng = engineMod.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
        errdefer eng.deinit();
        const ch = try eng.produceClientHello(&.{}, &.{}, null, null);
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
        if (len > recordMod.maxRecordWire) return error.TlsHandshakeFailed;
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
        var hsBuf = std.ArrayList(u8).empty;
        defer hsBuf.deinit(self.allocator);
        var sawFin = false;
        while (!sawFin) {
            const rec = try self.readRecord();
            defer self.allocator.free(rec.body);
            if (rec.typ == @intFromEnum(recordMod.ContentType.change_cipher_spec)) continue;
            if (rec.typ == @intFromEnum(recordMod.ContentType.handshake)) {
                // Plaintext ServerHello (first flight message).
                try self.eng.processServerHello(rec.body);
                continue;
            }
            if (rec.typ != @intFromEnum(recordMod.ContentType.application_data)) return error.TlsHandshakeFailed;
            const hsKeys = self.eng.hsKeys orelse return error.TlsHandshakeFailed;
            var wire = std.ArrayList(u8).empty;
            defer wire.deinit(self.allocator);
            try wire.appendSlice(self.allocator, &.{ rec.typ, 0x03, 0x03 });
            var lb: [2]u8 = undefined;
            std.mem.writeInt(u16, &lb, @intCast(rec.body.len), .big);
            try wire.appendSlice(self.allocator, &lb);
            try wire.appendSlice(self.allocator, rec.body);
            var plainBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = try recordMod.decodeRecord(
                wire.items,
                &plainBuf,
                self.hsRxSeq,
                hsKeys.serverKeySlice(),
                &hsKeys.serverIv,
                hsKeys.cipher,
            );
            self.hsRxSeq += 1;
            if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
            try hsBuf.appendSlice(self.allocator, dec.plaintext);
            // Dispatch complete handshake messages in order.
            while (true) {
                if (hsBuf.items.len < 4) break;
                const t = hsBuf.items[0];
                const blen: usize = (@as(usize, hsBuf.items[1]) << 16) | (@as(usize, hsBuf.items[2]) << 8) | hsBuf.items[3];
                if (hsBuf.items.len < 4 + blen) break;
                const msg = hsBuf.items[0 .. 4 + blen];
                const ee = @intFromEnum(handshakeMod.HandshakeType.encrypted_extensions);
                const cr = @intFromEnum(handshakeMod.HandshakeType.certificate_request);
                const cert = @intFromEnum(handshakeMod.HandshakeType.certificate);
                const cv = @intFromEnum(handshakeMod.HandshakeType.certificate_verify);
                const fin = @intFromEnum(handshakeMod.HandshakeType.finished);
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
                    sawFin = true;
                } else return error.TlsHandshakeFailed;
                // Drop the consumed prefix.
                const rest = hsBuf.items.len - (4 + blen);
                std.mem.copyForwards(u8, hsBuf.items[0..rest], hsBuf.items[4 + blen ..]);
                hsBuf.items.len = rest;
            }
        }
    }

    fn sendHandshake(self: *MtlsScript, msg: []const u8) !void {
        const hsKeys = self.eng.hsKeys orelse return error.TlsHandshakeFailed;
        const enc = try recordMod.encodeRecord(
            .handshake,
            msg,
            self.hsTxSeq,
            hsKeys.clientKeySlice(),
            &hsKeys.clientIv,
            hsKeys.cipher,
        );
        self.hsTxSeq += 1;
        try self.sock.writeAll(enc.bytes[0..enc.len]);
    }

    /// Sends the client flight: Certificate (+ CV when non-empty) + Finished.
    fn sendClientFlight(self: *MtlsScript, ders: []const []const u8, keyPem: ?[]const u8) !void {
        const cert = try self.eng.produceClientCertificate(ders);
        defer self.allocator.free(cert);
        try self.sendHandshake(cert);
        if (ders.len > 0) {
            const cv = try self.eng.produceClientCertificateVerify(keyPem.?);
            defer self.allocator.free(cv);
            try self.sendHandshake(cv);
        }
        const fin = try self.eng.produceClientFinished();
        defer self.allocator.free(fin);
        try self.sendHandshake(fin);
    }

    /// Application-data ping under 1-RTT keys; returns the peer reply.
    fn appPing(self: *MtlsScript, sendText: []const u8) ![]u8 {
        const ap = self.eng.apKeys orelse return error.TlsHandshakeFailed;
        const enc = try recordMod.encodeRecord(
            .application_data,
            sendText,
            self.apTxSeq,
            ap.clientKeySlice(),
            &ap.clientIv,
            ap.cipher,
        );
        self.apTxSeq += 1;
        try self.sock.writeAll(enc.bytes[0..enc.len]);

        const rec = try self.readRecord();
        defer self.allocator.free(rec.body);
        if (rec.typ != @intFromEnum(recordMod.ContentType.application_data)) return error.TlsHandshakeFailed;
        var wire = std.ArrayList(u8).empty;
        defer wire.deinit(self.allocator);
        try wire.appendSlice(self.allocator, &.{ rec.typ, 0x03, 0x03 });
        var lb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lb, @intCast(rec.body.len), .big);
        try wire.appendSlice(self.allocator, &lb);
        try wire.appendSlice(self.allocator, rec.body);
        var plainBuf: [recordMod.maxRecordPlaintext + 1]u8 = undefined;
        const dec = try recordMod.decodeRecord(
            wire.items,
            &plainBuf,
            self.apRxSeq,
            ap.serverKeySlice(),
            &ap.serverIv,
            ap.cipher,
        );
        self.apRxSeq += 1;
        if (dec.contentType != .application_data) return error.TlsHandshakeFailed;
        if (dec.plaintext.len == 0) return error.TlsHandshakeFailed;
        // decodeRecord already strips padding and the trailing content byte.
        return self.allocator.dupe(u8, dec.plaintext);
    }
};

const mtlsCertPem = @embedFile("testdata/localhostCert.pem");
const mtlsKeyPem = @embedFile("testdata/localhostKey.pem");

fn mtlsTestServer(a: Allocator, io: std.Io, auth: configMod.ClientAuthMode, caPem: ?[]const u8) !Server {
    return Server.init(a, io, .{
        .certificatePem = mtlsCertPem,
        .privateKeyPem = mtlsKeyPem,
        .clientAuth = auth,
        .clientCaPem = caPem,
    });
}

test "mtls required accepts valid client certificate over loopback" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = try mtlsTestServer(a, ctx.io, .required, mtlsCertPem);
    defer server.deinit();

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *Server, out: *?anyerror, got: *[32]u8, gotLen: *usize) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            var conn = srv.accept(&sock) catch |e| {
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
            gotLen.* = n;
            conn.writeAll("mtls-pong") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    var got: [32]u8 = undefined;
    var gotLen: usize = 0;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result, &got, &gotLen });

    var cli = try MtlsScript.dial(a, ctx.io, port);
    defer cli.deinit();
    try cli.readServerFlight();
    try std.testing.expectEqual(engineMod.Engine.State.handshakeComplete, cli.eng.state);

    var chain = try certMod.parseCertificateChainPem(a, mtlsCertPem);
    defer chain.deinit();
    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    var ci: usize = 0;
    while (chain.get(ci)) |c| : (ci += 1) {
        try ders.append(a, c.rawDer());
    }
    try cli.sendClientFlight(ders.items, mtlsKeyPem);

    const reply = try cli.appPing("mtls-ping");
    defer a.free(reply);
    try std.testing.expectEqualStrings("mtls-pong", reply);

    th.join();
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("mtls-ping", got[0..gotLen]);
}

test "mtls required rejects missing client certificate" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = try mtlsTestServer(a, ctx.io, .required, mtlsCertPem);
    defer server.deinit();

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *Server, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.accept(&sock)) |conn| {
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

    const badCa = "-----BEGIN CERTIFICATE-----\nbm90LWEtdmFsaWQtY2VydA==\n-----END CERTIFICATE-----\n";
    // Fail fast: a structurally invalid CA bundle is rejected at Server
    // init, never deferred to the first inbound handshake.
    try std.testing.expectError(error.ClientCertificateInvalid, mtlsTestServer(a, ctx.io, .required, badCa));
}
test "mtls optional allows missing client certificate" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = try mtlsTestServer(a, ctx.io, .optional, mtlsCertPem);
    defer server.deinit();

    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *Server, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            var conn = srv.accept(&sock) catch |e| {
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
