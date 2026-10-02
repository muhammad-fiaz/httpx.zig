//! Production TLS 1.3 handshake driver for QUIC (RFC 9001).
//!
//! Where the loopback `TlsHandshakeDriver` in `connection.zig` uses empty
//! certificates and fixed keys, this driver runs REAL handshakes: the
//! client offers ALPN `h3` with SNI and verifies the server chain against
//! system/custom trust; the server selects `h3` and signs with its real
//! P-256 identity; both sides exchange Finished and the server confirms
//! with HANDSHAKE_DONE.
//!
//! Deliberate scope (documented, not hidden):
//!   * Full handshakes only — no PSK resumption over QUIC yet (the TLS
//!     engine supports it on TCP; wiring offer/capture through CRYPTO
//!     streams is future work).
//!   * No HelloRetryRequest handling: our client always offers an x25519
//!     share, so a conforming server never needs to retry. A foreign HRR
//!     surfaces as a handshake timeout, never silent corruption.
//!   * Transport parameters (`quicTransportParameters`, ext 57) are
//!     exchanged in ClientHello/EncryptedExtensions and applied to
//!     flow-control windows, stream limits, and connection IDs; absent
//!     values keep compiled-in defaults. Retry/token and version
//!     negotiation stay future work.
//!   * No Retry/token round trip: first flight validates routability on
//!     loopback; deployments facing the open internet must add Retry.
//!   * No loss recovery / congestion control: reliable paths only
//!     (loopback, LAN). Lossy networks will stall to the deadline.
//!
//! Thread-safety: thread-confined per connection (one driver per side).

const std = @import("std");
const Allocator = std.mem.Allocator;
const connMod = @import("connection.zig");
const Connection = connMod.Connection;
const SpaceKind = connMod.SpaceKind;
const transportMod = @import("transport.zig");
const Endpoint = transportMod.Endpoint;
const tlsEngine = @import("../tls/engine.zig");
const qtls = @import("../tls/quicTls.zig");
const ths = @import("../tls/handshake.zig");
const verifyMod = @import("../tls/verify.zig");
const transportTls = @import("../tls/transport.zig");
const packetMod = @import("packet.zig");
const frames = @import("frames.zig");
const paramsMod = @import("params.zig");
const quicVarint = @import("varint.zig");
const clockMod = @import("../../common/clock.zig");
const addressMod = @import("../../net/address.zig");

const sessionMod = @import("../tls/session.zig");

pub const ClientConfig = struct {
    /// Server hostname: SNI (DNS names) + chain hostname check + ticket binding.
    host: []const u8,
    verify: transportTls.VerifyMode = .caBundle,
    /// Extra/custom CA PEM trusted in addition to system roots.
    caPem: ?[]const u8 = null,
    /// Resumption session with 0-RTT allowance
    session: ?*const sessionMod.ClientSession = null,
    earlyData: bool = false,
    /// Output pointer to capture new session ticket from server
    sessionOut: ?*sessionMod.ClientSession = null,
};

pub const ServerConfig = struct {
    certChainPem: []const u8,
    privateKeyPem: []const u8,
    ticketKeys: ?sessionMod.TicketKeys = null,
    maxEarlyData: u32 = 0,
    replayCache: ?*sessionMod.ReplayCache = null,
};

/// Precise handshake failure cause, preserved across the TlsDriver seam.
pub const Detail = enum {
    none,
    alpnMismatch,
    certFailed,
    handshakeFailed,
};

