//! TLS 1.3 client over TCP with ALPN + chain verification (RFC 8446).
//!
//! Native counterpart to tcp_tls.zig (server): drives the handshake engine
//! as a client, offers ALPN, verifies the server chain against system or
//! custom trust with hostname checks, and exchanges application records.
//! Used by the HTTP client for explicit HTTP/2-over-TLS (and anywhere the
//! std TLS wrapper cannot negotiate ALPN).
//!
//! Thread-safety: one connection = one TlsClientConn, not shared.

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine_mod = @import("engine.zig");
const handshake_mod = @import("handshake.zig");
const record_mod = @import("record.zig");
const alpn_mod = @import("alpn.zig");
const cert_mod = @import("certificate.zig");
const verify_mod = @import("verify.zig");
const trustStore_mod = @import("trust_store.zig");
const clock_mod = @import("../../common/clock.zig");
const address_mod = @import("../../net/address.zig");
const tcp = @import("../../sockets/tcp.zig");
const tcpTls = @import("tcp_tls.zig");
const transport_mod = @import("transport.zig");
const session_mod = @import("session.zig");

// Errors

pub const Error = error{
    TlsHandshakeFailed,
    TlsRecordError,
    CertificateUntrusted,
    CertificateHostMismatch,
    CertificateExpired,
    AlpnNegotiationFailed,
    IoError,
    OutOfMemory,
    BufferTooSmall,
    MissingCertificate,
    /// The server requested a client certificate but none is configured.
    ClientCertificateRequired,
    SequenceOverflow,
    RecordTooLarge,
    InvalidKeyLength,
    InvalidIvLength,
};

// TLS client connection (post-handshake)

