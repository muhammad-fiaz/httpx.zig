//! QUIC connection state machine (RFC 9000 sections 7-10).
//!
//! Assembles the layer modules into a working endpoint:
//!   * three packet-number spaces (Initial / Handshake / 1-RTT) each with
//!     own keys, next-PN, largest-acked, and ACK tracker
//!   * receive path: parse -> header-unprotect -> PN reconstruct ->
//!     AEAD open -> frame dispatch
//!   * send path: coalesce frames -> seal -> header-protect -> datagram
//!   * anti-amplification (3x received bytes) until address validation
//!   * idle timeout, closing/draining terminal states
//!   * CRYPTO stream reassembly handed to a pluggable TLS driver
//!
//! The TlsDriver interface lets the transport be fully exercised without
//! the TLS 1.3 engine; the loopback tests below wire the TLS engine
//! (protocols/tls/engine.zig) through CRYPTO frames, with QUIC packet
//! keys derived via protocols/tls/quicTls.zig (RFC 9001).

const std = @import("std");
const Allocator = std.mem.Allocator;

const varint = @import("varint.zig");
const packetMod = @import("packet.zig");
const protect = @import("packetProtection.zig");
const crypto = @import("crypto.zig");
const frames = @import("frames.zig");
const acktrMod = @import("ackTracker.zig");
const lossMod = @import("lossRecovery.zig");
const ccMod = @import("congestionControl.zig");
const paramsMod = @import("transportParameters.zig");
const pathMod = @import("path.zig");
const qstream = @import("stream.zig");
const tlsEngine = @import("../tls/tlsEngine.zig");
const qtls = @import("../tls/quicTls.zig");
const ths = @import("../tls/tlsHandshake.zig");
const h3conn = @import("../http3/connection.zig");
const h3frame = @import("../http3/frame.zig");
const h3qpack = @import("../http3/qpack.zig");

pub const Error = error{
    ProtocolViolation,
    AuthenticationFailed,
    FlowControlViolation,
    /// Peer transport parameters were missing, malformed, or
    /// inconsistent (RFC 9000 Section 7.4 / RFC 9001 Section 7.4).
    TransportParameterError,
    /// Send window exhausted (connection or stream). Retry after the
    /// peer raises MAX_DATA / MAX_STREAM_DATA.
    SendBlocked,
    OutOfMemory,
    AmplificationBlocked,
    ConnectionClosed,
    Draining,
    TlsDriverFailed,
    BufferTooSmall,
    InvalidState,
    UnsupportedVersion,
    VersionNegotiation,
};

const ShortPacket = struct {
    pn: u64,
    ctLen: usize,
    aadLen: usize,
    phase: bool,
};

/// Unprotects one short-header packet with `keys`. The caller retries
/// with the next/previous key phase when authentication fails.
fn openShortProtected(
    dgram: []const u8,
    dcidLen: usize,
    keys: crypto.ProtectionKeys,
    largestAcked: ?u64,
    work: *[MAX_DATAGRAM]u8,
    pt: []u8,
    phaseOut: *bool,
) Error!ShortPacket {
    if (dgram.len > work.len) return Error.ProtocolViolation;
    @memcpy(work[0..dgram.len], dgram);

    const pnOffset = 1 + dcidLen;
    if (dgram.len < pnOffset + 20) return Error.ProtocolViolation;

    var sample: [16]u8 = undefined;
    @memcpy(&sample, work[pnOffset + 4 ..][0..16]);
    const mask = switch (keys.cipher) {
        .aes128Gcm, .aes256Gcm => blk: {
            var hp16: [16]u8 = undefined;
            @memcpy(&hp16, keys.hp[0..16]);
            break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
        },
        .chacha20Poly1305 => blk: {
            var hp32: [32]u8 = undefined;
            @memcpy(&hp32, keys.hp[0..32]);
            break :blk protect.hpMaskChacha(hp32, &sample);
        },
    };
    work[0] ^= mask[0] & 0x1F;
    if (work[0] & 0x18 != 0) return Error.ProtocolViolation;
    phaseOut.* = (work[0] & 0x04) != 0;

    const pnLen: usize = (@as(usize, work[0]) & 0x03) + 1;
    for (0..pnLen) |i| work[pnOffset + i] ^= mask[1 + i];
    var pnTrunc: u64 = 0;
    for (0..pnLen) |i| pnTrunc = (pnTrunc << 8) | work[pnOffset + i];

    const expected: u64 = if (largestAcked) |la| la + 1 else 0;
    const pn = protect.reconstructPn(expected, pnTrunc, pnLen);
    const aadLen = pnOffset + pnLen;
    if (dgram.len < aadLen + 16) return Error.ProtocolViolation;
    const ctLen = dgram.len - aadLen - 16;
    if (pt.len < ctLen) return Error.BufferTooSmall;

    protect.openWithKeys(pt[0..ctLen], work[aadLen..][0..ctLen], work[aadLen + ctLen ..][0..16].*, work[0..aadLen], keys, pn) catch
        return Error.AuthenticationFailed;

    return .{ .pn = pn, .ctLen = ctLen, .aadLen = aadLen, .phase = phaseOut.* };
}

pub const Role = enum { client, server };

pub const SpaceKind = enum(u2) { initial = 0, handshake = 1, application = 2 };

pub const CryptoChunk = struct { offset: u64, data: []const u8 };
const CryptoSegment = struct { offset: u64, data: []u8 };

/// Keys + bookkeeping for one packet-number space.
pub const PnSpace = struct {
    kind: SpaceKind,
    nextPn: u64 = 0,
    largestAcked: ?u64 = null,
    acktr: acktrMod.AckTracker,
    /// Protection keys once installed (null until TLS provides them).
    keysRx: ?crypto.ProtectionKeys = null,
    keysTx: ?crypto.ProtectionKeys = null,
    /// Highest received PN for duplicate suppression.
    highestRxPn: i64 = -1,
    /// Once true, the keys are gone and the space can neither send nor
    /// receive again (RFC 9001 Sections 4.9.1 and 4.9.2).
    discarded: bool = false,
    gpa: Allocator,
    /// ACK-eliciting packets sent and not yet acknowledged, with their
    /// plaintext payloads retained for probe retransmission.
    sent: std.ArrayList(lossMod.SentPacket) = .empty,
    sentData: std.ArrayList([]u8) = .empty,
    inFlightBytes: usize = 0,
    inFlightAckEliciting: u64 = 0,
    lastAckElicitingTsMs: ?u64 = null,
    /// Largest peer-acknowledged PN in this space (loss threshold).
    ackedMax: ?u64 = null,
    /// Earliest time a time-threshold loss check must run (null = none).
    lossTimeMs: ?u64 = null,
    // Outgoing ACK state (acknowledgment frequency).
    ackQueued: bool = false,
    ackElicitingCount: u64 = 0,
    ackDeadlineMs: ?u64 = null,
    largestRecvTsMs: u64 = 0,

    pub fn init(allocator: Allocator, kind: SpaceKind) PnSpace {
        return .{ .kind = kind, .acktr = acktrMod.AckTracker.init(allocator), .gpa = allocator };
    }

    pub fn deinit(self: *PnSpace) void {
        self.acktr.deinit();
        for (self.sentData.items) |p| self.gpa.free(p);
        self.sentData.deinit(self.gpa);
        self.sent.deinit(self.gpa);
    }
};