/// Production handshake driver state (one per connection side).
pub const Driver = struct {
    allocator: Allocator,
    role: connMod.Role,
    engine: tlsEngine.Engine,
    /// Own ClientHello bytes (client: for key derivation binding).
    flight: std.ArrayList(u8) = .empty,
    /// Accumulated inbound CRYPTO bytes for record reassembly.
    incoming: std.ArrayList(u8) = .empty,
    /// Full peer flight (client: server SH..Fin, for key derivation).
    peerFlight: std.ArrayList(u8) = .empty,
    /// Server certificate DERs presented to this client (owned).
    certDers: std.ArrayList([]u8) = .empty,
    hsSecret: ?[32]u8 = null,
    flightDone: bool = false,
    /// Precise failure cause for the H3 layer to map (the TlsDriver
    /// seam only carries `connMod.Error`; this preserves the loud,
    /// specific reason across it).
    detail: Detail = .none,
    /// Latched on any driver failure. Pump loops poll this to fail FAST
    /// (precise cause via `detail`) instead of burning the whole
    /// deadline after the handshake is already doomed. Set and read on
    /// the owner thread only (the driver never runs on pump threads).
    failed: bool = false,
    // Client policy (unused on server role).
    host: []const u8 = "",
    verify: transportTls.VerifyMode = .caBundle,
    caPem: ?[]const u8 = null,
    session: ?*const sessionMod.ClientSession = null,
    earlyData: bool = false,
    sessionOut: ?*sessionMod.ClientSession = null,
    // Server identity (unused on client role).
    certChainPem: []const u8 = "",
    privateKeyPem: []const u8 = "",

    pub fn initClient(io: std.Io, allocator: Allocator, cfg: ClientConfig) Driver {
        return .{
            .allocator = allocator,
            .role = .client,
            .engine = tlsEngine.Engine.initClient(io, allocator, .{}),
            .host = cfg.host,
            .verify = cfg.verify,
            .caPem = cfg.caPem,
            .session = cfg.session,
            .earlyData = cfg.earlyData,
            .sessionOut = cfg.sessionOut,
        };
    }

    pub fn initServer(io: std.Io, allocator: Allocator, cfg: ServerConfig) Driver {
        var eng = tlsEngine.Engine.initServer(io, allocator, .{});
        eng.ticketKeys = cfg.ticketKeys;
        eng.maxEarlyData = cfg.maxEarlyData;
        eng.replayCache = cfg.replayCache;
        return .{
            .allocator = allocator,
            .role = .server,
            .engine = eng,
            .certChainPem = cfg.certChainPem,
            .privateKeyPem = cfg.privateKeyPem,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.engine.deinit();
        self.flight.deinit(self.allocator);
        self.incoming.deinit(self.allocator);
        self.peerFlight.deinit(self.allocator);
        for (self.certDers.items) |d| self.allocator.free(d);
        self.certDers.deinit(self.allocator);
    }

    /// Builds our transport-parameters block: numeric limits from the
    /// connection config plus our connection IDs. Stateless-reset and
    /// retry tokens are omitted (unsupported); peers must not expect
    /// them from us.
    fn buildLocalTransportParams(a: Allocator, conn: *Connection) ![]u8 {
        const cfg = conn.cfg;
        const p = paramsMod.Params{
            .maxIdleTimeoutMs = cfg.maxIdleTimeoutMs,
            .maxUdpPayloadSize = @intCast(cfg.maxUdpPayload),
            .initialMaxData = cfg.initialMaxData,
            .initialMaxStreamDataBidiLocal = 65536,
            .initialMaxStreamDataBidiRemote = 65536,
            .initialMaxStreamDataUni = 65536,
            .initialMaxStreamsBidi = conn.maxStreamsBidiLocal,
            .initialMaxStreamsUni = conn.maxStreamsUniLocal,
        };
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(a);
        try paramsMod.encode(&out, a, p);
        // initialSourceConnectionId: our SCID so the peer can bind it.
        {
            var vb: [8]u8 = undefined;
            var n = try quicVarint.encode(&vb, 0x0F);
            try out.appendSlice(a, vb[0..n]);
            n = try quicVarint.encode(&vb, conn.scidLen);
            try out.appendSlice(a, vb[0..n]);
            try out.appendSlice(a, conn.scid[0..conn.scidLen]);
        }
        // originalDestinationConnectionId: servers echo the DCID the
        // client first used (already installed by acceptInitial).
        if (conn.role == .server) {
            var vb: [8]u8 = undefined;
            var n = try quicVarint.encode(&vb, 0x00);
            try out.appendSlice(a, vb[0..n]);
            n = try quicVarint.encode(&vb, conn.dcidLen);
            try out.appendSlice(a, vb[0..n]);
            try out.appendSlice(a, conn.dcid[0..conn.dcidLen]);
        }
        return out.toOwnedSlice(a);
    }

    /// Applies decoded peer transport parameters to the connection.
    /// Nonzero values override the compiled defaults; absent values
    /// keep them (so unit paths without a TLS exchange keep working).
    /// Fails closed on Retry tokens (we never send Retry) and on an
    /// original-DCID mismatch (server side).
    fn applyPeerTransportParams(conn: *Connection, tp: []const u8, isServer: bool) connMod.Error!void {
        const p = paramsMod.decode(tp) catch return connMod.Error.TransportParameterError;
        const cids = paramsMod.parseCidParams(tp) catch return connMod.Error.TransportParameterError;
        if (cids.retrySourceConnectionId != null) return connMod.Error.TransportParameterError;
        if (isServer) {
            // Servers never receive originalDestinationConnectionId
            // (they send it); requiring it here would fail every client.
            if (cids.originalDestinationConnectionId != null) return connMod.Error.TransportParameterError;
        } else if (cids.originalDestinationConnectionId) |odcid| {
            // The server echoes the DCID from our Initial; a mismatch
            // means we are talking to a confused or hostile peer.
            if (odcid.len != conn.origDcidLen or !std.mem.eql(u8, odcid, conn.origDcid[0..conn.origDcidLen])) {
                return connMod.Error.TransportParameterError;
            }
        }
        if (p.initialMaxData != 0) conn.maxDataRemote = p.initialMaxData;
        // Our sends: streams we initiate use the peer's "remote" limit,
        // peer-initiated streams use their "local" limit; take the
        // tighter nonzero bound so either direction stays legal.
        var bidi: ?u64 = null;
        if (p.initialMaxStreamDataBidiLocal != 0) bidi = p.initialMaxStreamDataBidiLocal;
        if (p.initialMaxStreamDataBidiRemote != 0) {
            bidi = if (bidi) |b| @min(b, p.initialMaxStreamDataBidiRemote) else p.initialMaxStreamDataBidiRemote;
        }
        if (bidi) |b| conn.sendWindowBidi = b;
        if (p.initialMaxStreamDataUni != 0) conn.sendWindowUni = p.initialMaxStreamDataUni;
        if (p.initialMaxStreamsBidi != 0) conn.maxStreamsBidiRemote = p.initialMaxStreamsBidi;
        if (p.initialMaxStreamsUni != 0) conn.maxStreamsUniRemote = p.initialMaxStreamsUni;
        if (p.maxAckDelayMs != 0) conn.recovery.cfg.maxAckDelayMs = p.maxAckDelayMs;
        conn.peerParams = p;
    }

    /// Drains queued CRYPTO bytes into packet(s) on the given space.
    fn sendQueued(conn: *Connection, kind: SpaceKind, nowMs: u64) connMod.Error!void {
        const B = struct {
            var target: ?*Connection = null;
            var skind: SpaceKind = .initial;
            pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) connMod.Error!void {
                const c = target orelse return;
                while (c.takeCrypto(skind, 1200)) |chunk| {
                    frames.encode(payload, gpa, .{ .crypto = .{ .offset = chunk.offset, .data = chunk.data } }) catch
                        return connMod.Error.OutOfMemory;
                    _ = c.consumeCrypto(skind, chunk.data.len);
                }
            }
        };
        if (conn.takeCrypto(kind, 1) == null) return;
        B.target = conn;
        B.skind = kind;
        try conn.sendFrames(kind, B.build, nowMs);
    }

    /// Consumes one complete handshake record from the front of `buf`.
    fn takeRecord(buf: *std.ArrayList(u8)) ?struct { kind: u8, msg: []const u8 } {
        if (buf.items.len < 4) return null;
        const bodyLen: usize = (@as(usize, buf.items[1]) << 16) | (@as(usize, buf.items[2]) << 8) | buf.items[3];
        if (buf.items.len < 4 + bodyLen) return null;
        return .{ .kind = buf.items[0], .msg = buf.items[0 .. 4 + bodyLen] };
    }

    fn dropFront(buf: *std.ArrayList(u8), a: Allocator, n: usize) void {
        buf.replaceRange(a, 0, n, &.{}) catch {};
    }

    fn sniFor(host: []const u8) ?[]const u8 {
        var probe = addressMod.Address{ .family = .ip4, .port = 0 };
        return if (probe.parseIp(host)) |_| null else |_| host;
    }

    pub fn clientStart(ctx: ?*anyopaque, conn: *Connection, nowMs: u64) connMod.Error!void {
        const d: *Driver = @ptrCast(@alignCast(ctx.?));
        const tp = buildLocalTransportParams(conn.allocator, conn) catch
            return connMod.Error.OutOfMemory;
        defer conn.allocator.free(tp);

        const ch = if (d.session) |sess| blk: {
            if (d.earlyData and sess.maxEarlyData > 0) {
                break :blk d.engine.produceClientHelloResumption(&.{"h3"}, &.{}, sniFor(d.host), sess, nowMs, tp) catch
                    return connMod.Error.TlsDriverFailed;
            } else {
                break :blk d.engine.produceClientHello(&.{"h3"}, &.{}, sniFor(d.host), tp) catch
                    return connMod.Error.TlsDriverFailed;
            }
        } else (d.engine.produceClientHello(&.{"h3"}, &.{}, sniFor(d.host), tp) catch
            return connMod.Error.TlsDriverFailed);
        defer conn.allocator.free(ch);

        d.flight.appendSlice(conn.allocator, ch) catch return connMod.Error.OutOfMemory;

        // If early data was offered, install 0-RTT packet keys immediately!
        if (d.engine.earlyDataOffered and d.engine.clientEarlyTrafficSecret != null) {
            conn.installZeroRttKeys(d.engine.clientEarlyTrafficSecret.?, true);
        }

        _ = conn.queueCrypto(.initial, ch) catch return connMod.Error.TlsDriverFailed;
        try sendQueued(conn, .initial, nowMs);
    }

    pub fn onData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) connMod.Error!void {
        const d: *Driver = @ptrCast(@alignCast(ctx.?));
        if (d.role == .client) {
            clientOnData(d, conn, data, nowMs) catch |e| {
                d.failed = true;
                return e;
            };
        } else {
            serverOnData(d, conn, data, nowMs) catch |e| {
                d.failed = true;
                return e;
            };
        }
    }

    fn clientOnData(d: *Driver, conn: *Connection, data: []const u8, nowMs: u64) connMod.Error!void {
        const a = conn.allocator;
        d.incoming.appendSlice(a, data) catch return connMod.Error.OutOfMemory;
        d.peerFlight.appendSlice(a, data) catch return connMod.Error.OutOfMemory;
        while (takeRecord(&d.incoming)) |rec| {
            switch (rec.kind) {
                @intFromEnum(ths.HandshakeType.server_hello) => {
                    d.engine.processServerHello(rec.msg) catch return connMod.Error.TlsDriverFailed;
                    const shared = d.engine.sharedSecret32() orelse return connMod.Error.TlsDriverFailed;
                    const chSh = d.engine.transcript.finish();
                    const hs = if (d.engine.resumptionPsk) |psk|
                        qtls.handshakeKeysWithEarly(qtls.earlySecret(psk), shared, chSh)
                    else
                        qtls.handshakeKeys(shared, chSh);
                    d.hsSecret = hs.hsSecret;
                    try conn.installKeys(.handshake, hs.keys.txSecret, hs.keys.rxSecret);
                    conn.discardInitialKeys();
                },
                @intFromEnum(ths.HandshakeType.encrypted_extensions) => {
                    d.engine.processEncryptedExtensions(rec.msg) catch return connMod.Error.TlsDriverFailed;
                    conn.earlyDataAccepted = d.engine.earlyDataAccepted;
                    if (d.engine.earlyDataOffered and !d.engine.earlyDataAccepted) {
                        conn.discardZeroRtt();
                    }
                    const alpn = d.engine.negotiatedAlpn orelse {
                        d.detail = .alpnMismatch;
                        return connMod.Error.TlsDriverFailed;
                    };
                    if (!std.mem.eql(u8, alpn, "h3")) {
                        d.detail = .alpnMismatch;
                        return connMod.Error.TlsDriverFailed;
                    }
                    // Apply the peer's transport parameters before any
                    // 1-RTT traffic flows.
                    if (d.engine.peerQuicTransportParams) |tp| {
                        applyPeerTransportParams(conn, tp, false) catch {
                            d.detail = .handshakeFailed;
                            return connMod.Error.TlsDriverFailed;
                        };
                    }
                },
                @intFromEnum(ths.HandshakeType.certificate) => {
                    var presented = d.engine.processClientCertificate(rec.msg) catch
                        return connMod.Error.TlsDriverFailed;
                    defer presented.deinit();
                    for (presented.ders) |der| {
                        const owned = a.dupe(u8, der) catch return connMod.Error.OutOfMemory;
                        d.certDers.append(a, owned) catch {
                            a.free(owned);
                            return connMod.Error.OutOfMemory;
                        };
                    }
                },
                @intFromEnum(ths.HandshakeType.certificate_verify) => {
                    // Full verification (decode + signature + feed) in one
                    // step: calling the decode-only processCertificateVerify
                    // first would feed twice and verify against the wrong
                    // transcript (including CV itself).
                    if (d.certDers.items.len == 0) {
                        d.detail = .certFailed;
                        return connMod.Error.TlsDriverFailed;
                    }
                    d.engine.processServerCertificateVerify(rec.msg, d.certDers.items[0]) catch {
                        d.detail = .certFailed;
                        return connMod.Error.TlsDriverFailed;
                    };
                },
                @intFromEnum(ths.HandshakeType.finished) => {
                    d.engine.processFinished(rec.msg) catch return connMod.Error.TlsDriverFailed;
                    // Chain verification BEFORE installing application
                    // keys: never encrypt to an untrusted peer (omitted on PSK resumption).
                    if (d.engine.resumptionPsk == null) {
                        verifyMod.verifyServerChain(a, connIo(conn), d.verify, d.caPem, d.host, d.certDers.items) catch {
                            d.detail = .certFailed;
                            return connMod.Error.TlsDriverFailed;
                        };
                    }
                    const hsSecret = d.hsSecret orelse return connMod.Error.TlsDriverFailed;
                    const chSf = d.engine.transcript.finish();
                    const ap = qtls.applicationKeys(hsSecret, chSf);
                    try conn.installKeys(.application, ap.keys.txSecret, ap.keys.rxSecret);
                    // Our Finished completes the client flight.
                    const fin = d.engine.produceClientFinished() catch
                        return connMod.Error.TlsDriverFailed;
                    defer a.free(fin);
                    _ = conn.queueCrypto(.handshake, fin) catch return connMod.Error.TlsDriverFailed;
                    try sendQueued(conn, .handshake, nowMs);
                },
                @intFromEnum(ths.HandshakeType.new_session_ticket) => {
                    if (d.engine.deriveResumptionMaster()) |rm| {
                        var session = d.engine.processNewSessionTicket(rec.msg, rm, d.host, nowMs) catch null;
                        if (session) |*sess| {
                            if (d.sessionOut) |so| {
                                so.* = sess.*;
                            } else {
                                sess.deinit(a);
                            }
                        }
                    } else |_| {}
                },
                else => return connMod.Error.ProtocolViolation,
            }
            dropFront(&d.incoming, a, rec.msg.len);
        }
    }

    fn serverOnData(d: *Driver, conn: *Connection, data: []const u8, nowMs: u64) connMod.Error!void {
        const a = conn.allocator;
        if (d.flightDone) {
            // Post-flight: only the client's Finished is expected.
            d.incoming.appendSlice(a, data) catch return connMod.Error.OutOfMemory;
            while (takeRecord(&d.incoming)) |rec| {
                if (rec.kind != @intFromEnum(ths.HandshakeType.finished)) {
                    return connMod.Error.ProtocolViolation;
                }
                d.engine.verifyClientFinished(rec.msg) catch return connMod.Error.TlsDriverFailed;
                conn.state = .established;
                dropFront(&d.incoming, a, rec.msg.len);

                // If ticket keys configured, produce NewSessionTicket for client
                if (d.engine.ticketKeys != null) {
                    if (d.engine.deriveResumptionMaster()) |rm| {
                        if (d.engine.produceNewSessionTicket(rm, d.engine.selectedSuite, 86400, nowMs)) |nstMsg| {
                            defer a.free(nstMsg);
                            _ = conn.queueCrypto(.application, nstMsg) catch {};
                        } else |_| {}
                    } else |_| {}
                }

                // Handshake confirmed: tell the client to open 1-RTT (and deliver any queued NewSessionTicket).
                const DoneB = struct {
                    var target: ?*Connection = null;
                    pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) connMod.Error!void {
                        frames.encode(payload, gpa, .handshakeDone) catch
                            return connMod.Error.OutOfMemory;
                        if (target) |c| {
                            while (c.takeCrypto(.application, 1200)) |chunk| {
                                frames.encode(payload, gpa, .{ .crypto = .{ .offset = chunk.offset, .data = chunk.data } }) catch
                                    return connMod.Error.OutOfMemory;
                                _ = c.consumeCrypto(.application, chunk.data.len);
                            }
                        }
                    }
                };
                DoneB.target = conn;
                try conn.sendFrames(.application, DoneB.build, nowMs);
            }
            return;
        }
        d.incoming.appendSlice(a, data) catch return connMod.Error.OutOfMemory;
        const rec = takeRecord(&d.incoming) orelse return;
        if (rec.kind != @intFromEnum(ths.HandshakeType.client_hello)) return connMod.Error.ProtocolViolation;
        const chMsg = rec.msg;
        d.engine.processClientHello(chMsg) catch return connMod.Error.TlsDriverFailed;
        const clientAlpn = parseOfferedAlpn(a, chMsg[4..]) catch return connMod.Error.TlsDriverFailed;
        defer {
            for (clientAlpn) |s| a.free(s);
            a.free(clientAlpn);
        }
        // RFC 9001 Section 7.4: no overlap means noApplicationProtocol
        // (120, application close 0x178), not a silent stall. The client
        // maps the close to its alpnMismatch detail.
        var offersH3 = false;
        for (clientAlpn) |proto| {
            if (std.mem.eql(u8, proto, "h3")) {
                offersH3 = true;
                break;
            }
        }
        if (!offersH3) {
            d.detail = .alpnMismatch;
            // Transport close (0x1C) on the Initial space: Initial keys
            // are installed (acceptInitial ran) while application keys
            // never exist at this point, and a 0x1D application close is
            // forbidden before 1-RTT. Best effort: the driver error
            // below is the backstop.
            conn.queueControlFrame(.{ .connectionClose = .{
                .errorCode = 0x178,
                .triggeringFrameType = 0,
                .reason = "no application protocol",
                .application = false,
            } }) catch {};
            conn.flushControl(.initial, nowMs) catch {};
            return connMod.Error.TlsDriverFailed;
        }
        // Apply the client's transport parameters before sending ours.
        if (d.engine.peerQuicTransportParams) |tp| {
            applyPeerTransportParams(conn, tp, true) catch {
                d.detail = .handshakeFailed;
                return connMod.Error.TlsDriverFailed;
            };
        }
        const localTp = buildLocalTransportParams(a, conn) catch
            return connMod.Error.OutOfMemory;
        defer a.free(localTp);

        if (d.engine.ticketKeys != null) {
            _ = d.engine.selectPsk(chMsg, nowMs);
            if (d.engine.earlyDataAccepted and d.engine.clientEarlyTrafficSecret != null) {
                conn.earlyDataAccepted = true;
                conn.maxEarlyData = d.engine.maxEarlyData;
                conn.installZeroRttKeys(d.engine.clientEarlyTrafficSecret.?, false);
            }
        }

        var flight = d.engine.produceServerFlight(chMsg[4..], d.certChainPem, d.privateKeyPem, &.{.h3}, clientAlpn, localTp) catch
            return connMod.Error.TlsDriverFailed;
        defer flight.deinit(a);

        d.flight.appendSlice(a, flight.serverHello) catch return connMod.Error.OutOfMemory;
        d.flight.appendSlice(a, flight.encryptedExtensions) catch return connMod.Error.OutOfMemory;
        d.flight.appendSlice(a, flight.certificate) catch return connMod.Error.OutOfMemory;
        d.flight.appendSlice(a, flight.certificateVerify) catch return connMod.Error.OutOfMemory;
        d.flight.appendSlice(a, flight.finished) catch return connMod.Error.OutOfMemory;

        const shared = d.engine.sharedSecret32() orelse return connMod.Error.TlsDriverFailed;
        const hs = if (d.engine.resumptionPsk) |psk|
            qtls.handshakeKeysWithEarly(qtls.earlySecret(psk), shared, flight.hsHash)
        else
            qtls.handshakeKeys(shared, flight.hsHash);
        // LevelKeys are client-oriented (tx = client); mirror them.
        try conn.installKeys(.handshake, hs.keys.rxSecret, hs.keys.txSecret);

        // ServerHello leaves in an Initial packet (RFC 9001 4.1 pattern);
        // EE..Finished follow in Handshake packets.
        _ = conn.queueCrypto(.initial, flight.serverHello) catch return connMod.Error.TlsDriverFailed;
        try sendQueued(conn, .initial, nowMs);
        _ = conn.queueCrypto(.handshake, flight.encryptedExtensions) catch return connMod.Error.TlsDriverFailed;
        _ = conn.queueCrypto(.handshake, flight.certificate) catch return connMod.Error.TlsDriverFailed;
        _ = conn.queueCrypto(.handshake, flight.certificateVerify) catch return connMod.Error.TlsDriverFailed;
        _ = conn.queueCrypto(.handshake, flight.finished) catch return connMod.Error.TlsDriverFailed;
        try sendQueued(conn, .handshake, nowMs);

        const chSf = flight.sfHash;
        const ap = qtls.applicationKeys(hs.hsSecret, chSf);
        try conn.installKeys(.application, ap.keys.rxSecret, ap.keys.txSecret);

        // Consume the hello only after its last use above: `incoming` is
        // reused for the post-flight Finished, and stale bytes would
        // poison its record parser. (Dropping earlier would invalidate
        // `chMsg`, which borrows this buffer.)
        dropFront(&d.incoming, a, rec.msg.len);

        // An authentic ClientHello validates return routability on
        // loopback; open-internet deployments must gate amplification
        // on Retry/token instead (see module docs).
        conn.addressValidated = true;
        d.flightDone = true;
    }

    /// std.Io for trust-store time/random. Connections are driven by an
    /// Endpoint that owns io; threaded global io matches everywhere the
    /// TCP client uses it.
    fn connIo(conn: *Connection) std.Io {
        _ = conn;
        return std.Io.Threaded.global_single_threaded.io();
    }
};