/// Represents a completed TLS client connection ready for application data.
pub const TlsClientConn = struct {
    socket: *tcp.Socket,
    allocator: Allocator,

    /// Negotiated ALPN protocol, if the server selected one we offered.
    alpn: ?alpn_mod.Protocol = null,

    /// Application traffic keys for encrypt/decrypt.
    appKeys: engine_mod.DerivedKeys,

    /// Cipher suite negotiated for this connection (binds NST tickets).
    suite: std.crypto.tls.CipherSuite = .AES_128_GCM_SHA256,

    /// True when this connection resumed via PSK (abbreviated flight).
    resumed: bool = false,

    /// Resumption master secret for deriving NST-based PSKs. Present
    /// exactly when the handshake completed; consumed by ticket capture.
    resumptionMaster: ?[32]u8 = null,

    /// Capture post-handshake NewSessionTicket messages into
    /// `pendingSession` (see `takeCapturedSession`).
    captureSession: bool = false,
    /// Owned host binding for captured sessions (null unless capturing).
    sessionHost: ?[]u8 = null,
    /// Latest captured session, replaced by each subsequent ticket.
    /// Owned; transfer with `takeCapturedSession`.
    pendingSession: ?session_mod.ClientSession = null,

    /// Sequence numbers for application records.
    txSeq: u64 = 0,
    rxSeq: u64 = 0,

    /// Write buffer for outgoing encrypted records.
    writeBuf: []u8,

    /// Read buffer for incoming encrypted records.
    readBuf: []u8,

    /// Leftover plaintext from a previous read (partial record).
    leftoverBuf: [record_mod.maxRecordPlaintext + 1]u8 = undefined,
    leftoverLen: usize = 0,
    leftover: []const u8 = &.{},

    pub fn deinit(self: *TlsClientConn) void {
        if (self.pendingSession) |*s| {
            s.deinit(self.allocator);
            self.pendingSession = null;
        }
        if (self.sessionHost) |h| {
            self.allocator.free(h);
            self.sessionHost = null;
        }
        if (self.resumptionMaster) |*m| std.crypto.secureZero(u8, m);
        self.allocator.free(self.writeBuf);
        self.allocator.free(self.readBuf);
    }

    /// Takes ownership of the latest captured resumption session, if any.
    /// Returns null when capture is disabled or no ticket arrived yet.
    /// Caller owns the result and must `deinit` it with an allocator.
    pub fn takeCapturedSession(self: *TlsClientConn) ?session_mod.ClientSession {
        const s = self.pendingSession orelse return null;
        self.pendingSession = null;
        return s;
    }

    /// Encrypt and send application data.
    pub fn writeAll(self: *TlsClientConn, plaintext: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < plaintext.len) {
            const chunkLen = @min(plaintext.len - offset, record_mod.maxRecordPlaintext);
            const encoded = try record_mod.encodeRecord(
                .application_data,
                plaintext[offset..][0..chunkLen],
                self.txSeq,
                self.appKeys.clientKeySlice(),
                &self.appKeys.clientIv,
                self.appKeys.cipher,
            );
            self.socket.writeAll(encoded.bytes[0..encoded.len]) catch return error.IoError;
            self.txSeq +%= 1;
            offset += chunkLen;
        }
    }

    /// Read and decrypt one record worth of application data.
    ///
    /// Post-handshake handshake records (NewSessionTicket) are consumed
    /// transparently when capture is enabled: the ticket is stored and
    /// reading continues with the next record, so callers only ever see
    /// application bytes. Any other post-handshake handshake content
    /// (e.g. KeyUpdate, unimplemented) fails loudly instead of leaking
    /// handshake plaintext as application data.
    pub fn read(self: *TlsClientConn, buf: []u8) Error!usize {
        if (self.leftoverLen > 0) {
            const n = @min(self.leftoverLen, buf.len);
            @memcpy(buf[0..n], self.leftoverBuf[0..n]);
            const remain = self.leftoverLen - n;
            if (remain > 0) std.mem.copyForwards(u8, self.leftoverBuf[0..remain], self.leftoverBuf[n..][0..remain]);
            self.leftoverLen = remain;
            self.leftover = self.leftoverBuf[0..self.leftoverLen];
            return n;
        }

        while (true) {
            var hdr_buf: [5]u8 = undefined;
            var totalRead: usize = 0;
            while (totalRead < 5) {
                const n = self.socket.read(hdr_buf[totalRead..]) catch return error.IoError;
                if (n == 0) return 0; // peer closed
                totalRead += n;
            }
            if (hdr_buf[1] != 0x03 or hdr_buf[2] != 0x03) return error.TlsRecordError;

            const record_len: usize = (@as(usize, hdr_buf[3]) << 8) | hdr_buf[4];
            const tag_len = self.appKeys.cipher.tagLen();
            if (record_len < tag_len or
                record_len > record_mod.maxRecordPlaintext + 1 + tag_len)
            {
                return error.TlsRecordError;
            }

            var wire_buf: [record_mod.maxRecordWire]u8 = undefined;
            @memcpy(wire_buf[0..5], &hdr_buf);
            totalRead = 0;
            while (totalRead < record_len) {
                const n = self.socket.read(wire_buf[5 + totalRead ..][0 .. record_len - totalRead]) catch return error.IoError;
                if (n == 0) return error.TlsRecordError;
                totalRead += n;
            }

            const contentTypeByte = wire_buf[0];
            if (contentTypeByte != @intFromEnum(record_mod.ContentType.application_data)) {
                return error.TlsRecordError;
            }

            var decrypt_buf: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
            const result = record_mod.decodeRecord(
                wire_buf[0..][0 .. 5 + record_len],
                &decrypt_buf,
                self.rxSeq,
                self.appKeys.serverKeySlice(),
                &self.appKeys.serverIv,
                self.appKeys.cipher,
            ) catch return error.TlsRecordError;
            self.rxSeq +%= 1;

            if (result.contentType == .handshake) {
                // Post-handshake handshake message: capture NST tickets,
                // reject everything else. The rx sequence already advanced,
                // so continuing with the next record stays in sync.
                if (!self.captureSession) return error.TlsRecordError;
                try self.captureTicketRecord(result.plaintext);
                continue;
            }

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
    }

    /// Captures one post-handshake NewSessionTicket record's plaintext
    /// (full handshake message: type 4 + body, single record). Replaces
    /// any previously captured session. Unparseable or unusable tickets
    /// fail loudly: a corrupt ticket stream must never silently downgrade
    /// resumption bookkeeping.
    fn captureTicketRecord(self: *TlsClientConn, plaintext: []const u8) Error!void {
        const master = self.resumptionMaster orelse return error.TlsRecordError;
        const host = self.sessionHost orelse return error.TlsRecordError;
        if (plaintext.len < 4) return error.TlsRecordError;
        if (plaintext[0] != @intFromEnum(handshake_mod.HandshakeType.new_session_ticket)) {
            return error.TlsRecordError;
        }
        const nst = handshake_mod.NewSessionTicket.decode(plaintext[4..]) catch return error.TlsRecordError;
        const now_ms: u64 = @intCast(clock_mod.millisNow());
        var fresh = session_mod.clientSessionFromTicket(
            self.allocator,
            nst,
            master,
            self.suite,
            host,
            now_ms,
        ) catch return error.TlsRecordError;
        errdefer fresh.deinit(self.allocator);
        if (self.pendingSession) |*old| old.deinit(self.allocator);
        self.pendingSession = fresh;
    }

    pub fn close(self: *TlsClientConn) void {
        self.socket.close();
    }
};

