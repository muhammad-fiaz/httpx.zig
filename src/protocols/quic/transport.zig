//! QUIC <-> real UDP socket adapter.
//!
//! Bridges `Connection` to kernel UDP sockets so the engine runs over an
//! actual network path (not just the internal test pipe). Each endpoint
//! binds one UDP socket; `pump()` drains the socket into the connection
//! and flushes queued output datagrams to the last peer address seen.
//!
//! Initial-space packets derive their keys from the DCID (RFC 9001 section
//! 5.2). The TLS 1.3 handshake lives in `handshake.zig`; ACK tracking,
//! PTO/loss recovery, NewReno congestion control, Retry, and version
//! negotiation live in `connection.zig`. This adapter only owns the UDP
//! socket and the pump. Connection migration is not implemented.
//!
//! References:
//!   - RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport
//!   - RFC 9001 — Using TLS to Secure QUIC

const std = @import("std");
const Allocator = std.mem.Allocator;
const udpMod = @import("../../sockets/udp.zig");
const connMod = @import("connection.zig");
const syncMod = @import("../../common/sync.zig");
const clockMod = @import("../../common/clock.zig");
const Connection = connMod.Connection;

/// Background datagram pump for deadline-driven QUIC code.
///
/// `std.Io` datagram receives block indefinitely with no usable timeout
/// on several backends, so a quiet peer would stall any direct pump
/// loop forever. `Pump` instead receives on a dedicated reader thread
/// into a bounded queue; the owner thread pops with a deadline and feeds
/// the connection itself. ALL connection access stays on the owner
/// thread — the reader only moves socket bytes into the queue, so no
/// connection locking is needed anywhere.
///
/// Lifecycle: `start` spawns the reader; `next` pops (owned slice) until
/// the deadline; `stop` wakes the reader, joins it, and drains the queue.
/// The endpoint's socket stays open; one `Pump` spans the whole connection
/// use (handshake through exchange). Initialize
/// with `.{};` before starting. A second `start` before `stop` returns
/// `error.AlreadyRunning` without replacing the live reader thread.
pub const Pump = struct {
    ep: *Endpoint = undefined,
    allocator: Allocator = undefined,
    thread: std.Thread = undefined,
    running: bool = false,
    stopFlag: std.atomic.Value(bool) = .init(false),
    /// Set by `stop()`: in-flight and future `next()` calls fail fast
    /// with `error.PumpStopped` instead of polling to their deadline.
    /// This is what makes server-thread teardown instant.
    dead: std.atomic.Value(bool) = .init(false),
    mu: syncMod.Spinlock = .{},
    queue: std.ArrayList(Queued) = .empty,
    /// Hard cap: beyond this, newest datagrams drop (receive path has no
    /// loss recovery yet, so shedding under flood matches wire reality).
    maxQueued: usize = 256,

    const Queued = struct {
        data: []u8,
        from: std.Io.net.IpAddress,
    };

    pub fn start(self: *Pump, ep: *Endpoint, allocator: Allocator) !void {
        if (self.running) return error.AlreadyRunning;
        self.* = .{
            .ep = ep,
            .allocator = allocator,
            .thread = undefined,
        };
        self.stopFlag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, readerProc, .{self});
        self.running = true;
    }

    pub const Deliverable = struct {
        /// Owned datagram bytes (caller frees).
        data: []u8,
        from: std.Io.net.IpAddress,
    };

    /// Pops one queued datagram, null on deadline expiry, or
    /// `error.PumpStopped` once `stop()` ran. The owner thread — and
    /// only it — assigns `ep.peer` from `from`, so the endpoint's peer
    /// field is never shared across threads. Polls at ~1ms granularity;
    /// never blocks past the deadline.
    pub fn next(self: *Pump, deadlineMs: u64) !?Deliverable {
        const t0: u64 = @intCast(clockMod.monotonicMillis());
        while (true) {
            if (self.dead.load(.acquire)) return error.PumpStopped;
            self.mu.lock();
            const item = self.queue.pop();
            self.mu.unlock();
            if (item) |q| return .{ .data = q.data, .from = q.from };
            const now: u64 = @intCast(clockMod.monotonicMillis());
            if (now -| t0 >= deadlineMs) return null;
            clockMod.sleepMillis(1);
        }
    }

    /// Stops the reader and frees any unpopped datagrams. The reader is
    /// woken with a 1-byte loopback datagram, NOT a socket close:
    /// closing a socket with a blocked `std.Io` receive trips
    /// `.CANCELLED => unreachable` inside the Threaded backend on
    /// Windows. Short datagrams are ignored by `receiveDatagram`, so a
    /// queued wakeup is harmless. Safe to call once per started pump;
    /// the endpoint (and its socket) stays usable until `deinit`.
    pub fn stop(self: *Pump) void {
        if (!self.running) return;
        self.running = false;
        self.stopFlag.store(true, .release);
        self.dead.store(true, .release);
        self.wakeReader();
        self.thread.join();
        self.mu.lock();
        // Never toOwnedSlice a possibly-never-allocated list: remap on
        // the static empty backing is unsound. Pop item-by-item instead.
        while (self.queue.pop()) |q| {
            self.mu.unlock();
            self.allocator.free(q.data);
            self.mu.lock();
        }
        self.queue.deinit(self.allocator);
        self.mu.unlock();
    }

    fn wakeReader(self: *Pump) void {
        const dest = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.ep.localPort()) catch return;
        self.ep.sock.sendTo(&dest, &.{0}) catch {};
    }

    fn readerProc(self: *Pump) void {
        var buf: [MAX_DATAGRAM]u8 = undefined;
        while (!self.stopFlag.load(.acquire)) {
            const rx = self.ep.sock.receive(&buf) catch {
                // Socket closed (stop) or ICMP/transport noise: back off
                // briefly, then re-check the flag. Never hot-spins: a
                // persistently failing socket still yields the CPU.
                clockMod.sleepMillis(1);
                continue;
            };
            const owned = self.allocator.dupe(u8, rx.data) catch {
                clockMod.sleepMillis(1);
                continue;
            };
            self.mu.lock();
            if (self.queue.items.len >= self.maxQueued) {
                self.mu.unlock();
                self.allocator.free(owned);
                continue;
            }
            self.queue.append(self.allocator, .{ .data = owned, .from = rx.from }) catch {
                self.mu.unlock();
                self.allocator.free(owned);
                continue;
            };
            self.mu.unlock();
        }
    }
};