/// Extracts offered ALPN protocols from a ClientHello body (owned strings).
fn parseOfferedAlpn(a: Allocator, body: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| a.free(s);
        out.deinit(a);
    }
    if (body.len < 34) return out.toOwnedSlice(a);
    var pos: usize = 34;
    if (pos + 1 > body.len) return out.toOwnedSlice(a);
    pos += 1 + body[pos];
    if (pos + 2 > body.len) return out.toOwnedSlice(a);
    const csLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2 + csLen;
    if (pos + 1 > body.len) return out.toOwnedSlice(a);
    pos += 1 + body[pos];
    if (pos + 2 > body.len) return out.toOwnedSlice(a);
    const extLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2;
    const extEnd = @min(body.len, pos + extLen);
    const alpnType: u16 = 16; // applicationLayerProtocolNegotiation
    while (pos + 4 <= extEnd) {
        const t = std.mem.readInt(u16, body[pos..][0..2], .big);
        const l: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
        pos += 4;
        if (pos + l > extEnd) break;
        if (t == alpnType) {
            const data = body[pos..][0..l];
            if (data.len >= 2) {
                const listLen: usize = (@as(usize, data[0]) << 8) | data[1];
                var p: usize = 2;
                const listEnd = @min(data.len, 2 + listLen);
                while (p < listEnd) {
                    const n: usize = data[p];
                    p += 1;
                    if (p + n > listEnd) break;
                    try out.append(a, try a.dupe(u8, data[p..][0..n]));
                    p += n;
                }
            }
        }
        pos += l;
    }
    return out.toOwnedSlice(a);
}