/// Configuration for the native TLS client.
pub const TlsClientConfig = struct {
    allocator: Allocator,
    /// How the server certificate is verified.
    verify: transport_mod.VerifyMode = .caBundle,
    /// PEM bundle of extra/custom CAs (in addition to system trust when
    /// verify == .caBundle). Null means system trust only.
    caPem: ?[]const u8 = null,
    /// Client certificate chain (PEM) presented when the server requests
    /// mutual TLS. Both must be set; otherwise a CertificateRequest from
    /// the server fails the handshake loudly instead of proceeding
    /// unauthenticated.
    clientCertPem: ?[]const u8 = null,
    /// Client private key (PEM, P-256 ECDSA) for `clientCertPem`.
    clientKeyPem: ?[]const u8 = null,
    /// ALPN protocols offered in preference order.
    alpnProtocols: []const []const u8 = &.{ "h2", "http/1.1" },
    /// Resumption session to offer (single PSK identity). Borrowed for
    /// the handshake only; ownership stays with the caller. The offer is
    /// skipped unless usable for `host` right now.
    session: ?*const session_mod.ClientSession = null,
    /// When true, post-handshake NewSessionTicket messages are captured
    /// into the connection (see `takeCapturedSession`). Zero behavior
    /// change otherwise.
    captureSession: bool = false,

    pub fn init(allocator: Allocator) TlsClientConfig {
        return .{ .allocator = allocator };
    }
};