pub const MAX_DATAGRAM: usize = 1500;

pub const Endpoint = struct {
    conn: *Connection,
    sock: udpMod.UdpSocket,
    /// Last peer address observed (set on first received datagram).
    peer: ?std.Io.net.IpAddress = null,
    io: std.Io,

    pub const Options = struct {
        port: u16 = 0,
    };

    /// Binds `options.port` (0 = ephemeral by default) for `conn`. Servers bind a known
    /// port so clients can address them; clients use ephemeral ports.
    pub fn init(allocator: Allocator, io: std.Io, conn: *Connection, options: Options) !Endpoint {
        _ = allocator;
        const sock = try udpMod.UdpSocket.bind(io, options.port);
        // No SO_RCVTIMEO on purpose: a receive timeout surfaces as
        // error.WouldBlock, which the Threaded std.Io backend treats as
        // unreachable and aborts the process. The socket stays fully
        // blocking; Pump readers idle in receive until a datagram (or
        // the stop() wakeup) arrives, and pumpIn is only called where
        // progress is guaranteed.
        return .{ .conn = conn, .sock = sock, .io = io };
    }

    pub fn deinit(self: *Endpoint) void {
        self.sock.close();
    }

    pub fn localPort(self: *const Endpoint) u16 {
        return switch (self.sock.socket.address) {
            .ip4 => |v| v.port,
            .ip6 => |v| v.port,
        };
    }

    /// Receives up to `max` datagrams into the connection. Returns the
    /// number processed. Blocks indefinitely when the peer is quiet (see
    /// `UdpSocket.receive`), so only call this where progress is
    /// guaranteed (data known present, as in the Initial-ping test).
    /// Deadline-driven code uses `Pump.next` instead.
    /// Non-fatal per-datagram errors are counted and skipped
    /// (hostile-input tolerance); fatal connection errors surface.
    pub fn pumpIn(self: *Endpoint, max: usize, nowMs: u64) !usize {
        var buf: [MAX_DATAGRAM]u8 = undefined;
        var n: usize = 0;
        while (n < max) : (n += 1) {
            const rx = self.sock.receive(&buf) catch return n; // closed/err => drained
            self.peer = rx.from;
            self.conn.receiveDatagram(rx.data, nowMs) catch |e| switch (e) {
                error.Draining => return error.Draining,
                else => continue, // drop bad datagrams, keep going
            };
        }
        return n;
    }

    /// Flushes all currently queued connection output to the peer.
    /// Requires a known destination: either `peer` from prior traffic or
    /// an explicit `dest` for the first flight (client role).
    ///
    /// Packets are coalesced into datagrams, never split: a QUIC datagram
    /// carries whole packets only (RFC 9000 Section 12.2), and cutting a
    /// packet in half produces a datagram the peer must discard. Only
    /// long-header packets may be coalesced: a short-header (1-RTT)
    /// packet has no Length field, so it must be the last packet in the
    /// datagram (same section).
    pub fn flush(self: *Endpoint, dest: ?std.Io.net.IpAddress) !usize {
        const d = dest orelse self.peer orelse return error.NoRoute;
        var sent: usize = 0;
        while (self.conn.outbuf.items.len > 0) {
            const take = self.nextDatagramSize();
            try self.sock.sendTo(&d, self.conn.outbuf.items[0..take]);
            self.conn.outbuf.replaceRange(self.conn.allocator, 0, take, &.{}) catch
                return error.OutOfMemory;
            self.dropSentPackets(take);
            sent += take;
            if (self.conn.outbuf.items.len == 0) break;
        }
        return sent;
    }

    /// Size of the next datagram: as many queued packets as fit into one
    /// datagram, but never less than a single whole packet. Stops after a
    /// short-header packet, which must be the last one in a datagram
    /// because it carries no Length field (RFC 9000 Section 12.2).
    fn nextDatagramSize(self: *Endpoint) usize {
        const peer_max = if (self.conn.peerParams) |p| p.maxUdpPayloadSize else MAX_DATAGRAM;
        const limit = @min(@min(MAX_DATAGRAM, peer_max), self.conn.outbuf.items.len);
        return datagramBytes(self.conn.outPacketLengths(), self.conn.outPacketChainableFlags(), limit);
    }

    /// Drops the packet bookkeeping for the bytes that were just sent.
    fn dropSentPackets(self: *Endpoint, sent: usize) void {
        const lengths = self.conn.outPacketLengths();
        var remaining = sent;
        var count: usize = 0;
        for (lengths) |len| {
            if (remaining < len) break;
            remaining -= len;
            count += 1;
        }
        if (count == 0) return;
        self.conn.dropOutPackets(count);
    }
};