/// Feeds one pumped datagram into `ep` (if any arrived) and flushes
/// queued output. `dest` overrides the learned peer (client's first
/// flight); null flushes to the peer.
/// The flush is UNCONDITIONAL (even with no inbound datagram): queued
/// flights must reach the wire without waiting for peer traffic first,
/// or both sides idle forever. Pumps NEVER block: the reader thread
/// owns all waiting, so this is purely feed + flush on the owner thread.
pub fn feedPumped(
    ep: *Endpoint,
    pump: *transportMod.Pump,
    dest: ?std.Io.net.IpAddress,
    quantumMs: u64,
    nowMs: u64,
) !void {
    if (try pump.next(quantumMs)) |d| {
        // Free with the PUMP's allocator (it duped these bytes) — never
        // the connection's: the two are independently chosen and mixing
        // them corrupts the heap.
        defer pump.allocator.free(d.data);
        ep.peer = d.from;
        ep.conn.receiveDatagram(d.data, nowMs) catch |e| switch (e) {
            error.Draining => return e,
            else => {}, // drop bad datagrams, keep going
        };
    }
    // Loss and PTO timers fire here so every pump-driven runtime (client
    // transport, server loops, tests) gets retransmission without extra
    // plumbing. Best-effort like receives: only death propagates.
    ep.conn.pollTimeouts(nowMs) catch |e| switch (e) {
        error.Draining, error.ConnectionClosed => return e,
        else => {},
    };
    if (dest) |dst| {
        _ = ep.flush(dst) catch 0;
    } else {
        _ = ep.flush(null) catch 0;
    }
}