/// TLS client that performs a native handshake over TCP.
pub const TlsClient = struct {
    config: TlsClientConfig,

    pub fn init(config: TlsClientConfig) TlsClient {
        return .{ .config = config };
    }

    /// Builds CH1 (or CH2 after HelloRetryRequest): a resumption offer
    /// when a usable session is configured, else a plain full-handshake
    /// hello. Owned slice; caller frees.
    fn produceHello(
        self: *TlsClient,
        engine: *engine_mod.Engine,
        sni: ?[]const u8,
        session: ?*const session_mod.ClientSession,
        nowMs: u64,
    ) ![]u8 {
        if (session) |s| {
            return engine.produceClientHelloResumption(self.config.alpnProtocols, &.{}, sni, s, nowMs);
        }
        return engine.produceClientHelloWithSni(self.config.alpnProtocols, &.{}, sni);
    }

    /// Performs the TLS 1.3 client handshake against `host` over an
    /// already-connected TCP socket: SNI (DNS names only), ALPN offer,
    /// optional PSK resumption offer, HelloRetryRequest retry, chain +
    /// hostname verification (skipped on abbreviated resumption, where
    /// the binder authenticates), Finished exchange.
    pub fn handshake(self: *TlsClient, io: std.Io, socket: *tcp.Socket, host: []const u8) !TlsClientConn {
        const a = self.config.allocator;

        var engine = engine_mod.Engine.initClient(a, .{});
        defer engine.deinit();

        // SNI only for DNS names; IP literals carry none.
        var probe = address_mod.Address{ .family = .ip4, .port = 0 };
        const sni: ?[]const u8 = if (probe.parseIp(host)) |_| null else |_| host;
        const now_ms: u64 = @intCast(clock_mod.millisNow());

        // A configured session is offered only when usable for this host
        // right now (host binding + freshness); otherwise a full
        // handshake proceeds exactly as before.
        const offer_session: ?*const session_mod.ClientSession = blk: {
            const s = self.config.session orelse break :blk null;
            if (!s.isUsable(host, now_ms)) break :blk null;
            if (!session_mod.suiteSupportsResumption(s.suite)) break :blk null;
            break :blk s;
        };

        const ch = try self.produceHello(&engine, sni, offer_session, now_ms);
        defer a.free(ch);
        try writePlaintextHandshakeRecord(socket, ch);

        // ServerHello arrives as one plaintext record. A HelloRetryRequest
        // (at most one — the engine aborts a second) restarts the hello
        // with a fresh share; the PSK offer, if any, is re-sent on CH2.
        const sh_msg = try readPlaintextRecord(a, socket);
        defer a.free(sh_msg);
        try engine.processServerHello(sh_msg);
        if (engine.hrrPendingGroup != null) {
            engine.hrrPendingGroup = null;
            const ch2 = try self.produceHello(&engine, sni, offer_session, now_ms);
            defer a.free(ch2);
            try writePlaintextHandshakeRecord(socket, ch2);
            const sh2_msg = try readPlaintextRecord(a, socket);
            defer a.free(sh2_msg);
            try engine.processServerHello(sh2_msg);
            if (engine.hrrPendingGroup != null) return error.TlsHandshakeFailed;
        }

        // Remaining flight arrives encrypted; reassemble handshake messages.
        // The server Certificate DERs are retained for chain verification.
        // A CertificateRequest (if sent) only sets a flag here: the client
        // flight goes out after the server Finished, in one place below.
        var hs_buf = std.ArrayList(u8).empty;
        defer hs_buf.deinit(a);
        var cert_ders = std.ArrayList([]const u8).empty;
        defer {
            for (cert_ders.items) |d| a.free(d);
            cert_ders.deinit(a);
        }
        var hs_rx: u64 = 0;
        var hs_tx: u64 = 0;
        var saw_fin = false;
        var saw_cr = false;
        while (!saw_fin) {
            try readHandshakeRecord(socket, engine.hsKeys orelse return error.TlsHandshakeFailed, &hs_rx, &hs_buf, a);
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
                    try engine.processEncryptedExtensions(msg);
                } else if (t == cr) {
                    try engine.processCertificateRequest(msg);
                    saw_cr = true;
                } else if (t == cert) {
                    // Feeds the transcript AND returns the DERs (single
                    // parse); chain verification happens below.
                    var presented = try engine.processClientCertificate(msg);
                    defer presented.deinit();
                    for (presented.ders) |d| {
                        try cert_ders.append(a, try a.dupe(u8, d));
                    }
                } else if (t == cv) {
                    try engine.processCertificateVerify(msg);
                } else if (t == fin) {
                    try engine.processFinished(msg);
                    saw_fin = true;
                } else return error.TlsHandshakeFailed;
                const rest = hs_buf.items.len - (4 + blen);
                std.mem.copyForwards(u8, hs_buf.items[0..rest], hs_buf.items[4 + blen ..]);
                hs_buf.items.len = rest;
            }
        }

        // Abbreviated (PSK-resumed) flights carry no Certificate: the
        // binder already authenticated the handshake, so chain
        // verification is skipped exactly when the server selected our
        // PSK. Anything else without a certificate fails loudly below.
        const resumed = engine.resumptionPsk != null;
        if (!resumed) {
            try self.verifyServerChain(io, host, cert_ders.items);
        } else if (cert_ders.items.len != 0) {
            return error.TlsHandshakeFailed;
        }

        // Mutual TLS: answer a CertificateRequest before our Finished so
        // the transcript order is Cert/CV/Fin (RFC 8446 Section 4.3.1).
        if (saw_cr) {
            const cert_pem = self.config.clientCertPem orelse return error.ClientCertificateRequired;
            const key_pem = self.config.clientKeyPem orelse return error.ClientCertificateRequired;
            var chain = cert_mod.parseCertificateChainPem(a, cert_pem) catch return error.TlsHandshakeFailed;
            defer chain.deinit();
            var ours = std.ArrayList([]const u8).empty;
            defer ours.deinit(a);
            var ci: usize = 0;
            while (chain.get(ci)) |c| : (ci += 1) {
                try ours.append(a, c.rawDer());
            }
            if (ours.items.len == 0) return error.TlsHandshakeFailed;
            const cert_msg = try engine.produceClientCertificate(ours.items);
            defer a.free(cert_msg);
            try writeHandshakeRecord(socket, engine.hsKeys orelse return error.TlsHandshakeFailed, &hs_tx, cert_msg);
            const cv_msg = try engine.produceClientCertificateVerify(key_pem);
            defer a.free(cv_msg);
            try writeHandshakeRecord(socket, engine.hsKeys orelse return error.TlsHandshakeFailed, &hs_tx, cv_msg);
        }

        // Client Finished completes the handshake.
        const fin = try engine.produceClientFinished();
        defer a.free(fin);
        try writeHandshakeRecord(socket, engine.hsKeys orelse return error.TlsHandshakeFailed, &hs_tx, fin);

        const apKeys = engine.apKeys orelse return error.TlsHandshakeFailed;
        const writeBuf = try a.alloc(u8, record_mod.maxRecordWire);
        errdefer a.free(writeBuf);
        const read_buf_app = try a.alloc(u8, record_mod.maxRecordWire);
        errdefer a.free(read_buf_app);

        // Resumption master for future NST-derived sessions. The client
        // Finished was just fed to the transcript, so this binds the
        // complete handshake exactly per RFC 8446 Section 7.5.
        const resumption_master = engine.deriveResumptionMaster() catch null;
        // Host binding for captured sessions (owned copy — the caller's
        // `host` slice is not retained).
        const host_copy: ?[]u8 = if (self.config.captureSession)
            a.dupe(u8, host) catch null
        else
            null;
        errdefer if (host_copy) |h| a.free(h);

        const alpn = if (engine.negotiatedAlpn) |wire| alpn_mod.Protocol.fromWire(wire) else null;
        return .{
            .socket = socket,
            .allocator = a,
            .alpn = alpn,
            .appKeys = apKeys,
            .suite = engine.selectedSuite,
            .resumed = resumed,
            .resumptionMaster = resumption_master,
            .captureSession = self.config.captureSession,
            .sessionHost = host_copy,
            .writeBuf = writeBuf,
            .readBuf = read_buf_app,
        };
    }

    /// Verifies the server certificate chain against the configured trust
    /// (shared policy with the QUIC native client — see verify.zig).
    fn verifyServerChain(self: *TlsClient, io: std.Io, host: []const u8, ders: []const []const u8) !void {
        try verify_mod.verifyServerChain(
            self.config.allocator,
            io,
            self.config.verify,
            self.config.caPem,
            host,
            ders,
        );
    }

    fn writePlaintextHandshakeRecord(socket: *tcp.Socket, message: []const u8) !void {
        if (message.len > std.math.maxInt(u16)) return error.TlsHandshakeFailed;
        var header: [5]u8 = .{ 0x16, 0x03, 0x03, 0, 0 };
        std.mem.writeInt(u16, header[3..5], @intCast(message.len), .big);
        socket.writeAll(&header) catch return error.IoError;
        socket.writeAll(message) catch return error.IoError;
    }

    fn readPlaintextRecord(a: Allocator, socket: *tcp.Socket) ![]u8 {
        var hdr: [5]u8 = undefined;
        var have: usize = 0;
        while (have < 5) {
            const n = socket.read(hdr[have..]) catch return error.IoError;
            if (n == 0) return error.TlsHandshakeFailed;
            have += n;
        }
        if (hdr[0] != @intFromEnum(record_mod.ContentType.handshake)) return error.TlsHandshakeFailed;
        const len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
        if (len > record_mod.maxRecordPlaintext + 16) return error.TlsHandshakeFailed;
        const body = try a.alloc(u8, len);
        errdefer a.free(body);
        var got: usize = 0;
        while (got < len) {
            const n = socket.read(body[got..]) catch {
                a.free(body);
                return error.IoError;
            };
            if (n == 0) {
                a.free(body);
                return error.TlsHandshakeFailed;
            }
            got += n;
        }
        return body;
    }

    fn writeHandshakeRecord(socket: *tcp.Socket, hs_keys: engine_mod.DerivedKeys, seq: *u64, message: []const u8) !void {
        const enc = record_mod.encodeRecord(
            .handshake,
            message,
            seq.*,
            hs_keys.clientKeySlice(),
            &hs_keys.clientIv,
            hs_keys.cipher,
        ) catch return error.TlsHandshakeFailed;
        seq.* += 1;
        socket.writeAll(enc.bytes[0..enc.len]) catch return error.IoError;
    }

    fn readHandshakeRecord(
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
                hs_keys.serverKeySlice(),
                &hs_keys.serverIv,
                hs_keys.cipher,
            ) catch return error.TlsHandshakeFailed;
            rx_seq.* += 1;
            if (dec.contentType != .handshake) return error.TlsHandshakeFailed;
            try out.appendSlice(a, dec.plaintext);
            return;
        }
    }
};

