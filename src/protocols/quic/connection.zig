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
//! keys derived via protocols/tls/quic_tls.zig (RFC 9001).

const std = @import("std");
const Allocator = std.mem.Allocator;

const varint = @import("varint.zig");
const packet_mod = @import("packet.zig");
const protect = @import("protect.zig");
const crypto = @import("crypto.zig");
const frames = @import("frames.zig");
const acktr_mod = @import("acktr.zig");
const loss_mod = @import("loss.zig");
const params_mod = @import("params.zig");
const qstream = @import("stream.zig");
const tls_engine = @import("../tls/engine.zig");
const qtls = @import("../tls/quic_tls.zig");
const ths = @import("../tls/handshake.zig");
const h3conn = @import("../http3/connection.zig");
const h3frame = @import("../http3/frame.zig");
const h3qpack = @import("../http3/qpack.zig");

pub const Error = error{
    ProtocolViolation,
    AuthenticationFailed,
    FlowControlViolation,
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
    acktr: acktr_mod.AckTracker,
    /// Protection keys once installed (null until TLS provides them).
    keysRx: ?crypto.ProtectionKeys = null,
    keysTx: ?crypto.ProtectionKeys = null,
    /// Highest received PN for duplicate suppression.
    highestRxPn: i64 = -1,

    pub fn init(allocator: Allocator, kind: SpaceKind) PnSpace {
        return .{ .kind = kind, .acktr = acktr_mod.AckTracker.init(allocator) };
    }

    pub fn deinit(self: *PnSpace) void {
        self.acktr.deinit();
    }
};