/// Server side of a live handshake over an already-started pump:
/// bootstraps Initial keys from the first datagram's DCID, then pumps
/// until `.established` (client Finished verified) or the deadline
/// passes. `driver` (nullable) is polled for fast failure. The pump is
/// NOT stopped here — the caller owns its lifetime (handshake, then
/// request exchange, then stop).
pub fn serveHandshake(serverEp: *Endpoint, pump: *transportMod.Pump, driver: ?*Driver, deadlineMs: u64) !void {
    const start: u64 = @intCast(clockMod.millisNow());
    var booted = false;
    while (true) {
        const now: u64 = @intCast(clockMod.millisNow());
        if (now -| start > deadlineMs) return error.HandshakeTimeout;
        // Driver-doomed handshakes fail fast with a mappable error (the
        // precise cause stays on `driver.detail`); only the truly quiet
        // peer burns the deadline.
        if (driver) |d| {
            if (d.failed) return error.HandshakeFailed;
        }
        const remain = deadlineMs -| (now -| start);
        // Poll at 100 ms quanta: short enough to stay responsive to new
        // clients and shutdown signals, long enough to avoid hot-spinning
        // on a quiet path.
        if (!booted) {
            const d = try pump.next(@min(remain, 100)) orelse continue;
            defer pump.allocator.free(d.data);
            const parsed = packetMod.parseLongHeader(d.data) catch continue;
            if (parsed.header.type != .initial) continue;
            serverEp.peer = d.from;
            try serverEp.conn.acceptInitial(parsed.header.dcid);
            serverEp.conn.receiveDatagram(d.data, now) catch continue;
            booted = true;
            continue;
        }
        try feedPumped(serverEp, pump, null, @min(remain, 100), now);
        if (serverEp.conn.state == .established) return;
    }
}