/// TLS driver seam: consumes ordered CRYPTO data, produces handshake
/// bytes to transmit and installs keys when levels complete. `nowMs`
/// threads the connection clock through so handshake sends carry real
/// timestamps for loss recovery (never wall-clock-skewed literals).
pub const TlsDriver = struct {
    ctx: ?*anyopaque = null,
    /// Feed handshake data received from the peer.
    onData: ?*const fn (ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void = null,
    /// Called after connection setup to kick off the client flight.
    start: ?*const fn (ctx: ?*anyopaque, conn: *Connection, nowMs: u64) Error!void = null,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Borrowed slices (`data`, `reason`) alias the packet plaintext
    /// buffer and are valid only for the duration of the callback:
    /// copy anything retained past return.
    onStreamData: ?*const fn (ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void = null,
    onNewStream: ?*const fn (ctx: ?*anyopaque, sid: u64) void = null,
    onClose: ?*const fn (ctx: ?*anyopaque, errCode: u64, reason: []const u8) void = null,
    onHandshakeDone: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Peer reset a stream. Connection-level `onClose` is reserved for
    /// CONNECTION_CLOSE; stream resets route here.
    onStreamReset: ?*const fn (ctx: ?*anyopaque, sid: u64, code: u64) void = null,
    /// Peer asked us to stop sending on a stream. The stack already
    /// queued the matching RESET_STREAM reply.
    onStopSending: ?*const fn (ctx: ?*anyopaque, sid: u64, code: u64) void = null,
};

pub const Config = struct {
    maxIdleTimeoutMs: u64 = 30_000,
    initialMaxData: u64 = 1 << 20,
    maxUdpPayload: usize = 1472,
    isServer: bool = false,
    /// Preferred QUIC version for clients (default v1). Servers accept
    /// either v1 or v2 and adopt the version of the first Initial.
    version: u32 = 0x00000001,
    /// Require a Retry token before accepting a server-side Initial.
    retry: bool = false,
    /// Stable key for stateless Retry tokens. Generated per connection
    /// when omitted; production servers should supply a shared key.
    retryKey: ?[32]u8 = null,
};

pub const State = enum {
    initial,
    handshake,
    established,
    closing,
    draining,
    closed,
};

pub const MAX_DATAGRAM = 1500;
pub const MAX_PEER_CONNECTION_IDS = 16;
const MAX_CRYPTO_SEGMENTS = 1024;

/// Minimum UDP payload size for a datagram that carries an Initial
/// packet (RFC 9000 Section 14.1). A client MUST pad such datagrams up
/// to this size, and a server MUST discard Initial packets that arrive
/// in a smaller datagram.
pub const MIN_INITIAL_DATAGRAM = 1200;

pub const CidEntry = struct {
    sequence: u64,
    cid: [20]u8 = undefined,
    cidLen: u8 = 0,
    statelessResetToken: [16]u8 = undefined,
    retired: bool = false,
};

/// A control frame waiting for the next outgoing packet. Close reasons
/// are owned (duped at queue time, freed on drain).
pub const QueuedControl = struct {
    frame: frames.Frame,
    ownedReason: ?[]u8 = null,
};

/// Encryption level of a packet that is serialized but not yet flushed.
/// 0-RTT is tracked separately from 1-RTT even though both use the
/// application packet-number space: rejecting early data must remove
/// queued 0-RTT packets without touching 1-RTT output.
pub const QueuedKind = enum { initial, handshake, zero_rtt, application, other };

pub const Connection = struct {
    allocator: Allocator,
    io: std.Io,
    role: Role,
    cfg: Config,
    cbs: Callbacks = .{},
    tls: TlsDriver = .{},

    state: State = .initial,
    /// TLS has both sent our Finished and verified the peer's Finished
    /// (RFC 9001 Section 4.1.2).
    handshakeComplete: bool = false,
    /// Handshake confirmed: Handshake keys are discarded and no further
    /// Handshake packet may be sent or accepted (RFC 9001 Section 4.9.2).
    handshakeConfirmed: bool = false,
    /// Lowest packet number sent with 1-RTT keys, used for the client's
    /// optional ACK-based confirmation (RFC 9001 Section 4.1.2).
    firstAppPnSent: ?u64 = null,
    version: u32 = 0x00000001,
    versionNegotiated: ?u32 = null,
    vnSent: bool = false,
    retryKey: [32]u8 = undefined,
    retryToken: std.ArrayList(u8) = .empty,
    retryOdcid: [20]u8 = undefined,
    retryOdcidLen: u8 = 0,
    retryPending: bool = false,

    // Flow control.
    maxData: u64 = 1 << 20,
    dataSent: u64 = 0,
    dataReceived: u64 = 0,
    maxDataRemote: u64 = 1 << 20,
    /// Fallback per-stream send windows (peer's MAX_STREAM_DATA
    /// entries, once known, take precedence per stream). Seeded from
    /// transport parameters when exchanged, else compiled defaults.
    sendWindowBidi: u64 = 65536,
    sendWindowUni: u64 = 65536,

    // Connection IDs (RFC 9000 allows CIDs up to 20 bytes).
    dcid: [20]u8 = undefined, // our source cid / peer's destination
    dcidLen: u8 = 8,
    scid: [20]u8 = undefined, // what we advertise
    scidLen: u8 = 8,
    /// The DCID this endpoint first used (client: chosen at init).
    /// Validates the server's originalDestinationConnectionId.
    origDcid: [20]u8 = undefined,
    origDcidLen: u8 = 0,
    /// DCID used to derive Initial keys (changes after Retry).
    initialDcid: [20]u8 = undefined,
    initialDcidLen: u8 = 0,
    /// Server SCID received in a Retry packet (client side).
    retryScid: [20]u8 = undefined,
    retryScidLen: u8 = 0,
    /// Client Initial CRYPTO bytes retained for retransmission after Retry.
    initialCryptoLog: std.ArrayList(u8) = .empty,

    // Peer CID table (NEW_CONNECTION_ID entries).
    peerCids: std.ArrayList(CidEntry) = .empty,
    retirePriorTo: u64 = 0,

    // Stream-level flow control and reorder buffers.
    maxStreamData: std.AutoHashMap(u64, u64) = undefined,
    recvStreamEnd: std.AutoHashMap(u64, u64) = undefined,
    streams: std.AutoHashMap(u64, *qstream.Stream) = undefined,
    maxStreamsBidiRemote: u64 = 0,
    maxStreamsUniRemote: u64 = 0,

    // Loss detection.
    recovery: lossMod.Recovery = .{},
    /// Congestion window gating application-space sends (RFC 9002
    /// NewReno). Handshake and control traffic always flows.
    cc: ccMod.NewReno = ccMod.NewReno.init(1200),
    /// Path validation for address validation, migration and NAT rebinding (RFC 9000 Section 8.2).
    pathValidator: ?pathMod.PathValidator = null,
    /// ACK-eliciting bytes in flight across all spaces.
    bytesInFlight: usize = 0,
    /// Scratch for ACK range generation (reused per packet, no churn).
    ackScratch: std.ArrayList(acktrMod.Block) = .empty,
    /// Scratch for newly-acked / declared-lost packets.
    scratchSent: std.ArrayList(lossMod.SentPacket) = .empty,
    /// Set while dispatching the current datagram when any received
    /// frame is ack-eliciting.
    rxAckEliciting: bool = false,

    /// Control frames queued by the stack or the application, drained
    /// into the next outgoing packet so resets and window updates never
    /// starve behind bulk data.
    queuedControl: std.ArrayList(QueuedControl) = .empty,
    /// Highest stream send offset per stream (new-byte accounting for
    /// connection flow control; resends do not consume window twice).
    sendStreamEnd: std.AutoHashMap(u64, u64) = undefined,
    /// Limits we advertise (bumped on STREAMS_BLOCKED).
    maxStreamsBidiLocal: u64 = 128,
    maxStreamsUniLocal: u64 = 128,

    // Packet-number spaces.
    spaces: [3]PnSpace = undefined,

    // 1-RTT key update state (RFC 9001 Section 6). Secrets are retained
    // so either endpoint can rotate independently per direction.
    appTxSecret: ?[32]u8 = null,
    appRxSecret: ?[32]u8 = null,
    keyPhaseTx: bool = false,
    keyPhaseRx: bool = false,
    prevAppRxKeys: ?crypto.ProtectionKeys = null,
    prevKeyPhaseRx: bool = false,
    rxKeyUpdateAtMs: ?u64 = null,

    // 0-RTT early data state
    zeroRttKeysTx: ?crypto.ProtectionKeys = null,
    zeroRttKeysRx: ?crypto.ProtectionKeys = null,
    earlyDataAccepted: bool = false,
    earlyDataRejected: bool = false,
    maxEarlyData: u64 = 0,
    earlyDataBytesReceived: u64 = 0,

    // Transport parameters (peer's).
    peerParams: ?paramsMod.Params = null,

    // CRYPTO reassembly per space (offset -> contiguous).
    cryptoBuf: [3]std.ArrayList(u8) = undefined,
    cryptoRecvOff: [3]u64 = .{ 0, 0, 0 },
    cryptoSendOff: [3]u64 = .{ 0, 0, 0 },
    cryptoOut: [3]std.ArrayList(u8) = undefined,
    cryptoPending: [3]std.ArrayList(CryptoSegment) = undefined,

    // Anti-amplification (server side).
    bytesReceived: u64 = 0,
    bytesSent: u64 = 0,
    addressValidated: bool = false,

    // Timers (ms domain, caller-driven clock).
    lastActivityMs: u64 = 0,

    /// Bytes of the last datagram consumed (coalesced-packet support).
    rxConsumed: usize = 0,

    /// 1-RTT packets that arrived before the handshake completed.
    ///
    /// RFC 9001 Section 5.7: 1-RTT packets can arrive before the
    /// handshake does (a peer that receives the server flight early
    /// starts sending application data). Such packets cannot be
    /// decrypted yet, so they are buffered and replayed once the
    /// application keys are installed.
    pendingApp: std.ArrayList([]u8) = .empty,

    /// Serialized output accumulated by send operations.
    outbuf: std.ArrayList(u8) = .empty,
    /// Length of every packet queued in `outbuf`, in order. A QUIC
    /// datagram carries whole packets only (RFC 9000 Section 12.2), so the
    /// transport layer needs the packet boundaries to coalesce packets
    /// into datagrams without ever splitting one.
    outPackets: std.ArrayList(u32) = .empty,
    /// For each queued packet, whether a following packet may share its
    /// datagram. Long headers carry a Length field and can be
    /// concatenated; a short header does not, so it must be the last
    /// packet in a datagram (RFC 9000 Section 12.2).
    outPacketChainable: std.ArrayList(bool) = .empty,
    /// Encryption level of every queued packet. Discarding a packet
    /// number space (RFC 9001 Sections 4.9.1-4.9.2) must also remove the
    /// packets of that space that were already protected but not yet
    /// handed to the transport, or a Handshake ACK could still leave the
    /// endpoint after the keys are gone.
    outPacketKinds: std.ArrayList(QueuedKind) = .empty,

    /// `io` supplies the entropy for the connection IDs. There is
    /// deliberately no seed parameter: one invites callers to pass a
    /// clock value, and a predictable CID lets an off-path attacker
    /// correlate or hijack a flow (RFC 9000 Section 8.2).
    pub fn init(allocator: Allocator, io: std.Io, role: Role, cfg: Config) !*Connection {
        if (!packetMod.Version.isSupported(cfg.version)) return Error.UnsupportedVersion;
        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .role = role,
            .cfg = cfg,
            .version = cfg.version,
        };
        for (0..3) |i| {
            self.spaces[i] = PnSpace.init(allocator, @fromBackingInt(@intCast(i)));
        }
        for (&self.cryptoBuf) |*b| b.* = .empty;
        for (&self.cryptoOut) |*b| b.* = .empty;
        for (&self.cryptoPending) |*b| b.* = .empty;
        self.outbuf = .empty;
        self.peerCids = .empty;
        self.retryToken = .empty;
        self.initialCryptoLog = .empty;
        self.retryKey = cfg.retryKey orelse blk: {
            var key: [32]u8 = undefined;
            try io.randomSecure(&key);
            break :blk key;
        };
        self.maxStreamData = std.AutoHashMap(u64, u64).init(allocator);
        self.recvStreamEnd = std.AutoHashMap(u64, u64).init(allocator);
        self.sendStreamEnd = std.AutoHashMap(u64, u64).init(allocator);
        self.streams = std.AutoHashMap(u64, *qstream.Stream).init(allocator);

        // Local CIDs from OS entropy (8-byte default for the initial
        // handshake). Unpredictable, so an off-path observer cannot use
        // them to track or inject into a flow.
        self.scidLen = 8;
        try io.randomSecure(self.scid[0..self.scidLen]);
        if (role == .client) {
            self.dcidLen = 8;
            try io.randomSecure(self.dcid[0..self.dcidLen]); // chosen DCID for Initial
            @memcpy(self.origDcid[0..self.dcidLen], self.dcid[0..self.dcidLen]);
            self.origDcidLen = self.dcidLen;
            @memcpy(self.initialDcid[0..self.dcidLen], self.dcid[0..self.dcidLen]);
            self.initialDcidLen = self.dcidLen;
        }
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (&self.spaces) |*s| s.deinit();
        self.clearPendingApp();
        self.pendingApp.deinit(self.allocator);
        for (&self.cryptoBuf) |*b| b.deinit(self.allocator);
        for (&self.cryptoOut) |*b| b.deinit(self.allocator);
        for (&self.cryptoPending) |*b| {
            for (b.items) |segment| self.allocator.free(segment.data);
            b.deinit(self.allocator);
        }
        self.outbuf.deinit(self.allocator);
        self.outPackets.deinit(self.allocator);
        self.outPacketChainable.deinit(self.allocator);
        self.outPacketKinds.deinit(self.allocator);
        self.peerCids.deinit(self.allocator);
        self.retryToken.deinit(self.allocator);
        self.initialCryptoLog.deinit(self.allocator);
        self.maxStreamData.deinit();
        self.recvStreamEnd.deinit();
        self.sendStreamEnd.deinit();
        for (self.queuedControl.items) |*q| {
            if (q.ownedReason) |r| self.allocator.free(r);
        }
        self.queuedControl.deinit(self.allocator);
        var it = self.streams.valueIterator();
        while (it.next()) |sp| {
            sp.*.deinit();
            self.allocator.destroy(sp.*);
        }
        self.streams.deinit();
        self.ackScratch.deinit(self.allocator);
        self.scratchSent.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn spaceFor(self: *Connection, lt: packetMod.LongType) *PnSpace {
        return switch (lt) {
            .initial => &self.spaces[0],
            .handshake => &self.spaces[1],
            else => &self.spaces[2],
        };
    }

    // Key installation (driven by TLS driver)

    /// Installs Initial keys derived from the original DCID.
    pub fn installInitialKeys(self: *Connection) Error!void {
        const keyDcid = if (self.initialDcidLen > 0) self.initialDcid[0..self.initialDcidLen] else self.dcid[0..self.dcidLen];
        const secrets = crypto.initialSecrets(keyDcid, self.version) catch return Error.TlsDriverFailed;
        const sp = &self.spaces[0];
        sp.keysTx = if (self.role == .client)
            crypto.initialProtection(secrets, .client)
        else
            crypto.initialProtection(secrets, .server);
        sp.keysRx = if (self.role == .client)
            crypto.initialProtection(secrets, .server)
        else
            crypto.initialProtection(secrets, .client);
    }

    /// Installs Handshake or 1-RTT keys provided by the TLS layer.
    pub fn installKeys(
        self: *Connection,
        kind: SpaceKind,
        txSecret: [32]u8,
        rxSecret: [32]u8,
    ) !void {
        const sp = &self.spaces[@backingInt(kind)];
        var ktx = crypto.deriveProtectionKeys(txSecret);
        var krx = crypto.deriveProtectionKeys(rxSecret);
        // AES-128-GCM suite for this build; HP key same width.
        _ = &ktx;
        _ = &krx;
        sp.keysTx = ktx;
        sp.keysRx = krx;
        if (kind == .application) {
            if (self.role == .client) {
                // RFC 9001 Section 4.9.3: a client discards 0-RTT keys as
                // soon as it installs 1-RTT keys. Early data is never sent
                // under old keys after this point.
                self.zeroRttKeysTx = null;
                self.zeroRttKeysRx = null;
            }
            self.appTxSecret = txSecret;
            self.appRxSecret = rxSecret;
            self.keyPhaseTx = false;
            self.keyPhaseRx = false;
            self.prevAppRxKeys = null;
            self.prevKeyPhaseRx = false;
            self.rxKeyUpdateAtMs = null;
        }
    }

    /// Rotates our sending 1-RTT keys (RFC 9001 Section 6). The peer
    /// observes the new Key Phase bit and derives the same next secret.
    pub fn initiateKeyUpdate(self: *Connection) Error!void {
        if (self.state != .established and self.state != .closing) return Error.InvalidState;
        const current = self.appTxSecret orelse return Error.TlsDriverFailed;
        const next = crypto.nextApplicationSecret(current);
        self.appTxSecret = next;
        self.spaces[2].keysTx = crypto.deriveProtectionKeys(next);
        self.keyPhaseTx = !self.keyPhaseTx;
    }

    pub fn updateKeysForTesting(self: *Connection, secret: [32]u8) void {
        self.appTxSecret = secret;
        self.appRxSecret = secret;
        self.spaces[2].keysTx = crypto.deriveProtectionKeys(secret);
        self.spaces[2].keysRx = crypto.deriveProtectionKeys(secret);
        self.keyPhaseTx = false;
        self.keyPhaseRx = false;
        self.prevAppRxKeys = null;
        self.prevKeyPhaseRx = false;
        self.rxKeyUpdateAtMs = null;
    }

    pub fn installZeroRttKeys(self: *Connection, secret: [32]u8, isTx: bool) void {
        const keys = crypto.deriveProtectionKeys(secret);
        if (isTx) {
            self.zeroRttKeysTx = keys;
        } else {
            self.zeroRttKeysRx = keys;
        }
    }

    pub fn discardZeroRtt(self: *Connection) void {
        self.zeroRttKeysTx = null;
        self.zeroRttKeysRx = null;
        // RFC 9001 Section 4.9.3: once 0-RTT keys are discarded no 0-RTT
        // packet may be sent, including one that is already serialized.
        self.dropQueuedKind(.zero_rtt);
        self.earlyDataRejected = true;
        self.earlyDataAccepted = false;
    }

    /// Queues TLS handshake bytes for later packetization as CRYPTO frames.
    pub fn queueCrypto(self: *Connection, kind: SpaceKind, data: []const u8) Error!u64 {
        if (data.len > MAX_DATAGRAM) return Error.BufferTooSmall;
        const idx = @backingInt(kind);
        const offset = self.cryptoSendOff[idx];
        self.cryptoSendOff[idx] = std.math.add(u64, offset, data.len) catch return Error.BufferTooSmall;
        self.cryptoOut[idx].appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        if (kind == .initial) self.initialCryptoLog.appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        return offset;
    }

    /// Peeks queued CRYPTO bytes while retaining their absolute stream offset.
    /// Call `consumeCrypto` after the frame has been serialized.
    pub fn takeCrypto(self: *Connection, kind: SpaceKind, maxBytes: usize) ?CryptoChunk {
        const idx = @backingInt(kind);
        const queued = self.cryptoOut[idx].items;
        if (queued.len == 0) return null;
        const take = @min(maxBytes, queued.len);
        const result: CryptoChunk = .{ .offset = self.cryptoSendOff[idx] - queued.len, .data = queued[0..take] };
        return result;
    }

    /// Consumes bytes previously returned by `takeCrypto` after packetization.
    pub fn consumeCrypto(self: *Connection, kind: SpaceKind, count: usize) bool {
        const idx = @backingInt(kind);
        if (count > self.cryptoOut[idx].items.len) return false;
        self.cryptoOut[idx].replaceRange(self.allocator, 0, count, &.{}) catch return false;
        return true;
    }

    /// Discards one packet-number space exactly once.
    ///
    /// RFC 9001 Sections 4.9.1 and 4.9.2 require the Initial and Handshake
    /// keys to be dropped at well-defined points. Once a space is discarded
    /// it can neither protect nor open another packet, so the retained
    /// payloads, CRYPTO fragments, ACK timers and loss-recovery bookkeeping
    /// are released as well. The connection-wide in-flight counter is
    /// reduced by this space's contribution; without that, discarded
    /// packets would permanently consume congestion window.
    fn discardSpace(self: *Connection, idx: usize) void {
        const sp = &self.spaces[idx];
        if (sp.discarded) return;
        sp.discarded = true;
        // Packets of this space may already be serialized in `outbuf`
        // (an ACK or probe built before the keys were discarded). They
        // must never reach the wire, so remove them before dropping the
        // keys they were protected with.
        self.dropQueuedKind(switch (idx) {
            0 => .initial,
            1 => .handshake,
            else => .application,
        });
        sp.keysTx = null;
        sp.keysRx = null;
        for (sp.sentData.items) |p| self.allocator.free(p);
        sp.sentData.clearRetainingCapacity();
        sp.sent.clearRetainingCapacity();
        self.bytesInFlight -|= sp.inFlightBytes;
        sp.inFlightBytes = 0;
        sp.inFlightAckEliciting = 0;
        sp.lastAckElicitingTsMs = null;
        sp.ackedMax = null;
        sp.lossTimeMs = null;
        sp.ackQueued = false;
        sp.ackElicitingCount = 0;
        sp.ackDeadlineMs = null;
        sp.largestRecvTsMs = 0;
        // Neither outbound CRYPTO data nor inbound fragments can be used
        // in a discarded space; keeping them would only leak memory.
        self.cryptoOut[idx].clearRetainingCapacity();
        self.cryptoBuf[idx].clearRetainingCapacity();
        for (self.cryptoPending[idx].items) |segment| self.allocator.free(segment.data);
        self.cryptoPending[idx].clearRetainingCapacity();
    }

    /// Confirms the handshake and discards the Handshake keys.
    ///
    /// RFC 9001 Sections 4.1.2 and 4.9.2: the server confirms the handshake
    /// when it has sent and verified Finished; the client confirms it when
    /// it receives HANDSHAKE_DONE (or, optionally, an acknowledgment for a
    /// 1-RTT packet). Once confirmed no Handshake packet may be sent or
    /// processed. Idempotent.
    pub fn confirmHandshake(self: *Connection) void {
        if (self.handshakeConfirmed) return;
        self.handshakeConfirmed = true;
        self.handshakeComplete = true;
        self.discardSpace(1);
        // RFC 9001 Section 4.9.3: 0-RTT keys are no longer useful once the
        // handshake is confirmed. `earlyDataAccepted` is retained for
        // callers; only the keys are dropped, together with any queued
        // packet protected with them.
        self.zeroRttKeysTx = null;
        self.zeroRttKeysRx = null;
        self.dropQueuedKind(.zero_rtt);
        if (self.state == .initial or self.state == .handshake) self.state = .established;
    }

    /// Discards the Initial packet protection keys.
    ///
    /// RFC 9001 Section 4.9.1: a client discards Initial keys when it first
    /// sends a Handshake packet, and a server discards them when it first
    /// successfully processes one. Afterwards no Initial packet may be sent,
    /// so the pending Initial retransmissions are dropped as well.
    pub fn discardInitialKeys(self: *Connection) void {
        self.discardSpace(0);
    }

    // Send path

    /// Queues a control frame for the next outgoing packet. Close
    /// reasons are copied; the caller retains its slice.
    pub fn queueControlFrame(self: *Connection, f: frames.Frame) Error!void {
        var owned: ?[]u8 = null;
        if (f == .connectionClose) {
            owned = try self.allocator.dupe(u8, f.connectionClose.reason);
        }
        errdefer if (owned) |r| self.allocator.free(r);
        try self.queuedControl.append(self.allocator, .{ .frame = f, .ownedReason = owned });
    }

    /// Encodes all queued control frames into `payload`, freeing any
    /// owned close reasons. Queued frames ride ahead of bulk data.
    fn drainControlQueue(self: *Connection, payload: *std.ArrayList(u8)) Error!void {
        for (self.queuedControl.items) |*q| {
            if (q.frame == .connectionClose) {
                q.frame.connectionClose.reason = q.ownedReason orelse "";
            }
            frames.encode(payload, self.allocator, q.frame) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            if (q.ownedReason) |r| self.allocator.free(r);
        }
        self.queuedControl.clearRetainingCapacity();
    }

    /// Sends queued control frames immediately (no-op when empty).
    pub fn flushControl(self: *Connection, kind: SpaceKind, nowMs: u64) Error!void {
        if (self.queuedControl.items.len == 0) return;
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try self.drainControlQueue(&payload);
        try self.packetize(kind, &payload, nowMs);
    }

    /// Sends RESET_STREAM immediately (stream error). `finalSize` must
    /// equal the stream's send offset (RFC 9000 Section 19.4).
    pub fn sendResetStream(self: *Connection, sid: u64, code: u64, finalSize: u64, nowMs: u64) Error!void {
        try self.queueControlFrame(.{ .resetStream = .{ .streamId = sid, .errorCode = code, .finalSize = finalSize } });
        try self.flushControl(.application, nowMs);
    }

    /// Sends STOP_SENDING immediately.
    pub fn sendStopSending(self: *Connection, sid: u64, code: u64, nowMs: u64) Error!void {
        try self.queueControlFrame(.{ .stopSending = .{ .streamId = sid, .errorCode = code } });
        try self.flushControl(.application, nowMs);
    }

    /// Raises our receive window and sends MAX_DATA immediately.
    pub fn sendMaxData(self: *Connection, maximum: u64, nowMs: u64) Error!void {
        if (maximum > self.maxData) self.maxData = maximum;
        try self.queueControlFrame(.{ .maxData = .{ .maximum = self.maxData } });
        try self.flushControl(.application, nowMs);
    }

    /// Raises a stream receive window and sends MAX_STREAM_DATA.
    pub fn sendMaxStreamData(self: *Connection, sid: u64, maximum: u64, nowMs: u64) Error!void {
        if (self.streams.get(sid)) |st| {
            if (maximum > st.recvMaxOffset) st.recvMaxOffset = maximum;
        }
        try self.queueControlFrame(.{ .maxStreamData = .{ .streamId = sid, .maximum = maximum } });
        try self.flushControl(.application, nowMs);
    }

    /// Raises a stream-count limit and sends MAX_STREAMS.
    pub fn sendMaxStreams(self: *Connection, bidi: bool, maximum: u64, nowMs: u64) Error!void {
        if (bidi) {
            if (maximum > self.maxStreamsBidiLocal) self.maxStreamsBidiLocal = maximum;
        } else {
            if (maximum > self.maxStreamsUniLocal) self.maxStreamsUniLocal = maximum;
        }
        try self.queueControlFrame(.{ .maxStreams = .{ .maximum = maximum, .bidi = bidi } });
        try self.flushControl(.application, nowMs);
    }

    /// Sends CONNECTION_CLOSE immediately (`isApp` selects the
    /// application variant carrying H3/QPACK codes).
    pub fn sendConnectionClose(self: *Connection, code: u64, reason: []const u8, isApp: bool, nowMs: u64) Error!void {
        try self.queueControlFrame(.{ .connectionClose = .{
            .errorCode = code,
            .triggeringFrameType = 0,
            .reason = reason,
            .application = isApp,
        } });
        try self.flushControl(.application, nowMs);
    }

    /// Sends STREAM bytes with flow-control gating and window
    /// accounting. Resends of already-counted ranges do not consume
    /// window twice. Returns `error.SendBlocked` when the connection or
    /// stream window is exhausted; retry after MAX_DATA /
    /// MAX_STREAM_DATA arrives.
    pub fn sendStreamChecked(
        self: *Connection,
        sid: u64,
        offset: u64,
        data: []const u8,
        fin: bool,
        nowMs: u64,
    ) Error!void {
        const bidi = (sid & 0x02) == 0;
        const streamLim = self.maxStreamData.get(sid) orelse
            (if (bidi) self.sendWindowBidi else self.sendWindowUni);
        const end = std.math.add(u64, offset, data.len) catch return Error.BufferTooSmall;
        if (end > streamLim) return Error.SendBlocked;
        if (self.dataSent +| data.len > self.maxDataRemote) return Error.SendBlocked;
        // Congestion gate (application bulk data only; handshake and
        // control traffic always flows so recovery can never deadlock).
        // The +128 covers header/tag/queued-control slack.
        if (self.bytesInFlight + data.len + 128 > self.cc.bytesInFlightLimit()) return Error.SendBlocked;
        const oldEnd = self.sendStreamEnd.get(sid) orelse 0;
        if (end > oldEnd) {
            self.dataSent +|= end - oldEnd;
            try self.sendStreamEnd.put(sid, end);
        }
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try self.drainControlQueue(&payload);
        frames.encode(&payload, self.allocator, .{ .stream = .{
            .id = sid,
            .offset = offset,
            .data = data,
            .fin = fin,
        } }) catch |e| switch (e) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.ProtocolViolation,
        };
        try self.packetize(.application, &payload, nowMs);
    }

    /// Queues one protected packet into outbuf.
    pub fn sendFrames(
        self: *Connection,
        kind: SpaceKind,
        builder: anytype,
        nowMs: u64,
    ) Error!void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try self.drainControlQueue(&payload);
        try builder(self.allocator, &payload);
        if (payload.items.len == 0) {
            frames.encode(&payload, self.allocator, .ping) catch return Error.ProtocolViolation;
        }
        try self.packetize(kind, &payload, nowMs);
    }

    /// Protects one packet from already-built frames into outbuf.
    fn packetize(
        self: *Connection,
        kind: SpaceKind,
        payload: *std.ArrayList(u8),
        nowMs: u64,
    ) Error!void {
        switch (self.state) {
            .closing, .draining, .closed => return Error.ConnectionClosed,
            else => {},
        }
        const sp = &self.spaces[@backingInt(kind)];
        if (sp.discarded) return Error.TlsDriverFailed;
        const isZeroRtt = (kind == .application and sp.keysTx == null and self.zeroRttKeysTx != null);
        const keys = if (isZeroRtt)
            self.zeroRttKeysTx.?
        else
            (sp.keysTx orelse return Error.TlsDriverFailed);

        // Server anti-amplification gate until address validation.
        if (self.role == .server and !self.addressValidated) {
            const budget = self.bytesReceived *| 3;
            if (self.bytesSent >= budget) return Error.AmplificationBlocked;
        }

        // Queued ACKs ride first so the peer can release its own
        // recovery state promptly. ACK frames are forbidden in 0-RTT
        // (RFC 9000 Table 3); a queued ACK waits for a 1-RTT packet.
        if (sp.ackQueued and !isZeroRtt) {
            self.ackScratch.clearRetainingCapacity();
            sp.acktr.generateBlocks(&self.ackScratch, self.allocator, 32) catch return Error.OutOfMemory;
            if (self.ackScratch.items.len > 0) {
                const largest = self.ackScratch.items[0].highest;
                // RFC 9000 Section 19.3: the ACK Delay field counts units
                // of 2^ack_delay_exponent microseconds. Our transport
                // parameters advertise the default exponent (3), i.e.
                // 8 us per unit, so 125 units per millisecond.
                const delay = (nowMs -| sp.largestRecvTsMs) *| 125;
                frames.encodeAckFromBlocks(payload, self.allocator, largest, delay, self.ackScratch.items, null) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => return Error.ProtocolViolation,
                };
            }
            sp.ackQueued = false;
            sp.ackElicitingCount = 0;
            sp.ackDeadlineMs = null;
        }

        const pn = sp.nextPn;
        const pnLen: usize = 2;
        var pnBytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pnBytes, @intCast(pn & 0xFFFFFFFF), .big);

        // Ensure enough ciphertext for the header-protection sample
        // (sampleOff+16 <= wire) BEFORE the Length field is written.
        const minPayload = 4 + 16 - pnLen;
        if (payload.items.len < minPayload) {
            try payload.appendNTimes(self.allocator, 0x00, minPayload - payload.items.len);
        }

        // RFC 9000 Section 14.1: a client MUST expand the payload of
        // every UDP datagram carrying an Initial packet to at least 1200
        // bytes, and a server MUST do the same for datagrams carrying an
        // ack-eliciting Initial packet. Peers that enforce the minimum
        // drop smaller datagrams, so an unpadded flight never completes
        // the handshake.
        if (kind == .initial) {
            const must_pad = switch (self.role) {
                .client => true,
                .server => payloadHasAckEliciting(payload.items),
            };
            if (must_pad) try self.padInitialPayload(payload, pnLen);
        }

        var buf: [MAX_DATAGRAM]u8 = undefined;
        const hdrLen = if (isZeroRtt)
            packetMod.writeLongHeader(buf[0..], .{
                .type = .zeroRtt,
                .version = self.version,
                .dcid = self.dcid[0..self.dcidLen],
                .scid = self.scid[0..self.scidLen],
                .token = "",
                .pnLen = pnLen,
                .protectedPayloadLen = payload.items.len + 16,
            }) catch return Error.BufferTooSmall
        else if (kind == .application)
            packetMod.writeShortHeader(buf[0..], .{
                .keyPhase = self.keyPhaseTx,
                .dcid = self.dcid[0..self.dcidLen],
                .pnLen = pnLen,
            }) catch return Error.BufferTooSmall
        else
            packetMod.writeLongHeader(buf[0..], .{
                .type = if (kind == .initial) .initial else .handshake,
                .version = self.version,
                .dcid = self.dcid[0..self.dcidLen],
                .scid = self.scid[0..self.scidLen],
                .token = if (kind == .initial) self.retryToken.items else "",
                .pnLen = pnLen,
                .protectedPayloadLen = payload.items.len + 16,
            }) catch return Error.BufferTooSmall;

        const aadLen = hdrLen + pnLen;
        @memcpy(buf[hdrLen..][0..pnLen], pnBytes[4 - pnLen ..]);

        var ct: [MAX_DATAGRAM]u8 = undefined;
        var tag: [16]u8 = undefined;
        protect.sealWithKeys(ct[0..payload.items.len], &tag, payload.items, buf[0..aadLen], keys, pn);

        var wireLen: usize = aadLen;
        @memcpy(buf[wireLen..][0..payload.items.len], ct[0..payload.items.len]);
        wireLen += payload.items.len;
        @memcpy(buf[wireLen..][0..16], tag[0..]);
        wireLen += 16;

        // Header protection LAST: masks first byte + pn-field bytes with a
        // sample drawn from the ciphertext (RFC 9001 section 5.4).
        const sampleOff = hdrLen + 4;
        if (sampleOff + 16 > wireLen) return Error.BufferTooSmall;
        var sample: [16]u8 = undefined;
        @memcpy(&sample, buf[sampleOff..][0..16]);
        const mask = switch (keys.cipher) {
            .aes128Gcm, .aes256Gcm => blk: {
                var hp16: [16]u8 = undefined;
                @memcpy(&hp16, keys.hp[0..16]);
                break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
            },
            .chacha20Poly1305 => blk: {
                var hp32: [32]u8 = undefined;
                @memcpy(&hp32, keys.hp[0..32]);
                break :blk protect.hpMaskChacha(hp32, &sample);
            },
        };
        buf[0] ^= mask[0] & @as(u8, if (kind != .application or isZeroRtt) 0x0F else 0x1F);
        for (0..pnLen) |i| buf[hdrLen + i] ^= mask[1 + i];

        const queued_kind: QueuedKind = if (isZeroRtt)
            .zero_rtt
        else switch (kind) {
            .initial => .initial,
            .handshake => .handshake,
            .application => .application,
        };
        try self.queueOutPacket(buf[0..wireLen], kind != .application or isZeroRtt, queued_kind);
        self.bytesSent += wireLen;
        if (payloadHasAckEliciting(payload.items)) {
            sp.sent.append(self.allocator, .{
                .pn = sp.nextPn,
                .tsMs = nowMs,
                .inFlightBytes = wireLen,
                .ackEliciting = true,
            }) catch return Error.OutOfMemory;
            const copy = self.allocator.dupe(u8, payload.items) catch return Error.OutOfMemory;
            errdefer self.allocator.free(copy);
            sp.sentData.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return Error.OutOfMemory;
            };
            sp.inFlightBytes +|= wireLen;
            self.bytesInFlight +|= wireLen;
            sp.inFlightAckEliciting +|= 1;
            sp.lastAckElicitingTsMs = nowMs;
        }
        if (kind == .application and !isZeroRtt and self.firstAppPnSent == null) {
            // RFC 9001 Section 4.1.2: remember the lowest packet number
            // sent with 1-RTT keys so an acknowledgment of it can confirm
            // the handshake on the client.
            self.firstAppPnSent = pn;
        }
        sp.nextPn += 1;
    }

    /// Pads the payload of an Initial packet so the resulting UDP
    /// datagram reaches `MIN_INITIAL_DATAGRAM` bytes (RFC 9000 Section
    /// 14.1). PADDING frames are the only thing added; they carry no
    /// information and are never retransmitted on their own.
    fn padInitialPayload(self: *Connection, payload: *std.ArrayList(u8), pnLen: usize) Error!void {
        const tokenLen = self.retryToken.items.len;
        const tokenVarintLen = packetMod.varintLen(tokenLen);
        const dcidLen = self.dcidLen;
        const scidLen = self.scidLen;

        var pad: usize = 0;
        var lenVarintLen: usize = 1;
        // Two iterations are enough: growing the payload by the missing
        // bytes can only widen the Length field, never shrink it.
        var iter: usize = 0;
        while (iter < 4) : (iter += 1) {
            const hdrLen = 5 + 1 + dcidLen + 1 + scidLen + tokenVarintLen + tokenLen + lenVarintLen;
            const wireLen = hdrLen + pnLen + payload.items.len + pad + 16;
            if (wireLen >= MIN_INITIAL_DATAGRAM) break;
            pad += MIN_INITIAL_DATAGRAM - wireLen;
            const lengthValue = payload.items.len + pad + 16 + pnLen;
            lenVarintLen = packetMod.varintLen(lengthValue);
        }
        if (pad == 0) return;
        if (payload.items.len + pad > MAX_DATAGRAM) return Error.BufferTooSmall;
        try payload.appendNTimes(self.allocator, 0x00, pad);
    }

    /// True when the built payload carries a frame that requires the peer
    /// to acknowledge (RFC 9000 Section 13.2).
    ///
    /// Only ACK, PADDING, and CONNECTION_CLOSE are not ack-eliciting;
    /// PING *is* ack-eliciting, so a packet carrying only PING must still
    /// be tracked for loss recovery and must arm the PTO.
    fn payloadHasAckEliciting(payload: []const u8) bool {
        var pos: usize = 0;
        while (pos < payload.len) {
            const f = frames.decode(payload, &pos) catch return true;
            switch (f) {
                .padding, .ack, .connectionClose => {},
                else => return true,
            }
        }
        return false;
    }

    /// Removes a tracked sent packet (acknowledged or superseded),
    /// releasing its payload and window accounting.
    fn removeSent(self: *Connection, sp: *PnSpace, idx: usize) void {
        const p = sp.sent.items[idx];
        const pay = sp.sentData.items[idx];
        self.allocator.free(pay);
        _ = sp.sent.swapRemove(idx);
        _ = sp.sentData.swapRemove(idx);
        sp.inFlightBytes -|= p.inFlightBytes;
        self.bytesInFlight -|= p.inFlightBytes;
        sp.inFlightAckEliciting -|= 1;
    }

    fn indexOfPn(list: []const lossMod.SentPacket, pn: u64) ?usize {
        for (list, 0..) |p, i| {
            if (p.pn == pn) return i;
        }
        return null;
    }

    /// Removes newly-acked packets in [lo, hi], collecting copies for
    /// congestion and RTT accounting.
    fn ackRangeRemove(self: *Connection, sp: *PnSpace, lo: u64, hi: u64) Error!void {
        var i: usize = 0;
        while (i < sp.sent.items.len) {
            const p = sp.sent.items[i];
            if (p.pn >= lo and p.pn <= hi) {
                try self.scratchSent.append(self.allocator, p);
                self.removeSent(sp, i);
            } else {
                i += 1;
            }
        }
    }

    /// Processes one received ACK frame: retires newly-acked packets
    /// (RTT sample from the largest, per-packet CC growth), runs loss
    /// detection over the remainder (congestion event plus immediate
    /// retransmit on new loss), and frees the frame's range list.
    fn onAckFrame(self: *Connection, sp: *PnSpace, a: frames.Ack, nowMs: u64) Error!void {
        if (sp.ackedMax) |old| {
            if (a.largestAcknowledged > old) sp.ackedMax = a.largestAcknowledged;
        } else {
            sp.ackedMax = a.largestAcknowledged;
        }
        if (self.recovery.largestAckedPn) |old| {
            if (a.largestAcknowledged > old) self.recovery.largestAckedPn = a.largestAcknowledged;
        } else {
            self.recovery.largestAckedPn = a.largestAcknowledged;
        }

        self.scratchSent.clearRetainingCapacity();
        const firstLo = a.largestAcknowledged -| a.firstRange;
        try self.ackRangeRemove(sp, firstLo, a.largestAcknowledged);
        var prevLow = firstLo;
        for (a.ranges()) |r| {
            if (r.gap + 2 > prevLow) break;
            const curHigh = prevLow - r.gap - 2;
            const curLo = curHigh -| r.length;
            try self.ackRangeRemove(sp, curLo, curHigh);
            prevLow = curLo;
        }

        var sampleTs: ?u64 = null;
        var samplePn: u64 = 0;
        for (self.scratchSent.items) |p| {
            self.cc.onPacketAcked(p.inFlightBytes, p.tsMs);
            if (sampleTs == null or p.pn > samplePn) {
                samplePn = p.pn;
                sampleTs = p.tsMs;
            }
        }
        if (sampleTs) |ts| {
            self.recovery.rtt.onAckReceived(ts, nowMs, self.recovery.cfg.maxAckDelayMs);
            self.recovery.onAckOfInFlight();
        }
        try self.runLossDetection(sp, nowMs);
        // Note: `a.ranges` is freed by the dispatch caller, not here.
    }

    /// Runs time/packet-threshold loss detection over a space: congestion
    /// event (plus persistent-congestion collapse) and immediate
    /// retransmit of newly declared lost packets.
    fn runLossDetection(self: *Connection, sp: *PnSpace, nowMs: u64) Error!void {
        if (sp.discarded) return;
        self.recovery.largestAckedPn = sp.ackedMax;
        self.recovery.lossTimeMs = sp.lossTimeMs;
        self.recovery.detectLost(sp.sent.items, nowMs, &self.scratchSent, self.allocator) catch
            return Error.OutOfMemory;
        sp.lossTimeMs = self.recovery.lossTimeMs;
        if (self.scratchSent.items.len == 0) return;
        self.cc.onCongestionEvent(nowMs);
        if (self.recovery.persistentCongestion()) self.cc.onPersistentCongestion();
        for (self.scratchSent.items) |lost| {
            const idx = indexOfPn(sp.sent.items, lost.pn) orelse continue;
            try self.retransmitEntry(sp, idx, nowMs);
        }
    }

    /// Re-emits one unacked packet's frames (minus ACK/PADDING) under a
    /// fresh packet number, transferring payload ownership to the new
    /// tracking entry.
    fn retransmitEntry(self: *Connection, sp: *PnSpace, idx: usize, nowMs: u64) Error!void {
        const stored = sp.sentData.items[idx];
        // A space whose keys were discarded (the Initial space once the
        // handshake moved on) can no longer protect anything: drop the
        // entry instead of failing the connection.
        if (sp.discarded or sp.keysTx == null) {
            self.removeSent(sp, idx);
            return;
        }
        var rebuilt = std.ArrayList(u8).empty;
        defer rebuilt.deinit(self.allocator);
        var pos: usize = 0;
        var any = false;
        while (pos < stored.len) {
            const f = frames.decode(stored, &pos) catch break;
            switch (f) {
                .ack, .padding => {},
                else => {
                    // A retransmitted STREAM frame must carry an explicit
                    // offset: the peer's current offset may have moved on
                    // since the original frame was sent (RFC 9000 19.8).
                    const frame: frames.Frame = switch (f) {
                        .stream => |s| .{ .stream = .{
                            .id = s.id,
                            .offset = s.offset,
                            .offPresent = true,
                            .data = s.data,
                            .fin = s.fin,
                        } },
                        else => f,
                    };
                    frames.encode(&rebuilt, self.allocator, frame) catch |e| switch (e) {
                        error.OutOfMemory => return Error.OutOfMemory,
                        else => return Error.ProtocolViolation,
                    };
                    any = true;
                },
            }
        }
        const kind: SpaceKind = sp.kind;
        if (!any) {
            // Nothing retransmittable (only ACK/PADDING): drop tracking.
            self.removeSent(sp, idx);
            return;
        }
        // Packetize first so a send failure keeps the old entry (and
        // its payload) tracked for the next probe.
        try self.packetize(kind, &rebuilt, nowMs);
        self.removeSent(sp, idx);
    }

    /// Sends one PTO probe for a space: oldest unacked payload, else a
    /// bare PING. Probes bypass the congestion gate (one packet only).
    fn sendProbe(self: *Connection, spaceIdx: usize, nowMs: u64) Error!void {
        const sp = &self.spaces[spaceIdx];
        const kind: SpaceKind = @fromBackingInt(@intCast(spaceIdx));
        if (sp.sent.items.len > 0) {
            try self.retransmitEntry(sp, 0, nowMs);
            return;
        }
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        frames.encode(&payload, self.allocator, .ping) catch |e| switch (e) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.ProtocolViolation,
        };
        try self.packetize(kind, &payload, nowMs);
    }

    /// Emits a packet carrying only the ACK that `ackQueued` records.
    /// `packetize` prepends the queued ACK and pads the payload to the
    /// minimum needed for header protection.
    fn sendAckOnly(self: *Connection, kind: SpaceKind, nowMs: u64) Error!void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try self.packetize(kind, &payload, nowMs);
    }

    /// Drives loss and PTO timers; call every pump iteration with the
    /// clock. Retransmits declare themselves through the normal send
    /// path (fresh packet numbers, re-accounted windows). A pending ACK
    /// is sent on its own packet instead of waiting for unrelated
    /// application data, so the peer can retire its recovery state.
    pub fn pollTimeouts(self: *Connection, nowMs: u64) Error!void {
        switch (self.state) {
            .closing, .draining, .closed => return,
            else => {},
        }
        self.pollAckTimers(nowMs);
        for (&self.spaces, 0..) |*sp, idx| {
            if (sp.discarded) continue;
            if (sp.ackQueued and sp.keysTx != null) {
                try self.sendAckOnly(@fromBackingInt(@intCast(idx)), nowMs);
            }
            if (sp.lossTimeMs) |lt| {
                if (nowMs >= lt and sp.sent.items.len > 0) {
                    try self.runLossDetection(sp, nowMs);
                }
            }
            if (sp.inFlightAckEliciting > 0) {
                const pto = self.recovery.ptoDuration(sp.kind == .application);
                const last = sp.lastAckElicitingTsMs orelse nowMs;
                if (nowMs -| last >= pto) {
                    self.recovery.onPtoExpired();
                    try self.sendProbe(idx, nowMs);
                }
            }
        }
    }
    // Receive path

    /// Processes one UDP datagram, iterating over COALESCED packets.
    pub fn receiveDatagram(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        switch (self.state) {
            .draining, .closed => return Error.Draining,
            else => {},
        }
        self.bytesReceived += dgram.len;
        self.lastActivityMs = nowMs;

        var off: usize = 0;
        while (off < dgram.len) {
            const slice = dgram[off..];
            if (slice.len < 5) return;
            const first = slice[0];
            if ((first & 0x80) != 0) {
                const peerVersion = std.mem.readInt(u32, slice[1..5], .big);
                if (peerVersion == 0) {
                    if (self.role == .client and self.state == .initial) {
                        try self.handleVersionNegotiation(slice);
                    }
                    return;
                }
                if (!packetMod.Version.isSupported(peerVersion)) {
                    if (self.role == .server) try self.sendVersionNegotiation(slice);
                    return;
                }
                const wireType: u2 = @truncate((first >> 4) & 0x3);
                if (packetMod.LongType.fromWire(peerVersion, wireType) == .retry) {
                    if (self.role == .client and self.state == .initial) {
                        try self.handleRetry(slice, nowMs);
                    }
                    return;
                }
                // RFC 9000 Section 14.1: a server MUST discard an Initial
                // packet that arrives in a datagram smaller than 1200
                // bytes. Dropping it here also keeps a spoofed small
                // Initial from eliciting an amplified server flight. A
                // client has no such duty: an undersized datagram must
                // never close the connection (RFC 9000 Section 14).
                if (self.role == .server and
                    packetMod.LongType.fromWire(peerVersion, wireType) == .initial and
                    dgram.len < MIN_INITIAL_DATAGRAM)
                {
                    return;
                }
                self.rxConsumed = 0;
                try self.receiveLong(slice, nowMs);
                if (self.rxConsumed == 0) return;
                off += self.rxConsumed;
            } else {
                // A short header must carry the fixed bit (RFC 9000
                // Section 17.3.1). A datagram can be padded after its last
                // packet with bytes that are not a packet at all; aioquic
                // pads the Initial datagram with trailing zeros. Ignore the
                // remainder instead of failing the whole datagram.
                if ((first & 0x40) == 0) return;
                try self.receiveShort(slice, nowMs);
                off = dgram.len; // short packet spans the rest
            }
        }
    }

    /// Validates a Version Negotiation packet (RFC 9000 Section 6.2).
    /// Spoofed or malformed responses are ignored; a valid response
    /// that does not select our current version aborts this attempt so
    /// the caller can retry with `versionNegotiated`.
    fn handleVersionNegotiation(self: *Connection, dgram: []const u8) Error!void {
        const vn = packetMod.parseVersionNegotiation(dgram) catch return;
        if (!std.mem.eql(u8, vn.dcid, self.scid[0..self.scidLen])) return;
        if (!std.mem.eql(u8, vn.scid, self.dcid[0..self.dcidLen])) return;
        for (0..vn.versions.len / 4) |i| {
            if (vn.versionAt(i) == self.version) return; // spoofed downgrade
        }
        var chosen: ?u32 = null;
        for (0..vn.versions.len / 4) |i| {
            const v = vn.versionAt(i);
            if (packetMod.Version.isSupported(v)) {
                chosen = v;
                break;
            }
        }
        self.versionNegotiated = chosen;
        return Error.VersionNegotiation;
    }

    const RetryTokenInfo = struct { odcid: [20]u8, odcidLen: u8 };

    /// Builds a stateless Retry token bound to the original DCID, the
    /// QUIC version, and the current time. Layout: version(4) |
    /// odcidLen(1) | odcid | issuedAt(8) | HMAC-SHA256[:16].
    fn makeRetryToken(self: *Connection, odcid: []const u8, version: u32, nowMs: u64) Error![64]u8 {
        var buf: [64]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], version, .big);
        buf[4] = @intCast(odcid.len);
        @memcpy(buf[5..][0..odcid.len], odcid);
        const issuedOff = 5 + odcid.len;
        std.mem.writeInt(u64, buf[issuedOff..][0..8], nowMs, .big);
        const payloadLen = issuedOff + 8;
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, buf[0..payloadLen], &self.retryKey);
        @memcpy(buf[payloadLen..][0..16], mac[0..16]);
        return buf;
    }

    fn validateRetryToken(self: *Connection, token: []const u8, version: u32, nowMs: u64) ?RetryTokenInfo {
        if (token.len < 5 + 1 + 8 + 16) return null;
        const odcidLen: usize = token[4];
        if (odcidLen == 0 or odcidLen > 20) return null;
        if (token.len != 5 + odcidLen + 8 + 16) return null;
        const payloadLen = 5 + odcidLen + 8;
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, token[0..payloadLen], &self.retryKey);
        if (!std.crypto.timing_safe.eql([16]u8, mac[0..16].*, token[payloadLen..][0..16].*)) return null;
        if (std.mem.readInt(u32, token[0..4], .big) != version) return null;
        const issued = std.mem.readInt(u64, token[5 + odcidLen ..][0..8], .big);
        if (nowMs >= issued and nowMs - issued > 60_000) return null;
        if (issued > nowMs and issued - nowMs > 5_000) return null;
        var info: RetryTokenInfo = .{ .odcid = undefined, .odcidLen = @intCast(odcidLen) };
        @memcpy(info.odcid[0..odcidLen], token[5..][0..odcidLen]);
        return info;
    }

    /// Statelessly answers an unsupported-version long header with a
    /// Version Negotiation packet advertising v1 and v2.
    fn sendVersionNegotiation(self: *Connection, dgram: []const u8) Error!void {
        if (self.vnSent) return;
        const cids = packetMod.parseLongHeaderCids(dgram) catch return;
        var buf: [128]u8 = undefined;
        const versions = [_]u32{ 0x00000001, 0x6B3343CF };
        const n = packetMod.writeVersionNegotiation(buf[0..], cids.scid, cids.dcid, &versions) catch return;
        if (self.bytesSent + n > self.bytesReceived *| 3) return;
        try self.queueOutPacket(buf[0..n], false, .other);
        self.bytesSent += n;
        self.vnSent = true;
    }

    /// Client-side Retry processing (RFC 9000 Section 17.2.5): verifies
    /// the integrity tag against the original DCID, adopts the Retry
    /// SCID/token, resets the Initial packet-number space, and requeues
    /// the ClientHello CRYPTO bytes under the new Initial keys.
    fn handleRetry(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        const retry = packetMod.parseRetry(dgram) catch return;
        if (retry.version != self.version) return;
        if (retry.scid.len == 0 or retry.token.len == 0) return;
        if (!std.mem.eql(u8, retry.dcid, self.scid[0..self.scidLen])) return;
        if (self.retryPending) return;
        const expected = crypto.retryIntegrityTag(self.version, self.origDcid[0..self.origDcidLen], retry.withoutTag);
        if (!std.crypto.timing_safe.eql([16]u8, expected, retry.tag)) return;

        self.retryPending = true;
        // RFC 9000 Section 17.2.5.2: a client that receives a Retry
        // discards any 0-RTT packets it sent and MUST NOT send 0-RTT in
        // response. The request can be replayed once the handshake
        // completes under the new connection ID.
        self.discardZeroRtt();
        @memcpy(self.dcid[0..retry.scid.len], retry.scid);
        self.dcidLen = @intCast(retry.scid.len);
        @memcpy(self.initialDcid[0..retry.scid.len], retry.scid);
        self.initialDcidLen = @intCast(retry.scid.len);
        @memcpy(self.retryScid[0..retry.scid.len], retry.scid);
        self.retryScidLen = @intCast(retry.scid.len);
        self.retryToken.clearRetainingCapacity();
        self.retryToken.appendSlice(self.allocator, retry.token) catch return Error.OutOfMemory;

        // The first flight was protected with the old Initial keys and is
        // abandoned by the retry. Release its congestion-window share and
        // drop any queued Initial packet before replacing the space, or
        // `bytesInFlight` stays inflated and stale ciphertext is sent.
        self.bytesInFlight -|= self.spaces[0].inFlightBytes;
        self.dropQueuedKind(.initial);
        self.spaces[0].deinit();
        self.spaces[0] = PnSpace.init(self.allocator, .initial);
        try self.installInitialKeys();

        self.cryptoOut[0].clearRetainingCapacity();
        self.cryptoOut[0].appendSlice(self.allocator, self.initialCryptoLog.items) catch return Error.OutOfMemory;
        self.cryptoSendOff[0] = self.initialCryptoLog.items.len;
        self.cryptoRecvOff[0] = 0;
        self.cryptoBuf[0].clearRetainingCapacity();
        for (self.cryptoPending[0].items) |segment| self.allocator.free(segment.data);
        self.cryptoPending[0].clearRetainingCapacity();

        // The ClientHello was protected with the abandoned Initial keys.
        // Requeue it under the Retry SCID's keys so the token round trip
        // can make progress; the TLS driver is not restarted, because
        // that would generate a second ClientHello and corrupt the
        // transcript.
        try self.flushQueuedCrypto(.initial, nowMs);
    }

    /// Serializes queued CRYPTO bytes into one packet per chunk. Used when
    /// Initial keys are replaced (Retry) and no TLS driver callback runs
    /// to build the replacement flight.
    fn flushQueuedCrypto(self: *Connection, kind: SpaceKind, nowMs: u64) Error!void {
        while (self.takeCrypto(kind, MAX_DATAGRAM - 64)) |chunk| {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            frames.encode(&payload, self.allocator, .{ .crypto = .{ .offset = chunk.offset, .data = chunk.data } }) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            _ = self.consumeCrypto(kind, chunk.data.len);
            try self.packetize(kind, &payload, nowMs);
        }
    }

    fn sendRetry(self: *Connection, dgram: []const u8, header: packetMod.LongHeader, nowMs: u64) Error!void {
        if (self.retryPending or self.addressValidated) return;
        const cids = packetMod.parseLongHeaderCids(dgram) catch return;
        const token = try self.makeRetryToken(header.dcid, header.version, nowMs);
        const tokenLen = 5 + header.dcid.len + 8 + 16;

        var newScid: [8]u8 = undefined;
        self.io.randomSecure(&newScid) catch return;
        @memcpy(self.scid[0..newScid.len], &newScid);
        self.scidLen = newScid.len;
        @memcpy(self.dcid[0..cids.scid.len], cids.scid);
        self.dcidLen = @intCast(cids.scid.len);

        var buf: [128]u8 = undefined;
        const n = packetMod.writeRetry(buf[0..], header.version, cids.scid, &newScid, token[0..tokenLen]) catch return;
        const tag = crypto.retryIntegrityTag(header.version, header.dcid, buf[0..n]);
        @memcpy(buf[n..][0..16], &tag);
        const total = n + 16;
        if (self.bytesSent + total > self.bytesReceived *| 3) return;
        try self.queueOutPacket(buf[0..total], false, .other);
        self.bytesSent += total;
        self.retryPending = true;
        @memcpy(self.retryOdcid[0..header.dcid.len], header.dcid);
        self.retryOdcidLen = @intCast(header.dcid.len);
    }

    fn receiveLong(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        const parsed = packetMod.parseLongHeader(dgram) catch |e| switch (e) {
            error.UnsupportedVersion => return, // handled in receiveDatagram
            else => return Error.ProtocolViolation,
        };

        // A server adopts the version of the first Initial it accepts.
        if (self.role == .server and self.state == .initial and parsed.header.version != self.version) {
            self.version = parsed.header.version;
            self.spaces[0].keysRx = null;
            self.spaces[0].keysTx = null;
            try self.installInitialKeys();
        }

        if (self.role == .server and parsed.header.type == .initial) {
            if (self.cfg.retry and !self.addressValidated) {
                if (parsed.header.token.len == 0) {
                    try self.sendRetry(dgram, parsed.header, nowMs);
                    return;
                }
                const info = self.validateRetryToken(parsed.header.token, parsed.header.version, nowMs) orelse {
                    try self.sendRetry(dgram, parsed.header, nowMs);
                    return;
                };
                self.addressValidated = true;
                @memcpy(self.retryOdcid[0..info.odcidLen], info.odcid[0..info.odcidLen]);
                self.retryOdcidLen = info.odcidLen;
                @memcpy(self.origDcid[0..info.odcidLen], info.odcid[0..info.odcidLen]);
                self.origDcidLen = info.odcidLen;
            }
            // Initial keys use the DCID carried in this packet, which is
            // the Retry SCID after a token round trip.
            if (self.initialDcidLen != parsed.header.dcid.len or
                !std.mem.eql(u8, self.initialDcid[0..self.initialDcidLen], parsed.header.dcid))
            {
                @memcpy(self.initialDcid[0..parsed.header.dcid.len], parsed.header.dcid);
                self.initialDcidLen = @intCast(parsed.header.dcid.len);
                try self.installInitialKeys();
            }
            if (parsed.header.scid.len > 0) {
                @memcpy(self.dcid[0..parsed.header.scid.len], parsed.header.scid);
                self.dcidLen = @intCast(parsed.header.scid.len);
            }
        }

        const isZeroRtt = parsed.header.type == .zeroRtt;
        const spIdx: usize = if (isZeroRtt) 2 else switch (parsed.header.type) {
            .initial => 0,
            .handshake => 1,
            else => return,
        };
        const sp = &self.spaces[spIdx];
        const keys: crypto.ProtectionKeys = if (isZeroRtt) blk: {
            if (self.role != .server) return; // 0-RTT is client -> server only
            const zk = self.zeroRttKeysRx orelse {
                const payloadLen = std.math.cast(usize, parsed.header.length) orelse return;
                self.rxConsumed = parsed.header.pnOffset + payloadLen;
                return;
            };
            break :blk zk;
        } else (sp.keysRx orelse {
            // A late Initial/Handshake packet can arrive after its keys
            // were legitimately discarded. RFC 9001 Section 4.9 says to
            // ignore it; consume the whole packet so a coalesced packet
            // that follows still parses.
            if (sp.discarded) {
                const payloadLen = std.math.cast(usize, parsed.header.length) orelse return;
                self.rxConsumed = parsed.header.pnOffset + payloadLen;
                return;
            }
            return Error.TlsDriverFailed;
        });

        const pnOffset = parsed.header.pnOffset;
        if (dgram.len > MAX_DATAGRAM) return Error.ProtocolViolation;
        var work: [MAX_DATAGRAM]u8 = undefined;
        @memcpy(work[0..dgram.len], dgram);

        // Header protection removal (RFC 9001 section 5.4.2).
        const sampleOff = pnOffset + 4;
        if (dgram.len < sampleOff + 16) return Error.ProtocolViolation;
        var sample: [16]u8 = undefined;
        @memcpy(&sample, work[sampleOff..][0..16]);
        const mask = switch (keys.cipher) {
            .aes128Gcm, .aes256Gcm => blk: {
                var hp16: [16]u8 = undefined;
                @memcpy(&hp16, keys.hp[0..16]);
                break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
            },
            .chacha20Poly1305 => blk: {
                var hp32: [32]u8 = undefined;
                @memcpy(&hp32, keys.hp[0..32]);
                break :blk protect.hpMaskChacha(hp32, &sample);
            },
        };
        work[0] ^= mask[0] & 0x0F;

        // Reserved bits must be zero once unprotected.
        if (work[0] & 0x0C != 0) return Error.ProtocolViolation;
        const pnLen: usize = (@as(usize, work[0]) & 0x03) + 1;
        for (0..pnLen) |i| work[pnOffset + i] ^= mask[1 + i];
        var pnTrunc: u64 = 0;
        for (0..pnLen) |i| pnTrunc = (pnTrunc << 8) | work[pnOffset + i];

        const expected: u64 = if (sp.largestAcked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pnTrunc, pnLen);

        const aadLen = pnOffset + pnLen;
        const payloadLen = std.math.cast(usize, parsed.header.length) orelse return Error.ProtocolViolation;
        const declaredEnd = std.math.add(usize, pnOffset, payloadLen) catch return Error.ProtocolViolation;
        if (declaredEnd < aadLen + 16 or dgram.len < declaredEnd) return Error.ProtocolViolation;
        const ctLen = declaredEnd - aadLen - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ctLen], work[aadLen..][0..ctLen], work[declaredEnd - 16 ..][0..16].*, work[0..aadLen], keys, pn) catch {
            return Error.AuthenticationFailed;
        };

        // The server's first authenticated Initial selects the destination
        // CID the client must use for subsequent packets (RFC 9000 §7.2).
        // Keep initialDcid unchanged: it remains the input to Initial key
        // derivation for retransmitted Initial packets.
        if (self.role == .client and parsed.header.type == .initial) {
            if (!std.mem.eql(u8, parsed.header.dcid, self.scid[0..self.scidLen])) return;
            if (sp.highestRxPn < 0) {
                @memcpy(self.dcid[0..parsed.header.scid.len], parsed.header.scid);
                self.dcidLen = @intCast(parsed.header.scid.len);
            } else if (!std.mem.eql(u8, parsed.header.scid, self.dcid[0..self.dcidLen])) {
                return;
            }
        }

        if (isZeroRtt) {
            if (self.maxEarlyData > 0) {
                self.earlyDataBytesReceived +|= ctLen;
                if (self.earlyDataBytesReceived > self.maxEarlyData) {
                    return Error.FlowControlViolation;
                }
            }
        }

        const isNewLargest = sp.largestAcked == null or pn > sp.largestAcked.?;
        sp.highestRxPn = @max(sp.highestRxPn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largestAcked = if (sp.largestAcked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch |e| switch (e) {
            // Duplicates carry no new information: drop without
            // redelivering to the application or arming ACKs.
            error.DuplicatePacket => {
                self.rxConsumed = declaredEnd;
                return;
            },
            error.OutOfMemory => return Error.OutOfMemory,
        };
        // RFC 9000 Section 19.3: ACK Delay is measured from the receipt
        // of the largest acknowledged packet, not from the most recent
        // (possibly older, reordered) packet.
        if (isNewLargest) sp.largestRecvTsMs = nowMs;

        self.rxConsumed = declaredEnd;
        self.rxAckEliciting = false;
        try self.dispatchFrames(sp, pt[0..ctLen], nowMs, isZeroRtt);
        self.afterPacketReceived(sp, pn, nowMs);

        // RFC 9001 Section 4.9.1: a server discards the Initial keys when
        // it first successfully processes a Handshake packet. Without this
        // the server keeps retransmitting Initial packets, which peers
        // treat as a protocol violation.
        if (self.role == .server and !isZeroRtt and parsed.header.type == .handshake) {
            self.discardInitialKeys();
        }
    }
    fn receiveShort(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        const sp = &self.spaces[2];
        const currentKeys = sp.keysRx orelse {
            // The handshake is not complete yet, so the application keys
            // are not installed and the packet cannot be decrypted.
            // RFC 9001 Section 5.7: buffer it and replay it once the
            // handshake completes; dropping it would lose the peer's
            // first request (a peer may start sending 1-RTT data as
            // soon as it has the handshake keys).
            const copy = self.allocator.dupe(u8, dgram) catch return Error.OutOfMemory;
            self.pendingApp.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return Error.OutOfMemory;
            };
            self.rxConsumed = dgram.len;
            return;
        };

        var work: [MAX_DATAGRAM]u8 = undefined;
        var pt: [MAX_DATAGRAM]u8 = undefined;
        var phase = false;

        // Try the current key phase first. A differing Key Phase bit
        // means the peer initiated an update (RFC 9001 Section 6.2);
        // authentication failure falls back to the retained previous
        // phase for reordered packets from before an update.
        const opened = openShortProtected(dgram, self.scidLen, currentKeys, sp.largestAcked, &work, &pt, &phase) catch |firstErr| blk: {
            if (firstErr != Error.AuthenticationFailed and firstErr != Error.ProtocolViolation) return firstErr;
            if (self.appRxSecret) |secret| {
                const nextSecret = crypto.nextApplicationSecret(secret);
                const nextKeys = crypto.deriveProtectionKeys(nextSecret);
                var nextPhase = false;
                if (openShortProtected(dgram, self.scidLen, nextKeys, sp.largestAcked, &work, &pt, &nextPhase)) |next| {
                    self.prevAppRxKeys = sp.keysRx;
                    self.prevKeyPhaseRx = self.keyPhaseRx;
                    self.appRxSecret = nextSecret;
                    sp.keysRx = nextKeys;
                    self.keyPhaseRx = nextPhase;
                    self.rxKeyUpdateAtMs = nowMs;
                    break :blk next;
                } else |_| {}
            }
            if (self.prevAppRxKeys) |prevKeys| {
                if (phase == self.prevKeyPhaseRx) {
                    var prevPhase = false;
                    if (openShortProtected(dgram, self.scidLen, prevKeys, sp.largestAcked, &work, &pt, &prevPhase)) |prev| {
                        break :blk prev;
                    } else |_| {}
                }
            }
            return firstErr;
        };

        const pn = opened.pn;
        const isNewLargest = sp.largestAcked == null or pn > sp.largestAcked.?;
        sp.highestRxPn = @max(sp.highestRxPn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largestAcked = if (sp.largestAcked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch |e| switch (e) {
            // Duplicates carry no new information: drop without
            // redelivering to the application or arming ACKs.
            error.DuplicatePacket => {
                self.rxConsumed = dgram.len;
                return;
            },
            error.OutOfMemory => return Error.OutOfMemory,
        };
        // RFC 9000 Section 19.3: the ACK Delay baseline is the largest
        // acknowledged packet, not a later reordered one.
        if (isNewLargest) sp.largestRecvTsMs = nowMs;

        self.rxConsumed = dgram.len;
        self.rxAckEliciting = false;
        try self.dispatchFrames(sp, pt[0..opened.ctLen], nowMs, false);
        self.afterPacketReceived(sp, pn, nowMs);
    }

    /// Updates acknowledgment state after one received packet.
    /// Immediate ACK when the second eliciting packet arrives, on
    /// reordering, or in handshake spaces (latency-sensitive); otherwise
    /// arms the max-ack-delay timer drained by `pollAckTimers`.
    fn afterPacketReceived(self: *Connection, sp: *PnSpace, pn: u64, nowMs: u64) void {
        if (sp.discarded) return;
        if (!self.rxAckEliciting) return;
        sp.ackElicitingCount += 1;
        const outOfOrder = if (sp.acktr.largestSeen) |ls| pn < ls else false;
        if (sp.ackElicitingCount >= 2 or outOfOrder or sp.kind != .application) {
            sp.ackQueued = true;
            sp.ackElicitingCount = 0;
            sp.ackDeadlineMs = null;
        } else if (sp.ackDeadlineMs == null) {
            sp.ackDeadlineMs = nowMs +| self.recovery.cfg.maxAckDelayMs;
        }
    }

    /// Arms/drains ACK timers; `pollTimeouts` calls this once per pump
    /// iteration and then emits any queued ACK in its own packet.
    pub fn pollAckTimers(self: *Connection, nowMs: u64) void {
        for (&self.spaces) |*sp| {
            if (sp.discarded) continue;
            if (sp.ackQueued) continue;
            if (sp.ackDeadlineMs) |dl| {
                if (nowMs >= dl) {
                    sp.ackQueued = true;
                    sp.ackDeadlineMs = null;
                    sp.ackElicitingCount = 0;
                }
            }
        }
    }

    fn isAckElicitingFrame(f: frames.Frame) bool {
        return switch (f) {
            .padding, .ack, .connectionClose => false,
            else => true,
        };
    }

    /// RFC 9000 Table 3: each frame type is valid only in specific packet
    /// number spaces. A frame in the wrong space is a PROTOCOL_VIOLATION.
    fn frameAllowedInSpace(f: frames.Frame, kind: SpaceKind, isZeroRtt: bool) bool {
        const app = kind == .application;
        const oneRtt = app and !isZeroRtt;
        return switch (f) {
            .padding, .ping => true,
            .ack, .crypto => oneRtt or !app,
            .resetStream,
            .stopSending,
            .stream,
            .maxData,
            .maxStreamData,
            .maxStreams,
            .dataBlocked,
            .streamDataBlocked,
            .streamsBlocked,
            .newConnectionId,
            .retireConnectionId,
            .pathChallenge,
            => app,
            .newToken, .pathResponse, .handshakeDone => oneRtt,
            // 0x1c (transport) is Initial/Handshake/1-RTT; 0x1d
            // (application) is 0-RTT/1-RTT.
            .connectionClose => |c| if (c.application) app else oneRtt or !app,
        };
    }

    fn dispatchFrames(
        self: *Connection,
        sp: *PnSpace,
        plaintext: []const u8,
        nowMs: u64,
        isZeroRtt: bool,
    ) Error!void {
        var pos: usize = 0;
        while (pos < plaintext.len) {
            const f = frames.decode(plaintext, &pos) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            if (!frameAllowedInSpace(f, sp.kind, isZeroRtt)) return Error.ProtocolViolation;
            if (isAckElicitingFrame(f)) self.rxAckEliciting = true;
            switch (f) {
                .padding, .ping => {},
                .ack => |a| {
                    try self.onAckFrame(sp, a, nowMs);
                    // RFC 9001 Section 4.1.2: a client MAY consider the
                    // handshake confirmed once one of its 1-RTT packets
                    // has been acknowledged. This matters when
                    // HANDSHAKE_DONE is lost but the peer already
                    // processed the client Finished.
                    if (!isZeroRtt and sp.kind == .application and
                        self.role == .client and !self.handshakeConfirmed)
                    {
                        if (self.firstAppPnSent) |first| {
                            if (a.largestAcknowledged >= first) self.confirmHandshake();
                        }
                    }
                },
                .crypto => |c| {
                    try self.receiveCrypto(sp.kind, c.offset, c.data, nowMs);
                },
                .stream => |s| {
                    const bidi = (s.id & 0x02) == 0;
                    const initiatorIsClient = (s.id & 0x01) == 0;
                    const initiatorIsSelf = (self.role == .client and initiatorIsClient) or (self.role == .server and !initiatorIsClient);
                    var stPtr = self.streams.get(s.id);
                    if (stPtr == null) {
                        const ns = try self.allocator.create(qstream.Stream);
                        ns.* = qstream.Stream.init(self.allocator, s.id, bidi, initiatorIsSelf);
                        if (self.maxStreamData.get(s.id)) |lim| ns.recvMaxOffset = lim;
                        try self.streams.put(s.id, ns);
                        stPtr = ns;
                        if (self.cbs.onNewStream) |cb| cb(self.cbs.ctx, s.id);
                    }
                    const st = stPtr.?;
                    // RFC 9000 Section 19.8: when OFF is absent, stream data
                    // starts at offset zero. This matters for retransmitted
                    // first-byte ranges after the receive cursor has advanced.
                    const off = if (s.offPresent) s.offset else 0;
                    const Sink = struct {
                        cbs: Callbacks,
                        sid: u64,
                        pub fn call(sinkSelf: *@This(), data: []const u8) !void {
                            if (sinkSelf.cbs.onStreamData) |cb| cb(sinkSelf.cbs.ctx, sinkSelf.sid, data, false);
                        }
                    };
                    var sink = Sink{ .cbs = self.cbs, .sid = s.id };
                    if (!st.fcAllows(off, s.data.len)) return Error.FlowControlViolation;
                    _ = st.receive(off, s.data, s.fin, &sink) catch |e| switch (e) {
                        error.FlowControlViolation => return Error.FlowControlViolation,
                        error.FinalSizeViolation => return Error.ProtocolViolation,
                        error.StreamReset => return,
                        else => return Error.OutOfMemory,
                    };
                    const end = off + s.data.len;
                    const oldEnd = self.recvStreamEnd.get(s.id) orelse 0;
                    if (end > oldEnd) {
                        self.dataReceived +|= end - oldEnd;
                        try self.recvStreamEnd.put(s.id, end);
                    }
                    if (st.canReceiveMore() and st.recvMaxOffset < (1 << 30)) {
                        const raised = @min(st.recvMaxOffset *| 2, 1 << 30);
                        st.recvMaxOffset = raised;
                        try self.queueControlFrame(.{ .maxStreamData = .{ .streamId = s.id, .maximum = raised } });
                        try self.flushControl(.application, nowMs);
                    }
                    if (self.dataReceived > self.maxData) return Error.FlowControlViolation;
                    try self.maybeBumpMaxData();
                    if (!st.finNotified and st.finOffset != null and st.recvOffset == st.finOffset.?) {
                        st.finNotified = true;
                        if (self.cbs.onStreamData) |cb| cb(self.cbs.ctx, s.id, &.{}, true);
                    }
                },
                .handshakeDone => {
                    // RFC 9000 Section 19.20: only servers send
                    // HANDSHAKE_DONE; a server receiving one has a
                    // misbehaving or spoofing peer.
                    if (self.role == .server) return Error.ProtocolViolation;
                    // Client confirmation (RFC 9001 Section 4.1.2): drop
                    // the Handshake keys and open the connection.
                    self.confirmHandshake();
                    // Application data can have arrived before the
                    // handshake completed; it is decryptable now.
                    self.replayPendingApp(nowMs) catch {};
                    if (self.cbs.onHandshakeDone) |cb| cb(self.cbs.ctx);
                },
                .connectionClose => |c| {
                    self.state = .draining;
                    // Surface the peer's reason: a transport close code is
                    // the only clue when a handshake or HTTP/3 exchange
                    // fails against an independent implementation.
                    std.log.scoped(.httpx).debug("peer closed the connection: code={d} application={} trigger=0x{x} reason={s}", .{ c.errorCode, c.application, c.triggeringFrameType, c.reason });
                    if (self.cbs.onClose) |cb| cb(self.cbs.ctx, c.errorCode, c.reason);
                },
                .pathChallenge => |p| {
                    // Echo back as PATH_RESPONSE per RFC 9000 section 19.3.
                    self.queueControlFrame(.{ .pathResponse = .{ .data = p.data } }) catch |e| switch (e) {
                        error.OutOfMemory => return Error.OutOfMemory,
                        else => return Error.ProtocolViolation,
                    };
                },
                .maxData => |m| {
                    self.maxDataRemote = m.maximum;
                },
                .maxStreamData => |m| {
                    self.maxStreamData.put(m.streamId, m.maximum) catch return Error.OutOfMemory;
                },
                .maxStreams => |m| {
                    if (m.bidi) {
                        self.maxStreamsBidiRemote = m.maximum;
                    } else {
                        self.maxStreamsUniRemote = m.maximum;
                    }
                },
                .dataBlocked => {
                    // Peer is blocked on our maxData: raise the window and
                    // answer immediately (the peer is waiting on this).
                    self.maxData = @min(self.maxData *| 2, 1 << 30);
                    self.queueControlFrame(.{ .maxData = .{ .maximum = self.maxData } }) catch |e| switch (e) {
                        error.OutOfMemory => return Error.OutOfMemory,
                        else => return Error.ProtocolViolation,
                    };
                    self.flushControl(.application, nowMs) catch {};
                },
                .streamDataBlocked => |b| {
                    // Peer is blocked on a stream receive window: raise it
                    // and answer immediately.
                    if (self.streams.get(b.streamId)) |st| {
                        const raised = @min(st.recvMaxOffset *| 2, 1 << 30);
                        st.recvMaxOffset = raised;
                        self.queueControlFrame(.{ .maxStreamData = .{ .streamId = b.streamId, .maximum = raised } }) catch |e| switch (e) {
                            error.OutOfMemory => return Error.OutOfMemory,
                            else => return Error.ProtocolViolation,
                        };
                        self.flushControl(.application, nowMs) catch {};
                    }
                },
                .streamsBlocked => |b| {
                    // Peer is blocked on stream count: raise our advertised
                    // limit and answer immediately.
                    if (b.bidi) {
                        self.maxStreamsBidiLocal = @min(self.maxStreamsBidiLocal + 64, 65536);
                        self.queueControlFrame(.{ .maxStreams = .{ .maximum = self.maxStreamsBidiLocal, .bidi = true } }) catch |e| switch (e) {
                            error.OutOfMemory => return Error.OutOfMemory,
                            else => return Error.ProtocolViolation,
                        };
                    } else {
                        self.maxStreamsUniLocal = @min(self.maxStreamsUniLocal + 64, 65536);
                        self.queueControlFrame(.{ .maxStreams = .{ .maximum = self.maxStreamsUniLocal, .bidi = false } }) catch |e| switch (e) {
                            error.OutOfMemory => return Error.OutOfMemory,
                            else => return Error.ProtocolViolation,
                        };
                    }
                    self.flushControl(.application, nowMs) catch {};
                },
                .newConnectionId => |n| {
                    // RFC 9000 section 19.15: a NEW_CONNECTION_ID frame
                    // that repeats a sequence number MAY be treated as a
                    // protocol violation, but peers retransmit the frame
                    // in a fresh packet, so the repeat is ignored here
                    // instead of tearing the connection down.
                    for (self.peerCids.items) |c| {
                        if (c.sequence == n.sequence) return;
                    }
                    var entry = CidEntry{
                        .sequence = n.sequence,
                        .cidLen = @intCast(@min(n.cid.len, 20)),
                        .statelessResetToken = n.statelessResetToken,
                    };
                    @memcpy(entry.cid[0..entry.cidLen], n.cid[0..entry.cidLen]);
                    // Retire older CIDs per retirePriorTo.
                    for (self.peerCids.items) |*c| {
                        if (n.retirePriorTo > 0 and c.sequence < n.retirePriorTo and !c.retired) {
                            c.retired = true;
                        }
                    }
                    var activeCount: usize = 0;
                    for (self.peerCids.items) |c| {
                        if (!c.retired) activeCount += 1;
                    }
                    if (!entry.retired and activeCount >= MAX_PEER_CONNECTION_IDS) return Error.ProtocolViolation;
                    self.peerCids.append(self.allocator, entry) catch return Error.OutOfMemory;
                },
                .retireConnectionId => {
                    // Mark our CID with the given sequence as retired.
                },
                .stopSending => |s| {
                    // RFC 9000 section 19.5: answer with RESET_STREAM at
                    // once, then tell the application to abandon the
                    // stream. Final size is our send offset, if known.
                    const finalSize = self.sendStreamEnd.get(s.streamId) orelse 0;
                    self.queueControlFrame(.{ .resetStream = .{
                        .streamId = s.streamId,
                        .errorCode = s.errorCode,
                        .finalSize = finalSize,
                    } }) catch |e| switch (e) {
                        error.OutOfMemory => return Error.OutOfMemory,
                        else => return Error.ProtocolViolation,
                    };
                    if (self.cbs.onStopSending) |cb| cb(self.cbs.ctx, s.streamId, s.errorCode);
                    self.flushControl(.application, nowMs) catch {};
                },
                .resetStream => |r| {
                    // Peer reset a stream: mark stream state and route to
                    // the per-stream callback (connection-level onClose is
                    // reserved for CONNECTION_CLOSE).
                    if (self.streams.get(r.streamId)) |st| st.onReset(r.errorCode);
                    if (self.cbs.onStreamReset) |cb| cb(self.cbs.ctx, r.streamId, r.errorCode);
                },
                .newToken => {
                    // RFC 9000 section 19.7: store token for future address validation.
                },
                .pathResponse => |p| {
                    if (self.pathValidator) |*pv| {
                        _ = pv.onResponse(&p.data);
                    }
                },
            }
        }
    }

    /// Initiates QUIC path validation (RFC 9000 Section 8.2) for connection migration
    /// or NAT rebinding. Queues PATH_CHALLENGE frames on the wire.
    pub fn initiatePathValidation(self: *Connection, nowMs: u64, rng: std.Random) Error!void {
        if (self.pathValidator == null) {
            self.pathValidator = pathMod.PathValidator.init(100);
        }
        self.pathValidator.?.start(nowMs, rng);
        while (self.pathValidator.?.nextChallenge()) |c| {
            try self.queueControlFrame(.{ .pathChallenge = .{ .data = c } });
            self.pathValidator.?.markSent();
        }
        self.flushControl(.application, nowMs) catch {};
    }

    /// Checks whether path validation is currently complete and validated.
    pub fn isPathValidated(self: *const Connection) bool {
        if (self.pathValidator) |pv| {
            return pv.state == .validated;
        }
        return false;
    }

    /// Raises our receive window once it is more than half consumed,
    /// keeping the pipe full without waiting for DATA_BLOCKED. The
    /// update rides the next outgoing packet (no immediate flush).
    fn maybeBumpMaxData(self: *Connection) Error!void {
        if (self.maxData >= 1 << 30) return;
        if (self.dataReceived *| 2 <= self.maxData) return;
        self.maxData = @min(self.maxData *| 2, 1 << 30);
        try self.queueControlFrame(.{ .maxData = .{ .maximum = self.maxData } });
    }

    fn maybeDiscardInitial(self: *Connection) void {
        if (self.role == .client and self.spaces[1].keysTx != null) {
            self.discardInitialKeys();
        }
    }

    fn receiveCrypto(self: *Connection, kind: SpaceKind, offset: u64, data: []const u8, nowMs: u64) Error!void {
        const idx = @backingInt(kind);
        if (data.len == 0) return;
        const end = std.math.add(u64, offset, data.len) catch return Error.ProtocolViolation;
        const received = self.cryptoRecvOff[idx];
        if (end <= received) return;

        var start = offset;
        var source = data;
        if (start < received) {
            const skip: usize = @intCast(received - start);
            start = received;
            source = source[skip..];
        }
        if (start != received) {
            var pendingBytes: usize = 0;
            if (self.cryptoPending[idx].items.len >= MAX_CRYPTO_SEGMENTS) return Error.BufferTooSmall;
            for (self.cryptoPending[idx].items) |segment| {
                pendingBytes = std.math.add(usize, pendingBytes, segment.data.len) catch return Error.BufferTooSmall;
            }
            const pendingTotal = std.math.add(usize, pendingBytes, source.len) catch return Error.BufferTooSmall;
            if (pendingTotal > 1 << 20)
                return Error.BufferTooSmall;
            const copy = self.allocator.dupe(u8, source) catch return Error.OutOfMemory;
            self.cryptoPending[idx].append(self.allocator, .{ .offset = start, .data = copy }) catch {
                self.allocator.free(copy);
                return Error.OutOfMemory;
            };
            return;
        }

        try self.cryptoBuf[idx].appendSlice(self.allocator, source);
        self.cryptoRecvOff[idx] = std.math.add(u64, received, source.len) catch return Error.ProtocolViolation;
        while (true) {
            var found: ?usize = null;
            for (self.cryptoPending[idx].items, 0..) |segment, i| {
                if (segment.offset <= self.cryptoRecvOff[idx]) {
                    found = i;
                    break;
                }
            }
            const i = found orelse break;
            const segment = self.cryptoPending[idx].swapRemove(i);
            defer self.allocator.free(segment.data);
            const skip: usize = @intCast(self.cryptoRecvOff[idx] - segment.offset);
            if (skip >= segment.data.len) continue;
            const contiguous = segment.data[skip..];
            try self.cryptoBuf[idx].appendSlice(self.allocator, contiguous);
            self.cryptoRecvOff[idx] = std.math.add(u64, self.cryptoRecvOff[idx], contiguous.len) catch return Error.ProtocolViolation;
        }
        if (self.tls.onData) |cb| {
            try cb(self.tls.ctx, self, self.cryptoBuf[idx].items, nowMs);
            self.cryptoBuf[idx].clearRetainingCapacity();
        }
    }

    /// Kicks off the handshake (client role only).
    pub fn startHandshake(self: *Connection, nowMs: u64) Error!void {
        if (self.role != .client) return;
        self.installInitialKeys() catch return Error.TlsDriverFailed;
        if (self.tls.start) |cb| try cb(self.tls.ctx, self, nowMs);
    }

    /// Server-side entry: install Initial keys from the DCID seen on the
    /// first datagram before processing it.
    pub fn acceptInitial(self: *Connection, clientDcid: []const u8) Error!void {
        if (self.role != .server) return Error.ProtocolViolation;
        if (clientDcid.len > 20) return Error.ProtocolViolation;
        @memcpy(self.dcid[0..clientDcid.len], clientDcid);
        self.dcidLen = @intCast(clientDcid.len);
        @memcpy(self.origDcid[0..clientDcid.len], clientDcid);
        self.origDcidLen = @intCast(clientDcid.len);
        @memcpy(self.initialDcid[0..clientDcid.len], clientDcid);
        self.initialDcidLen = @intCast(clientDcid.len);
        self.installInitialKeys() catch return Error.TlsDriverFailed;
    }

    /// Hands the queued packets to the caller. The returned slice holds
    /// whole packets back to back; use `outPacketLengths` to recover the
    /// boundaries when splitting them into datagrams.
    /// Replays the 1-RTT packets that arrived before the handshake
    /// completed (RFC 9001 Section 5.7). Called once the application
    /// keys are installed.
    pub fn replayPendingApp(self: *Connection, nowMs: u64) Error!void {
        // The buffered datagrams are consumed one by one: clearing the list
        // first would poison the stored slice headers.
        while (self.pendingApp.items.len > 0) {
            const d = self.pendingApp.orderedRemove(0);
            defer self.allocator.free(d);
            self.receiveDatagram(d, nowMs) catch {};
        }
    }

    /// Discards the buffered 1-RTT packets (connection is going away).
    pub fn clearPendingApp(self: *Connection) void {
        for (self.pendingApp.items) |d| self.allocator.free(d);
        self.pendingApp.clearRetainingCapacity();
    }

    pub fn takeOutput(self: *Connection, gpa: Allocator) ![]u8 {
        defer {
            self.outbuf = .empty;
            self.outPackets.clearRetainingCapacity();
            self.outPacketChainable.clearRetainingCapacity();
            self.outPacketKinds.clearRetainingCapacity();
        }
        return self.outbuf.toOwnedSlice(gpa);
    }

    /// Lengths of the packets still queued in `outbuf`, in order.
    pub fn outPacketLengths(self: *const Connection) []const u32 {
        return self.outPackets.items;
    }

    /// For each queued packet, whether another packet may follow it in
    /// the same datagram. False marks a short-header (1-RTT) packet,
    /// which has no Length field and must end its datagram
    /// (RFC 9000 Section 12.2).
    pub fn outPacketChainableFlags(self: *const Connection) []const bool {
        return self.outPacketChainable.items;
    }

    /// Encryption level of each queued packet, in the same order as
    /// `outPacketLengths`.
    pub fn outQueuedKinds(self: *const Connection) []const QueuedKind {
        return self.outPacketKinds.items;
    }

    /// Discards the bookkeeping for the first `count` queued packets,
    /// matching output bytes already handed to the transport layer.
    pub fn dropOutPackets(self: *Connection, count: usize) void {
        self.outPackets.replaceRange(self.allocator, 0, count, &.{}) catch {};
        self.outPacketChainable.replaceRange(self.allocator, 0, count, &.{}) catch {};
        self.outPacketKinds.replaceRange(self.allocator, 0, count, &.{}) catch {};
    }

    /// Reserves all packet bookkeeping before writing, so a queued packet
    /// never leaves the three parallel lists inconsistent.
    fn queueOutPacket(self: *Connection, bytes: []const u8, chainable: bool, kind: QueuedKind) Error!void {
        try self.outbuf.ensureUnusedCapacity(self.allocator, bytes.len);
        try self.outPackets.ensureUnusedCapacity(self.allocator, 1);
        try self.outPacketChainable.ensureUnusedCapacity(self.allocator, 1);
        try self.outPacketKinds.ensureUnusedCapacity(self.allocator, 1);
        self.outbuf.appendSliceAssumeCapacity(bytes);
        // Remember the packet boundary so the transport layer can build
        // datagrams out of whole packets (RFC 9000 Section 12.2).
        self.outPackets.appendAssumeCapacity(@intCast(bytes.len));
        self.outPacketChainable.appendAssumeCapacity(chainable);
        self.outPacketKinds.appendAssumeCapacity(kind);
    }

    /// Removes every queued packet of one encryption level from the
    /// output buffer. Called when a space's keys are discarded: a packet
    /// protected with those keys must not be flushed afterwards, even if
    /// it was already serialized (for example a Handshake ACK queued just
    /// before HANDSHAKE_DONE confirmed the handshake).
    fn dropQueuedKind(self: *Connection, kind: QueuedKind) void {
        if (self.outPackets.items.len == 0) return;
        var read: usize = 0;
        var write: usize = 0;
        var kept: usize = 0;
        for (self.outPackets.items, 0..) |len, i| {
            const n: usize = len;
            if (self.outPacketKinds.items[i] == kind) {
                read += n;
                continue;
            }
            if (write != read) {
                std.mem.copyForwards(u8, self.outbuf.items[write .. write + n], self.outbuf.items[read .. read + n]);
            }
            self.outPackets.items[kept] = len;
            self.outPacketChainable.items[kept] = self.outPacketChainable.items[i];
            self.outPacketKinds.items[kept] = self.outPacketKinds.items[i];
            write += n;
            read += n;
            kept += 1;
        }
        self.outbuf.shrinkRetainingCapacity(write);
        self.outPackets.shrinkRetainingCapacity(kept);
        self.outPacketChainable.shrinkRetainingCapacity(kept);
        self.outPacketKinds.shrinkRetainingCapacity(kept);
    }
};

/// Marker error used internally for short datagrams (kept private-ish).
const TruncatedPacket = struct {};

// Loopback integration: full handshake-shaped exchange between two
// Connections through an in-memory pipe. Packet protection (AEAD +
// header protection + PN coding) uses the installed packet keys
// throughout; the TLS message layer below is a deterministic driver
// standing in for tls13.zig.

const TestDriverCtx = struct {
    role: Role,
    doneInstalled: bool = false,

    const clientHello = "TEST-CLIENT-FLIGHT";
    const serverHello = "TEST-SERVER-FLIGHT";
    const clientFinished = "TEST-CLIENT-FINISHED";

    fn transcript() [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(clientHello);
        h.update(serverHello);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }
};

/// Frame encode mapped into the connection error set (test helpers).
fn fe(gpa: Allocator, payload: *std.ArrayList(u8), f: frames.Frame) Error!void {
    frames.encode(payload, gpa, f) catch return Error.OutOfMemory;
}

test "loopback connection pair completes protected handshake and stream" {
    const a = std.testing.allocator;

    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();

    const Hs = struct {
        // Server-side driver: ClientHello -> install HS keys and reply;
        // client Finished -> confirm and send HANDSHAKE_DONE.
        fn serverOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void {
            const role: *Role = @ptrCast(@alignCast(ctx.?));
            _ = role;
            const t = TestDriverCtx.transcript();
            if (std.mem.eql(u8, data, TestDriverCtx.clientHello)) {
                const srvTx = crypto.deriveSecret(t, "server in");
                const srvRx = crypto.deriveSecret(t, "client in");
                try conn.installKeys(.handshake, srvTx, srvRx);
                conn.addressValidated = true;

                // Reply flight in Handshake space.
                const B = struct {
                    pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                        try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.serverHello } });
                    }
                };
                try conn.sendFrames(.handshake, B.build, nowMs);

                const appBase = crypto.deriveSecret(t, "quic ap");
                try conn.installKeys(.application, appBase, appBase);
                return;
            }
            if (std.mem.eql(u8, data, TestDriverCtx.clientFinished)) {
                // The synthetic Finished stands in for TLS 1.3
                // verify_data; confirmation itself follows the RFC.
                conn.handshakeComplete = true;
                conn.confirmHandshake();
                const D = struct {
                    pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                        try fe(gpa, payload, .handshakeDone);
                    }
                };
                try conn.sendFrames(.application, D.build, nowMs);
            }
        }

        // Client-side driver: emit flight, install HS keys, and send a
        // Finished once the server flight is verified.
        fn clientStart(ctx: ?*anyopaque, conn: *Connection, nowMs: u64) Error!void {
            _ = ctx;
            try conn.installInitialKeys();
            const t = TestDriverCtx.transcript();
            const cliTx = crypto.deriveSecret(t, "client in");
            const cliRx = crypto.deriveSecret(t, "server in");
            try conn.installKeys(.handshake, cliTx, cliRx);

            const B = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.clientHello } });
                }
            };
            try conn.sendFrames(.initial, B.build, nowMs);
        }

        fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void {
            _ = ctx;
            if (!std.mem.eql(u8, data, TestDriverCtx.serverHello)) return;
            // App keys arrive mirrored from the server's choice.
            const t = TestDriverCtx.transcript();
            const appBase = crypto.deriveSecret(t, "quic ap");
            conn.installKeys(.application, appBase, appBase) catch return Error.TlsDriverFailed;
            conn.handshakeComplete = true;
            const F = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.clientFinished } });
                }
            };
            try conn.sendFrames(.handshake, F.build, nowMs);
        }
    };

    var serverRole: Role = .server;
    server.tls = .{ .ctx = &serverRole, .onData = Hs.serverOnData };
    client.tls = .{ .start = Hs.clientStart, .onData = Hs.clientOnData };

    // Client begins: produces Initial datagram.
    try client.startHandshake(50);
    const cOut = try client.takeOutput(a);
    defer a.free(cOut);
    try std.testing.expect(cOut.len >= 64);

    // Server accepts based on the DCID the client used.
    try server.acceptInitial(client.dcid[0..8]);
    try server.receiveDatagram(cOut, 100);

    // Server produced Handshake + Application responses.
    const sOut = try server.takeOutput(a);
    defer a.free(sOut);
    try std.testing.expect(sOut.len > 0);

    // Client consumes the server flight, installs app keys and answers
    // with its Finished. The server verifies it, confirms the handshake
    // and returns HANDSHAKE_DONE, which confirms the client.
    client.receiveDatagram(sOut[0..], 200) catch |e| {
        return e;
    };
    const cFin = try client.takeOutput(a);
    defer a.free(cFin);
    try std.testing.expect(cFin.len > 0);
    try server.receiveDatagram(cFin, 250);
    const sDone = try server.takeOutput(a);
    defer a.free(sDone);
    try std.testing.expect(sDone.len > 0);
    try client.receiveDatagram(sDone, 260);
    try std.testing.expectEqual(State.established, client.state);
    try std.testing.expectEqual(State.established, server.state);
    try std.testing.expect(client.handshakeConfirmed);
    try std.testing.expect(server.handshakeConfirmed);
    try std.testing.expect(client.spaces[1].keysRx == null and client.spaces[1].keysTx == null);
    try std.testing.expect(server.spaces[1].keysRx == null and server.spaces[1].keysTx == null);

    // Exchange application STREAM data over 1-RTT (short header).
    const StreamSink = struct {
        var got: [64]u8 = undefined;
        var gotLen: usize = 0;
        fn onStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
            _ = sid;
            _ = fin;
            @memcpy(got[gotLen..][0..data.len], data);
            gotLen += data.len;
        }
        fn onClose(_: ?*anyopaque, e: u64, reason: []const u8) void {
            _ = e;
            _ = reason;
        }
    };
    server.cbs = .{ .onStreamData = StreamSink.onStream };

    const SB = struct {
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            try fe(gpa, payload, .{ .stream = .{ .id = 0, .offset = 0, .data = "ping-over-quic", .fin = false } });
        }
    };
    try client.sendFrames(.application, SB.build, 300);
    const c2 = try client.takeOutput(a);
    defer a.free(c2);
    try std.testing.expect(c2.len < 120); // short header packet is compact

    try server.receiveDatagram(c2, 400);
    try std.testing.expectEqualStrings("ping-over-quic", StreamSink.got[0..StreamSink.gotLen]);
}

