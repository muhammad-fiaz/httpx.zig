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
const protect = @import("protect.zig");
const crypto = @import("crypto.zig");
const frames = @import("frames.zig");
const acktrMod = @import("acktr.zig");
const lossMod = @import("loss.zig");
const ccMod = @import("cc.zig");
const paramsMod = @import("params.zig");
const qstream = @import("stream.zig");
const tlsEngine = @import("../tls/engine.zig");
const qtls = @import("../tls/quicTls.zig");
const ths = @import("../tls/handshake.zig");
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
};

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

pub const Connection = struct {
    allocator: Allocator,
    role: Role,
    cfg: Config,
    cbs: Callbacks = .{},
    tls: TlsDriver = .{},

    state: State = .initial,

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

    /// Serialized output accumulated by send operations.
    outbuf: std.ArrayList(u8) = .empty,

    /// `io` supplies the entropy for the connection IDs. There is
    /// deliberately no seed parameter: one invites callers to pass a
    /// clock value, and a predictable CID lets an off-path attacker
    /// correlate or hijack a flow (RFC 9000 Section 8.2).
    pub fn init(allocator: Allocator, io: std.Io, role: Role, cfg: Config) !*Connection {
        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .role = role,
            .cfg = cfg,
        };
        for (0..3) |i| {
            self.spaces[i] = PnSpace.init(allocator, @enumFromInt(i));
        }
        for (&self.cryptoBuf) |*b| b.* = .empty;
        for (&self.cryptoOut) |*b| b.* = .empty;
        for (&self.cryptoPending) |*b| b.* = .empty;
        self.outbuf = .empty;
        self.peerCids = .empty;
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
        }
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (&self.spaces) |*s| s.deinit();
        for (&self.cryptoBuf) |*b| b.deinit(self.allocator);
        for (&self.cryptoOut) |*b| b.deinit(self.allocator);
        for (&self.cryptoPending) |*b| {
            for (b.items) |segment| self.allocator.free(segment.data);
            b.deinit(self.allocator);
        }
        self.outbuf.deinit(self.allocator);
        self.peerCids.deinit(self.allocator);
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
        const secrets = crypto.initialSecrets(self.dcid[0..self.dcidLen], 0x00000001) catch return Error.TlsDriverFailed;
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
        const sp = &self.spaces[@intFromEnum(kind)];
        var ktx = crypto.deriveProtectionKeys(txSecret);
        var krx = crypto.deriveProtectionKeys(rxSecret);
        // AES-128-GCM suite for this build; HP key same width.
        _ = &ktx;
        _ = &krx;
        sp.keysTx = ktx;
        sp.keysRx = krx;
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
        self.earlyDataRejected = true;
        self.earlyDataAccepted = false;
    }

    /// Queues TLS handshake bytes for later packetization as CRYPTO frames.
    pub fn queueCrypto(self: *Connection, kind: SpaceKind, data: []const u8) Error!u64 {
        if (data.len > MAX_DATAGRAM) return Error.BufferTooSmall;
        const idx = @intFromEnum(kind);
        const offset = self.cryptoSendOff[idx];
        self.cryptoSendOff[idx] = std.math.add(u64, offset, data.len) catch return Error.BufferTooSmall;
        self.cryptoOut[idx].appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        return offset;
    }

    /// Peeks queued CRYPTO bytes while retaining their absolute stream offset.
    /// Call `consumeCrypto` after the frame has been serialized.
    pub fn takeCrypto(self: *Connection, kind: SpaceKind, maxBytes: usize) ?CryptoChunk {
        const idx = @intFromEnum(kind);
        const queued = self.cryptoOut[idx].items;
        if (queued.len == 0) return null;
        const take = @min(maxBytes, queued.len);
        const result: CryptoChunk = .{ .offset = self.cryptoSendOff[idx] - queued.len, .data = queued[0..take] };
        return result;
    }

    /// Consumes bytes previously returned by `takeCrypto` after packetization.
    pub fn consumeCrypto(self: *Connection, kind: SpaceKind, count: usize) bool {
        const idx = @intFromEnum(kind);
        if (count > self.cryptoOut[idx].items.len) return false;
        self.cryptoOut[idx].replaceRange(self.allocator, 0, count, &.{}) catch return false;
        return true;
    }

    pub fn discardInitialKeys(self: *Connection) void {
        self.spaces[0].keysTx = null;
        self.spaces[0].keysRx = null;
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
        const sp = &self.spaces[@intFromEnum(kind)];
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
        // recovery state promptly.
        if (sp.ackQueued) {
            self.ackScratch.clearRetainingCapacity();
            sp.acktr.generateBlocks(&self.ackScratch, self.allocator, 32) catch return Error.OutOfMemory;
            if (self.ackScratch.items.len > 0) {
                const largest = self.ackScratch.items[0].highest;
                const delay = nowMs -| sp.largestRecvTsMs;
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

        var buf: [MAX_DATAGRAM]u8 = undefined;
        const hdrLen = if (isZeroRtt)
            packetMod.writeLongHeader(buf[0..], .{
                .type = .zeroRtt,
                .version = 0x00000001,
                .dcid = self.dcid[0..self.dcidLen],
                .scid = self.scid[0..self.scidLen],
                .token = "",
                .pnLen = pnLen,
                .protectedPayloadLen = payload.items.len + 16,
            }) catch return Error.BufferTooSmall
        else if (kind == .application)
            packetMod.writeShortHeader(buf[0..], .{
                .keyPhase = false,
                .dcid = self.dcid[0..self.dcidLen],
                .pnLen = pnLen,
            }) catch return Error.BufferTooSmall
        else
            packetMod.writeLongHeader(buf[0..], .{
                .type = if (kind == .initial) .initial else .handshake,
                .version = 0x00000001,
                .dcid = self.dcid[0..self.dcidLen],
                .scid = self.scid[0..self.scidLen],
                .token = "",
                .pnLen = pnLen,
                .protectedPayloadLen = payload.items.len + 16,
            }) catch return Error.BufferTooSmall;

        const aadLen = hdrLen + pnLen;
        @memcpy(buf[hdrLen..][0..pnLen], pnBytes[4 - pnLen ..]);

        // Ensure enough ciphertext for the header-protection sample
        // (sampleOff+16 <= wire): pad with PADDING frames if needed.
        const minPayload = 4 + 16 - pnLen;
        if (payload.items.len < minPayload) {
            try payload.appendNTimes(self.allocator, 0x00, minPayload - payload.items.len);
        }

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

        try self.outbuf.appendSlice(self.allocator, buf[0..wireLen]);
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
        sp.nextPn += 1;
    }

    /// True when the built payload carries anything beyond ACK, PADDING,
    /// PING, and CONNECTION_CLOSE (which are never retransmitted).
    fn payloadHasAckEliciting(payload: []const u8) bool {
        var pos: usize = 0;
        while (pos < payload.len) {
            const f = frames.decode(payload, &pos) catch return true;
            switch (f) {
                .padding, .ping, .ack, .connectionClose => {},
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
        for (a.ranges) |r| {
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
        var rebuilt = std.ArrayList(u8).empty;
        defer rebuilt.deinit(self.allocator);
        var pos: usize = 0;
        var any = false;
        while (pos < stored.len) {
            const f = frames.decode(stored, &pos) catch break;
            switch (f) {
                .ack, .padding => {},
                else => {
                    frames.encode(&rebuilt, self.allocator, f) catch |e| switch (e) {
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
        const kind: SpaceKind = @enumFromInt(spaceIdx);
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

    /// Drives loss and PTO timers; call every pump iteration with the
    /// clock. Retransmits declare themselves through the normal send
    /// path (fresh packet numbers, re-accounted windows).
    pub fn pollTimeouts(self: *Connection, nowMs: u64) Error!void {
        switch (self.state) {
            .closing, .draining, .closed => return,
            else => {},
        }
        for (&self.spaces, 0..) |*sp, idx| {
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
            if ((first & 0x80) != 0 and std.mem.readInt(u32, slice[1..5], .big) == 0) {
                return; // Version negotiation: policy handled above this layer.
            }
            if ((first & 0x80) != 0) {
                self.rxConsumed = 0;
                try self.receiveLong(slice, nowMs);
                if (self.rxConsumed == 0) return;
                off += self.rxConsumed;
            } else {
                try self.receiveShort(slice, nowMs);
                off = dgram.len; // short packet spans the rest
            }
        }
    }

    fn receiveLong(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        const parsed = packetMod.parseLongHeader(dgram) catch |e| switch (e) {
            error.UnsupportedVersion => return, // ignore unknown versions
            else => return Error.ProtocolViolation,
        };

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
        } else (sp.keysRx orelse return Error.TlsDriverFailed);

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
        protect.openWithKeys(pt[0..ctLen], work[aadLen..][0..ctLen], work[declaredEnd - 16 ..][0..16].*, work[0..aadLen], keys, pn) catch
            return Error.AuthenticationFailed;

        if (isZeroRtt) {
            if (self.maxEarlyData > 0) {
                self.earlyDataBytesReceived +|= ctLen;
                if (self.earlyDataBytesReceived > self.maxEarlyData) {
                    return Error.FlowControlViolation;
                }
            }
        }

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
        sp.largestRecvTsMs = nowMs;

        self.rxConsumed = declaredEnd;
        self.rxAckEliciting = false;
        try self.dispatchFrames(sp, pt[0..ctLen], nowMs);
        self.afterPacketReceived(sp, pn, nowMs);
    }
    fn receiveShort(self: *Connection, dgram: []const u8, nowMs: u64) Error!void {
        const sp = &self.spaces[2];
        const keys = sp.keysRx orelse return Error.TlsDriverFailed;

        var work: [MAX_DATAGRAM]u8 = undefined;
        if (dgram.len > work.len) return Error.ProtocolViolation;
        @memcpy(work[0..dgram.len], dgram);

        const pnOffset = 1 + self.scidLen; // peer uses OUR scid as dcid
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
        const pnLen: usize = (@as(usize, work[0]) & 0x03) + 1;
        for (0..pnLen) |i| work[pnOffset + i] ^= mask[1 + i];
        var pnTrunc: u64 = 0;
        for (0..pnLen) |i| pnTrunc = (pnTrunc << 8) | work[pnOffset + i];

        const expected: u64 = if (sp.largestAcked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pnTrunc, pnLen);

        const aadLen = pnOffset + pnLen;
        if (dgram.len < aadLen + 16) return Error.ProtocolViolation;
        const ctLen = dgram.len - aadLen - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ctLen], work[aadLen..][0..ctLen], work[aadLen + ctLen ..][0..16].*, work[0..aadLen], keys, pn) catch
            return Error.AuthenticationFailed;

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
        sp.largestRecvTsMs = nowMs;

        self.rxConsumed = dgram.len;
        self.rxAckEliciting = false;
        try self.dispatchFrames(sp, pt[0..ctLen], nowMs);
        self.afterPacketReceived(sp, pn, nowMs);
    }

    /// Updates acknowledgment state after one received packet.
    /// Immediate ACK when the second eliciting packet arrives, on
    /// reordering, or in handshake spaces (latency-sensitive); otherwise
    /// arms the max-ack-delay timer drained by `pollAckTimers`.
    fn afterPacketReceived(self: *Connection, sp: *PnSpace, pn: u64, nowMs: u64) void {
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

    /// Arms/drains ACK timers; call every pump iteration with the clock.
    /// Pure state update: emission happens in `packetize`.
    pub fn pollAckTimers(self: *Connection, nowMs: u64) void {
        for (&self.spaces) |*sp| {
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
            .padding, .ping, .ack, .connectionClose => false,
            else => true,
        };
    }

    fn dispatchFrames(self: *Connection, sp: *PnSpace, plaintext: []const u8, nowMs: u64) Error!void {
        var pos: usize = 0;
        while (pos < plaintext.len) {
            const f = frames.decode(plaintext, &pos) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            if (isAckElicitingFrame(f)) self.rxAckEliciting = true;
            switch (f) {
                .padding, .ping => {},
                .ack => |a| {
                    try self.onAckFrame(sp, a, nowMs);
                    if (a.ranges.len > 0) std.heap.page_allocator.free(a.ranges);
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
                    const Sink = struct {
                        cbs: Callbacks,
                        sid: u64,
                        pub fn call(sinkSelf: *@This(), data: []const u8) !void {
                            if (sinkSelf.cbs.onStreamData) |cb| cb(sinkSelf.cbs.ctx, sinkSelf.sid, data, false);
                        }
                    };
                    var sink = Sink{ .cbs = self.cbs, .sid = s.id };
                    if (!st.fcAllows(s.offset, s.data.len)) return Error.FlowControlViolation;
                    _ = st.receive(s.offset, s.data, s.fin, &sink) catch |e| switch (e) {
                        error.FlowControlViolation => return Error.FlowControlViolation,
                        error.FinalSizeViolation => return Error.ProtocolViolation,
                        error.StreamReset => return,
                        else => return Error.OutOfMemory,
                    };
                    const end = s.offset + s.data.len;
                    const oldEnd = self.recvStreamEnd.get(s.id) orelse 0;
                    if (end > oldEnd) {
                        self.dataReceived +|= end - oldEnd;
                        try self.recvStreamEnd.put(s.id, end);
                    }
                    if (self.dataReceived > self.maxData) return Error.FlowControlViolation;
                    try self.maybeBumpMaxData();
                    if (s.fin and st.finOffset != null and st.recvOffset == st.finOffset.?) {
                        if (self.cbs.onStreamData) |cb| cb(self.cbs.ctx, s.id, &.{}, true);
                    }
                },
                .handshakeDone => {
                    self.state = .established;
                    if (self.cbs.onHandshakeDone) |cb| cb(self.cbs.ctx);
                },
                .connectionClose => |c| {
                    self.state = .draining;
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
                    // RFC 9000 section 19.15: store peer's new CID.
                    for (self.peerCids.items) |c| {
                        if (c.sequence == n.sequence) return Error.ProtocolViolation;
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
                .pathResponse => {
                    // Path response received; path validated.
                },
            }
        }
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
        const idx = @intFromEnum(kind);
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
        @memcpy(self.dcid[0..clientDcid.len], clientDcid);
        self.dcidLen = @intCast(clientDcid.len);
        self.installInitialKeys() catch return Error.TlsDriverFailed;
    }

    pub fn takeOutput(self: *Connection, gpa: Allocator) ![]u8 {
        defer self.outbuf = .empty;
        return self.outbuf.toOwnedSlice(gpa);
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
        // Server-side driver: on client flight -> install HS keys, reply.
        fn serverOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, nowMs: u64) Error!void {
            const role: *Role = @ptrCast(@alignCast(ctx.?));
            _ = role;
            if (!std.mem.eql(u8, data, TestDriverCtx.clientHello)) return;

            const t = TestDriverCtx.transcript();
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

            // Also install app-space keys and confirm the handshake.
            const appBase = crypto.deriveSecret(t, "quic ap");
            try conn.installKeys(.application, appBase, appBase);
            const D = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .handshakeDone);
                }
            };
            try conn.sendFrames(.application, D.build, nowMs);
        }

        // Client-side driver: emit flight, preinstall HS keys symmetrically.
        fn clientStart(ctx: ?*anyopaque, conn: *Connection, nowMs: u64) Error!void {
            _ = ctx;
            try conn.installInitialKeys();
            const t = TestDriverCtx.transcript();
            const cliTx = crypto.deriveSecret(t, "client in");
            const cliRx = crypto.deriveSecret(t, "server in");
            try conn.installKeys(.handshake, cliTx, cliRx);
            try conn.installKeys(.application, cliRx, cliRx); // mirrored below

            const B = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.clientHello } });
                }
            };
            try conn.sendFrames(.initial, B.build, nowMs);
        }

        fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, _: u64) Error!void {
            _ = ctx;
            if (std.mem.eql(u8, data, TestDriverCtx.serverHello)) {
                // App keys arrive mirrored from server's choice.
                const t = TestDriverCtx.transcript();
                const appBase = crypto.deriveSecret(t, "quic ap");
                conn.installKeys(.application, appBase, appBase) catch return Error.TlsDriverFailed;
            }
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
    try std.testing.expect(sOut.len > 64);

    // Client consumes server flight -> installs app keys -> established.
    client.receiveDatagram(sOut[0..], 200) catch |e| {
        return e;
    };
    try std.testing.expectEqual(State.established, client.state);

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
    sec1: [39]u8 = .{0} ** 39,

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
        if (d.flightDone) return;
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        const rec = takeRecord(&d.incoming) orelse return;
        if (rec.kind != @intFromEnum(ths.HandshakeType.client_hello)) return Error.ProtocolViolation;
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

        // Loopback simplification (documented): an authentic ClientHello
        // validates return routability, so no Retry token round trip.
        // Production deployments must gate amplification on Retry/token.
        conn.addressValidated = true;
        const DoneB = struct {
            pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                try fe(gpa, payload, .handshakeDone);
            }
        };
        try conn.sendFrames(.application, DoneB.build, nowMs);
        d.flightDone = true;
    }

    fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8, _: u64) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        d.peerFlight.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        while (takeRecord(&d.incoming)) |rec| {
            switch (rec.kind) {
                @intFromEnum(ths.HandshakeType.server_hello) => {
                    d.engine.processServerHello(rec.msg) catch return Error.TlsDriverFailed;
                    const shared = d.engine.sharedSecret32() orelse return Error.TlsDriverFailed;
                    d.shared = shared;
                    const chSh = hashConcat(&.{ d.flight.items, rec.msg });
                    const hs = qtls.handshakeKeys(shared, chSh);
                    d.hsSecret = hs.hsSecret;
                    try conn.installKeys(.handshake, hs.keys.txSecret, hs.keys.rxSecret);
                    conn.discardInitialKeys();
                },
                @intFromEnum(ths.HandshakeType.encrypted_extensions) => {
                    d.engine.processEncryptedExtensions(rec.msg) catch return Error.TlsDriverFailed;
                },
                @intFromEnum(ths.HandshakeType.certificate) => {
                    d.engine.processCertificate(rec.msg) catch return Error.TlsDriverFailed;
                },
                @intFromEnum(ths.HandshakeType.certificate_verify) => {
                    d.engine.processCertificateVerify(rec.msg) catch return Error.TlsDriverFailed;
                },
                @intFromEnum(ths.HandshakeType.finished) => {
                    // HMAC over the shared transcript: proves both sides
                    // agree on every handshake byte before 1-RTT starts.
                    d.engine.processFinished(rec.msg) catch return Error.TlsDriverFailed;
                    const hsSecret = d.hsSecret orelse return Error.TlsDriverFailed;
                    const chSf = hashConcat(&.{ d.flight.items, d.peerFlight.items });
                    const ap = qtls.applicationKeys(hsSecret, chSf);
                    try conn.installKeys(.application, ap.keys.txSecret, ap.keys.rxSecret);
                },
                else => return Error.ProtocolViolation,
            }
            dropFront(&d.incoming, conn.allocator, rec.msg.len);
        }
    }
};