/// Bytes of the next datagram: coalesce whole queued packets while they
/// fit and while the current packet may be followed. A short-header
/// packet reports `chainable = false` and ends the datagram; when the
/// flags are missing the splitter sends one packet per datagram rather
/// than risk an unparseable coalescing (RFC 9000 Section 12.2).
fn datagramBytes(lengths: []const u32, chainable: []const bool, limit: usize) usize {
    var total: usize = 0;
    var count: usize = 0;
    for (lengths, 0..) |len, i| {
        if (total + len > limit) break;
        total += len;
        count += 1;
        if (i >= chainable.len or !chainable[i]) break;
    }
    if (count == 0) {
        // The first packet does not fit the datagram limit (or the
        // boundary information is missing): send that packet on its own
        // rather than splitting it across datagrams.
        if (lengths.len > 0) return lengths[0];
        return limit;
    }
    return total;
}

test "quic datagram splitter never coalesces packets after a short header" {
    const long_then_short = [_]u32{ 61, 57 };
    const long_flags = [_]bool{ true, false };
    try std.testing.expectEqual(@as(usize, 118), datagramBytes(&long_then_short, &long_flags, 1200));

    const three_short = [_]u32{ 61, 57, 57 };
    const short_flags = [_]bool{ false, false, false };
    try std.testing.expectEqual(@as(usize, 61), datagramBytes(&three_short, &short_flags, 1200));

    const two_short = [_]u32{ 57, 57 };
    const two_short_flags = [_]bool{ false, false };
    try std.testing.expectEqual(@as(usize, 57), datagramBytes(&two_short, &two_short_flags, 1200));

    // Long headers may still share a datagram when they fit together.
    const two_long = [_]u32{ 1201, 694 };
    const two_long_flags = [_]bool{ true, true };
    try std.testing.expectEqual(@as(usize, 1201), datagramBytes(&two_long, &two_long_flags, 1500));
    try std.testing.expectEqual(@as(usize, 1895), datagramBytes(&two_long, &two_long_flags, 2000));

    // Missing flags: one packet per datagram (no unsafe coalescing).
    try std.testing.expectEqual(@as(usize, 61), datagramBytes(&long_then_short, &.{}, 1200));
}