// TLS-in-QUIC integration: the TLS 1.3 engine drives both ends
// through CRYPTO frames, with QUIC packet keys derived from the live
// handshake via tls/quicTls.zig (RFC 9001 Section 7). Packet protection
// (AEAD + header protection) applies throughout; a forged or reordered
// byte fails packet authentication or Finished verification instead of
// silently passing.
//
// Honest scope: server authentication here is key-continuity (the client
// verifies the server Finished MAC over the shared transcript, which
// proves both sides agree on every handshake byte and the ECDHE secret).
// X.509 chain validation against a trust store stays policy-level (see
// protocols/tls/verify.zig); the server flight carries an empty
// certificate list and an ECDSA signature from a deterministic test key.

const TlsHandshakeDriver = struct {
    engine: tlsEngine.Engine,
    /// Our own flight bytes (client: ClientHello; server: SH..Fin).
    flight: std.ArrayList(u8) = .empty,
    /// Accumulated inbound CRYPTO bytes for our space.
    incoming: std.ArrayList(u8) = .empty,
    /// Full peer flight retained for transcript binding + comparison.
    peerFlight: std.ArrayList(u8) = .empty,
    /// RFC 9001 chain point agreed with the peer (for test asserts).
    shared: ?[32]u8 = null,
    hsSecret: ?[32]u8 = null,
    flightDone: bool = false,
    finishedVerified: bool = false,
    finishedSent: bool = false,
    sec1: [39]u8 = @splat(0),

    fn hashConcat(parts: []const []const u8) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (parts) |p| h.update(p);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    /// Drains queued CRYPTO bytes into packet(s) on the given space.
    fn sendQueued(conn: *Connection, kind: SpaceKind, nowMs: u64) Error!void {
        const B = struct {
            var target: ?*Connection = null;
            var skind: SpaceKind = .initial;
            pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                const c = target orelse return;
                while (c.takeCrypto(skind, 1200)) |chunk| {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = chunk.offset, .data = chunk.data } });
                    _ = c.consumeCrypto(skind, chunk.data.len);
                }
            }
        };
        if (conn.takeCrypto(kind, 1) == null) return;
        B.target = conn;
        B.skind = kind;
        try conn.sendFrames(kind, B.build, nowMs);
    }

    fn clientStart(ctx: ?*anyopaque, conn: *Connection, nowMs: u64) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        const ch = d.engine.produceClientHello(&.{"h2"}, &.{}, null, null) catch return Error.TlsDriverFailed;
        defer conn.allocator.free(ch);
        d.flight.appendSlice(conn.allocator, ch) catch return Error.OutOfMemory;
        _ = try conn.queueCrypto(.initial, ch);
        try sendQueued(conn, .initial, nowMs);
    }

    /// Consumes one complete handshake record from the front of `buf`.
    /// Returns the record (type + full message) or null when incomplete.
    fn takeRecord(buf: *std.ArrayList(u8)) ?struct { kind: u8, msg: []const u8 } {
        if (buf.items.len < 4) return null;
        const bodyLen: usize = (@as(usize, buf.items[1]) << 16) | (@as(usize, buf.items[2]) << 8) | buf.items[3];
        if (buf.items.len < 4 + bodyLen) return null;
        return .{ .kind = buf.items[0], .msg = buf.items[0 .. 4 + bodyLen] };
    }

    fn dropFront(buf: *std.ArrayList(u8), a: Allocator, n: usize) void {
        buf.replaceRange(a, 0, n, &.{}) catch {};
    }

    fn serverOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        if (d.finishedVerified) return;
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        if (d.flightDone) {
            // Post-flight: only the client's Finished is expected.
            const frec = takeRecord(&d.incoming) orelse return;
            if (frec.kind != @backingInt(ths.HandshakeType.finished)) return Error.ProtocolViolation;
            d.engine.verifyClientFinished(frec.msg) catch return Error.TlsDriverFailed;
            dropFront(&d.incoming, conn.allocator, frec.msg.len);
            d.finishedVerified = true;
            // A verified Finished proves the peer can receive at this
            // address. Until then the 3x anti-amplification gate stays
            // active unless a Retry token validated the address earlier.
            conn.addressValidated = true;
            // RFC 9001 Section 4.1.2: the server confirms once Finished
            // is verified, then discards the Handshake keys and tells
            // the client to do the same with HANDSHAKE_DONE.
            conn.handshakeComplete = true;
            conn.confirmHandshake();
            conn.replayPendingApp(nowMs) catch {};
            const DoneB = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .handshakeDone);
                }
            };
            try conn.sendFrames(.application, DoneB.build, nowMs);
            return;
        }
        const rec = takeRecord(&d.incoming) orelse return;
        if (rec.kind != @backingInt(ths.HandshakeType.client_hello)) return Error.ProtocolViolation;
        const chMsg = rec.msg;
        d.engine.processClientHello(chMsg) catch return Error.TlsDriverFailed;
        var flight = d.engine.produceServerFlight(chMsg[4..], "", &d.sec1, &.{}, &.{}, null) catch return Error.TlsDriverFailed;
        defer flight.deinit(conn.allocator);

        d.flight.appendSlice(conn.allocator, flight.serverHello) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.encryptedExtensions) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.certificate) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.certificateVerify) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.finished) catch return Error.OutOfMemory;

        const shared = d.engine.sharedSecret32() orelse return Error.TlsDriverFailed;
        d.shared = shared;
        const chSh = hashConcat(&.{ chMsg, flight.serverHello });
        const hs = qtls.handshakeKeys(shared, chSh);
        d.hsSecret = hs.hsSecret;
        // LevelKeys secrets are client-oriented (tx = client); mirror them.
        try conn.installKeys(.handshake, hs.keys.rxSecret, hs.keys.txSecret);

        // Bootstrap (RFC 9001 Section 4.1 pattern): ServerHello leaves in
        // an Initial packet so the peer can open it with Initial keys and
        // derive Handshake keys; EE..Finished follow in Handshake packets.
        _ = try conn.queueCrypto(.initial, flight.serverHello);
        try sendQueued(conn, .initial, nowMs);
        _ = try conn.queueCrypto(.handshake, flight.encryptedExtensions);
        _ = try conn.queueCrypto(.handshake, flight.certificate);
        _ = try conn.queueCrypto(.handshake, flight.certificateVerify);
        _ = try conn.queueCrypto(.handshake, flight.finished);
        try sendQueued(conn, .handshake, nowMs);

        const chSf = hashConcat(&.{ chMsg, d.flight.items });
        const ap = qtls.applicationKeys(hs.hsSecret, chSf);
        try conn.installKeys(.application, ap.keys.rxSecret, ap.keys.txSecret);

        // Retain the exact peer flight for the caller's comparison, then
        // consume the hello: `incoming` is reused for the Finished.
        d.peerFlight.appendSlice(conn.allocator, chMsg) catch return Error.OutOfMemory;
        dropFront(&d.incoming, conn.allocator, chMsg.len);

        // The ClientHello does not validate the peer address. Keep the
        // 3x anti-amplification gate active until Finished is verified,
        // or until a Retry token has already validated the address.
        // HANDSHAKE_DONE waits for the client Finished: the server has not
        // confirmed the handshake yet (RFC 9001 Section 4.1.2).
        d.flightDone = true;
    }

    fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        d.peerFlight.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        while (takeRecord(&d.incoming)) |rec| {
            switch (rec.kind) {
                @backingInt(ths.HandshakeType.server_hello) => {
                    d.engine.processServerHello(rec.msg) catch return Error.TlsDriverFailed;
                    const shared = d.engine.sharedSecret32() orelse return Error.TlsDriverFailed;
                    d.shared = shared;
                    const chSh = hashConcat(&.{ d.flight.items, rec.msg });
                    const hs = qtls.handshakeKeys(shared, chSh);
                    d.hsSecret = hs.hsSecret;
                    try conn.installKeys(.handshake, hs.keys.txSecret, hs.keys.rxSecret);
                    conn.discardInitialKeys();
                },
                @backingInt(ths.HandshakeType.encrypted_extensions) => {
                    d.engine.processEncryptedExtensions(rec.msg) catch return Error.TlsDriverFailed;
                },
                @backingInt(ths.HandshakeType.certificate) => {
                    d.engine.processCertificate(rec.msg) catch return Error.TlsDriverFailed;
                },
                @backingInt(ths.HandshakeType.certificate_verify) => {
                    d.engine.processCertificateVerify(rec.msg) catch return Error.TlsDriverFailed;
                },
                @backingInt(ths.HandshakeType.finished) => {
                    if (d.finishedSent) return;
                    // HMAC over the shared transcript: proves both sides
                    // agree on every handshake byte before 1-RTT starts.
                    d.engine.processFinished(rec.msg) catch return Error.TlsDriverFailed;
                    const hsSecret = d.hsSecret orelse return Error.TlsDriverFailed;
                    const chSf = hashConcat(&.{ d.flight.items, d.peerFlight.items });
                    const ap = qtls.applicationKeys(hsSecret, chSf);
                    try conn.installKeys(.application, ap.keys.txSecret, ap.keys.rxSecret);
                    // The client's Finished completes the handshake; the
                    // server confirms it and answers with HANDSHAKE_DONE.
                    const fin = d.engine.produceClientFinished() catch return Error.TlsDriverFailed;
                    defer conn.allocator.free(fin);
                    _ = try conn.queueCrypto(.handshake, fin);
                    try sendQueued(conn, .handshake, nowMs);
                    d.finishedSent = true;
                    conn.handshakeComplete = true;
                },
                else => return Error.ProtocolViolation,
            }
            dropFront(&d.incoming, conn.allocator, rec.msg.len);
        }
    }
};