const test_cert_pem = @embedFile("testdata/localhost_cert.pem");
const test_key_pem = @embedFile("testdata/localhost_key.pem");

fn testServer(a: Allocator) tcpTls.TlsServer {
    return tcpTls.TlsServer.init(.{
        .allocator = a,
        .defaultIdentity = .{ .certChainPem = test_cert_pem, .privateKeyPem = test_key_pem },
    });
}

test "tls resumption over loopback abbreviates the second handshake" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = tcpTls.TlsServer.init(.{
        .allocator = a,
        .defaultIdentity = .{ .certChainPem = test_cert_pem, .privateKeyPem = test_key_pem },
        .ticketKeys = .{ .current = [_]u8{0x5E} ** 32 },
    });
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
            // Two sequential connections: full, then resumed.
            var resumed_flags: [2]bool = .{ false, false };
            for (0..2) |i| {
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
                resumed_flags[i] = conn.resumed;
                var buf: [16]u8 = undefined;
                const n = conn.read(&buf) catch |e| {
                    out.* = e;
                    return;
                };
                if (!std.mem.eql(u8, buf[0..n], "ping")) {
                    out.* = error.BadReply;
                    return;
                }
                conn.writeAll("pong") catch |e| {
                    out.* = e;
                    return;
                };
            }
            if (resumed_flags[0]) {
                out.* = error.UnexpectedResumption;
                return;
            }
            if (!resumed_flags[1]) {
                out.* = error.ResumptionMissing;
                return;
            }
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    // First connection: full handshake, capture the issued ticket while
    // reading application data (the NST arrives ahead of it).
    var sock1 = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock1.close();
    var cli1 = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
        .captureSession = true,
    });
    var conn1 = try cli1.handshake(ctx.io, &sock1, "127.0.0.1");
    defer conn1.deinit();
    try std.testing.expect(!conn1.resumed);
    try conn1.writeAll("ping");
    var buf1: [16]u8 = undefined;
    var got1: usize = 0;
    while (got1 < "pong".len) {
        const n = try conn1.read(buf1[got1..]);
        if (n == 0) break;
        got1 += n;
    }
    try std.testing.expectEqualStrings("pong", buf1[0..got1]);
    var session = conn1.takeCapturedSession() orelse return error.NoTicketCaptured;
    defer session.deinit(a);
    conn1.close();
    sock1.close();

    // Second connection: abbreviated handshake from the captured session.
    var sock2 = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock2.close();
    var cli2 = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
        .session = &session,
    });
    var conn2 = try cli2.handshake(ctx.io, &sock2, "127.0.0.1");
    defer conn2.deinit();
    try std.testing.expect(conn2.resumed);
    try conn2.writeAll("ping");
    var buf2: [16]u8 = undefined;
    var got2: usize = 0;
    while (got2 < "pong".len) {
        const n = try conn2.read(buf2[got2..]);
        if (n == 0) break;
        got2 += n;
    }
    try std.testing.expectEqualStrings("pong", buf2[0..got2]);
    conn2.close();
    sock2.close();

    th.join();
    try std.testing.expect(result == null);
}