const hsTestCertPem = @embedFile("../tls/testdata/localhostCert.pem");
const hsTestKeyPem = @embedFile("../tls/testdata/localhostKey.pem");

test "live handshake over real udp loopback establishes both ends" {
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;
    defer ctx.deinit();

    var cliConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer cliConn.deinit();
    var srvConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer srvConn.deinit();

    var cliEp = try transportMod.Endpoint.init(a, ctx.io, cliConn, .{});
    defer cliEp.deinit();
    var srvEp = try transportMod.Endpoint.init(a, ctx.io, srvConn, .{});
    defer srvEp.deinit();
    const sport = srvEp.localPort();

    var cliDrv = Driver.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{ .host = "127.0.0.1", .caPem = hsTestCertPem });
    defer cliDrv.deinit();
    var srvDrv = Driver.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{ .certChainPem = hsTestCertPem, .privateKeyPem = hsTestKeyPem });
    defer srvDrv.deinit();
    cliConn.tls = .{ .ctx = &cliDrv, .start = Driver.clientStart, .onData = Driver.onData };
    srvConn.tls = .{ .ctx = &srvDrv, .start = Driver.clientStart, .onData = Driver.onData };

    var cliPump: transportMod.Pump = undefined;
    try cliPump.start(&cliEp, a);
    defer cliPump.stop();
    var srvPump: transportMod.Pump = undefined;
    try srvPump.start(&srvEp, a);
    defer srvPump.stop();

    const dest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;
    try performHandshake(&cliEp, &cliPump, &cliDrv, &srvEp, &srvPump, &srvDrv, dest, 15_000);
    try std.testing.expectEqual(connMod.State.established, cliConn.state);
    try std.testing.expectEqual(connMod.State.established, srvConn.state);
    // ALPN h3 was negotiated through the real TLS flight.
    try std.testing.expectEqualStrings("h3", cliDrv.engine.negotiatedAlpn.?);
    try std.testing.expectEqualStrings("h3", srvDrv.engine.negotiatedAlpn.?);
}

/// Drives a client handshake to completion. `clientPump` must be
/// started; with `serverEp`/`serverPump` set, an in-process peer is
/// co-pumped (loopback), otherwise only our side pumps against `dest`
/// (external peer). `clientDriver` (nullable) is polled for fast
/// failure with a mappable cause. No pump is stopped here — lifetimes
/// stay with the caller. Returns when our side reaches `.established`
/// (and the peer confirms, when co-pumped).
pub fn performHandshakeWithEarlyData(
    clientEp: *Endpoint,
    clientPump: *transportMod.Pump,
    clientDriver: ?*Driver,
    serverEp: ?*Endpoint,
    serverPump: ?*transportMod.Pump,
    serverDriver: ?*Driver,
    dest: std.Io.net.IpAddress,
    deadlineMs: u64,
    earlyStream: ?struct { sid: u64, data: []const u8 },
) !void {
    const start: u64 = @intCast(clockMod.millisNow());
    try clientEp.conn.startHandshake(start);
    if (earlyStream) |es| {
        if (clientEp.conn.zeroRttKeysTx != null) {
            try clientEp.conn.sendStreamChecked(es.sid, 0, es.data, false, start);
        }
    }
    _ = try clientEp.flush(dest);
    var serverBooted = serverEp == null;
    while (true) {
        const now: u64 = @intCast(clockMod.millisNow());
        if (now -| start > deadlineMs) return error.HandshakeTimeout;
        if (clientDriver) |d| {
            if (d.failed) return error.HandshakeFailed;
        }
        if (serverDriver) |d| {
            if (d.failed) return error.HandshakeFailed;
        }
        const remain = deadlineMs -| (now -| start);
        if (serverEp) |sep| {
            const spump = serverPump orelse return error.HandshakeTimeout;
            if (!serverBooted) {
                const d = try spump.next(@min(remain, 100)) orelse continue;
                defer spump.allocator.free(d.data);
                const parsed = packetMod.parseLongHeader(d.data) catch continue;
                if (parsed.header.type != .initial) continue;
                sep.peer = d.from;
                try sep.conn.acceptInitial(parsed.header.dcid);
                sep.conn.receiveDatagram(d.data, now) catch continue;
                serverBooted = true;
                continue;
            }
            try feedPumped(sep, spump, null, @min(remain, 100), now);
        }
        try feedPumped(clientEp, clientPump, dest, @min(remain, 100), now);
        if (clientEp.conn.state == .established) {
            if (serverEp) |sep| {
                if (sep.conn.state == .established) return;
            } else {
                return;
            }
        }
    }
}