test "quic pump rejects a duplicate start without losing its reader" {
    const a = std.testing.allocator;
    var ctx = try @import("../../sockets/tcp.zig").IoContext.init(a);
    defer ctx.deinit();
    var conn = try connMod.Connection.init(a, ctx.io, .client, .{});
    defer conn.deinit();
    var ep = try Endpoint.init(a, ctx.io, conn, .{});
    defer ep.deinit();
    var pump: Pump = .{};
    try pump.start(&ep, a);
    defer pump.stop();

    try std.testing.expectError(error.AlreadyRunning, pump.start(&ep, a));
    try std.testing.expect(pump.running);
}

// Loopback integration: two Endpoints over REAL kernel UDP sockets
// exchanging protected Initial-space traffic (RFC 9001 initial secrets).

test "quic endpoints exchange protected initial packets over real udp" {
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;

    defer ctx.deinit();

    var client = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .client, .{});
    defer client.deinit();
    var server = try connMod.Connection.init(a, std.Io.Threaded.global_single_threaded.io(), .server, .{});
    defer server.deinit();

    // Queue a real Initial-space flight (keys derive from DCID alone, so
    // no TLS driver is needed at this level).
    try client.installInitialKeys();
    const PingC = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) connMod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch
                return connMod.Error.OutOfMemory;
        }
    };
    try client.sendFrames(.initial, PingC.build, 50);
    try server.acceptInitial(client.dcid[0..8]);

    var ce = try Endpoint.init(a, ctx.io, client, .{});
    defer ce.deinit();
    var se = try Endpoint.init(a, ctx.io, server, .{});
    defer se.deinit();

    const cport = ce.localPort();
    const sport = se.localPort();
    try std.testing.expect(cport != 0 and sport != 0);

    const cdest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;

    // Client -> server over the kernel; fail fast if nothing was queued.
    const sent = try ce.flush(cdest);
    try std.testing.expect(sent > 0);
    const gotIn = try se.pumpIn(1, 100);
    try std.testing.expect(gotIn >= 1);

    // Server -> client reply (ACK-bearing ping injected via sendFrames).
    const Ping = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) connMod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch return connMod.Error.OutOfMemory;
        }
    };
    try server.sendFrames(.initial, Ping.build, 150);

    // Flush BEFORE reading localPort-independent peer info: server learned
    // the client's address from its received datagram.
    _ = try se.flush(null);
    const gotBack = try ce.pumpIn(1, 200);
    try std.testing.expect(gotBack >= 1);
}

test "coalesced packets are never split across datagrams" {
    // A QUIC datagram carries whole packets only (RFC 9000 Section 12.2).
    // Splitting a packet in half makes the peer discard the datagram.
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;
    defer ctx.deinit();

    var client = try connMod.Connection.init(a, ctx.io, .client, .{});
    defer client.deinit();
    var server = try connMod.Connection.init(a, ctx.io, .server, .{});
    defer server.deinit();

    var clientEp = try Endpoint.init(a, ctx.io, client, .{});
    defer clientEp.deinit();
    var serverEp = try Endpoint.init(a, ctx.io, server, .{});
    defer serverEp.deinit();

    try client.installInitialKeys();
    try server.acceptInitial(client.dcid[0..client.dcidLen]);

    const PingC = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) connMod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch
                return connMod.Error.OutOfMemory;
        }
    };

    // Two packets in the output buffer: the flush must send them as two
    // datagrams, not as one datagram with a truncated second packet.
    try client.sendFrames(.initial, PingC.build, 50);
    try client.sendFrames(.initial, PingC.build, 51);
    try std.testing.expectEqual(@as(usize, 2), client.outPackets.items.len);

    const dest = std.Io.net.IpAddress.parseIp4("127.0.0.1", serverEp.localPort()) catch unreachable;
    const sent = try clientEp.flush(dest);
    try std.testing.expect(sent > 0);

    // The server must see two datagrams, each carrying a complete packet.
    var buf: [1500]u8 = undefined;
    var received: usize = 0;
    while (received < 2) {
        const rx = serverEp.sock.receive(&buf) catch break;
        try server.receiveDatagram(rx.data, 60);
        received += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), received);
}