/// Runs a complete TLS 1.3 handshake between two QUIC Connections through
/// the TlsHandshakeDriver: Initial + Handshake + 1-RTT keys installed,
/// client Finished exchanged, and HANDSHAKE_DONE confirming the client.
/// Shared by the QUIC/TLS and HTTP/3 loopback tests so the handshake pump
/// has one definition.
fn runTlsHandshake(
    a: Allocator,
    client: *Connection,
    server: *Connection,
    cliD: *TlsHandshakeDriver,
    srvD: *TlsHandshakeDriver,
) !void {
    // Deterministic P-256 signing identity (same construction as the
    // engine unit test): ECDSA signatures without PKI involvement.
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const ecKp = try EcdsaP256.KeyPair.generateDeterministic((@as([32]u8, @splat(0x42))));
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);
    srvD.sec1 = sec1;

    client.tls = .{ .ctx = cliD, .start = TlsHandshakeDriver.clientStart, .onData = TlsHandshakeDriver.clientOnData };
    server.tls = .{ .ctx = srvD, .onData = TlsHandshakeDriver.serverOnData };

    try client.startHandshake(50);
    const c0 = try client.takeOutput(a);
    defer a.free(c0);

    try std.testing.expect(c0.len >= 64);

    try server.acceptInitial(client.dcid[0..8]);
    try server.receiveDatagram(c0, 100);
    // A ClientHello alone does not validate the source address; the
    // anti-amplification gate must stay active until Finished.
    try std.testing.expect(!server.addressValidated);

    const s0 = try server.takeOutput(a);
    defer a.free(s0);
    try std.testing.expect(s0.len > 64);
    try client.receiveDatagram(s0, 200);
    try std.testing.expectEqual(server.scidLen, client.dcidLen);
    try std.testing.expectEqualSlices(u8, server.scid[0..server.scidLen], client.dcid[0..client.dcidLen]);

    // The client verifies the server Finished and answers with its own
    // Finished; only then may the server confirm and send HANDSHAKE_DONE.
    const c1 = try client.takeOutput(a);
    defer a.free(c1);
    try std.testing.expect(c1.len > 0);
    try server.receiveDatagram(c1, 300);
    try std.testing.expect(server.addressValidated);

    const s1 = try server.takeOutput(a);
    defer a.free(s1);
    try std.testing.expect(s1.len > 0);
    try client.receiveDatagram(s1, 400);
}