pub fn performHandshake(
    clientEp: *Endpoint,
    clientPump: *transportMod.Pump,
    clientDriver: ?*Driver,
    serverEp: ?*Endpoint,
    serverPump: ?*transportMod.Pump,
    serverDriver: ?*Driver,
    dest: std.Io.net.IpAddress,
    deadlineMs: u64,
) !void {
    return performHandshakeWithEarlyData(clientEp, clientPump, clientDriver, serverEp, serverPump, serverDriver, dest, deadlineMs, null);
}

test "peer transport parameters apply to connection windows" {
    const a = std.testing.allocator;
    var conn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();

    const putCid = struct {
        fn f(out: *std.ArrayList(u8), gpa: Allocator, id: u64, v: []const u8) !void {
            var vb: [8]u8 = undefined;
            var n = try quicVarint.encode(&vb, id);
            try out.appendSlice(gpa, vb[0..n]);
            n = try quicVarint.encode(&vb, v.len);
            try out.appendSlice(gpa, vb[0..n]);
            try out.appendSlice(gpa, v);
        }
    }.f;

    var p = paramsMod.Params{};
    p.initialMaxData = 2 << 20;
    p.initialMaxStreamDataBidiLocal = 1 << 20;
    p.initialMaxStreamDataBidiRemote = 512 << 10;
    p.initialMaxStreamDataUni = 256 << 10;
    p.initialMaxStreamsBidi = 64;
    p.initialMaxStreamsUni = 8;
    p.maxAckDelayMs = 42;

    const fakeIscid = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x01, 0x02, 0x03, 0x04 };
    const wrongCid = [_]u8{0x11} ** 8;

    // Server first flight: odcid echoes our original DCID.
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try paramsMod.encode(&block, a, p);
    try putCid(&block, a, 0x00, conn.origDcid[0..conn.origDcidLen]);
    try putCid(&block, a, 0x0F, &fakeIscid);

    try Driver.applyPeerTransportParams(conn, block.items, false);
    try std.testing.expectEqual(@as(u64, 2 << 20), conn.maxDataRemote);
    // Bidi send window is the tighter of the peer local/remote limits.
    try std.testing.expectEqual(@as(u64, 512 << 10), conn.sendWindowBidi);
    try std.testing.expectEqual(@as(u64, 256 << 10), conn.sendWindowUni);
    try std.testing.expectEqual(@as(u64, 64), conn.maxStreamsBidiRemote);
    try std.testing.expectEqual(@as(u64, 8), conn.maxStreamsUniRemote);
    try std.testing.expectEqual(@as(u64, 42), conn.recovery.cfg.maxAckDelayMs);
    try std.testing.expect(conn.peerParams != null);

    // The server path takes a block WITHOUT odcid (servers send it,
    // they never receive it) and rejects one that carries it.
    var srvBlock = std.ArrayList(u8).empty;
    defer srvBlock.deinit(a);
    try paramsMod.encode(&srvBlock, a, p);
    try putCid(&srvBlock, a, 0x0F, &fakeIscid);
    try Driver.applyPeerTransportParams(conn, srvBlock.items, true);
    try std.testing.expectError(
        connMod.Error.TransportParameterError,
        Driver.applyPeerTransportParams(conn, block.items, true),
    );

    // A forged originalDestinationConnectionId is rejected.
    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(a);
    try paramsMod.encode(&bad, a, p);
    try putCid(&bad, a, 0x00, &wrongCid);
    try putCid(&bad, a, 0x0F, &fakeIscid);
    try std.testing.expectError(
        connMod.Error.TransportParameterError,
        Driver.applyPeerTransportParams(conn, bad.items, false),
    );

    // A retrySourceConnectionId without a Retry is rejected.
    var rsc = std.ArrayList(u8).empty;
    defer rsc.deinit(a);
    try paramsMod.encode(&rsc, a, p);
    try putCid(&rsc, a, 0x00, conn.origDcid[0..conn.origDcidLen]);
    try putCid(&rsc, a, 0x0F, &fakeIscid);
    try putCid(&rsc, a, 0x10, &wrongCid);
    try std.testing.expectError(
        connMod.Error.TransportParameterError,
        Driver.applyPeerTransportParams(conn, rsc.items, false),
    );
}