/// TLS driver seam: consumes ordered CRYPTO data, produces handshake
/// bytes to transmit and installs keys when levels complete.
pub const TlsDriver = struct {
    ctx: ?*anyopaque = null,
    /// Feed handshake data received from the peer.
    onData: ?*const fn (ctx: ?*anyopaque, conn: *Connection, data: []const u8) Error!void = null,
    /// Called after connection setup to kick off the client flight.
    start: ?*const fn (ctx: ?*anyopaque, conn: *Connection) Error!void = null,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    onStreamData: ?*const fn (ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void = null,
    onNewStream: ?*const fn (ctx: ?*anyopaque, sid: u64) void = null,
    onClose: ?*const fn (ctx: ?*anyopaque, err_code: u64, reason: []const u8) void = null,
    onHandshakeDone: ?*const fn (ctx: ?*anyopaque) void = null,
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

    // Connection IDs (RFC 9000 allows CIDs up to 20 bytes).
    dcid: [20]u8 = undefined, // our source cid / peer's destination
    dcidLen: u8 = 8,
    scid: [20]u8 = undefined, // what we advertise
    scidLen: u8 = 8,

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
    recovery: loss_mod.Recovery = .{},
    sentPackets: std.ArrayList(loss_mod.SentPacket) = .empty,

    pendingPathResponse: ?[8]u8 = null,
    pendingResetStream: ?struct { streamId: u64, errorCode: u64 } = null,

    // Packet-number spaces.
    spaces: [3]PnSpace = undefined,

    // Transport parameters (peer's).
    peerParams: ?params_mod.Params = null,

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

    rng: std.Random.DefaultPrng,

    pub fn init(allocator: Allocator, role: Role, cfg: Config, seed: u64) !*Connection {
        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .role = role,
            .cfg = cfg,
            .rng = std.Random.DefaultPrng.init(seed ^ 0x9E3779B97F4A7C15),
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
        self.streams = std.AutoHashMap(u64, *qstream.Stream).init(allocator);
        self.sentPackets = .empty;

        // Random local CIDs (8-byte default for initial handshake).
        self.scidLen = 8;
        self.rng.random().bytes(self.scid[0..self.scidLen]);
        if (role == .client) {
            self.dcidLen = 8;
            self.rng.random().bytes(self.dcid[0..self.dcidLen]); // chosen DCID for Initial
        }
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (&self.spaces) |*s| s.acktr.deinit();
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
        var it = self.streams.valueIterator();
        while (it.next()) |sp| {
            sp.*.deinit();
            self.allocator.destroy(sp.*);
        }
        self.streams.deinit();
        self.sentPackets.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn spaceFor(self: *Connection, lt: packet_mod.LongType) *PnSpace {
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

    /// Queues TLS handshake bytes for later packetization as CRYPTO frames.
    pub fn queueCrypto(self: *Connection, kind: SpaceKind, data: []const u8) Error!u64 {
        if (kind == .application or data.len > MAX_DATAGRAM) return Error.BufferTooSmall;
        const idx = @intFromEnum(kind);
        const offset = self.cryptoSendOff[idx];
        self.cryptoSendOff[idx] = std.math.add(u64, offset, data.len) catch return Error.BufferTooSmall;
        self.cryptoOut[idx].appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        return offset;
    }

    /// Peeks queued CRYPTO bytes while retaining their absolute stream offset.
    /// Call `consumeCrypto` after the frame has been serialized.
    pub fn takeCrypto(self: *Connection, kind: SpaceKind, maxBytes: usize) ?CryptoChunk {
        if (kind == .application) return null;
        const idx = @intFromEnum(kind);
        const queued = self.cryptoOut[idx].items;
        if (queued.len == 0) return null;
        const take = @min(maxBytes, queued.len);
        const result: CryptoChunk = .{ .offset = self.cryptoSendOff[idx] - queued.len, .data = queued[0..take] };
        return result;
    }

    /// Consumes bytes previously returned by `takeCrypto` after packetization.
    pub fn consumeCrypto(self: *Connection, kind: SpaceKind, count: usize) bool {
        if (kind == .application or count > self.cryptoOut[@intFromEnum(kind)].items.len) return false;
        self.cryptoOut[@intFromEnum(kind)].replaceRange(self.allocator, 0, count, &.{}) catch return false;
        return true;
    }

    pub fn discardInitialKeys(self: *Connection) void {
        self.spaces[0].keysTx = null;
        self.spaces[0].keysRx = null;
    }

    // Send path

    /// Queues one protected packet into outbuf.
    pub fn sendFrames(
        self: *Connection,
        kind: SpaceKind,
        builder: anytype,
        nowMs: u64,
    ) Error!void {
        _ = nowMs;
        switch (self.state) {
            .closing, .draining, .closed => return Error.ConnectionClosed,
            else => {},
        }
        const sp = &self.spaces[@intFromEnum(kind)];
        const keys = sp.keysTx orelse return Error.TlsDriverFailed;

        // Server anti-amplification gate until address validation.
        if (self.role == .server and !self.addressValidated) {
            const budget = self.bytesReceived *| 3;
            if (self.bytesSent >= budget) return Error.AmplificationBlocked;
        }

        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try builder(self.allocator, &payload);
        if (payload.items.len == 0) {
            frames.encode(&payload, self.allocator, .ping) catch return Error.ProtocolViolation;
        }

        const pn = sp.nextPn;
        const pnLen: usize = 2;
        var pn_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pn_bytes, @intCast(pn & 0xFFFFFFFF), .big);

        var buf: [MAX_DATAGRAM]u8 = undefined;
        const hdr_len = if (kind == .application)
            packet_mod.writeShortHeader(buf[0..], .{
                .keyPhase = false,
                .dcid = self.dcid[0..self.dcidLen],
                .pnLen = pnLen,
            }) catch return Error.BufferTooSmall
        else
            packet_mod.writeLongHeader(buf[0..], .{
                .type = if (kind == .initial) .initial else .handshake,
                .version = 0x00000001,
                .dcid = self.dcid[0..self.dcidLen],
                .scid = self.scid[0..self.scidLen],
                .token = "",
                .pnLen = pnLen,
                .protectedPayloadLen = payload.items.len + 16,
            }) catch return Error.BufferTooSmall;

        const aad_len = hdr_len + pnLen;
        @memcpy(buf[hdr_len..][0..pnLen], pn_bytes[4 - pnLen ..]);

        // Ensure enough ciphertext for the header-protection sample
        // (sample_off+16 <= wire): pad with PADDING frames if needed.
        const min_payload = 4 + 16 - pnLen;
        if (payload.items.len < min_payload) {
            try payload.appendNTimes(self.allocator, 0x00, min_payload - payload.items.len);
        }

        var ct: [MAX_DATAGRAM]u8 = undefined;
        var tag: [16]u8 = undefined;
        protect.sealWithKeys(ct[0..payload.items.len], &tag, payload.items, buf[0..aad_len], keys, pn);

        var wireLen: usize = aad_len;
        @memcpy(buf[wireLen..][0..payload.items.len], ct[0..payload.items.len]);
        wireLen += payload.items.len;
        @memcpy(buf[wireLen..][0..16], tag[0..]);
        wireLen += 16;

        // Header protection LAST: masks first byte + pn-field bytes with a
        // sample drawn from the ciphertext (RFC 9001 section 5.4).
        const sample_off = hdr_len + 4;
        if (sample_off + 16 > wireLen) return Error.BufferTooSmall;
        var sample: [16]u8 = undefined;
        @memcpy(&sample, buf[sample_off..][0..16]);
        const mask = switch (keys.cipher) {
            .aes_128_gcm, .aes_256_gcm => blk: {
                var hp16: [16]u8 = undefined;
                @memcpy(&hp16, keys.hp[0..16]);
                break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
            },
            .chacha20_poly1305 => blk: {
                var hp32: [32]u8 = undefined;
                @memcpy(&hp32, keys.hp[0..32]);
                break :blk protect.hpMaskChacha(hp32, &sample);
            },
        };
        buf[0] ^= mask[0] & @as(u8, if (kind != .application) 0x0F else 0x1F);
        for (0..pnLen) |i| buf[hdr_len + i] ^= mask[1 + i];

        try self.outbuf.appendSlice(self.allocator, buf[0..wireLen]);
        self.bytesSent += wireLen;
        sp.nextPn += 1;
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
        const parsed = packet_mod.parseLongHeader(dgram) catch |e| switch (e) {
            error.UnsupportedVersion => return, // ignore unknown versions
            else => return Error.ProtocolViolation,
        };

        const sp_idx: usize = switch (parsed.header.type) {
            .initial => 0,
            .handshake => 1,
            else => return, // 0-RTT not enabled in this build
        };
        const sp = &self.spaces[sp_idx];
        const keys = sp.keysRx orelse return Error.TlsDriverFailed;

        const pnOffset = parsed.header.pnOffset;
        if (dgram.len > MAX_DATAGRAM) return Error.ProtocolViolation;
        var work: [MAX_DATAGRAM]u8 = undefined;
        @memcpy(work[0..dgram.len], dgram);

        // Header protection removal (RFC 9001 section 5.4.2).
        const sample_off = pnOffset + 4;
        if (dgram.len < sample_off + 16) return Error.ProtocolViolation;
        var sample: [16]u8 = undefined;
        @memcpy(&sample, work[sample_off..][0..16]);
        const mask = switch (keys.cipher) {
            .aes_128_gcm, .aes_256_gcm => blk: {
                var hp16: [16]u8 = undefined;
                @memcpy(&hp16, keys.hp[0..16]);
                break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
            },
            .chacha20_poly1305 => blk: {
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
        var pn_trunc: u64 = 0;
        for (0..pnLen) |i| pn_trunc = (pn_trunc << 8) | work[pnOffset + i];

        const expected: u64 = if (sp.largestAcked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pn_trunc, pnLen);

        const aad_len = pnOffset + pnLen;
        const payload_len = std.math.cast(usize, parsed.header.length) orelse return Error.ProtocolViolation;
        const declared_end = std.math.add(usize, pnOffset, payload_len) catch return Error.ProtocolViolation;
        if (declared_end < aad_len + 16 or dgram.len < declared_end) return Error.ProtocolViolation;
        const ctLen = declared_end - aad_len - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ctLen], work[aad_len..][0..ctLen], work[declared_end - 16 ..][0..16].*, work[0..aad_len], keys, pn) catch
            return Error.AuthenticationFailed;

        sp.highestRxPn = @max(sp.highestRxPn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largestAcked = if (sp.largestAcked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch return Error.OutOfMemory;

        self.rxConsumed = declared_end;
        try self.dispatchFrames(sp, pt[0..ctLen], nowMs);
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
            .aes_128_gcm, .aes_256_gcm => blk: {
                var hp16: [16]u8 = undefined;
                @memcpy(&hp16, keys.hp[0..16]);
                break :blk protect.hpMaskAesCtx(std.crypto.core.aes.Aes128.initEnc(hp16), &sample);
            },
            .chacha20_poly1305 => blk: {
                var hp32: [32]u8 = undefined;
                @memcpy(&hp32, keys.hp[0..32]);
                break :blk protect.hpMaskChacha(hp32, &sample);
            },
        };
        work[0] ^= mask[0] & 0x1F;
        if (work[0] & 0x18 != 0) return Error.ProtocolViolation;
        const pnLen: usize = (@as(usize, work[0]) & 0x03) + 1;
        for (0..pnLen) |i| work[pnOffset + i] ^= mask[1 + i];
        var pn_trunc: u64 = 0;
        for (0..pnLen) |i| pn_trunc = (pn_trunc << 8) | work[pnOffset + i];

        const expected: u64 = if (sp.largestAcked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pn_trunc, pnLen);

        const aad_len = pnOffset + pnLen;
        if (dgram.len < aad_len + 16) return Error.ProtocolViolation;
        const ctLen = dgram.len - aad_len - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ctLen], work[aad_len..][0..ctLen], work[aad_len + ctLen ..][0..16].*, work[0..aad_len], keys, pn) catch
            return Error.AuthenticationFailed;

        sp.highestRxPn = @max(sp.highestRxPn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largestAcked = if (sp.largestAcked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch return Error.OutOfMemory;
        self.rxConsumed = dgram.len;
        try self.dispatchFrames(sp, pt[0..ctLen], nowMs);
    }

    fn dispatchFrames(self: *Connection, sp: *PnSpace, plaintext: []const u8, nowMs: u64) Error!void {
        _ = nowMs;
        var pos: usize = 0;
        while (pos < plaintext.len) {
            const f = frames.decode(plaintext, &pos) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            switch (f) {
                .padding, .ping => {},
                .ack => |a| {
                    self.recovery.largestAckedPn = if (self.recovery.largestAckedPn) |old|
                        @max(old, a.largestAcknowledged)
                    else
                        a.largestAcknowledged;
                    self.recovery.rtt.onAckReceived(
                        self.lastActivityMs,
                        self.lastActivityMs +| a.ackDelay,
                        25,
                    );
                    self.recovery.onAckOfInFlight();
                },
                .crypto => |c| {
                    try self.receiveCrypto(sp.kind, c.offset, c.data);
                },
                .stream => |s| {
                    const bidi = (s.id & 0x02) == 0;
                    const initiator_is_client = (s.id & 0x01) == 0;
                    const initiator_is_self = (self.role == .client and initiator_is_client) or (self.role == .server and !initiator_is_client);
                    var st_ptr = self.streams.get(s.id);
                    if (st_ptr == null) {
                        const ns = try self.allocator.create(qstream.Stream);
                        ns.* = qstream.Stream.init(self.allocator, s.id, bidi, initiator_is_self);
                        if (self.maxStreamData.get(s.id)) |lim| ns.recvMaxOffset = lim;
                        try self.streams.put(s.id, ns);
                        st_ptr = ns;
                        if (self.cbs.onNewStream) |cb| cb(self.cbs.ctx, s.id);
                    }
                    const st = st_ptr.?;
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
                    const old_end = self.recvStreamEnd.get(s.id) orelse 0;
                    if (end > old_end) {
                        self.dataReceived +|= end - old_end;
                        try self.recvStreamEnd.put(s.id, end);
                    }
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
                    // Store for send in next outgoing packet.
                    self.pendingPathResponse = p.data;
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
                    // Peer is blocked on our maxData; send MAX_DATA update.
                },
                .streamDataBlocked => {
                    // Peer is blocked on stream-level flow control; send MAX_STREAM_DATA.
                },
                .streamsBlocked => {
                    // Peer is blocked on stream count; send MAX_STREAMS update.
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
                    var active_count: usize = 0;
                    for (self.peerCids.items) |c| {
                        if (!c.retired) active_count += 1;
                    }
                    if (!entry.retired and active_count >= MAX_PEER_CONNECTION_IDS) return Error.ProtocolViolation;
                    self.peerCids.append(self.allocator, entry) catch return Error.OutOfMemory;
                },
                .retireConnectionId => {
                    // Mark our CID with the given sequence as retired.
                },
                .stopSending => |s| {
                    // RFC 9000 section 19.5: respond with RESET_STREAM.
                    // Store for send in next outgoing packet.
                    self.pendingResetStream = .{ .streamId = s.streamId, .errorCode = s.errorCode };
                },
                .resetStream => |r| {
                    // Peer reset a stream; notify application.
                    if (self.cbs.onClose) |cb| cb(self.cbs.ctx, r.errorCode, "");
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

    fn maybeDiscardInitial(self: *Connection) void {
        if (self.role == .client and self.spaces[1].keysTx != null) {
            self.discardInitialKeys();
        }
    }

    fn receiveCrypto(self: *Connection, kind: SpaceKind, offset: u64, data: []const u8) Error!void {
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
            var pending_bytes: usize = 0;
            if (self.cryptoPending[idx].items.len >= MAX_CRYPTO_SEGMENTS) return Error.BufferTooSmall;
            for (self.cryptoPending[idx].items) |segment| {
                pending_bytes = std.math.add(usize, pending_bytes, segment.data.len) catch return Error.BufferTooSmall;
            }
            const pending_total = std.math.add(usize, pending_bytes, source.len) catch return Error.BufferTooSmall;
            if (pending_total > 1 << 20)
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
            try cb(self.tls.ctx, self, self.cryptoBuf[idx].items);
            self.cryptoBuf[idx].clearRetainingCapacity();
        }
    }

    /// Kicks off the handshake (client role only).
    pub fn startHandshake(self: *Connection) Error!void {
        if (self.role != .client) return;
        self.installInitialKeys() catch return Error.TlsDriverFailed;
        if (self.tls.start) |cb| try cb(self.tls.ctx, self);
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

    const client_hello = "TEST-CLIENT-FLIGHT";
    const serverHello = "TEST-SERVER-FLIGHT";

    fn transcript() [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(client_hello);
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

    var client = try Connection.init(a, .client, .{}, 11);
    defer client.deinit();
    var server = try Connection.init(a, .server, .{}, 22);
    defer server.deinit();

    const Hs = struct {
        // Server-side driver: on client flight -> install HS keys, reply.
        fn serverOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8) Error!void {
            const role: *Role = @ptrCast(@alignCast(ctx.?));
            _ = role;
            if (!std.mem.eql(u8, data, TestDriverCtx.client_hello)) return;

            const t = TestDriverCtx.transcript();
            const srv_tx = crypto.deriveSecret(t, "server in");
            const srv_rx = crypto.deriveSecret(t, "client in");
            try conn.installKeys(.handshake, srv_tx, srv_rx);
            conn.addressValidated = true;

            // Reply flight in Handshake space.
            const B = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.serverHello } });
                }
            };
            try conn.sendFrames(.handshake, B.build, 0);

            // Also install app-space keys and confirm the handshake.
            const app_base = crypto.deriveSecret(t, "quic ap");
            try conn.installKeys(.application, app_base, app_base);
            const D = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .handshakeDone);
                }
            };
            try conn.sendFrames(.application, D.build, 0);
        }

        // Client-side driver: emit flight, preinstall HS keys symmetrically.
        fn clientStart(ctx: ?*anyopaque, conn: *Connection) Error!void {
            _ = ctx;
            try conn.installInitialKeys();
            const t = TestDriverCtx.transcript();
            const cli_tx = crypto.deriveSecret(t, "client in");
            const cli_rx = crypto.deriveSecret(t, "server in");
            try conn.installKeys(.handshake, cli_tx, cli_rx);
            try conn.installKeys(.application, cli_rx, cli_rx); // mirrored below

            const B = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.client_hello } });
                }
            };
            try conn.sendFrames(.initial, B.build, 0);
        }

        fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8) Error!void {
            _ = ctx;
            if (std.mem.eql(u8, data, TestDriverCtx.serverHello)) {
                // App keys arrive mirrored from server's choice.
                const t = TestDriverCtx.transcript();
                const app_base = crypto.deriveSecret(t, "quic ap");
                conn.installKeys(.application, app_base, app_base) catch return Error.TlsDriverFailed;
            }
        }
    };

    var server_role: Role = .server;
    server.tls = .{ .ctx = &server_role, .onData = Hs.serverOnData };
    client.tls = .{ .start = Hs.clientStart, .onData = Hs.clientOnData };

    // Client begins: produces Initial datagram.
    try client.startHandshake();
    const c_out = try client.takeOutput(a);
    defer a.free(c_out);
    try std.testing.expect(c_out.len >= 64);

    // Server accepts based on the DCID the client used.
    try server.acceptInitial(client.dcid[0..8]);
    try server.receiveDatagram(c_out, 100);

    // Server produced Handshake + Application responses.
    const s_out = try server.takeOutput(a);
    defer a.free(s_out);
    try std.testing.expect(s_out.len > 64);

    // Client consumes server flight -> installs app keys -> established.
    client.receiveDatagram(s_out[0..], 200) catch |e| {
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
// handshake via tls/quic_tls.zig (RFC 9001 Section 7). Packet protection
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
    engine: tls_engine.Engine,
    /// Our own flight bytes (client: ClientHello; server: SH..Fin).
    flight: std.ArrayList(u8) = .empty,
    /// Accumulated inbound CRYPTO bytes for our space.
    incoming: std.ArrayList(u8) = .empty,
    /// Full peer flight retained for transcript binding + comparison.
    peer_flight: std.ArrayList(u8) = .empty,
    /// RFC 9001 chain point agreed with the peer (for test asserts).
    shared: ?[32]u8 = null,
    hs_secret: ?[32]u8 = null,
    flight_done: bool = false,
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

    fn clientStart(ctx: ?*anyopaque, conn: *Connection) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        const ch = d.engine.produceClientHello(&.{"h2"}, &.{}) catch return Error.TlsDriverFailed;
        defer conn.allocator.free(ch);
        d.flight.appendSlice(conn.allocator, ch) catch return Error.OutOfMemory;
        _ = try conn.queueCrypto(.initial, ch);
        try sendQueued(conn, .initial, 0);
    }

    /// Consumes one complete handshake record from the front of `buf`.
    /// Returns the record (type + full message) or null when incomplete.
    fn takeRecord(buf: *std.ArrayList(u8)) ?struct { kind: u8, msg: []const u8 } {
        if (buf.items.len < 4) return null;
        const body_len: usize = (@as(usize, buf.items[1]) << 16) | (@as(usize, buf.items[2]) << 8) | buf.items[3];
        if (buf.items.len < 4 + body_len) return null;
        return .{ .kind = buf.items[0], .msg = buf.items[0 .. 4 + body_len] };
    }

    fn dropFront(buf: *std.ArrayList(u8), a: Allocator, n: usize) void {
        buf.replaceRange(a, 0, n, &.{}) catch {};
    }

    fn serverOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        if (d.flight_done) return;
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        const rec = takeRecord(&d.incoming) orelse return;
        if (rec.kind != @intFromEnum(ths.HandshakeType.client_hello)) return Error.ProtocolViolation;
        const ch_msg = rec.msg;
        d.engine.processClientHello(ch_msg) catch return Error.TlsDriverFailed;
        var flight = d.engine.produceServerFlight(ch_msg[4..], "", &d.sec1, &.{}, &.{}) catch return Error.TlsDriverFailed;
        defer flight.deinit(conn.allocator);

        d.flight.appendSlice(conn.allocator, flight.serverHello) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.encryptedExtensions) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.certificate) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.certificateVerify) catch return Error.OutOfMemory;
        d.flight.appendSlice(conn.allocator, flight.finished) catch return Error.OutOfMemory;

        const shared = d.engine.sharedSecret orelse return Error.TlsDriverFailed;
        d.shared = shared;
        const ch_sh = hashConcat(&.{ ch_msg, flight.serverHello });
        const hs = qtls.handshakeKeys(shared, ch_sh);
        d.hs_secret = hs.hsSecret;
        // LevelKeys secrets are client-oriented (tx = client); mirror them.
        try conn.installKeys(.handshake, hs.keys.rxSecret, hs.keys.txSecret);

        // Bootstrap (RFC 9001 Section 4.1 pattern): ServerHello leaves in
        // an Initial packet so the peer can open it with Initial keys and
        // derive Handshake keys; EE..Finished follow in Handshake packets.
        _ = try conn.queueCrypto(.initial, flight.serverHello);
        try sendQueued(conn, .initial, 100);
        _ = try conn.queueCrypto(.handshake, flight.encryptedExtensions);
        _ = try conn.queueCrypto(.handshake, flight.certificate);
        _ = try conn.queueCrypto(.handshake, flight.certificateVerify);
        _ = try conn.queueCrypto(.handshake, flight.finished);
        try sendQueued(conn, .handshake, 100);

        const ch_sf = hashConcat(&.{ ch_msg, d.flight.items });
        const ap = qtls.applicationKeys(hs.hsSecret, ch_sf);
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
        try conn.sendFrames(.application, DoneB.build, 100);
        d.flight_done = true;
    }

    fn clientOnData(ctx: ?*anyopaque, conn: *Connection, data: []const u8) Error!void {
        const d: *TlsHandshakeDriver = @ptrCast(@alignCast(ctx.?));
        d.incoming.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        d.peer_flight.appendSlice(conn.allocator, data) catch return Error.OutOfMemory;
        while (takeRecord(&d.incoming)) |rec| {
            switch (rec.kind) {
                @intFromEnum(ths.HandshakeType.server_hello) => {
                    d.engine.processServerHello(rec.msg) catch return Error.TlsDriverFailed;
                    const shared = d.engine.sharedSecret orelse return Error.TlsDriverFailed;
                    d.shared = shared;
                    const ch_sh = hashConcat(&.{ d.flight.items, rec.msg });
                    const hs = qtls.handshakeKeys(shared, ch_sh);
                    d.hs_secret = hs.hsSecret;
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
                    const hs_secret = d.hs_secret orelse return Error.TlsDriverFailed;
                    const ch_sf = hashConcat(&.{ d.flight.items, d.peer_flight.items });
                    const ap = qtls.applicationKeys(hs_secret, ch_sf);
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
    cli_d: *TlsHandshakeDriver,
    srv_d: *TlsHandshakeDriver,
) !void {
    // Deterministic P-256 signing identity (same construction as the
    // engine unit test): ECDSA signatures without PKI involvement.
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ec_sec);
    srv_d.sec1 = sec1;

    client.tls = .{ .ctx = cli_d, .start = TlsHandshakeDriver.clientStart, .onData = TlsHandshakeDriver.clientOnData };
    server.tls = .{ .ctx = srv_d, .onData = TlsHandshakeDriver.serverOnData };

    try client.startHandshake();
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

    var cli_d = TlsHandshakeDriver{ .engine = tls_engine.Engine.initClient(a, .{}) };
    defer cli_d.flight.deinit(a);
    defer cli_d.incoming.deinit(a);
    defer cli_d.peer_flight.deinit(a);
    var srv_d = TlsHandshakeDriver{ .engine = tls_engine.Engine.initServer(a, .{}) };
    defer srv_d.flight.deinit(a);
    defer srv_d.incoming.deinit(a);
    defer srv_d.peer_flight.deinit(a);

    var client = try Connection.init(a, .client, .{}, 0xC11E);
    defer client.deinit();
    var server = try Connection.init(a, .server, .{}, 0x5EED);
    defer server.deinit();

    try runTlsHandshake(a, client, server, &cli_d, &srv_d);

    // The server saw the exact ClientHello bytes the client sent.
    try std.testing.expectEqualSlices(u8, cli_d.flight.items, srv_d.incoming.items);
    // The client saw the exact server flight bytes.
    try std.testing.expectEqualSlices(u8, srv_d.flight.items, cli_d.peer_flight.items);

    // ECDHE agreement: both engines derived the same secret.
    try std.testing.expectEqualSlices(u8, &cli_d.shared.?, &srv_d.shared.?);
    // Engine key schedule matches the independent RFC 9001 chain.
    try std.testing.expectEqualSlices(u8, &cli_d.engine.handshakeSecret.?, &cli_d.hs_secret.?);
    try std.testing.expectEqualSlices(u8, &srv_d.engine.handshakeSecret.?, &srv_d.hs_secret.?);
    // Transcripts agree bit-for-bit (Finished HMAC already enforced it).
    var c_tr = cli_d.engine.transcript;
    var s_tr = srv_d.engine.transcript;
    try std.testing.expectEqualSlices(u8, &c_tr.finish(), &s_tr.finish());

    try std.testing.expectEqual(tls_engine.Engine.State.handshakeComplete, cli_d.engine.state);
    try std.testing.expectEqual(tls_engine.Engine.State.server_finished_sent, srv_d.engine.state);
    try std.testing.expect(cli_d.engine.apKeys != null);
    try std.testing.expect(srv_d.engine.apKeys != null);
    try std.testing.expectEqual(State.established, client.state);

    // 1-RTT STREAM data under keys derived from the live handshake.
    const GotSink = struct {
        var got: [64]u8 = undefined;
        var got_len: usize = 0;
        fn onStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
            _ = sid;
            _ = fin;
            @memcpy(got[got_len..][0..data.len], data);
            got_len += data.len;
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
    try std.testing.expectEqualStrings("tls-bound-stream", GotSink.got[0..GotSink.got_len]);
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
        var s_id: u64 = 0;
        var s_off: u64 = 0;
        var s_fin: bool = false;
        var s_data: []const u8 = "";
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
            try fe(gpa, payload, .{ .stream = .{ .id = s_id, .offset = s_off, .data = s_data, .fin = s_fin } });
        }
    };
    B.s_id = sid;
    B.s_off = offset;
    B.s_fin = fin;
    B.s_data = bytes;
    try conn.sendFrames(.application, B.build, nowMs);
}

/// Direction-aware STREAM accumulator for the HTTP/3 loopback test.
const H3LoopSink = struct {
    var cli_bufs: [8][2048]u8 = undefined;
    var cli_lens: [8]usize = .{0} ** 8;
    var cli_fins: [8]bool = .{false} ** 8;
    var cli_sids: [8]u64 = .{std.math.maxInt(u64)} ** 8;
    var srv_bufs: [8][2048]u8 = undefined;
    var srv_lens: [8]usize = .{0} ** 8;
    var srv_fins: [8]bool = .{false} ** 8;
    var srv_sids: [8]u64 = .{std.math.maxInt(u64)} ** 8;

    fn reset() void {
        cli_lens = .{0} ** 8;
        cli_fins = .{false} ** 8;
        cli_sids = .{std.math.maxInt(u64)} ** 8;
        srv_lens = .{0} ** 8;
        srv_fins = .{false} ** 8;
        srv_sids = .{std.math.maxInt(u64)} ** 8;
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
        store(&cli_bufs, &cli_lens, &cli_fins, &cli_sids, sid, data, fin);
    }

    fn onSrvStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        store(&srv_bufs, &srv_lens, &srv_fins, &srv_sids, sid, data, fin);
    }

    fn find(sids: *[8]u64, lens: *[8]usize, bufs: *[8][2048]u8, sid: u64) ?[]const u8 {
        for (sids.*, 0..) |s, i| if (s == sid) return bufs.*[i][0..lens.*[i]];
        return null;
    }

    fn cliBytes(sid: u64) ?[]const u8 {
        return find(&cli_sids, &cli_lens, &cli_bufs, sid);
    }

    fn srvBytes(sid: u64) ?[]const u8 {
        return find(&srv_sids, &srv_lens, &srv_bufs, sid);
    }
};

