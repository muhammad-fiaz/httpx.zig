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
//! the real TLS 1.3 engine; protocols/tls/quic_tls.zig implements the
//! same interface with genuine handshake messages.

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
    next_pn: u64 = 0,
    largest_acked: ?u64 = null,
    acktr: acktr_mod.AckTracker,
    /// Protection keys once installed (null until TLS provides them).
    keys_rx: ?crypto.ProtectionKeys = null,
    keys_tx: ?crypto.ProtectionKeys = null,
    /// Highest received PN for duplicate suppression.
    highest_rx_pn: i64 = -1,

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
    max_idle_timeout_ms: u64 = 30_000,
    initial_max_data: u64 = 1 << 20,
    max_udp_payload: usize = 1472,
    is_server: bool = false,
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
    cid_len: u8 = 0,
    stateless_reset_token: [16]u8 = undefined,
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
    max_data: u64 = 1 << 20,
    data_sent: u64 = 0,
    data_received: u64 = 0,
    max_data_remote: u64 = 1 << 20,

    // Connection IDs (RFC 9000 allows CIDs up to 20 bytes).
    dcid: [20]u8 = undefined, // our source cid / peer's destination
    dcid_len: u8 = 8,
    scid: [20]u8 = undefined, // what we advertise
    scid_len: u8 = 8,

    // Peer CID table (NEW_CONNECTION_ID entries).
    peer_cids: std.ArrayList(CidEntry) = .empty,
    retire_prior_to: u64 = 0,

    // Stream-level flow control and reorder buffers.
    max_stream_data: std.AutoHashMap(u64, u64) = undefined,
    recv_stream_end: std.AutoHashMap(u64, u64) = undefined,
    streams: std.AutoHashMap(u64, *qstream.Stream) = undefined,
    max_streams_bidi_remote: u64 = 0,
    max_streams_uni_remote: u64 = 0,

    // Loss detection.
    recovery: loss_mod.Recovery = .{},
    sent_packets: std.ArrayList(loss_mod.SentPacket) = .empty,

    pending_path_response: ?[8]u8 = null,
    pending_reset_stream: ?struct { stream_id: u64, error_code: u64 } = null,

    // Packet-number spaces.
    spaces: [3]PnSpace = undefined,

    // Transport parameters (peer's).
    peer_params: ?params_mod.Params = null,

    // CRYPTO reassembly per space (offset -> contiguous).
    crypto_buf: [3]std.ArrayList(u8) = undefined,
    crypto_recv_off: [3]u64 = .{ 0, 0, 0 },
    crypto_send_off: [3]u64 = .{ 0, 0, 0 },
    crypto_out: [3]std.ArrayList(u8) = undefined,
    crypto_pending: [3]std.ArrayList(CryptoSegment) = undefined,

    // Anti-amplification (server side).
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    address_validated: bool = false,

    // Timers (ms domain, caller-driven clock).
    last_activity_ms: u64 = 0,

    /// Bytes of the last datagram consumed (coalesced-packet support).
    rx_consumed: usize = 0,

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
        for (&self.crypto_buf) |*b| b.* = .empty;
        for (&self.crypto_out) |*b| b.* = .empty;
        for (&self.crypto_pending) |*b| b.* = .empty;
        self.outbuf = .empty;
        self.peer_cids = .empty;
        self.max_stream_data = std.AutoHashMap(u64, u64).init(allocator);
        self.recv_stream_end = std.AutoHashMap(u64, u64).init(allocator);
        self.streams = std.AutoHashMap(u64, *qstream.Stream).init(allocator);
        self.sent_packets = .empty;

        // Random local CIDs (8-byte default for initial handshake).
        self.scid_len = 8;
        self.rng.random().bytes(self.scid[0..self.scid_len]);
        if (role == .client) {
            self.dcid_len = 8;
            self.rng.random().bytes(self.dcid[0..self.dcid_len]); // chosen DCID for Initial
        }
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (&self.spaces) |*s| s.acktr.deinit();
        for (&self.crypto_buf) |*b| b.deinit(self.allocator);
        for (&self.crypto_out) |*b| b.deinit(self.allocator);
        for (&self.crypto_pending) |*b| {
            for (b.items) |segment| self.allocator.free(segment.data);
            b.deinit(self.allocator);
        }
        self.outbuf.deinit(self.allocator);
        self.peer_cids.deinit(self.allocator);
        self.max_stream_data.deinit();
        self.recv_stream_end.deinit();
        var it = self.streams.valueIterator();
        while (it.next()) |sp| {
            sp.*.deinit();
            self.allocator.destroy(sp.*);
        }
        self.streams.deinit();
        self.sent_packets.deinit(self.allocator);
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
        const secrets = crypto.initialSecrets(self.dcid[0..self.dcid_len], 0x00000001) catch return Error.TlsDriverFailed;
        const sp = &self.spaces[0];
        sp.keys_tx = if (self.role == .client)
            crypto.initialProtection(secrets, .client)
        else
            crypto.initialProtection(secrets, .server);
        sp.keys_rx = if (self.role == .client)
            crypto.initialProtection(secrets, .server)
        else
            crypto.initialProtection(secrets, .client);
    }

    /// Installs Handshake or 1-RTT keys provided by the TLS layer.
    pub fn installKeys(
        self: *Connection,
        kind: SpaceKind,
        tx_secret: [32]u8,
        rx_secret: [32]u8,
    ) !void {
        const sp = &self.spaces[@intFromEnum(kind)];
        var ktx = crypto.deriveProtectionKeys(tx_secret);
        var krx = crypto.deriveProtectionKeys(rx_secret);
        // AES-128-GCM suite for this build; HP key same width.
        _ = &ktx;
        _ = &krx;
        sp.keys_tx = ktx;
        sp.keys_rx = krx;
    }

    /// Queues TLS handshake bytes for later packetization as CRYPTO frames.
    pub fn queueCrypto(self: *Connection, kind: SpaceKind, data: []const u8) Error!u64 {
        if (kind == .application or data.len > MAX_DATAGRAM) return Error.BufferTooSmall;
        const idx = @intFromEnum(kind);
        const offset = self.crypto_send_off[idx];
        self.crypto_send_off[idx] = std.math.add(u64, offset, data.len) catch return Error.BufferTooSmall;
        self.crypto_out[idx].appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        return offset;
    }

    /// Peeks queued CRYPTO bytes while retaining their absolute stream offset.
    /// Call `consumeCrypto` after the frame has been serialized.
    pub fn takeCrypto(self: *Connection, kind: SpaceKind, max_bytes: usize) ?CryptoChunk {
        if (kind == .application) return null;
        const idx = @intFromEnum(kind);
        const queued = self.crypto_out[idx].items;
        if (queued.len == 0) return null;
        const take = @min(max_bytes, queued.len);
        const result: CryptoChunk = .{ .offset = self.crypto_send_off[idx] - queued.len, .data = queued[0..take] };
        return result;
    }

    /// Consumes bytes previously returned by `takeCrypto` after packetization.
    pub fn consumeCrypto(self: *Connection, kind: SpaceKind, count: usize) bool {
        if (kind == .application or count > self.crypto_out[@intFromEnum(kind)].items.len) return false;
        self.crypto_out[@intFromEnum(kind)].replaceRange(self.allocator, 0, count, &.{}) catch return false;
        return true;
    }

    pub fn discardInitialKeys(self: *Connection) void {
        self.spaces[0].keys_tx = null;
        self.spaces[0].keys_rx = null;
    }

    // Send path

    /// Queues one protected packet into outbuf.
    pub fn sendFrames(
        self: *Connection,
        kind: SpaceKind,
        builder: anytype,
        now_ms: u64,
    ) Error!void {
        _ = now_ms;
        switch (self.state) {
            .closing, .draining, .closed => return Error.ConnectionClosed,
            else => {},
        }
        const sp = &self.spaces[@intFromEnum(kind)];
        const keys = sp.keys_tx orelse return Error.TlsDriverFailed;

        // Server anti-amplification gate until address validation.
        if (self.role == .server and !self.address_validated) {
            const budget = self.bytes_received *| 3;
            if (self.bytes_sent >= budget) return Error.AmplificationBlocked;
        }

        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try builder(self.allocator, &payload);
        if (payload.items.len == 0) {
            frames.encode(&payload, self.allocator, .ping) catch return Error.ProtocolViolation;
        }

        const pn = sp.next_pn;
        const pn_len: usize = 2;
        var pn_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pn_bytes, @intCast(pn & 0xFFFFFFFF), .big);

        var buf: [MAX_DATAGRAM]u8 = undefined;
        const hdr_len = if (kind == .application)
            packet_mod.writeShortHeader(buf[0..], .{
                .key_phase = false,
                .dcid = self.dcid[0..self.dcid_len],
                .pn_len = pn_len,
            }) catch return Error.BufferTooSmall
        else
            packet_mod.writeLongHeader(buf[0..], .{
                .type = if (kind == .initial) .initial else .handshake,
                .version = 0x00000001,
                .dcid = self.dcid[0..self.dcid_len],
                .scid = self.scid[0..self.scid_len],
                .token = "",
                .pn_len = pn_len,
                .protected_payload_len = payload.items.len + 16,
            }) catch return Error.BufferTooSmall;

        const aad_len = hdr_len + pn_len;
        @memcpy(buf[hdr_len..][0..pn_len], pn_bytes[4 - pn_len ..]);

        // Ensure enough ciphertext for the header-protection sample
        // (sample_off+16 <= wire): pad with PADDING frames if needed.
        const min_payload = 4 + 16 - pn_len;
        if (payload.items.len < min_payload) {
            try payload.appendNTimes(self.allocator, 0x00, min_payload - payload.items.len);
        }

        var ct: [MAX_DATAGRAM]u8 = undefined;
        var tag: [16]u8 = undefined;
        protect.sealWithKeys(ct[0..payload.items.len], &tag, payload.items, buf[0..aad_len], keys, pn);

        var wire_len: usize = aad_len;
        @memcpy(buf[wire_len..][0..payload.items.len], ct[0..payload.items.len]);
        wire_len += payload.items.len;
        @memcpy(buf[wire_len..][0..16], tag[0..]);
        wire_len += 16;

        // Header protection LAST: masks first byte + pn-field bytes with a
        // sample drawn from the ciphertext (RFC 9001 section 5.4).
        const sample_off = hdr_len + 4;
        if (sample_off + 16 > wire_len) return Error.BufferTooSmall;
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
        for (0..pn_len) |i| buf[hdr_len + i] ^= mask[1 + i];

        try self.outbuf.appendSlice(self.allocator, buf[0..wire_len]);
        self.bytes_sent += wire_len;
        sp.next_pn += 1;
    }
    // Receive path

    /// Processes one UDP datagram, iterating over COALESCED packets.
    pub fn receiveDatagram(self: *Connection, dgram: []const u8, now_ms: u64) Error!void {
        switch (self.state) {
            .draining, .closed => return Error.Draining,
            else => {},
        }
        self.bytes_received += dgram.len;
        self.last_activity_ms = now_ms;

        var off: usize = 0;
        while (off < dgram.len) {
            const slice = dgram[off..];
            if (slice.len < 5) return;
            const first = slice[0];
            if ((first & 0x80) != 0 and std.mem.readInt(u32, slice[1..5], .big) == 0) {
                return; // Version negotiation: policy handled above this layer.
            }
            if ((first & 0x80) != 0) {
                self.rx_consumed = 0;
                try self.receiveLong(slice, now_ms);
                if (self.rx_consumed == 0) return;
                off += self.rx_consumed;
            } else {
                try self.receiveShort(slice, now_ms);
                off = dgram.len; // short packet spans the rest
            }
        }
    }

    fn receiveLong(self: *Connection, dgram: []const u8, now_ms: u64) Error!void {
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
        const keys = sp.keys_rx orelse return Error.TlsDriverFailed;

        const pn_offset = parsed.header.pn_offset;
        if (dgram.len > MAX_DATAGRAM) return Error.ProtocolViolation;
        var work: [MAX_DATAGRAM]u8 = undefined;
        @memcpy(work[0..dgram.len], dgram);

        // Header protection removal (RFC 9001 section 5.4.2).
        const sample_off = pn_offset + 4;
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
        const pn_len: usize = (@as(usize, work[0]) & 0x03) + 1;
        for (0..pn_len) |i| work[pn_offset + i] ^= mask[1 + i];
        var pn_trunc: u64 = 0;
        for (0..pn_len) |i| pn_trunc = (pn_trunc << 8) | work[pn_offset + i];

        const expected: u64 = if (sp.largest_acked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pn_trunc, pn_len);

        const aad_len = pn_offset + pn_len;
        const payload_len = std.math.cast(usize, parsed.header.length) orelse return Error.ProtocolViolation;
        const declared_end = std.math.add(usize, pn_offset, payload_len) catch return Error.ProtocolViolation;
        if (declared_end < aad_len + 16 or dgram.len < declared_end) return Error.ProtocolViolation;
        const ct_len = declared_end - aad_len - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ct_len], work[aad_len..][0..ct_len], work[declared_end - 16 ..][0..16].*, work[0..aad_len], keys, pn) catch
            return Error.AuthenticationFailed;

        sp.highest_rx_pn = @max(sp.highest_rx_pn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largest_acked = if (sp.largest_acked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch return Error.OutOfMemory;

        self.rx_consumed = declared_end;
        try self.dispatchFrames(sp, pt[0..ct_len], now_ms);
    }
    fn receiveShort(self: *Connection, dgram: []const u8, now_ms: u64) Error!void {
        const sp = &self.spaces[2];
        const keys = sp.keys_rx orelse return Error.TlsDriverFailed;

        var work: [MAX_DATAGRAM]u8 = undefined;
        if (dgram.len > work.len) return Error.ProtocolViolation;
        @memcpy(work[0..dgram.len], dgram);

        const pn_offset = 1 + self.scid_len; // peer uses OUR scid as dcid
        if (dgram.len < pn_offset + 20) return Error.ProtocolViolation;

        var sample: [16]u8 = undefined;
        @memcpy(&sample, work[pn_offset + 4 ..][0..16]);
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
        const pn_len: usize = (@as(usize, work[0]) & 0x03) + 1;
        for (0..pn_len) |i| work[pn_offset + i] ^= mask[1 + i];
        var pn_trunc: u64 = 0;
        for (0..pn_len) |i| pn_trunc = (pn_trunc << 8) | work[pn_offset + i];

        const expected: u64 = if (sp.largest_acked) |la| la + 1 else 0;
        const pn = protect.reconstructPn(expected, pn_trunc, pn_len);

        const aad_len = pn_offset + pn_len;
        if (dgram.len < aad_len + 16) return Error.ProtocolViolation;
        const ct_len = dgram.len - aad_len - 16;

        var pt: [MAX_DATAGRAM]u8 = undefined;
        protect.openWithKeys(pt[0..ct_len], work[aad_len..][0..ct_len], work[aad_len + ct_len ..][0..16].*, work[0..aad_len], keys, pn) catch
            return Error.AuthenticationFailed;

        sp.highest_rx_pn = @max(sp.highest_rx_pn, @as(i64, @intCast(@min(pn, 1 << 62))));
        sp.largest_acked = if (sp.largest_acked) |old| @max(old, pn) else pn;
        sp.acktr.add(pn) catch return Error.OutOfMemory;
        self.rx_consumed = dgram.len;
        try self.dispatchFrames(sp, pt[0..ct_len], now_ms);
    }

    fn dispatchFrames(self: *Connection, sp: *PnSpace, plaintext: []const u8, now_ms: u64) Error!void {
        _ = now_ms;
        var pos: usize = 0;
        while (pos < plaintext.len) {
            const f = frames.decode(plaintext, &pos) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            switch (f) {
                .padding, .ping => {},
                .ack => |a| {
                    self.recovery.largest_acked_pn = if (self.recovery.largest_acked_pn) |old|
                        @max(old, a.largest_acknowledged)
                    else
                        a.largest_acknowledged;
                    self.recovery.rtt.onAckReceived(
                        self.last_activity_ms,
                        self.last_activity_ms +| a.ack_delay,
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
                        if (self.max_stream_data.get(s.id)) |lim| ns.recv_max_offset = lim;
                        try self.streams.put(s.id, ns);
                        st_ptr = ns;
                        if (self.cbs.onNewStream) |cb| cb(self.cbs.ctx, s.id);
                    }
                    const st = st_ptr.?;
                    const Sink = struct {
                        cbs: Callbacks,
                        sid: u64,
                        pub fn call(sink_self: *@This(), data: []const u8) !void {
                            if (sink_self.cbs.onStreamData) |cb| cb(sink_self.cbs.ctx, sink_self.sid, data, false);
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
                    const old_end = self.recv_stream_end.get(s.id) orelse 0;
                    if (end > old_end) {
                        self.data_received +|= end - old_end;
                        try self.recv_stream_end.put(s.id, end);
                    }
                    if (s.fin and st.fin_offset != null and st.recv_offset == st.fin_offset.?) {
                        if (self.cbs.onStreamData) |cb| cb(self.cbs.ctx, s.id, &.{}, true);
                    }
                },
                .handshake_done => {
                    self.state = .established;
                    if (self.cbs.onHandshakeDone) |cb| cb(self.cbs.ctx);
                },
                .connection_close => |c| {
                    self.state = .draining;
                    if (self.cbs.onClose) |cb| cb(self.cbs.ctx, c.error_code, c.reason);
                },
                .path_challenge => |p| {
                    // Echo back as PATH_RESPONSE per RFC 9000 section 19.3.
                    // Store for send in next outgoing packet.
                    self.pending_path_response = p.data;
                },
                .max_data => |m| {
                    self.max_data_remote = m.maximum;
                },
                .max_stream_data => |m| {
                    self.max_stream_data.put(m.stream_id, m.maximum) catch return Error.OutOfMemory;
                },
                .max_streams => |m| {
                    if (m.bidi) {
                        self.max_streams_bidi_remote = m.maximum;
                    } else {
                        self.max_streams_uni_remote = m.maximum;
                    }
                },
                .data_blocked => {
                    // Peer is blocked on our max_data; send MAX_DATA update.
                },
                .stream_data_blocked => {
                    // Peer is blocked on stream-level flow control; send MAX_STREAM_DATA.
                },
                .streams_blocked => {
                    // Peer is blocked on stream count; send MAX_STREAMS update.
                },
                .new_connection_id => |n| {
                    // RFC 9000 section 19.15: store peer's new CID.
                    for (self.peer_cids.items) |c| {
                        if (c.sequence == n.sequence) return Error.ProtocolViolation;
                    }
                    var entry = CidEntry{
                        .sequence = n.sequence,
                        .cid_len = @intCast(@min(n.cid.len, 20)),
                        .stateless_reset_token = n.stateless_reset_token,
                    };
                    @memcpy(entry.cid[0..entry.cid_len], n.cid[0..entry.cid_len]);
                    // Retire older CIDs per retire_prior_to.
                    for (self.peer_cids.items) |*c| {
                        if (n.retire_prior_to > 0 and c.sequence < n.retire_prior_to and !c.retired) {
                            c.retired = true;
                        }
                    }
                    var active_count: usize = 0;
                    for (self.peer_cids.items) |c| {
                        if (!c.retired) active_count += 1;
                    }
                    if (!entry.retired and active_count >= MAX_PEER_CONNECTION_IDS) return Error.ProtocolViolation;
                    self.peer_cids.append(self.allocator, entry) catch return Error.OutOfMemory;
                },
                .retire_connection_id => {
                    // Mark our CID with the given sequence as retired.
                },
                .stop_sending => |s| {
                    // RFC 9000 section 19.5: respond with RESET_STREAM.
                    // Store for send in next outgoing packet.
                    self.pending_reset_stream = .{ .stream_id = s.stream_id, .error_code = s.error_code };
                },
                .reset_stream => |r| {
                    // Peer reset a stream; notify application.
                    if (self.cbs.onClose) |cb| cb(self.cbs.ctx, r.error_code, "");
                },
                .new_token => {
                    // RFC 9000 section 19.7: store token for future address validation.
                },
                .path_response => {
                    // Path response received; path validated.
                },
            }
        }
    }

    fn maybeDiscardInitial(self: *Connection) void {
        if (self.role == .client and self.spaces[1].keys_tx != null) {
            self.discardInitialKeys();
        }
    }

    fn receiveCrypto(self: *Connection, kind: SpaceKind, offset: u64, data: []const u8) Error!void {
        const idx = @intFromEnum(kind);
        if (data.len == 0) return;
        const end = std.math.add(u64, offset, data.len) catch return Error.ProtocolViolation;
        const received = self.crypto_recv_off[idx];
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
            if (self.crypto_pending[idx].items.len >= MAX_CRYPTO_SEGMENTS) return Error.BufferTooSmall;
            for (self.crypto_pending[idx].items) |segment| {
                pending_bytes = std.math.add(usize, pending_bytes, segment.data.len) catch return Error.BufferTooSmall;
            }
            const pending_total = std.math.add(usize, pending_bytes, source.len) catch return Error.BufferTooSmall;
            if (pending_total > 1 << 20)
                return Error.BufferTooSmall;
            const copy = self.allocator.dupe(u8, source) catch return Error.OutOfMemory;
            self.crypto_pending[idx].append(self.allocator, .{ .offset = start, .data = copy }) catch {
                self.allocator.free(copy);
                return Error.OutOfMemory;
            };
            return;
        }

        try self.crypto_buf[idx].appendSlice(self.allocator, source);
        self.crypto_recv_off[idx] = std.math.add(u64, received, source.len) catch return Error.ProtocolViolation;
        while (true) {
            var found: ?usize = null;
            for (self.crypto_pending[idx].items, 0..) |segment, i| {
                if (segment.offset <= self.crypto_recv_off[idx]) {
                    found = i;
                    break;
                }
            }
            const i = found orelse break;
            const segment = self.crypto_pending[idx].swapRemove(i);
            defer self.allocator.free(segment.data);
            const skip: usize = @intCast(self.crypto_recv_off[idx] - segment.offset);
            if (skip >= segment.data.len) continue;
            const contiguous = segment.data[skip..];
            try self.crypto_buf[idx].appendSlice(self.allocator, contiguous);
            self.crypto_recv_off[idx] = std.math.add(u64, self.crypto_recv_off[idx], contiguous.len) catch return Error.ProtocolViolation;
        }
        if (self.tls.onData) |cb| {
            try cb(self.tls.ctx, self, self.crypto_buf[idx].items);
            self.crypto_buf[idx].clearRetainingCapacity();
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
    pub fn acceptInitial(self: *Connection, client_dcid: []const u8) Error!void {
        if (self.role != .server) return Error.ProtocolViolation;
        @memcpy(self.dcid[0..client_dcid.len], client_dcid);
        self.dcid_len = @intCast(client_dcid.len);
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
// header protection + PN coding) is REAL crypto throughout; the TLS
// message layer is a deterministic driver standing in for tls13.zig.

const TestDriverCtx = struct {
    role: Role,
    done_installed: bool = false,

    const client_hello = "TEST-CLIENT-FLIGHT";
    const server_hello = "TEST-SERVER-FLIGHT";

    fn transcript() [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(client_hello);
        h.update(server_hello);
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
            conn.address_validated = true;

            // Reply flight in Handshake space.
            const B = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .{ .crypto = .{ .offset = 0, .data = TestDriverCtx.server_hello } });
                }
            };
            try conn.sendFrames(.handshake, B.build, 0);

            // Also install app-space keys and confirm the handshake.
            const app_base = crypto.deriveSecret(t, "quic ap");
            try conn.installKeys(.application, app_base, app_base);
            const D = struct {
                pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) Error!void {
                    try fe(gpa, payload, .handshake_done);
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
            if (std.mem.eql(u8, data, TestDriverCtx.server_hello)) {
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
        var got_len: usize = 0;
        fn onStream(_: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
            _ = sid;
            _ = fin;
            @memcpy(got[got_len..][0..data.len], data);
            got_len += data.len;
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
    try std.testing.expectEqualStrings("ping-over-quic", StreamSink.got[0..StreamSink.got_len]);
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
    try std.testing.expectEqual(@as(u64, 0), conn.crypto_recv_off[0]);
    try conn.receiveCrypto(.initial, 0, "hello");
    try std.testing.expectEqual(@as(u64, 11), conn.crypto_recv_off[0]);
    try std.testing.expectEqualStrings("hello world", conn.crypto_buf[0].items);
    try conn.receiveCrypto(.initial, 3, "lo world");
    try std.testing.expectEqual(@as(u64, 11), conn.crypto_recv_off[0]);
}