/// Runs a complete TLS 1.3 handshake between two QUIC Connections through
/// the TlsHandshakeDriver: Initial + Handshake + 1-RTT keys installed on
/// both ends, server handshakeDone sent. Shared by the QUIC/TLS and
/// HTTP/3 loopback tests so the handshake pump has one definition.
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
    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
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

    const s0 = try server.takeOutput(a);
    defer a.free(s0);
    try std.testing.expect(s0.len > 64);
    try client.receiveDatagram(s0, 200);
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
    try std.testing.expectEqualSlices(u8, cliD.flight.items, srvD.incoming.items);
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
    var cliBufs: [8][2048]u8 = undefined;
    var cliLens: [8]usize = .{0} ** 8;
    var cliFins: [8]bool = .{false} ** 8;
    var cliSids: [8]u64 = .{std.math.maxInt(u64)} ** 8;
    var srvBufs: [8][2048]u8 = undefined;
    var srvLens: [8]usize = .{0} ** 8;
    var srvFins: [8]bool = .{false} ** 8;
    var srvSids: [8]u64 = .{std.math.maxInt(u64)} ** 8;

    fn reset() void {
        cliLens = .{0} ** 8;
        cliFins = .{false} ** 8;
        cliSids = .{std.math.maxInt(u64)} ** 8;
        srvLens = .{0} ** 8;
        srvFins = .{false} ** 8;
        srvSids = .{std.math.maxInt(u64)} ** 8;
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

    fn store(bufs: *[8][2048]u8, lens: *[8]usize, fins: *[8]bool, sids: *[8]u64, sid: u64, data: []const u8, fin: bool) void {
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

    fn find(sids: *[8]u64, lens: *[8]usize, bufs: *[8][2048]u8, sid: u64) ?[]const u8 {
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

    // 5. Graceful shutdown: GOAWAY on the server control stream.
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
        const secret = [_]u8{0xA5} ** 32;
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
    const data = [_]u8{0xAB} ** 100;

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

    const data = [_]u8{0xCD} ** 100;
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

    const data = [_]u8{0xEF} ** 10;
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
    const d = [_]u8{0x11} ** 10;

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
    const d = [_]u8{0x22} ** 10;

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
    const d = [_]u8{0x33} ** 10;

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
    const d = [_]u8{0x44} ** 10;

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
        const one = [_]u8{@intCast(0x50 + i)} ** 1;
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
        const out = try pair.client.takeOutput(a);
        defer a.free(out);
        try std.testing.expect(out.len > 0);
        try pair.server.receiveDatagram(out, 501);
    }
    const st = pair.server.streams.get(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 5), st.recvOffset);
}

test "send blocks when congestion window exhausted" {
    const a = std.testing.allocator;
    var pair = try CtlPair.init(a);
    defer pair.deinit();
    const chunk = [_]u8{0xAA} ** 500;
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
    const d = [_]u8{0x55} ** 10;

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