test "tls client retries after hello retry request over loopback" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    // Scripted server: HRR unconditionally (to exercise the production
    // client retry path), then a real engine-driven full flight.
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            var eng = engine_mod.Engine.initServer(std.heap.page_allocator, .{});
            defer eng.deinit();
            // CH1 (with share — production client always offers; the HRR
            // here is unconditional to drive the retry path).
            const ch1 = readPlain(io2, &sock) catch |e| {
                out.* = e;
                return;
            };
            defer std.heap.page_allocator.free(ch1);
            eng.processClientHello(ch1) catch |e| {
                out.* = e;
                return;
            };
            const hrr = eng.produceHelloRetryRequest() catch |e| {
                out.* = e;
                return;
            };
            defer std.heap.page_allocator.free(hrr);
            writePlain(io2, &sock, hrr) catch |e| {
                out.* = e;
                return;
            };
            // CH2 then the real flight.
            const ch2 = readPlain(io2, &sock) catch |e| {
                out.* = e;
                return;
            };
            defer std.heap.page_allocator.free(ch2);
            eng.processClientHello(ch2) catch |e| {
                out.* = e;
                return;
            };
            var flight = eng.produceServerFlight(ch2[4..], test_cert_pem, test_key_pem, &.{}, &.{}) catch |e| {
                out.* = e;
                return;
            };
            defer flight.deinit(std.heap.page_allocator);
            writePlain(io2, &sock, flight.serverHello) catch |e| {
                out.* = e;
                return;
            };
            const hs = eng.hsKeys orelse {
                out.* = error.NoKeys;
                return;
            };
            var seq: u64 = 0;
            writeHs(io2, &sock, hs, &seq, flight.encryptedExtensions) catch |e| {
                out.* = e;
                return;
            };
            writeHs(io2, &sock, hs, &seq, flight.certificate) catch |e| {
                out.* = e;
                return;
            };
            writeHs(io2, &sock, hs, &seq, flight.certificateVerify) catch |e| {
                out.* = e;
                return;
            };
            writeHs(io2, &sock, hs, &seq, flight.finished) catch |e| {
                out.* = e;
                return;
            };
            // Client Finished, then app-data echo.
            var hs_buf = std.ArrayList(u8).empty;
            defer hs_buf.deinit(std.heap.page_allocator);
            var rx: u64 = 0;
            readHs(io2, &sock, hs, &rx, &hs_buf) catch |e| {
                out.* = e;
                return;
            };
            eng.verifyClientFinished(hs_buf.items) catch |e| {
                out.* = e;
                return;
            };
            const ap = eng.apKeys orelse {
                out.* = error.NoKeys;
                return;
            };
            var app_buf: [64]u8 = undefined;
            const n = readApp(io2, &sock, ap, &app_buf) catch |e| {
                out.* = e;
                return;
            };
            if (!std.mem.eql(u8, app_buf[0..n], "hrr-ping")) {
                out.* = error.BadReply;
                return;
            }
            writeApp(io2, &sock, ap, "hrr-pong") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }

        fn readPlain(io2: std.Io, sock: *tcp.Socket) ![]u8 {
            _ = io2;
            var hdr: [5]u8 = undefined;
            var have: usize = 0;
            while (have < 5) {
                const n = try sock.read(hdr[have..]);
                if (n == 0) return error.Closed;
                have += n;
            }
            const len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
            const body = try std.heap.page_allocator.alloc(u8, len);
            errdefer std.heap.page_allocator.free(body);
            var got: usize = 0;
            while (got < len) {
                const n = try sock.read(body[got..]);
                if (n == 0) return error.Closed;
                got += n;
            }
            return body;
        }

        fn writePlain(io2: std.Io, sock: *tcp.Socket, msg: []const u8) !void {
            _ = io2;
            var hdr: [5]u8 = .{ 0x16, 0x03, 0x03, 0, 0 };
            std.mem.writeInt(u16, hdr[3..5], @intCast(msg.len), .big);
            try sock.writeAll(&hdr);
            try sock.writeAll(msg);
        }

        fn writeHs(io2: std.Io, sock: *tcp.Socket, keys: engine_mod.DerivedKeys, seq: *u64, msg: []const u8) !void {
            _ = io2;
            const enc = try record_mod.encodeRecord(.handshake, msg, seq.*, keys.serverKeySlice(), &keys.serverIv, keys.cipher);
            seq.* += 1;
            try sock.writeAll(enc.bytes[0..enc.len]);
        }

        fn readHs(io2: std.Io, sock: *tcp.Socket, keys: engine_mod.DerivedKeys, rx: *u64, out: *std.ArrayList(u8)) !void {
            _ = io2;
            var hdr: [5]u8 = undefined;
            var have: usize = 0;
            while (have < 5) {
                const n = try sock.read(hdr[have..]);
                if (n == 0) return error.Closed;
                have += n;
            }
            const len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
            var wire: [record_mod.maxRecordWire]u8 = undefined;
            @memcpy(wire[0..5], &hdr);
            var got: usize = 0;
            while (got < len) {
                const n = try sock.read(wire[5 + got ..][0 .. len - got]);
                if (n == 0) return error.Closed;
                got += n;
            }
            var plain: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = try record_mod.decodeRecord(wire[0..][0 .. 5 + len], &plain, rx.*, keys.clientKeySlice(), &keys.clientIv, keys.cipher);
            rx.* += 1;
            try out.appendSlice(std.heap.page_allocator, dec.plaintext);
        }

        fn readApp(io2: std.Io, sock: *tcp.Socket, keys: engine_mod.DerivedKeys, buf: []u8) !usize {
            _ = io2;
            var hdr: [5]u8 = undefined;
            var have: usize = 0;
            while (have < 5) {
                const n = try sock.read(hdr[have..]);
                if (n == 0) return error.Closed;
                have += n;
            }
            const len: usize = (@as(usize, hdr[3]) << 8) | hdr[4];
            var wire: [record_mod.maxRecordWire]u8 = undefined;
            @memcpy(wire[0..5], &hdr);
            var got: usize = 0;
            while (got < len) {
                const n = try sock.read(wire[5 + got ..][0 .. len - got]);
                if (n == 0) return error.Closed;
                got += n;
            }
            var plain: [record_mod.maxRecordPlaintext + 1]u8 = undefined;
            const dec = try record_mod.decodeRecord(wire[0..][0 .. 5 + len], &plain, 0, keys.clientKeySlice(), &keys.clientIv, keys.cipher);
            const n = @min(dec.plaintext.len, buf.len);
            @memcpy(buf[0..n], dec.plaintext[0..n]);
            return n;
        }

        fn writeApp(io2: std.Io, sock: *tcp.Socket, keys: engine_mod.DerivedKeys, msg: []const u8) !void {
            _ = io2;
            const enc = try record_mod.encodeRecord(.application_data, msg, 0, keys.serverKeySlice(), &keys.serverIv, keys.cipher);
            try sock.writeAll(enc.bytes[0..enc.len]);
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });

    // Production client path: HRR retry is inside `handshake`.
    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
    });
    var conn = try cli.handshake(ctx.io, &sock, "127.0.0.1");
    defer conn.deinit();
    try std.testing.expect(!conn.resumed);
    try conn.writeAll("hrr-ping");
    var buf: [16]u8 = undefined;
    var got: usize = 0;
    while (got < "hrr-pong".len) {
        const n = try conn.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqualStrings("hrr-pong", buf[0..got]);
    conn.close();
    sock.close();

    th.join();
    try std.testing.expect(result == null);
}