test "server closes unknown alpn with no_application_protocol" {
    const a = std.testing.allocator;
    var srvConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer srvConn.deinit();
    // Initial keys + validated address so the close packet can fly.
    try srvConn.installInitialKeys();
    srvConn.addressValidated = true;
    var srvDrv = Driver.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{ .certChainPem = hsTestCertPem, .privateKeyPem = hsTestKeyPem });
    defer srvDrv.deinit();
    srvConn.tls = .{ .ctx = &srvDrv, .start = Driver.clientStart, .onData = Driver.onData };

    // A ClientHello offering only HTTP/1.1, no h3.
    var tmp = tlsEngine.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{});
    defer tmp.deinit();
    const ch = try tmp.produceClientHello(&.{"http/1.1"}, &.{}, "localhost", null);
    defer a.free(ch);

    const r = Driver.onData(&srvDrv, srvConn, ch, 1000);
    try std.testing.expectError(connMod.Error.TlsDriverFailed, r);
    try std.testing.expect(srvDrv.failed);
    try std.testing.expectEqual(Detail.alpnMismatch, srvDrv.detail);
    // RFC 9001 Section 7.4: a transport close 0x178 went out on the
    // Initial space (outbuf holds the datagram) and no TLS flight was
    // built for the rejected client.
    try std.testing.expect(srvConn.outbuf.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), srvDrv.flight.items.len);
}

test "live QUIC 0-RTT resumption over real udp loopback sends early data and establishes" {
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;
    defer ctx.deinit();

    const tk = sessionMod.TicketKeys{ .current = [_]u8{0x5A} ** 32 };
    var replayCache = sessionMod.ReplayCache.init(a, 100);
    defer replayCache.deinit();

    // 1. Initial Connection: Establish full handshake and obtain NewSessionTicket
    var savedSession: sessionMod.ClientSession = .{
        .ticket = &.{},
        .psk = [_]u8{0} ** 32,
        .ageAdd = 0,
        .createdMs = 0,
        .lifetimeSecs = 0,
        .suite = .AES_128_GCM_SHA256,
        .host = &.{},
    };
    var sessionCaptured = false;

    {
        var cliConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
        defer cliConn.deinit();
        var srvConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
        defer srvConn.deinit();

        var cliEp = try transportMod.Endpoint.init(a, ctx.io, cliConn, .{});
        defer cliEp.deinit();
        var srvEp = try transportMod.Endpoint.init(a, ctx.io, srvConn, .{});
        defer srvEp.deinit();
        const sport = srvEp.localPort();

        var cliDrv = Driver.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{
            .host = "127.0.0.1",
            .caPem = hsTestCertPem,
            .sessionOut = &savedSession,
        });
        defer cliDrv.deinit();

        var srvDrv = Driver.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{
            .certChainPem = hsTestCertPem,
            .privateKeyPem = hsTestKeyPem,
            .ticketKeys = tk,
            .maxEarlyData = 0xFFFFFFFF,
            .replayCache = &replayCache,
        });
        defer srvDrv.deinit();

        cliConn.tls = .{ .ctx = &cliDrv, .start = Driver.clientStart, .onData = Driver.onData };
        srvConn.tls = .{ .ctx = &srvDrv, .start = Driver.clientStart, .onData = Driver.onData };

        var cliPump: transportMod.Pump = undefined;
        try cliPump.start(&cliEp, a);
        defer cliPump.stop();
        var srvPump: transportMod.Pump = undefined;
        try srvPump.start(&srvEp, a);
        defer srvPump.stop();

        const dest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;
        try performHandshake(&cliEp, &cliPump, &cliDrv, &srvEp, &srvPump, &srvDrv, dest, 15_000);
        try std.testing.expectEqual(connMod.State.established, cliConn.state);
        try std.testing.expectEqual(connMod.State.established, srvConn.state);

        // Pump until the server's post-handshake NewSessionTicket is received
        var tries: usize = 0;
        while (tries < 20 and savedSession.ticket.len == 0) : (tries += 1) {
            const now2: u64 = @intCast(clockMod.millisNow());
            _ = srvEp.flush(null) catch {};
            try feedPumped(&cliEp, &cliPump, dest, 50, now2);
        }

        if (savedSession.ticket.len > 0) {
            sessionCaptured = true;
        }
    }
    defer if (savedSession.ticket.len > 0) savedSession.deinit(a);
    try std.testing.expect(sessionCaptured);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), savedSession.maxEarlyData);

    // 2. Resumed Connection: Client uses savedSession and sends 0-RTT early data
    {
        var cliConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
        defer cliConn.deinit();
        var srvConn = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
        defer srvConn.deinit();

        var cliEp = try transportMod.Endpoint.init(a, ctx.io, cliConn, .{});
        defer cliEp.deinit();
        var srvEp = try transportMod.Endpoint.init(a, ctx.io, srvConn, .{});
        defer srvEp.deinit();
        const sport = srvEp.localPort();

        var cliDrv = Driver.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{
            .host = "127.0.0.1",
            .caPem = hsTestCertPem,
            .session = &savedSession,
            .earlyData = true,
        });
        defer cliDrv.deinit();

        var srvDrv = Driver.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{
            .certChainPem = hsTestCertPem,
            .privateKeyPem = hsTestKeyPem,
            .ticketKeys = tk,
            .maxEarlyData = 0xFFFFFFFF,
            .replayCache = &replayCache,
        });
        defer srvDrv.deinit();

        cliConn.tls = .{ .ctx = &cliDrv, .start = Driver.clientStart, .onData = Driver.onData };
        srvConn.tls = .{ .ctx = &srvDrv, .start = Driver.clientStart, .onData = Driver.onData };

        var cliPump: transportMod.Pump = undefined;
        try cliPump.start(&cliEp, a);
        defer cliPump.stop();
        var srvPump: transportMod.Pump = undefined;
        try srvPump.start(&srvEp, a);
        defer srvPump.stop();

        const dest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;

        // Drive both to completion with 0-RTT early data sent on stream 0
        try performHandshakeWithEarlyData(
            &cliEp,
            &cliPump,
            &cliDrv,
            &srvEp,
            &srvPump,
            &srvDrv,
            dest,
            15_000,
            .{ .sid = 0, .data = "0-rtt-early-payload" },
        );
        try std.testing.expectEqual(connMod.State.established, cliConn.state);
        try std.testing.expectEqual(connMod.State.established, srvConn.state);
        try std.testing.expect(srvConn.earlyDataAccepted);
        try std.testing.expect(cliConn.earlyDataAccepted);
    }
}