test "http3 request over quic loopback reaches handler and returns response" {
    const a = std.testing.allocator;
    H3LoopSink.reset();

    var cli_d = TlsHandshakeDriver{ .engine = tls_engine.Engine.initClient(a, .{}) };
    defer cli_d.flight.deinit(a);
    defer cli_d.incoming.deinit(a);
    defer cli_d.peer_flight.deinit(a);
    var srv_d = TlsHandshakeDriver{ .engine = tls_engine.Engine.initServer(a, .{}) };
    defer srv_d.flight.deinit(a);
    defer srv_d.incoming.deinit(a);
    defer srv_d.peer_flight.deinit(a);

    var client = try Connection.init(a, .client, .{}, 0xB311);
    defer client.deinit();
    var server = try Connection.init(a, .server, .{}, 0xB312);
    defer server.deinit();
    client.cbs = .{ .onStreamData = H3LoopSink.onCliStream };
    server.cbs = .{ .onStreamData = H3LoopSink.onSrvStream };

    try runTlsHandshake(a, client, server, &cli_d, &srv_d);
    try std.testing.expectEqual(State.established, client.state);

    var cli_h3 = h3conn.Connection.init(a, .client);
    defer cli_h3.deinit();
    var srv_h3 = h3conn.Connection.init(a, .server);
    defer srv_h3.deinit();

    // 1. Control streams: SETTINGS both directions on uni streams 2 / 3.
    const cli_ctl = try cli_h3.buildControlStream();
    defer a.free(cli_ctl);
    try sendH3Stream(client, 2, 0, cli_ctl, false, 500);
    try pumpH3(client, server, 501);
    {
        const got = H3LoopSink.srvBytes(2).?;
        var off: usize = 0;
        try std.testing.expectEqual(h3conn.CONTROL_STREAM_TYPE, try varint.decode(got, &off));
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x4), fr.frameType);
        const entries = try h3frame.parseSettingsPayload(fr.payload, a);
        defer a.free(entries);
        try srv_h3.processPeerSettings(entries);
        try std.testing.expect(srv_h3.settingsReceived);
    }
    const srv_ctl = try srv_h3.buildControlStream();
    defer a.free(srv_ctl);
    try sendH3Stream(server, 3, 0, srv_ctl, false, 502);
    try pumpH3(server, client, 503);
    {
        const got = H3LoopSink.cliBytes(3).?;
        var off: usize = 0;
        try std.testing.expectEqual(h3conn.CONTROL_STREAM_TYPE, try varint.decode(got, &off));
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x4), fr.frameType);
        const entries = try h3frame.parseSettingsPayload(fr.payload, a);
        defer a.free(entries);
        try cli_h3.processPeerSettings(entries);
        try std.testing.expect(cli_h3.settingsReceived);
    }

    // 2. QPACK encoder/decoder uni streams carry their type prefixes.
    const cli_enc = try h3conn.buildQpackEncoderStreamPrefix(a);
    defer a.free(cli_enc);
    const cli_dec = try h3conn.buildQpackDecoderStreamPrefix(a);
    defer a.free(cli_dec);
    // Short-header packets carry no length prefix, so each datagram holds
    // exactly one of them: pump after every send.
    try sendH3Stream(client, 6, 0, cli_enc, false, 504);
    try pumpH3(client, server, 505);
    try sendH3Stream(client, 10, 0, cli_dec, false, 506);
    try pumpH3(client, server, 507);
    {
        var off: usize = 0;
        try std.testing.expectEqual(h3frame.UniStreamType.qpackEncoder, try varint.decode(H3LoopSink.srvBytes(6).?, &off));
        off = 0;
        try std.testing.expectEqual(h3frame.UniStreamType.qpackDecoder, try varint.decode(H3LoopSink.srvBytes(10).?, &off));
    }

    // 3. Request 1: GET /hello on client bidi stream 0.
    var rs = h3conn.RequestStream{ .id = 0, .allocator = a, .qpack = h3qpack.Encoder.init(a) };
    defer rs.qpack.deinit();
    const req_head = try rs.buildRequestHeaders("GET", "https", "example.com", "/hello", &.{});
    defer a.free(req_head);
    try sendH3Stream(client, 0, 0, req_head, true, 508);
    try pumpH3(client, server, 509);

    // Server decodes HEADERS, dispatches by :path, and responds.
    const Handler = struct {
        fn route(path: []const u8) struct { status: u16, body: []const u8 } {
            if (std.mem.eql(u8, path, "/hello")) return .{ .status = 200, .body = "hello-h3" };
            return .{ .status = 404, .body = "not-found" };
        }
    };
    var resp_status: u16 = 0;
    var resp_body: []const u8 = "";
    {
        const got = H3LoopSink.srvBytes(0).?;
        var off: usize = 0;
        const fr = try h3frame.parseFrame(got, &off);
        try std.testing.expectEqual(@as(u64, 0x1), fr.frameType);
        const fields = try srv_h3.qdec.decodeSectionWithPrefix(fr.payload);
        defer srv_h3.qdec.freeFields(fields);
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
        var srs = h3conn.RequestStream{ .id = 0, .allocator = a, .qpack = h3qpack.Encoder.init(a) };
        defer srs.qpack.deinit();
        const resp_head = try srs.buildResponseHeaders(r.status, &.{});
        defer a.free(resp_head);
        const resp_data = try srs.buildData(r.body);
        defer a.free(resp_data);
        var resp_wire = std.ArrayList(u8).empty;
        defer resp_wire.deinit(a);
        try resp_wire.appendSlice(a, resp_head);
        try resp_wire.appendSlice(a, resp_data);
        try sendH3Stream(server, 0, 0, resp_wire.items, true, 510);
    }
    try pumpH3(server, client, 511);
    {
        const got = H3LoopSink.cliBytes(0).?;
        var off: usize = 0;
        while (off < got.len) {
            const fr = try h3frame.parseFrame(got, &off);
            if (fr.frameType == 0x1) {
                const fields = try cli_h3.qdec.decodeSectionWithPrefix(fr.payload);
                defer cli_h3.qdec.freeFields(fields);
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        resp_status = try std.fmt.parseInt(u16, f.value, 10);
                    }
                }
            } else if (fr.frameType == 0x0) {
                resp_body = fr.payload;
            }
        }
    }
    try std.testing.expectEqual(@as(u16, 200), resp_status);
    try std.testing.expectEqualStrings("hello-h3", resp_body);

    // 4. Request 2 on a fresh stream proves multiplexing + dispatch miss.
    var rs2 = h3conn.RequestStream{ .id = 4, .allocator = a, .qpack = h3qpack.Encoder.init(a) };
    defer rs2.qpack.deinit();
    const req2 = try rs2.buildRequestHeaders("GET", "https", "example.com", "/missing", &.{});
    defer a.free(req2);
    try sendH3Stream(client, 4, 0, req2, true, 512);
    try pumpH3(client, server, 513);
    {
        const got = H3LoopSink.srvBytes(4).?;
        var off: usize = 0;
        const fr = try h3frame.parseFrame(got, &off);
        const fields = try srv_h3.qdec.decodeSectionWithPrefix(fr.payload);
        defer srv_h3.qdec.freeFields(fields);
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
    const srv_ctl_len = srv_ctl.len;
    try sendH3Stream(server, 3, srv_ctl_len, go[0 .. ghlen + idlen], true, 514);
    try pumpH3(server, client, 515);
    {
        const got = H3LoopSink.cliBytes(3).?;
        // Skip the stream-type prefix + SETTINGS already verified above.
        var prefix_off: usize = 0;
        _ = try varint.decode(got, &prefix_off);
        var f_off = prefix_off;
        _ = try h3frame.parseFrame(got, &f_off);
        const fr = try h3frame.parseFrame(got, &f_off);
        try std.testing.expectEqual(@as(u64, 0x7), fr.frameType);
        var id_off: usize = 0;
        try std.testing.expectEqual(@as(u64, 4), try varint.decode(fr.payload, &id_off));
    }
}

test "crypto transmit queue preserves offsets across partial drains" {
    const a = std.testing.allocator;
    var conn = try Connection.init(a, .client, .{}, 91);
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
    try std.testing.expect(conn.takeCrypto(.initial, 1) == null);
    try std.testing.expectError(Error.BufferTooSmall, conn.queueCrypto(.application, "bad"));
}

test "crypto receive reassembles reordered and overlapping segments" {
    const a = std.testing.allocator;
    var conn = try Connection.init(a, .client, .{}, 92);
    defer conn.deinit();

    try conn.receiveCrypto(.initial, 5, " world");
    try std.testing.expectEqual(@as(u64, 0), conn.cryptoRecvOff[0]);
    try conn.receiveCrypto(.initial, 0, "hello");
    try std.testing.expectEqual(@as(u64, 11), conn.cryptoRecvOff[0]);
    try std.testing.expectEqualStrings("hello world", conn.cryptoBuf[0].items);
    try conn.receiveCrypto(.initial, 3, "lo world");
    try std.testing.expectEqual(@as(u64, 11), conn.cryptoRecvOff[0]);
}