test "quic carries TLS 1.3 handshake end to end" {
    const a = std.testing.allocator;

    var cliD = TlsHandshakeDriver{ .engine = tlsEngine.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{}) };
    defer cliD.flight.deinit(a);
    defer cliD.incoming.deinit(a);
    defer cliD.peerFlight.deinit(a);
    var srvD = TlsHandshakeDriver{ .engine = tlsEngine.Engine.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{}) };
    defer srvD.flight.deinit(a);
    defer srvD.incoming.deinit(a);
    defer srvD.peerFlight.deinit(a);

    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();

    try runTlsHandshake(a, client, server, &cliD, &srvD);

    // The server saw the exact ClientHello bytes the client sent.
    try std.testing.expectEqualSlices(u8, cliD.flight.items, srvD.peerFlight.items);
    // The client saw the exact server flight bytes.
    try std.testing.expectEqualSlices(u8, srvD.flight.items, cliD.peerFlight.items);

    // ECDHE agreement: both engines derived the same secret.
    try std.testing.expectEqualSlices(u8, &cliD.shared.?, &srvD.shared.?);
    // Engine key schedule matches the independent RFC 9001 chain.
    try std.testing.expectEqualSlices(u8, &cliD.engine.handshakeSecret.?, &cliD.hsSecret.?);
    try std.testing.expectEqualSlices(u8, &srvD.engine.handshakeSecret.?, &srvD.hsSecret.?);
    // Transcripts agree bit-for-bit (Finished HMAC already enforced it).
    var cTr = cliD.engine.transcript;
    var sTr = srvD.engine.transcript;
    try std.testing.expectEqualSlices(u8, &cTr.finish(), &sTr.finish());

    try std.testing.expectEqual(tlsEngine.Engine.State.handshakeComplete, cliD.engine.state);
    try std.testing.expectEqual(tlsEngine.Engine.State.serverFinishedSent, srvD.engine.state);
    try std.testing.expect(cliD.engine.apKeys != null);
    try std.testing.expect(srvD.engine.apKeys != null);
    try std.testing.expectEqual(State.established, client.state);
    try std.testing.expectEqual(State.established, server.state);
    // Both sides completed the lifecycle: confirmation discarded the
    // Handshake keys and released their recovery state (RFC 9001 4.9.2).
    try std.testing.expect(client.handshakeConfirmed);
    try std.testing.expect(server.handshakeConfirmed);
    try std.testing.expect(client.spaces[1].keysRx == null and client.spaces[1].keysTx == null);
    try std.testing.expect(server.spaces[1].keysRx == null and server.spaces[1].keysTx == null);
    try std.testing.expectEqual(@as(usize, 0), client.spaces[1].inFlightBytes);
    try std.testing.expectEqual(@as(usize, 0), server.spaces[1].inFlightBytes);

    // 1-RTT STREAM data under keys derived from the live handshake.
    const GotSink = struct {
        var got: [64]u8 = undefined;
        var gotLen: usize = 0;
        fn onStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
            _ = sid;
            _ = fin;
            @memcpy(got[gotLen..][0..data.len], data);
            gotLen += data.len;
        }
    };
    client.cbs = .{ .onStreamData = GotSink.onStream };
    const SB = struct {
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            try fe(gpa, payload, .{ .stream = .{ .id = 1, .offset = 0, .data = "tls-bound-stream", .fin = false } });
        }
    };
    try server.sendFrames(.application, SB.build, 300);
    const s1 = try server.takeOutput(a);
    defer a.free(s1);
    try client.receiveDatagram(s1, 400);
    try std.testing.expectEqualStrings("tls-bound-stream", GotSink.got[0..GotSink.gotLen]);
}

/// Moves one datagram from `from` to `to` (loopback pipe for tests).
fn pumpH3(from: *Connection, to: *Connection, nowMs: u64) !void {
    const a = from.allocator;
    const out = try from.takeOutput(a);
    defer a.free(out);
    try to.receiveDatagram(out, nowMs);
}
/// Sends `bytes` as one QUIC STREAM frame on `sid` at `offset`.
fn sendH3Stream(conn: *Connection, sid: u64, offset: u64, bytes: []const u8, fin: bool, nowMs: u64) !void {
    const B = struct {
        var sId: u64 = 0;
        var sOff: u64 = 0;
        var sFin: bool = false;
        var sData: []const u8 = "";
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            try fe(gpa, payload, .{ .stream = .{ .id = sId, .offset = sOff, .data = sData, .fin = sFin } });
        }
    };
    B.sId = sid;
    B.sOff = offset;
    B.sFin = fin;
    B.sData = bytes;
    try conn.sendFrames(.application, B.build, nowMs);
}