// Loopback native handshake: ALPN h2 negotiated, chain anchors in the
// custom CA, hostname verified, app data round-trips.
test "native client handshake negotiates h2 with verified chain" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = testServer(a);
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
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
            if (!std.mem.eql(u8, buf[0..n], "h2-hello")) {
                out.* = error.BadReply;
                return;
            }
            conn.writeAll("h2-world") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
        .alpnProtocols = &.{"h2"},
    });
    var conn = try cli.handshake(ctx.io, &sock, "127.0.0.1");
    defer conn.deinit();
    try std.testing.expect(conn.alpn.? == .h2);

    try conn.writeAll("h2-hello");
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < "h2-world".len) {
        const n = try conn.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqualStrings("h2-world", buf[0..got]);

    th.join();
    try std.testing.expect(result == null);
}

test "native client rejects hostname mismatch" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = testServer(a);
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer) void {
            var sock = lst.accept(io2) catch return;
            defer sock.close();
            if (srv.handshake(io2, &sock)) |conn| {
                var c = conn;
                c.deinit();
            } else |_| {}
        }
    };
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server });
    defer th.join();

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
    });
    // Chain anchors fine, but the cert is for 127.0.0.1/localhost.
    try std.testing.expectError(error.CertificateHostMismatch, cli.handshake(ctx.io, &sock, "wrong.invalid"));
}