/// Direction-aware STREAM accumulator for the HTTP/3 loopback test.
const H3LoopSink = struct {
    var cliBufs: [8][16384]u8 = undefined;
    var cliLens: [8]usize = @splat(0);
    var cliFins: [8]bool = @splat(false);
    var cliSids: [8]u64 = @splat(std.math.maxInt(u64));
    var srvBufs: [8][16384]u8 = undefined;
    var srvLens: [8]usize = @splat(0);
    var srvFins: [8]bool = @splat(false);
    var srvSids: [8]u64 = @splat(std.math.maxInt(u64));

    fn reset() void {
        cliLens = @splat(0);
        cliFins = @splat(false);
        cliSids = @splat(std.math.maxInt(u64));
        srvLens = @splat(0);
        srvFins = @splat(false);
        srvSids = @splat(std.math.maxInt(u64));
    }

    fn slot(sids: *[8]u64, sid: u64) usize {
        var i: usize = 0;
        while (i < sids.len) : (i += 1) {
            if (sids.*[i] == sid) return i;
        }
        i = 0;
        while (i < sids.len) : (i += 1) {
            if (sids.*[i] == std.math.maxInt(u64)) {
                sids.*[i] = sid;
                return i;
            }
        }
        unreachable;
    }

    fn store(bufs: *[8][16384]u8, lens: *[8]usize, fins: *[8]bool, sids: *[8]u64, sid: u64, data: []const u8, fin: bool) void {
        const i = slot(sids, sid);
        std.debug.assert(lens.*[i] + data.len <= bufs.*[i].len);
        @memcpy(bufs.*[i][lens.*[i]..][0..data.len], data);
        lens.*[i] += data.len;
        if (fin) fins.*[i] = true;
    }

    fn onCliStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        store(&cliBufs, &cliLens, &cliFins, &cliSids, sid, data, fin);
    }

    fn onSrvStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        store(&srvBufs, &srvLens, &srvFins, &srvSids, sid, data, fin);
    }

    fn find(sids: *[8]u64, lens: *[8]usize, bufs: *[8][16384]u8, sid: u64) ?[]const u8 {
        for (sids.*, 0..) |s, i| if (s == sid) return bufs.*[i][0..lens.*[i]];
        return null;
    }

    fn cliBytes(sid: u64) ?[]const u8 {
        return find(&cliSids, &cliLens, &cliBufs, sid);
    }

    fn srvBytes(sid: u64) ?[]const u8 {
        return find(&srvSids, &srvLens, &srvBufs, sid);
    }
};

test "http3 request over quic loopback reaches handler and returns response" {
    const a = std.testing.allocator;
    H3LoopSink.reset();

    var cliD = TlsHandshakeDriver{ .engine = tlsEngine.Engine.initClient(std.Io.Threaded.global_single_threaded.io(), a, .{}) };
    defer cliD.flight.deinit(a);
    defer cliD.incoming.deinit(a);
    defer cliD.peerFlight.deinit(a);
    var srvD = TlsHandshakeDriver{ .engine = tlsEngine.Engine.initServer(std.Io.Threaded.global_single_threaded.io(), a, .{}) };
    defer srvD.flight.deinit(a);
    defer srvD.incoming.deinit(a);
    defer srvD.peerFlight.deinit(a);

    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();
    client.cbs = .{ .onStreamData = H3LoopSink.onCliStream };
    server.cbs = .{ .onStreamData = H3LoopSink.onSrvStream };

    try runTlsHandshake(a, client, server, &cliD, &srvD);
    try std.testing.expectEqual(State.established, client.state);

    var cliH3 = h3conn.Connection.init(a, .client);
    defer cliH3.deinit();
    var srvH3 = h3conn.Connection.init(a, .server);
    defer srvH3.deinit();

    // 1. Control streams: SETTINGS both directions on uni streams 2 / 3.
    const cliCtl = try cliH3.buildControlStream();
    defer a.free(cliCtl);
    try sendH3Stream(client, 2, 0, cliCtl, false, 500);
    try pumpH3(client, server, 501);
    {
        const got = H3LoopSink.srvBytes(2).?;
        var off: usize = 0;
        try std.testing.expectEqual(h3conn.CONTROL_STREAM_TYPE, try varint.decode(got, &off));
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x4), fr.frameType);
        const entries = try h3frame.parseSettingsPayload(fr.payload, a);
        defer a.free(entries);
        try srvH3.processPeerSettings(entries);
        try std.testing.expect(srvH3.settingsReceived);
    }
    const srvCtl = try srvH3.buildControlStream();
    defer a.free(srvCtl);
    try sendH3Stream(server, 3, 0, srvCtl, false, 502);
    try pumpH3(server, client, 503);
    {
        const got = H3LoopSink.cliBytes(3).?;
        var off: usize = 0;
        try std.testing.expectEqual(h3conn.CONTROL_STREAM_TYPE, try varint.decode(got, &off));
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x4), fr.frameType);
        const entries = try h3frame.parseSettingsPayload(fr.payload, a);
        defer a.free(entries);
        try cliH3.processPeerSettings(entries);
        try std.testing.expect(cliH3.settingsReceived);
    }

    // 2. QPACK encoder/decoder uni streams carry their type prefixes.
    const cliEnc = try h3conn.buildQpackEncoderStreamPrefix(a);
    defer a.free(cliEnc);
    const cliDec = try h3conn.buildQpackDecoderStreamPrefix(a);
    defer a.free(cliDec);
    // Short-header packets carry no length prefix, so each datagram holds
    // exactly one of them: pump after every send.
    try sendH3Stream(client, 6, 0, cliEnc, false, 504);
    try pumpH3(client, server, 505);
    try sendH3Stream(client, 10, 0, cliDec, false, 506);
    try pumpH3(client, server, 507);
    {
        var off: usize = 0;
        try std.testing.expectEqual(h3frame.UniStreamType.qpackEncoder, try varint.decode(H3LoopSink.srvBytes(6).?, &off));
        off = 0;
        try std.testing.expectEqual(h3frame.UniStreamType.qpackDecoder, try varint.decode(H3LoopSink.srvBytes(10).?, &off));
    }

    // 3. Request 1: GET /hello on client bidi stream 0.
    var cliQenc = h3qpack.Encoder.init(a);
    defer cliQenc.deinit();
    var rs = h3conn.RequestStream{ .id = 0, .allocator = a, .qpack = &cliQenc };
    const reqHead = try rs.buildRequestHeaders("GET", "https", "example.com", "/hello", &.{});
    defer a.free(reqHead);
    try sendH3Stream(client, 0, 0, reqHead, true, 508);
    try pumpH3(client, server, 509);

    // Server decodes HEADERS, dispatches by :path, and responds.
    const Handler = struct {
        fn route(path: []const u8) struct { status: u16, body: []const u8 } {
            if (std.mem.eql(u8, path, "/hello")) return .{ .status = 200, .body = "hello-h3" };
            return .{ .status = 404, .body = "not-found" };
        }
    };
    var respStatus: u16 = 0;
    var respBody: []const u8 = "";
    {
        const got = H3LoopSink.srvBytes(0).?;
        var off: usize = 0;
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x1), fr.frameType);
        const fields = try srvH3.qdec.decodeSectionCounted(fr.payload, 0, null);
        defer srvH3.qdec.freeFields(fields);
        var path: []const u8 = "";
        var method: []const u8 = "";
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":path")) {
                path = f.value;
            }
            if (std.mem.eql(u8, f.name, ":method")) {
                method = f.value;
            }
        }
        try std.testing.expectEqualStrings("GET", method);
        const r = Handler.route(path);
        var srvQenc = h3qpack.Encoder.init(a);
        defer srvQenc.deinit();
        var srs = h3conn.RequestStream{ .id = 0, .allocator = a, .qpack = &srvQenc };
        const respHead = try srs.buildResponseHeaders(r.status, &.{});
        defer a.free(respHead);
        const respData = try srs.buildData(r.body);
        defer a.free(respData);
        var respWire = std.ArrayList(u8).empty;
        defer respWire.deinit(a);
        try respWire.appendSlice(a, respHead);
        try respWire.appendSlice(a, respData);
        try sendH3Stream(server, 0, 0, respWire.items, true, 510);
    }
    try pumpH3(server, client, 511);
    {
        const got = H3LoopSink.cliBytes(0).?;
        var off: usize = 0;
        while (off < got.len) {
            const fr = try h3frame.parseFrame(got, &off);
            if (fr.frameType == 0x1) {
                const fields = try cliH3.qdec.decodeSectionCounted(fr.payload, 0, null);
                defer cliH3.qdec.freeFields(fields);
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        respStatus = try std.fmt.parseInt(u16, f.value, 10);
                    }
                }
            } else if (fr.frameType == 0x0) {
                respBody = fr.payload;
            }
        }
    }
    try std.testing.expectEqual(@as(u16, 200), respStatus);
    try std.testing.expectEqualStrings("hello-h3", respBody);

    // 4. Request 2 on a fresh stream proves multiplexing + dispatch miss.
    var cliQenc2 = h3qpack.Encoder.init(a);
    defer cliQenc2.deinit();
    var rs2 = h3conn.RequestStream{ .id = 4, .allocator = a, .qpack = &cliQenc2 };
    const req2 = try rs2.buildRequestHeaders("GET", "https", "example.com", "/missing", &.{});
    defer a.free(req2);
    try sendH3Stream(client, 4, 0, req2, true, 512);
    try pumpH3(client, server, 513);
    {
        const got = H3LoopSink.srvBytes(4).?;
        var off: usize = 0;
        const fr = try h3frame.parseFrame(got, &off);
        const fields = try srvH3.qdec.decodeSectionCounted(fr.payload, 0, null);
        defer srvH3.qdec.freeFields(fields);
        var path: []const u8 = "";
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":path")) {
                path = f.value;
            }
        }
        const r = Handler.route(path);
        try std.testing.expectEqual(@as(u16, 404), r.status);
        try std.testing.expectEqualStrings("not-found", r.body);
    }

    // 5. Request 3: POST /echo with request body on client bidi stream 8.
    {
        var cliQenc3 = h3qpack.Encoder.init(a);
        defer cliQenc3.deinit();
        var rs3 = h3conn.RequestStream{ .id = 8, .allocator = a, .qpack = &cliQenc3 };
        const req3Head = try rs3.buildRequestHeaders("POST", "https", "example.com", "/echo", &.{});
        defer a.free(req3Head);
        const req3Data = try rs3.buildData("{\"name\":\"zig-h3\",\"magic\":42}");
        defer a.free(req3Data);

        var req3Wire = std.ArrayList(u8).empty;
        defer req3Wire.deinit(a);
        try req3Wire.appendSlice(a, req3Head);
        try req3Wire.appendSlice(a, req3Data);

        try sendH3Stream(client, 8, 0, req3Wire.items, true, 514);
        try pumpH3(client, server, 515);

        // Server receives stream 8, decodes HEADERS and DATA frames, responds with echo.
        const got = H3LoopSink.srvBytes(8).?;
        var off: usize = 0;
        const frH = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x1), frH.frameType);
        const fields = try srvH3.qdec.decodeSectionCounted(frH.payload, 0, null);
        defer srvH3.qdec.freeFields(fields);
        var postMethod: []const u8 = "";
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":method")) postMethod = f.value;
        }
        try std.testing.expectEqualStrings("POST", postMethod);

        const frD = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x0), frD.frameType);
        try std.testing.expectEqualStrings("{\"name\":\"zig-h3\",\"magic\":42}", frD.payload);

        // Server returns 201 Created and echoes back the body
        var srvQenc3 = h3qpack.Encoder.init(a);
        defer srvQenc3.deinit();
        var srs3 = h3conn.RequestStream{ .id = 8, .allocator = a, .qpack = &srvQenc3 };
        const resp3Head = try srs3.buildResponseHeaders(201, &.{});
        defer a.free(resp3Head);
        const resp3Data = try srs3.buildData(frD.payload);
        defer a.free(resp3Data);
        var resp3Wire = std.ArrayList(u8).empty;
        defer resp3Wire.deinit(a);
        try resp3Wire.appendSlice(a, resp3Head);
        try resp3Wire.appendSlice(a, resp3Data);
        try sendH3Stream(server, 8, 0, resp3Wire.items, true, 516);
        try pumpH3(server, client, 517);

        const cliGot = H3LoopSink.cliBytes(8).?;
        var cliOff: usize = 0;
        var postStatus: u16 = 0;
        var postRespBody: []const u8 = "";
        while (cliOff < cliGot.len) {
            const fr = try h3frame.parseFrame(cliGot, &cliOff);
            if (fr.frameType == 0x1) {
                const sfields = try cliH3.qdec.decodeSectionCounted(fr.payload, 0, null);
                defer cliH3.qdec.freeFields(sfields);
                for (sfields) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        postStatus = try std.fmt.parseInt(u16, f.value, 10);
                    }
                }
            } else if (fr.frameType == 0x0) {
                postRespBody = fr.payload;
            }
        }
        try std.testing.expectEqual(@as(u16, 201), postStatus);
        try std.testing.expectEqualStrings("{\"name\":\"zig-h3\",\"magic\":42}", postRespBody);
    }

    // 6. Request 4: PUT /upload with large multi-frame body (>4KB) on client bidi stream 12.
    {
        var cliQenc4 = h3qpack.Encoder.init(a);
        defer cliQenc4.deinit();
        var rs4 = h3conn.RequestStream{ .id = 12, .allocator = a, .qpack = &cliQenc4 };
        const req4Head = try rs4.buildRequestHeaders("PUT", "https", "example.com", "/upload", &.{});
        defer a.free(req4Head);

        // Build a 4500-byte test body
        const bigPayload = try a.alloc(u8, 4500);
        defer a.free(bigPayload);
        for (bigPayload, 0..) |*b, i| b.* = @intCast(i % 251);

        // Send HEADERS first with fin=false
        try sendH3Stream(client, 12, 0, req4Head, false, 518);
        try pumpH3(client, server, 519);

        // Send 4 DATA frames of ~1125 bytes each
        var uploaded: usize = 0;
        var putStreamOff: u64 = req4Head.len;
        while (uploaded < bigPayload.len) {
            const end = @min(uploaded + 1125, bigPayload.len);
            const chunk = bigPayload[uploaded..end];
            const isLast = end == bigPayload.len;
            const dfr = try rs4.buildData(chunk);
            defer a.free(dfr);
            try sendH3Stream(client, 12, putStreamOff, dfr, isLast, 520 + @as(u64, @intCast(uploaded)));
            putStreamOff += dfr.len;
            uploaded = end;
            try pumpH3(client, server, 521 + @as(u64, @intCast(uploaded)));
        }

        // Server receives stream 12, validates all DATA frames reconstruct into bigPayload
        const got = H3LoopSink.srvBytes(12).?;
        var off: usize = 0;
        const frH = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x1), frH.frameType);
        const fields = try srvH3.qdec.decodeSectionCounted(frH.payload, 0, null);
        defer srvH3.qdec.freeFields(fields);

        var assembledBody = std.ArrayList(u8).empty;
        defer assembledBody.deinit(a);
        while (off < got.len) {
            const dfr = try h3frame.parseFrame(got, &off);
            if (dfr.frameType == 0x0) {
                try assembledBody.appendSlice(a, dfr.payload);
            }
        }
        try std.testing.expectEqualSlices(u8, bigPayload, assembledBody.items);

        // Server responds with 200 and a 3000-byte streaming response
        var srvQenc4 = h3qpack.Encoder.init(a);
        defer srvQenc4.deinit();
        var srs4 = h3conn.RequestStream{ .id = 12, .allocator = a, .qpack = &srvQenc4 };
        const resp4Head = try srs4.buildResponseHeaders(200, &.{});
        defer a.free(resp4Head);

        const bigResp = try a.alloc(u8, 3000);
        defer a.free(bigResp);
        for (bigResp, 0..) |*b, i| b.* = @intCast((i + 13) % 251);

        try sendH3Stream(server, 12, 0, resp4Head, false, 600);
        try pumpH3(server, client, 601);

        var srvStreamOff: u64 = resp4Head.len;
        var srvSent: usize = 0;
        while (srvSent < bigResp.len) {
            const end = @min(srvSent + 1000, bigResp.len);
            const chunk = bigResp[srvSent..end];
            const isLast = end == bigResp.len;
            const dfr = try srs4.buildData(chunk);
            defer a.free(dfr);
            try sendH3Stream(server, 12, srvStreamOff, dfr, isLast, 602 + @as(u64, @intCast(srvSent)));
            srvStreamOff += dfr.len;
            srvSent = end;
            try pumpH3(server, client, 603 + @as(u64, @intCast(srvSent)));
        }

        const cliGot = H3LoopSink.cliBytes(12).?;
        var cliOff: usize = 0;
        _ = try h3frame.parseFrame(cliGot, &cliOff); // headers
        var cliAssembled = std.ArrayList(u8).empty;
        defer cliAssembled.deinit(a);
        while (cliOff < cliGot.len) {
            const fr = try h3frame.parseFrame(cliGot, &cliOff);
            if (fr.frameType == 0x0) {
                try cliAssembled.appendSlice(a, fr.payload);
            }
        }
        try std.testing.expectEqualSlices(u8, bigResp, cliAssembled.items);
    }

    // 7. Request 5: DELETE /item/99 on client bidi stream 16 with body and unknown frame skipping.
    {
        var cliQenc5 = h3qpack.Encoder.init(a);
        defer cliQenc5.deinit();
        var rs5 = h3conn.RequestStream{ .id = 16, .allocator = a, .qpack = &cliQenc5 };
        const req5Head = try rs5.buildRequestHeaders("DELETE", "https", "example.com", "/item/99", &.{});
        defer a.free(req5Head);
        const req5Data = try rs5.buildData("{\"reason\":\"test\"}");
        defer a.free(req5Data);

        // Synthesize an unknown extension frame (type 0xbeef, len 4) to ensure RFC 9114 7.2.8 compliance
        var unkFrame: [16]u8 = undefined;
        const unkHlen = try h3frame.encodeFrameHeader(&unkFrame, 0xbeef, 4);
        @memcpy(unkFrame[unkHlen..][0..4], "test");
        const unkTotal = unkHlen + 4;

        var req5Wire = std.ArrayList(u8).empty;
        defer req5Wire.deinit(a);
        try req5Wire.appendSlice(a, req5Head);
        try req5Wire.appendSlice(a, unkFrame[0..unkTotal]);
        try req5Wire.appendSlice(a, req5Data);

        try sendH3Stream(client, 16, 0, req5Wire.items, true, 700);
        try pumpH3(client, server, 701);

        const got = H3LoopSink.srvBytes(16).?;
        var off: usize = 0;
        const frH = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x1), frH.frameType);
        const fields = try srvH3.qdec.decodeSectionCounted(frH.payload, 0, null);
        defer srvH3.qdec.freeFields(fields);
        var delMethod: []const u8 = "";
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":method")) delMethod = f.value;
        }
        try std.testing.expectEqualStrings("DELETE", delMethod);

        // Unknown frame should be parsed and skipped cleanly
        const frUnk = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0xbeef), frUnk.frameType);
        try std.testing.expectEqualStrings("test", frUnk.payload);

        // Following DATA frame arrives intact
        const frD = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x0), frD.frameType);
        try std.testing.expectEqualStrings("{\"reason\":\"test\"}", frD.payload);
    }

    // 8. Graceful shutdown: GOAWAY on the server control stream.
    var idbuf: [8]u8 = undefined;
    const idlen = try varint.encode(&idbuf, 4);
    var go: [32]u8 = undefined;
    const ghlen = try h3frame.encodeFrameHeader(go[0..], 0x7, @intCast(idlen));
    @memcpy(go[ghlen..][0..idlen], idbuf[0..idlen]);
    const srvCtlLen = srvCtl.len;
    try sendH3Stream(server, 3, srvCtlLen, go[0 .. ghlen + idlen], true, 514);
    try pumpH3(server, client, 515);
    {
        const got = H3LoopSink.cliBytes(3).?;
        // Skip the stream-type prefix + SETTINGS already verified above.
        var prefixOff: usize = 0;
        _ = try varint.decode(got, &prefixOff);
        var fOff = prefixOff;
        _ = try h3frame.parseFrame(got, &fOff);
        const fr = try h3frame.parseFrame(got, &fOff);
        try std.testing.expectEqual(@as(u64, 0x7), fr.frameType);
        var idOff: usize = 0;
        try std.testing.expectEqual(@as(u64, 4), try varint.decode(fr.payload, &idOff));
    }
}

test "crypto transmit queue preserves offsets across partial drains" {
    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();

    try std.testing.expectEqual(@as(u64, 0), try conn.queueCrypto(.initial, "client-hello"));
    try std.testing.expectEqual(@as(u64, 12), try conn.queueCrypto(.initial, "-tail"));

    const first = conn.takeCrypto(.initial, 6).?;
    try std.testing.expectEqual(@as(u64, 0), first.offset);
    try std.testing.expectEqualStrings("client", first.data);
    try std.testing.expect(conn.consumeCrypto(.initial, first.data.len));

    const second = conn.takeCrypto(.initial, 64).?;
    try std.testing.expectEqual(@as(u64, 6), second.offset);
    try std.testing.expectEqualStrings("-hello-tail", second.data);
    try std.testing.expect(conn.consumeCrypto(.initial, second.data.len));
    var huge: [1501]u8 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, conn.queueCrypto(.initial, &huge));
}

test "crypto receive reassembles reordered and overlapping segments" {
    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();

    try conn.receiveCrypto(.initial, 5, " world", 100);
    try std.testing.expectEqual(@as(u64, 0), conn.cryptoRecvOff[0]);
    try conn.receiveCrypto(.initial, 0, "hello", 101);
    try std.testing.expectEqual(@as(u64, 11), conn.cryptoRecvOff[0]);
    try std.testing.expectEqualStrings("hello world", conn.cryptoBuf[0].items);
    try conn.receiveCrypto(.initial, 3, "lo world", 102);
    try std.testing.expectEqual(@as(u64, 11), conn.cryptoRecvOff[0]);
}

// Control-plane send APIs: queued frames drain into packets, resets
// route per-stream, and flow-control windows gate sends while
// DATA_BLOCKED-style signals raise them immediately on both ends.

const CtlPair = struct {
    client: *Connection,
    server: *Connection,

    fn init(a: Allocator) !CtlPair {
        const client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
        errdefer client.deinit();
        const server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
        errdefer server.deinit();
        // Mirrored 1-RTT secrets (same loopback convention as the
        // handshake tests); CIDs need no alignment for short headers.
        const secret = (@as([32]u8, @splat(0xA5)));
        try client.installKeys(.application, secret, secret);
        try server.installKeys(.application, secret, secret);
        server.addressValidated = true;
        return .{ .client = client, .server = server };
    }

    fn deinit(self: *CtlPair) void {
        self.client.deinit();
        self.server.deinit();
    }

    fn pumpCS(self: *CtlPair, a: Allocator) !void {
        const out = try self.client.takeOutput(a);
        defer a.free(out);
        try self.server.receiveDatagram(out, 900);
    }

    fn pumpSC(self: *CtlPair, a: Allocator) !void {
        const out = try self.server.takeOutput(a);
        defer a.free(out);
        try self.client.receiveDatagram(out, 901);
    }
};

const CtlRec = struct {
    resetSid: ?u64 = null,
    resetCode: u64 = 0,
    stopSid: ?u64 = null,
    stopCode: u64 = 0,
    closeCode: ?u64 = null,
    closeReasonBuf: [64]u8 = undefined,
    closeReasonLen: usize = 0,
    closeReason: []const u8 = "",

    fn cbs(self: *CtlRec) Callbacks {
        return .{
            .ctx = self,
            .onStreamReset = onReset,
            .onStopSending = onStop,
            .onClose = onClose,
        };
    }
    fn onReset(ctx: ?*anyopaque, sid: u64, code: u64) void {
        const r: *CtlRec = @ptrCast(@alignCast(ctx.?));
        r.resetSid = sid;
        r.resetCode = code;
    }
    fn onStop(ctx: ?*anyopaque, sid: u64, code: u64) void {
        const r: *CtlRec = @ptrCast(@alignCast(ctx.?));
        r.stopSid = sid;
        r.stopCode = code;
    }
    fn onClose(ctx: ?*anyopaque, code: u64, reason: []const u8) void {
        const r: *CtlRec = @ptrCast(@alignCast(ctx.?));
        r.closeCode = code;
        // The reason borrows packet plaintext: copy before return.
        const n = @min(reason.len, r.closeReasonBuf.len);
        @memcpy(r.closeReasonBuf[0..n], reason[0..n]);
        r.closeReasonLen = n;
        r.closeReason = r.closeReasonBuf[0..n];
    }
};