test "native client verify none skips chain checks" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = testServer(a);
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.handshake(io2, &sock)) |conn| {
                var c = conn;
                c.deinit();
                out.* = null;
            } else |e| {
                out.* = e;
            }
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{ .allocator = a, .verify = .none });
    var conn = try cli.handshake(ctx.io, &sock, "anything.invalid");
    defer conn.deinit();

    th.join();
    try std.testing.expect(result == null);
}

test "native client falls back to http/1.1 alpn when h2 not offered" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = testServer(a);
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
            var sock = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer sock.close();
            if (srv.handshake(io2, &sock)) |conn| {
                var c = conn;
                c.deinit();
                out.* = null;
            } else |e| {
                out.* = e;
            }
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{
        .allocator = a,
        .verify = .none,
        .alpnProtocols = &.{"http/1.1"},
    });
    var conn = try cli.handshake(ctx.io, &sock, "127.0.0.1");
    defer conn.deinit();
    try std.testing.expect(conn.alpn.? == .@"http/1.1");

    th.join();
    try std.testing.expect(result == null);
}

test "native client presents certificate to requiring server" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = tcpTls.TlsServer.init(.{
        .allocator = a,
        .defaultIdentity = .{ .certChainPem = test_cert_pem, .privateKeyPem = test_key_pem },
        .clientAuth = .required,
        .clientCaPem = test_cert_pem,
    });
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
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
            if (!std.mem.eql(u8, buf[0..n], "mtls-cli")) {
                out.* = error.BadReply;
                return;
            }
            conn.writeAll("mtls-srv") catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &server, &result });

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = test_cert_pem,
        .clientCertPem = test_cert_pem,
        .clientKeyPem = test_key_pem,
    });
    var conn = try cli.handshake(ctx.io, &sock, "127.0.0.1");
    defer conn.deinit();

    try conn.writeAll("mtls-cli");
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < "mtls-srv".len) {
        const n = try conn.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqualStrings("mtls-srv", buf[0..got]);

    th.join();
    try std.testing.expect(result == null);
}

test "native client without certificate fails required server" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    var server = tcpTls.TlsServer.init(.{
        .allocator = a,
        .defaultIdentity = .{ .certChainPem = test_cert_pem, .privateKeyPem = test_key_pem },
        .clientAuth = .required,
        .clientCaPem = test_cert_pem,
    });
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, srv: *tcpTls.TlsServer, out: *?anyerror) void {
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

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();
    var cli = TlsClient.init(.{ .allocator = a, .verify = .none });
    // No client certificate configured while the server requires one.
    // Close first so the blocked server reader observes EOF and exits;
    // joining against the open connection would deadlock (see the
    // join-ordering rule documented in the H2 transport test).
    try std.testing.expectError(error.ClientCertificateRequired, cli.handshake(ctx.io, &sock, "127.0.0.1"));
    sock.close();

    th.join();
    // Server side only ever sees the connection vanish mid-flight.
    const r = result.?;
    try std.testing.expect(r == error.IoError or r == error.TlsHandshakeFailed);
}