test "control queue drains into next packet and applies remotely" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.queueControlFrame(.{ .maxData = .{ .maximum = 2 << 20 } });
    try std.testing.expectEqual(@as(usize, 1), pair.client.queuedControl.items.len);
    const Empty = struct {
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            _ = gpa;
            _ = payload;
        }
    };
    try pair.client.sendFrames(.application, Empty.build, 100);
    try std.testing.expectEqual(@as(usize, 0), pair.client.queuedControl.items.len);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(u64, 2 << 20), pair.server.maxDataRemote);
}

test "stop sending triggers immediate reset reply" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    var crec = CtlRec{};
    var srec = CtlRec{};
    pair.client.cbs = crec.cbs();
    pair.server.cbs = srec.cbs();

    try pair.client.sendStopSending(4, 0x100, 100);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(?u64, 4), srec.stopSid);
    try std.testing.expectEqual(@as(u64, 0x100), srec.stopCode);
    // The server answered with RESET_STREAM in the same exchange.
    try pair.pumpSC(a);
    try std.testing.expectEqual(@as(?u64, 4), crec.resetSid);
    try std.testing.expectEqual(@as(u64, 0x100), crec.resetCode);
    try std.testing.expect(crec.closeCode == null);
}

test "reset routes to stream callback and stream state, not close" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    var srec = CtlRec{};
    pair.server.cbs = srec.cbs();

    // Open stream 0 first so reset state has a stream to mark.
    try pair.client.sendStreamChecked(0, 0, "hello", false, 100);
    try pair.pumpCS(a);
    try pair.client.sendResetStream(0, 0x10C, 5, 101);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(?u64, 0), srec.resetSid);
    try std.testing.expectEqual(@as(u64, 0x10C), srec.resetCode);
    try std.testing.expect(srec.closeCode == null);
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u64, 0x10C), st.resetError);
}

test "send stream checked gates windows and accounts once" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const data = (@as([100]u8, @splat(0xAB)));

    try pair.client.sendStreamChecked(0, 0, &data, false, 100);
    try std.testing.expectEqual(@as(u64, 100), pair.client.dataSent);
    try std.testing.expectEqual(@as(u64, 100), pair.client.sendStreamEnd.get(0).?);
    // Resending the same range does not consume window twice.
    try pair.client.sendStreamChecked(0, 0, &data, false, 101);
    try std.testing.expectEqual(@as(u64, 100), pair.client.dataSent);

    pair.client.maxDataRemote = 50;
    try std.testing.expectError(Error.SendBlocked, pair.client.sendStreamChecked(4, 0, &data, false, 102));
    pair.client.maxDataRemote = 1 << 20;
    try pair.client.maxStreamData.put(4, 10);
    try std.testing.expectError(Error.SendBlocked, pair.client.sendStreamChecked(4, 0, &data, false, 103));
    try pair.client.maxStreamData.put(4, 1 << 20);
    try pair.client.sendStreamChecked(4, 0, &data, false, 104);
    try std.testing.expectEqual(@as(u64, 200), pair.client.dataSent);
}

test "data blocked raises window immediately on both ends" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.queueControlFrame(.{ .dataBlocked = .{ .limit = 1 << 20 } });
    try pair.client.flushControl(.application, 100);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(u64, 2 << 20), pair.server.maxData);
    // The server answered with MAX_DATA without waiting for other sends.
    try pair.pumpSC(a);
    try std.testing.expectEqual(@as(u64, 2 << 20), pair.client.maxDataRemote);
}

test "receive flow control violation enforced" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    pair.server.maxData = 10;

    const data = (@as([100]u8, @splat(0xCD)));
    try pair.client.sendStreamChecked(0, 0, &data, false, 100);
    const out = try pair.client.takeOutput(a);
    defer a.free(out);
    try std.testing.expectError(Error.FlowControlViolation, pair.server.receiveDatagram(out, 101));
}

test "connection close roundtrip carries code and reason" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    var srec = CtlRec{};
    pair.server.cbs = srec.cbs();

    try pair.client.sendConnectionClose(0x100, "going away", true, 100);
    try pair.pumpCS(a);
    try std.testing.expectEqual(State.draining, pair.server.state);
    try std.testing.expectEqual(@as(?u64, 0x100), srec.closeCode);
    try std.testing.expectEqualStrings("going away", srec.closeReason);
}

test "stream data blocked raises the stream window" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    const data = (@as([10]u8, @splat(0xEF)));
    try pair.client.sendStreamChecked(0, 0, &data, false, 100);
    try pair.pumpCS(a);
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 65535), st.recvMaxOffset);

    try pair.client.queueControlFrame(.{ .streamDataBlocked = .{ .streamId = 0, .limit = 65535 } });
    try pair.client.flushControl(.application, 101);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(u64, 131070), st.recvMaxOffset);
    try pair.pumpSC(a);
    try std.testing.expectEqual(@as(u64, 131070), pair.client.maxStreamData.get(0).?);
}

test "receive stream window grows and is advertised before its initial limit" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    pair.client.cc.cwnd = 1 << 20;

    const data = (@as([70_000]u8, @splat(0xEF)));
    var offset: usize = 0;
    var now: u64 = 100;
    while (offset < data.len) {
        const end = @min(offset + 1200, data.len);
        try pair.client.sendStreamChecked(0, offset, data[offset..end], end == data.len, now);
        try pair.pumpCS(a);
        try pair.pumpSC(a);
        offset = end;
        now += 1;
    }

    const stream = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(stream.recvOffset == data.len);
    try std.testing.expect(stream.recvMaxOffset >= data.len);
    try std.testing.expect(pair.client.maxStreamData.get(0).? >= data.len);
}

test "max streams bumps advertise higher limits" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.sendMaxStreams(true, 256, 100);
    try std.testing.expectEqual(@as(u64, 256), pair.client.maxStreamsBidiLocal);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(u64, 256), pair.server.maxStreamsBidiRemote);
}

// Reliability (RFC 9002): ACK generation, duplicate suppression, RTT
// sampling, PTO probes, loss declaration with congestion response and
// retransmission, and congestion-window send gating.

const EmptyBuild = struct {
    pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
        _ = gpa;
        _ = payload;
    }
};

test "acks arm on second packet and roundtrip through peer" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const d = (@as([10]u8, @splat(0x11)));

    try pair.client.sendStreamChecked(0, 0, &d, false, 100);
    try pair.pumpCS(a);
    try std.testing.expect(!pair.server.spaces[2].ackQueued);
    try pair.client.sendStreamChecked(0, 10, &d, false, 101);
    try pair.pumpCS(a);
    try std.testing.expect(pair.server.spaces[2].ackQueued);

    try std.testing.expect(pair.client.spaces[2].sent.items.len > 0);
    try std.testing.expect(pair.client.bytesInFlight > 0);
    try pair.server.sendFrames(.application, EmptyBuild.build, 102);
    try std.testing.expect(!pair.server.spaces[2].ackQueued);
    try pair.pumpSC(a);
    try std.testing.expectEqual(@as(usize, 0), pair.client.spaces[2].sent.items.len);
    try std.testing.expectEqual(@as(usize, 0), pair.client.bytesInFlight);
}

test "duplicate packets drop without redelivery" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const d = (@as([10]u8, @splat(0x22)));

    try pair.client.sendStreamChecked(0, 0, &d, false, 100);
    const out = try pair.client.takeOutput(a);
    defer a.free(out);
    try pair.server.receiveDatagram(out, 110);
    const recv1 = pair.server.dataReceived;
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
    // Same datagram again: dropped, no state change, no error.
    try pair.server.receiveDatagram(out, 120);
    try std.testing.expectEqual(recv1, pair.server.dataReceived);
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
}

test "rtt samples use real send and ack timestamps" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const d = (@as([10]u8, @splat(0x33)));

    try pair.client.sendStreamChecked(0, 0, &d, false, 100);
    {
        const out = try pair.client.takeOutput(a);
        defer a.free(out);
        try pair.server.receiveDatagram(out, 110);
    }
    try pair.client.sendStreamChecked(0, 10, &d, false, 101);
    {
        const out = try pair.client.takeOutput(a);
        defer a.free(out);
        try pair.server.receiveDatagram(out, 111);
    }
    try pair.server.sendFrames(.application, EmptyBuild.build, 112);
    {
        const out = try pair.server.takeOutput(a);
        defer a.free(out);
        try pair.client.receiveDatagram(out, 150);
    }
    // Largest newly acked is pn 1 sent at 101, acked at 150.
    try std.testing.expectEqual(@as(u64, 49), pair.client.recovery.rtt.minRttMs);
    try std.testing.expectEqual(@as(u64, 49), pair.client.recovery.rtt.smoothedRttMs);
}

test "pto probe retransmits unacked data for real delivery" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const d = (@as([10]u8, @splat(0x44)));

    try pair.client.sendStreamChecked(0, 0, &d, false, 100);
    const orig = try pair.client.takeOutput(a);
    defer a.free(orig);
    // PTO (499ms on fresh RTT state) fires: probe goes out, count bumps.
    try pair.client.pollTimeouts(700);
    try std.testing.expectEqual(@as(u32, 1), pair.client.recovery.ptoCount);
    {
        const probe = try pair.client.takeOutput(a);
        defer a.free(probe);
        try std.testing.expect(probe.len > 0);
        try pair.server.receiveDatagram(probe, 701);
    }
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
    // The original arriving late is a duplicate: no redelivery.
    const before = pair.server.dataReceived;
    try pair.server.receiveDatagram(orig, 702);
    try std.testing.expectEqual(before, pair.server.dataReceived);
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
}

test "loss declaration halves cwnd and retransmits for real delivery" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    var pkts: [5][]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const one = (@as([1]u8, @splat(@intCast(0x50 + i))));
        try pair.client.sendStreamChecked(0, i, &one, false, 100 + i);
        pkts[i] = try pair.client.takeOutput(a);
    }
    defer {
        for (pkts) |p| a.free(p);
    }
    // Deliver all but pn 3 (offsets are 1:1 with pns here).
    try pair.server.receiveDatagram(pkts[0], 110);
    try pair.server.receiveDatagram(pkts[1], 111);
    try pair.server.receiveDatagram(pkts[2], 112);
    try pair.server.receiveDatagram(pkts[4], 113);
    try pair.server.sendFrames(.application, EmptyBuild.build, 114);
    {
        const ack = try pair.server.takeOutput(a);
        defer a.free(ack);
        try pair.client.receiveDatagram(ack, 120);
    }
    // pn 3 unacked with largest 4: below packet threshold, time pending.
    try std.testing.expect(pair.client.spaces[2].lossTimeMs != null);
    const cwndBefore = pair.client.cc.cwnd;
    try pair.client.pollTimeouts(500);
    const cwndAfter = pair.client.cc.cwnd;
    try std.testing.expect(cwndAfter < cwndBefore);
    // The retransmit completes the stream byte range on the server.
    {
        // The timer pump may also emit a standalone ACK for the PING that
        // rode the earlier server packet; each packet becomes its own
        // datagram because a short header must end the datagram.
        var lens_buf: [8]u32 = undefined;
        const lens = pair.client.outPacketLengths();
        try std.testing.expect(lens.len <= lens_buf.len);
        @memcpy(lens_buf[0..lens.len], lens);
        const out = try pair.client.takeOutput(a);
        defer a.free(out);
        try std.testing.expect(out.len > 0);
        var off: usize = 0;
        for (lens_buf[0..lens.len]) |len| {
            try pair.server.receiveDatagram(out[off..][0..len], 501);
            off += len;
        }
    }
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 5), st.recvOffset);
}

test "send blocks when congestion window exhausted" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const chunk = (@as([500]u8, @splat(0xAA)));
    var blockedAt: usize = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        pair.client.sendStreamChecked(0, i * 500, &chunk, false, 100) catch |e| {
            try std.testing.expectEqual(Error.SendBlocked, e);
            blockedAt = i;
            break;
        };
    }
    try std.testing.expect(blockedAt > 0);
    try std.testing.expect(blockedAt < 500);
}

test "out of order receipt acks immediately" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const d = (@as([10]u8, @splat(0x55)));

    var outs: [6][]u8 = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try pair.client.sendStreamChecked(0, i * 10, &d, false, 100 + i);
        outs[i] = try pair.client.takeOutput(a);
    }
    defer {
        for (outs) |p| a.free(p);
    }
    // pn 5 first: single packet, in order so far, no immediate ack.
    try pair.server.receiveDatagram(outs[5], 110);
    try std.testing.expect(!pair.server.spaces[2].ackQueued);
    // pn 3 arrives below the max seen: gap, ack immediately.
    try pair.server.receiveDatagram(outs[3], 111);
    try std.testing.expect(pair.server.spaces[2].ackQueued);
}

test "key update rotates the receiving phase and accepts reordered old packets" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    pair.client.state = .established;
    pair.server.state = .established;

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 100);
    const old = try pair.client.takeOutput(a);
    defer a.free(old);

    try pair.client.initiateKeyUpdate();
    try std.testing.expect(pair.client.keyPhaseTx);
    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 101);
    const first = try pair.client.takeOutput(a);
    defer a.free(first);

    try pair.server.receiveDatagram(first, 102);
    try std.testing.expect(pair.server.keyPhaseRx);
    try std.testing.expect(pair.server.prevAppRxKeys != null);

    // A packet sealed before the update must still open with the
    // retained previous keys after the receiver has rotated.
    try pair.server.receiveDatagram(old, 103);
}

test "server emits version negotiation for unsupported versions" {
    const a = std.testing.allocator;
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();

    var raw: [128]u8 = @splat(0);
    const dcid = [_]u8{ 1, 2, 3, 4 };
    const scid = [_]u8{ 9, 8, 7 };
    const n = try packetMod.writeLongHeader(raw[0..], .{
        .type = .initial,
        .version = 0xDEADBEEF,
        .dcid = &dcid,
        .scid = &scid,
        .token = "",
        .pnLen = 1,
        .protectedPayloadLen = 20,
    });
    try server.receiveDatagram(raw[0..n], 10);
    const out = try server.takeOutput(a);
    defer a.free(out);
    const vn = try packetMod.parseVersionNegotiation(out);
    try std.testing.expectEqualSlices(u8, &scid, vn.dcid);
    try std.testing.expectEqualSlices(u8, &dcid, vn.scid);
    try std.testing.expectEqual(@as(u32, 1), vn.versionAt(0));
    try std.testing.expectEqual(@as(u32, 0x6B3343CF), vn.versionAt(1));
}

test "client validates version negotiation and rejects downgrade spoofing" {
    const a = std.testing.allocator;
    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    try client.installInitialKeys();

    var buf: [64]u8 = undefined;
    const n = try packetMod.writeVersionNegotiation(buf[0..], client.scid[0..client.scidLen], client.dcid[0..client.dcidLen], &.{0x6B3343CF});
    try std.testing.expectError(Error.VersionNegotiation, client.receiveDatagram(buf[0..n], 1));
    try std.testing.expectEqual(@as(?u32, 0x6B3343CF), client.versionNegotiated);

    client.versionNegotiated = null;
    var spoof: [64]u8 = undefined;
    const sn = try packetMod.writeVersionNegotiation(spoof[0..], client.scid[0..client.scidLen], client.dcid[0..client.dcidLen], &.{0x00000001});
    try client.receiveDatagram(spoof[0..sn], 2);
    try std.testing.expectEqual(@as(?u32, null), client.versionNegotiated);
}

test "retry token round trip validates address and reinstalls initial keys" {
    const a = std.testing.allocator;
    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{ .retry = true });
    defer server.deinit();
    try client.installInitialKeys();
    try server.acceptInitial(client.dcid[0..client.dcidLen]);
    var odcid: [20]u8 = undefined;
    const odcidLen = client.dcidLen;
    @memcpy(odcid[0..odcidLen], client.dcid[0..odcidLen]);

    try client.queueControlFrame(.ping);
    try client.flushControl(.initial, 100);
    const first = try client.takeOutput(a);
    defer a.free(first);
    try server.receiveDatagram(first, 101);

    const retryWire = try server.takeOutput(a);
    defer a.free(retryWire);
    try std.testing.expect(retryWire.len > 0);
    try client.receiveDatagram(retryWire, 102);
    try std.testing.expect(client.retryPending);
    try std.testing.expectEqualSlices(u8, odcid[0..odcidLen], client.origDcid[0..client.origDcidLen]);
    try std.testing.expect(client.retryToken.items.len > 0);

    try client.queueControlFrame(.ping);
    try client.flushControl(.initial, 103);
    const second = try client.takeOutput(a);
    defer a.free(second);
    try server.receiveDatagram(second, 104);
    try std.testing.expect(server.addressValidated);
    try std.testing.expectEqualSlices(u8, odcid[0..odcidLen], server.origDcid[0..server.origDcidLen]);
    try std.testing.expect(server.retryPending);
}

test "client pads initial datagrams to the 1200 byte minimum" {
    // RFC 9000 Section 14.1: a client MUST expand the payload of every
    // datagram carrying an Initial packet to at least 1200 bytes.
    const a = std.testing.allocator;
    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    try client.installInitialKeys();

    // A small ack-eliciting flight (PING) still has to reach 1200 bytes.
    try client.queueControlFrame(.ping);
    try client.flushControl(.initial, 100);
    const dgram = try client.takeOutput(a);
    defer a.free(dgram);
    try std.testing.expect(dgram.len >= MIN_INITIAL_DATAGRAM);
    try std.testing.expect(dgram.len <= MAX_DATAGRAM);
}

test "server pads ack-eliciting initial datagrams" {
    // RFC 9000 Section 14.1: a server MUST expand datagrams carrying an
    // ack-eliciting Initial packet to the minimum size.
    const a = std.testing.allocator;
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();
    try server.installInitialKeys();
    // The anti-amplification gate needs a budget: pretend the client
    // already sent 4 KiB, which the server may answer three times over.
    server.bytesReceived = 4096;

    // PING is ack-eliciting: the datagram must reach the minimum size.
    try server.queueControlFrame(.ping);
    try server.flushControl(.initial, 100);
    const eliciting = try server.takeOutput(a);
    defer a.free(eliciting);
    try std.testing.expect(eliciting.len >= MIN_INITIAL_DATAGRAM);
}

test "server discards initial packets below the 1200 byte minimum" {
    // RFC 9000 Section 14.1: a server MUST discard an Initial packet
    // carried in a datagram below the minimum size. The datagram is
    // ignored: no error, no state change, no output.
    const a = std.testing.allocator;
    var client = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();
    try client.installInitialKeys();
    try server.acceptInitial(client.dcid[0..client.dcidLen]);
    server.bytesReceived = 4096;

    try client.queueControlFrame(.ping);
    try client.flushControl(.initial, 100);
    const padded = try client.takeOutput(a);
    defer a.free(padded);
    try std.testing.expect(padded.len >= MIN_INITIAL_DATAGRAM);

    const small = padded[0 .. MIN_INITIAL_DATAGRAM - 1];
    try server.receiveDatagram(small, 101);
    try std.testing.expectEqual(@as(i64, -1), server.spaces[0].highestRxPn);
    const out = try server.takeOutput(a);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "server accepts the initial flight of an independent quic client" {
    // Captured from curl 8.15.0, an independent QUIC client, talking to
    // this server. This vector checks header protection, packet protection,
    // packet-number encoding, and CRYPTO stream reassembly independently.
    const raw = @embedFile("testdata/interop_client_initial.bin");

    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer conn.deinit();

    var off: usize = 0;
    var packets: usize = 0;
    var booted = false;
    while (off + 4 <= raw.len) {
        const len = std.mem.readInt(u32, raw[off..][0..4], .little);
        off += 4;
        const dgram = raw[off..][0..len];
        off += len;
        packets += 1;

        if (!booted) {
            const parsed = try packetMod.parseLongHeader(dgram);
            try std.testing.expectEqual(packetMod.LongType.initial, parsed.header.type);
            try conn.acceptInitial(parsed.header.dcid);
            booted = true;
        }

        try conn.receiveDatagram(dgram, 1000 + @as(u64, @intCast(packets)));
    }

    try std.testing.expectEqual(@as(usize, 6), packets);
    try std.testing.expect(conn.cryptoRecvOff[0] > 0);
    try std.testing.expectEqual(@as(i64, 5), conn.spaces[0].highestRxPn);
}

test "one rtt data that arrives before the handshake is replayed afterwards" {
    // RFC 9001 Section 5.7: 1-RTT packets can arrive before the
    // handshake completes. They must be buffered, not dropped: a peer
    // that sends its request in the same flight as its Finished would
    // otherwise lose the request.
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = try Connection.init(a, io, .client, .{});
    defer client.deinit();
    var server = try Connection.init(a, io, .server, .{});
    defer server.deinit();
    server.addressValidated = true;

    const secret = @as([32]u8, @splat(0xA5));
    try client.installKeys(.application, secret, secret);
    // The server has no application keys yet: the packet cannot be
    // decrypted and must be buffered.
    try std.testing.expect(server.spaces[2].keysRx == null);

    try client.sendStreamChecked(0, 0, "early", false, 100);
    const early = try client.takeOutput(a);
    defer a.free(early);

    try server.receiveDatagram(early, 101);
    try std.testing.expectEqual(@as(usize, 1), server.pendingApp.items.len);
    try std.testing.expectEqual(@as(u64, 0), server.dataReceived);

    // Once the application keys exist the buffered packet is replayed.
    try server.installKeys(.application, secret, secret);
    try server.replayPendingApp(102);
    try std.testing.expectEqual(@as(usize, 0), server.pendingApp.items.len);
    try std.testing.expectEqual(@as(u64, 5), server.dataReceived);
}

test "repeated new connection id sequences are ignored" {
    // RFC 9000 Section 19.15 lets an endpoint reject a repeated
    // sequence number, but peers retransmit the frame in a fresh
    // packet, so the repeat is ignored instead of killing the
    // connection.
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    const Cid = struct {
        seq: u64,
        cid: [4]u8,
        token: [16]u8,
    };
    const one = Cid{ .seq = 1, .cid = .{ 1, 2, 3, 4 }, .token = @splat(0x11) };
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try frames.encode(&payload, a, .{ .newConnectionId = .{
        .sequence = one.seq,
        .retirePriorTo = 0,
        .cid = one.cid[0..],
        .statelessResetToken = one.token,
    } });

    // Feed the frame twice: the second copy must not be an error.
    const sp = &pair.server.spaces[2];
    try pair.server.dispatchFrames(sp, payload.items, 100, false);
    try std.testing.expectEqual(@as(usize, 1), pair.server.peerCids.items.len);
    try pair.server.dispatchFrames(sp, payload.items, 101, false);
    try std.testing.expectEqual(@as(usize, 1), pair.server.peerCids.items.len);
}

test "a ping only packet is ack eliciting" {
    // RFC 9000 Section 13.2: only ACK, PADDING and CONNECTION_CLOSE are
    // not ack-eliciting. A PING must be tracked for loss recovery and
    // must arm the PTO.
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 100);
    const out = try pair.client.takeOutput(a);
    defer a.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expectEqual(@as(usize, 1), pair.client.spaces[2].sent.items.len);
    try std.testing.expect(pair.client.spaces[2].inFlightAckEliciting == 1);
}

test "a received ping arms an ack for the peer" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const sp = &pair.server.spaces[2];

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 100);
    try pair.pumpCS(a);
    try std.testing.expectEqual(@as(u64, 1), sp.ackElicitingCount);
    try std.testing.expect(sp.ackDeadlineMs != null);
    try std.testing.expect(!sp.ackQueued);

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 101);
    try pair.pumpCS(a);
    try std.testing.expect(sp.ackQueued);
}

test "max ack delay timer emits a standalone ack packet" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 100);
    try pair.pumpCS(a);
    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 101);
    try pair.pumpCS(a);
    try std.testing.expect(pair.server.spaces[2].ackQueued);

    {
        // No application traffic is pending: the ACK must come from the
        // timer pump, not ride an unrelated packet.
        const pre = try pair.server.takeOutput(a);
        defer a.free(pre);
        try std.testing.expectEqual(@as(usize, 0), pre.len);
    }
    try pair.server.pollTimeouts(5000);
    try std.testing.expect(!pair.server.spaces[2].ackQueued);

    const ack = try pair.server.takeOutput(a);
    defer a.free(ack);
    try std.testing.expect(ack.len > 0);
    try pair.client.receiveDatagram(ack, 5001);
    try std.testing.expectEqual(@as(usize, 0), pair.client.spaces[2].sent.items.len);
}

test "1-rtt packets are never chainable in a datagram" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.sendStreamChecked(0, 0, "a", false, 100);
    try pair.client.sendStreamChecked(0, 1, "b", false, 101);
    const flags = pair.client.outPacketChainableFlags();
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expect(!flags[0]);
    try std.testing.expect(!flags[1]);
}

test "ack delay is encoded in units of the advertised exponent" {
    // Our transport parameters advertise the default ack_delay_exponent
    // of 3, so one millisecond is 125 units (RFC 9000 Section 19.3).
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.sendStreamChecked(0, 0, "x", false, 100);
    try pair.pumpCS(a);
    pair.server.spaces[2].ackQueued = true;
    try pair.server.sendFrames(.application, struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            _ = gpa;
            _ = payload;
        }
    }.build, 910);

    const out = try pair.server.takeOutput(a);
    defer a.free(out);

    var work: [MAX_DATAGRAM]u8 = undefined;
    var pt: [MAX_DATAGRAM]u8 = undefined;
    var phase: bool = false;
    const opened = try openShortProtected(
        out,
        pair.server.dcidLen,
        pair.server.spaces[2].keysTx.?,
        null,
        &work,
        &pt,
        &phase,
    );
    var pos: usize = 0;
    var ack_frame: ?frames.Ack = null;
    while (pos < opened.ctLen) {
        const f = try frames.decode(pt[0..opened.ctLen], &pos);
        if (f == .ack) ack_frame = f.ack;
    }
    const f = ack_frame orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), f.largestAcknowledged);
    try std.testing.expectEqual(@as(u64, 1250), f.ackDelay);
}

// Handshake lifecycle (RFC 9001 Section 4.9): discarding a packet number
// space must drop its keys, recovery state and buffered CRYPTO, and a
// confirming client/server must silently ignore late packets from it.

test "discarding initial keys releases their in-flight bytes" {
    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();
    try conn.installInitialKeys();
    try conn.queueControlFrame(.ping);
    try conn.flushControl(.initial, 100);

    try std.testing.expect(conn.spaces[0].inFlightBytes >= MIN_INITIAL_DATAGRAM);
    try std.testing.expect(conn.bytesInFlight >= MIN_INITIAL_DATAGRAM);

    conn.discardInitialKeys();
    try std.testing.expect(conn.spaces[0].discarded);
    try std.testing.expectEqual(@as(usize, 0), conn.spaces[0].inFlightBytes);
    try std.testing.expectEqual(@as(usize, 0), conn.bytesInFlight);
    try std.testing.expectEqual(@as(usize, 0), conn.spaces[0].sent.items.len);
    try std.testing.expect(conn.spaces[0].keysTx == null and conn.spaces[0].keysRx == null);

    // Repeated discards are harmless and cannot underflow the counter.
    conn.discardInitialKeys();
    try std.testing.expectEqual(@as(usize, 0), conn.bytesInFlight);
}

test "handshake confirmation discards keys and ignores late packets" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var sender = try Connection.init(a, io, .client, .{});
    defer sender.deinit();
    var receiver = try Connection.init(a, io, .client, .{});
    defer receiver.deinit();
    const secret = @as([32]u8, @splat(0x6B));
    try sender.installKeys(.handshake, secret, secret);
    try receiver.installKeys(.handshake, secret, secret);

    try sender.queueControlFrame(.ping);
    try sender.flushControl(.handshake, 100);
    const first = try sender.takeOutput(a);
    defer a.free(first);
    try sender.queueControlFrame(.ping);
    try sender.flushControl(.handshake, 101);
    const second = try sender.takeOutput(a);
    defer a.free(second);
    try std.testing.expect(sender.bytesInFlight > 0);

    try receiver.receiveDatagram(first, 102);
    try std.testing.expectEqual(@as(i64, 0), receiver.spaces[1].highestRxPn);

    receiver.confirmHandshake();
    try std.testing.expect(receiver.handshakeConfirmed);
    try std.testing.expect(receiver.spaces[1].discarded);
    try std.testing.expect(receiver.spaces[1].keysRx == null and receiver.spaces[1].keysTx == null);
    try std.testing.expectEqual(@as(usize, 0), receiver.spaces[1].inFlightBytes);
    try std.testing.expectEqual(State.established, receiver.state);

    // A reordered packet from the discarded space is dropped without an
    // error and must not resurrect ACK timers or receive state.
    try receiver.receiveDatagram(second, 103);
    try std.testing.expectEqual(@as(i64, 0), receiver.spaces[1].highestRxPn);
    try receiver.pollTimeouts(5000);
    const out = try receiver.takeOutput(a);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "h3-style client confirms handshake on a 1-rtt acknowledgment" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.queueControlFrame(.ping);
    try pair.client.flushControl(.application, 100);
    try std.testing.expectEqual(@as(?u64, 0), pair.client.firstAppPnSent);
    try pair.pumpCS(a);

    pair.server.spaces[2].ackQueued = true;
    try pair.server.sendFrames(.application, EmptyBuild.build, 101);
    try pair.pumpSC(a);

    try std.testing.expect(pair.client.handshakeConfirmed);
    try std.testing.expect(pair.client.spaces[1].discarded);
    try std.testing.expectEqual(State.established, pair.client.state);
}

test "handshake_done confirms clients and is a server protocol violation" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try frames.encode(&payload, a, .handshakeDone);

    try std.testing.expectError(
        Error.ProtocolViolation,
        pair.server.dispatchFrames(&pair.server.spaces[2], payload.items, 100, false),
    );
    try std.testing.expect(!pair.server.handshakeConfirmed);

    const DoneBuild = struct {
        pub fn build(gpa: Allocator, out: *std.ArrayList(u8)) Error!void {
            try fe(gpa, out, .handshakeDone);
        }
    };
    try pair.server.sendFrames(.application, DoneBuild.build, 101);
    try pair.pumpSC(a);
    try std.testing.expect(pair.client.handshakeConfirmed);
    try std.testing.expect(pair.client.spaces[1].discarded);
    try std.testing.expectEqual(State.established, pair.client.state);
}

test "frame spaces match RFC 9000 table 3" {
    const F = frames.Frame;
    const app_close = F{ .connectionClose = .{
        .errorCode = 0,
        .triggeringFrameType = 0,
        .reason = "",
        .application = true,
    } };
    const transport_close = F{ .connectionClose = .{
        .errorCode = 0,
        .triggeringFrameType = 0,
        .reason = "",
        .application = false,
    } };
    const ping: F = .ping;
    const crypto_frame: F = .{ .crypto = .{ .offset = 0, .data = "" } };
    const stream: F = .{ .stream = .{ .id = 0, .offset = 0, .data = "", .fin = false } };
    const new_cid: F = .{ .newConnectionId = .{
        .sequence = 0,
        .retirePriorTo = 0,
        .cid = "cid",
        .statelessResetToken = @splat(0),
    } };
    const path_response: F = .{ .pathResponse = .{ .data = @splat(0) } };
    const done: F = .handshakeDone;

    // PING is valid everywhere; STREAM is application-only.
    for ([_]SpaceKind{ .initial, .handshake, .application }) |k| {
        try std.testing.expect(Connection.frameAllowedInSpace(ping, k, k == .application));
    }
    try std.testing.expect(!Connection.frameAllowedInSpace(stream, .initial, false));
    try std.testing.expect(!Connection.frameAllowedInSpace(stream, .handshake, false));
    try std.testing.expect(Connection.frameAllowedInSpace(stream, .application, true));

    // CRYPTO is Initial/Handshake/1-RTT, never 0-RTT.
    try std.testing.expect(Connection.frameAllowedInSpace(crypto_frame, .initial, false));
    try std.testing.expect(Connection.frameAllowedInSpace(crypto_frame, .handshake, false));
    try std.testing.expect(Connection.frameAllowedInSpace(crypto_frame, .application, false));
    try std.testing.expect(!Connection.frameAllowedInSpace(crypto_frame, .application, true));

    // NEW_CONNECTION_ID may appear in 0-RTT; PATH_RESPONSE may not.
    try std.testing.expect(Connection.frameAllowedInSpace(new_cid, .application, true));
    try std.testing.expect(!Connection.frameAllowedInSpace(new_cid, .handshake, false));
    try std.testing.expect(!Connection.frameAllowedInSpace(path_response, .application, true));
    try std.testing.expect(Connection.frameAllowedInSpace(path_response, .application, false));

    // HANDSHAKE_DONE is 1-RTT only.
    try std.testing.expect(!Connection.frameAllowedInSpace(done, .handshake, false));
    try std.testing.expect(Connection.frameAllowedInSpace(done, .application, false));

    // CONNECTION_CLOSE 0x1c is I/H/1-RTT; the app variant is 0/1-RTT.
    try std.testing.expect(Connection.frameAllowedInSpace(transport_close, .initial, false));
    try std.testing.expect(Connection.frameAllowedInSpace(transport_close, .handshake, false));
    try std.testing.expect(Connection.frameAllowedInSpace(transport_close, .application, false));
    try std.testing.expect(!Connection.frameAllowedInSpace(transport_close, .application, true));
    try std.testing.expect(!Connection.frameAllowedInSpace(app_close, .initial, false));
    try std.testing.expect(!Connection.frameAllowedInSpace(app_close, .handshake, false));
    try std.testing.expect(Connection.frameAllowedInSpace(app_close, .application, true));
}

test "a 0-rtt packet may not carry an ack frame" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try frames.encodeAckFromBlocks(&payload, a, 0, 0, &.{.{ .highest = 0, .len = 1 }}, null);
    try std.testing.expectError(
        Error.ProtocolViolation,
        pair.client.dispatchFrames(&pair.client.spaces[2], payload.items, 100, true),
    );
}

test "confirmed handshake drops queued handshake packets but keeps 1-rtt output" {
    // RFC 9001 Section 4.9.2: once the handshake is confirmed, no packet
    // protected with Handshake keys may be sent. An ACK-only packet can
    // already be serialized when HANDSHAKE_DONE confirms the handshake;
    // it must be removed from the output queue rather than flushed after
    // the keys are gone.
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var conn = try Connection.init(a, io, .server, .{});
    defer conn.deinit();
    // The peer's address was validated before this point in a real
    // handshake; without that, server-side amplification limits rightly
    // refuse to emit the Handshake ACK this test is about.
    conn.addressValidated = true;

    const hs_secret = @as([32]u8, @splat(0x31));
    const app_secret = @as([32]u8, @splat(0x32));
    try conn.installKeys(.handshake, hs_secret, hs_secret);
    try conn.installKeys(.application, app_secret, app_secret);

    // A pending Handshake ACK is protected and queued before confirmation.
    try conn.spaces[1].acktr.add(0);
    conn.spaces[1].ackQueued = true;
    try conn.sendAckOnly(.handshake, 100);
    try std.testing.expectEqual(@as(usize, 1), conn.outPacketLengths().len);
    try std.testing.expectEqual(QueuedKind.handshake, conn.outQueuedKinds()[0]);

    // A 1-RTT packet queued at the same time must survive.
    try conn.queueControlFrame(.ping);
    try conn.flushControl(.application, 101);
    conn.confirmHandshake();
    try std.testing.expect(conn.spaces[1].discarded);
    try std.testing.expectEqualSlices(QueuedKind, &.{.application}, conn.outQueuedKinds());

    const out = try conn.takeOutput(a);
    defer a.free(out);
    try std.testing.expect(out.len > 0);

    // Timer-driven ACK work for the discarded space must stay silent.
    // Stay below the 1-RTT PTO so the unacknowledged PING in the
    // surviving application space does not legitimately probe here.
    try conn.pollTimeouts(102);
    const late = try conn.takeOutput(a);
    defer a.free(late);
    try std.testing.expectEqual(@as(usize, 0), late.len);
}

test "discarding initial keys drops a queued initial packet" {
    // RFC 9001 Section 4.9.1: after the Initial keys are discarded an
    // Initial packet cannot be protected or sent, even if it was already
    // serialized.
    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();
    try conn.installInitialKeys();

    try conn.queueControlFrame(.ping);
    try conn.flushControl(.initial, 100);
    try std.testing.expectEqual(@as(usize, 1), conn.outPacketLengths().len);
    try std.testing.expectEqual(QueuedKind.initial, conn.outQueuedKinds()[0]);

    conn.discardInitialKeys();
    const out = try conn.takeOutput(a);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
    try std.testing.expectEqual(@as(usize, 0), conn.outPacketLengths().len);
}

test "rejecting early data drops a queued 0-rtt packet" {
    // RFC 9001 Section 4.9.3: discarded 0-RTT keys cannot protect a
    // queued 0-RTT packet, so the packet must not be sent.
    const a = std.testing.allocator;
    var conn = try Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer conn.deinit();
    const secret = @as([32]u8, @splat(0x44));
    conn.installZeroRttKeys(secret, true);

    try conn.queueControlFrame(.ping);
    try conn.flushControl(.application, 100);
    try std.testing.expectEqual(@as(usize, 1), conn.outPacketLengths().len);
    try std.testing.expectEqual(QueuedKind.zero_rtt, conn.outQueuedKinds()[0]);

    conn.discardZeroRtt();
    const out = try conn.takeOutput(a);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "ack delay is measured from the largest acknowledged packet" {
    // RFC 9000 Section 19.3: ACK Delay counts from receipt of the largest
    // acknowledged packet. A later, reordered packet with a lower number
    // must not move that baseline and understate the delay.
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try pair.client.sendStreamChecked(0, 0, "a", false, 100);
    const p0 = try pair.client.takeOutput(a);
    defer a.free(p0);
    try pair.client.sendStreamChecked(0, 1, "b", false, 110);
    const p1 = try pair.client.takeOutput(a);
    defer a.free(p1);

    // Packet 1 arrives first at t=200; reordered packet 0 follows at 500.
    try pair.server.receiveDatagram(p1, 200);
    try pair.server.receiveDatagram(p0, 500);
    try std.testing.expect(pair.server.spaces[2].ackQueued);

    try pair.server.sendFrames(.application, EmptyBuild.build, 1000);
    const out = try pair.server.takeOutput(a);
    defer a.free(out);

    var work: [MAX_DATAGRAM]u8 = undefined;
    var pt: [MAX_DATAGRAM]u8 = undefined;
    var phase: bool = false;
    const opened = try openShortProtected(
        out,
        pair.server.dcidLen,
        pair.server.spaces[2].keysTx.?,
        null,
        &work,
        &pt,
        &phase,
    );
    var pos: usize = 0;
    var ack_frame: ?frames.Ack = null;
    while (pos < opened.ctLen) {
        const f = try frames.decode(pt[0..opened.ctLen], &pos);
        if (f == .ack) ack_frame = f.ack;
    }
    const f = ack_frame orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), f.largestAcknowledged);
    try std.testing.expectEqual(@as(u64, 100_000), f.ackDelay);
}

test "regression: quic variable-length integer parsing and boundaries" {
    const seeds = [_][]const u8{
        &[_]u8{0x25},
        &[_]u8{ 0x7b, 0xbd },
        &[_]u8{ 0x9d, 0x7f, 0x3e, 0x7d },
        &[_]u8{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c },
    };

    for (seeds) |s| {
        for (0..s.len + 1) |cut| {
            var off: usize = 0;
            _ = varint.decode(s[0..cut], &off) catch {};
        }
    }

    var prng = std.Random.DefaultPrng.init(0x9999);
    const rng = prng.random();
    var buf: [16]u8 = undefined;

    for (0..200) |_| {
        const len = rng.uintLessThan(usize, buf.len);
        rng.bytes(buf[0..len]);
        var off: usize = 0;
        _ = varint.decode(buf[0..len], &off) catch {};
    }
}

test "regression: quic transport frame decoding and truncation sweeps" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);

    try frames.encode(&list, std.testing.allocator, .ping);
    try list.appendNTimes(std.testing.allocator, 0x00, 4);
    try frames.encodeAckFromBlocks(&list, std.testing.allocator, 10, 2, &[_]frames.AckBlock{
        .{ .highest = 10, .len = 3 },
    }, null);
    try frames.encode(&list, std.testing.allocator, .{ .resetStream = .{
        .streamId = 4,
        .errorCode = 0x01,
        .finalSize = 1024,
    } });
    try frames.encode(&list, std.testing.allocator, .{ .stopSending = .{
        .streamId = 4,
        .errorCode = 0x02,
    } });
    try frames.encode(&list, std.testing.allocator, .{ .crypto = .{
        .offset = 0,
        .data = "client_hello_bytes",
    } });
    try frames.encode(&list, std.testing.allocator, .{ .stream = .{
        .id = 0,
        .offset = 0,
        .data = "hello quic",
        .fin = true,
    } });
    try frames.encode(&list, std.testing.allocator, .{ .maxData = .{ .maximum = 1048576 } });
    try frames.encode(&list, std.testing.allocator, .{ .maxStreamData = .{ .streamId = 0, .maximum = 65536 } });
    try frames.encode(&list, std.testing.allocator, .handshakeDone);
    try frames.encode(&list, std.testing.allocator, .{ .connectionClose = .{
        .errorCode = 0,
        .triggeringFrameType = 0,
        .reason = "clean",
        .application = false,
    } });

    const encoded = list.items;

    const helper = struct {
        fn decodeFrames(data: []const u8) void {
            var pos: usize = 0;
            while (pos < data.len) {
                const start = pos;
                _ = frames.decode(data, &pos) catch break;
                if (pos <= start) break;
            }
        }
    };

    for (0..encoded.len + 1) |cut| {
        helper.decodeFrames(encoded[0..cut]);
    }

    var prng = std.Random.DefaultPrng.init(0xaaaa);
    const rng = prng.random();
    var mut: [256]u8 = undefined;

    for (0..150) |_| {
        const copyLen = @min(encoded.len, mut.len);
        @memcpy(mut[0..copyLen], encoded[0..copyLen]);
        const flips = 1 + rng.uintLessThan(usize, 5);
        for (0..flips) |_| {
            const idx = rng.uintLessThan(usize, copyLen);
            mut[idx] = rng.int(u8);
        }
        helper.decodeFrames(mut[0..copyLen]);
    }
}

test "regression: quic transport parameters decoding and validation" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);

    const initialParams = paramsMod.Params{
        .maxIdleTimeoutMs = 30_000,
        .maxUdpPayloadSize = 1472,
        .initialMaxData = 1048576,
        .initialMaxStreamDataBidiLocal = 65536,
        .initialMaxStreamDataBidiRemote = 65536,
        .initialMaxStreamDataUni = 65536,
        .initialMaxStreamsBidi = 100,
        .initialMaxStreamsUni = 100,
        .ackDelayExponent = 3,
        .maxAckDelayMs = 25,
        .activeConnectionIdLimit = 4,
    };
    try paramsMod.encode(&list, std.testing.allocator, initialParams);
    const encoded = list.items;

    for (0..encoded.len + 1) |cut| {
        _ = paramsMod.decode(encoded[0..cut]) catch {};
    }

    var prng = std.Random.DefaultPrng.init(0xbbbb);
    const rng = prng.random();
    var buf: [128]u8 = undefined;

    for (0..150) |_| {
        const copyLen = @min(encoded.len, buf.len);
        @memcpy(buf[0..copyLen], encoded[0..copyLen]);
        const flips = 1 + rng.uintLessThan(usize, 4);
        for (0..flips) |_| {
            const idx = rng.uintLessThan(usize, copyLen);
            buf[idx] = rng.int(u8);
        }
        _ = paramsMod.decode(buf[0..copyLen]) catch {};
    }
}

test "regression: quic packet header parsing" {
    var initialHdrBuf: [64]u8 = undefined;
    const initialLen = packetMod.writeLongHeader(initialHdrBuf[0..], .{
        .type = .initial,
        .version = 0x00000001,
        .dcid = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .scid = &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 },
        .token = "token123",
        .pnLen = 2,
        .protectedPayloadLen = 32,
    }) catch unreachable;

    var shortHdrBuf: [32]u8 = undefined;
    const shortLen = packetMod.writeShortHeader(shortHdrBuf[0..], .{
        .keyPhase = false,
        .dcid = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .pnLen = 2,
    }) catch unreachable;

    const helper = struct {
        fn parse(data: []const u8) void {
            if (data.len == 0) return;
            const first = data[0];
            if ((first & 0x80) != 0) {
                _ = packetMod.parseLongHeader(data) catch {};
            } else {
                _ = packetMod.parseShortHeader(data, 8) catch {};
            }
        }
    };

    for (0..initialLen + 1) |cut| helper.parse(initialHdrBuf[0..cut]);
    for (0..shortLen + 1) |cut| helper.parse(shortHdrBuf[0..cut]);

    var prng = std.Random.DefaultPrng.init(0xcccc);
    const rng = prng.random();
    var mut: [64]u8 = undefined;

    for (0..150) |_| {
        const len = 1 + rng.uintLessThan(usize, mut.len);
        rng.bytes(mut[0..len]);
        helper.parse(mut[0..len]);
    }
}

test "regression: quic connection receiveDatagram state machine under adversarial packets" {
    const io = std.Io.Threaded.global_single_threaded.io();

    const helper = struct {
        fn feed(in_io: std.Io, data: []const u8) void {
            const alloc = std.heap.page_allocator;
            var srv = Connection.init(alloc, in_io, .server, .{
                .isServer = true,
                .version = 0x00000001,
            }) catch return;
            defer srv.deinit();
            _ = srv.receiveDatagram(data, 1000) catch {};

            var cli = Connection.init(alloc, in_io, .client, .{
                .isServer = false,
                .version = 0x00000001,
            }) catch return;
            defer cli.deinit();
            _ = cli.receiveDatagram(data, 1000) catch {};
        }
    };

    var prng = std.Random.DefaultPrng.init(0xdddd);
    const rng = prng.random();

    var smallInitial: [100]u8 = undefined;
    rng.bytes(&smallInitial);
    smallInitial[0] = 0xc0;
    std.mem.writeInt(u32, smallInitial[1..5], 0x00000001, .big);
    helper.feed(io, &smallInitial);

    var fullDatagram: [1200]u8 = undefined;
    @memset(&fullDatagram, 0);
    fullDatagram[0] = 0xc0;
    std.mem.writeInt(u32, fullDatagram[1..5], 0x00000001, .big);
    fullDatagram[5] = 8;
    @memcpy(fullDatagram[6..14], "dcid1234");
    fullDatagram[14] = 8;
    @memcpy(fullDatagram[15..23], "scid1234");
    fullDatagram[23] = 0;
    fullDatagram[24] = 0x40;
    fullDatagram[25] = 0x20;

    helper.feed(io, &fullDatagram);

    for (0..50) |_| {
        const len = 16 + rng.uintLessThan(usize, fullDatagram.len - 16);
        const flips = 1 + rng.uintLessThan(usize, 6);
        for (0..flips) |_| {
            const idx = rng.uintLessThan(usize, len);
            fullDatagram[idx] = rng.int(u8);
        }
        helper.feed(io, fullDatagram[0..len]);
    }
}

test "path validation initiation and response roundtrip" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    var pair = try CtlPair.init(a);
    defer pair.deinit();

    try std.testing.expect(!pair.client.isPathValidated());

    try pair.client.initiatePathValidation(1000, rng);
    try std.testing.expect(pair.client.pathValidator != null);
    try std.testing.expectEqual(pathMod.State.validating, pair.client.pathValidator.?.state);
    try std.testing.expect(pair.client.outbuf.items.len > 0);

    // Grab the challenge data from pathValidator queue
    const challengeData = pair.client.pathValidator.?.queue[0].data;

    // Simulate receiving PATH_RESPONSE frame matching the challenge
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try frames.encode(&payload, a, .{ .pathResponse = .{ .data = challengeData } });

    try pair.client.dispatchFrames(&pair.client.spaces[2], payload.items, 1050, false);

    try std.testing.expect(pair.client.isPathValidated());
}
