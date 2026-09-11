//! QUIC <-> real UDP socket adapter.
//!
//! Bridges `Connection` to kernel UDP sockets so the engine runs over an
//! actual network path (not just the internal test pipe). Each endpoint
//! binds one UDP socket; `pump()` drains the socket into the connection
//! and flushes queued output datagrams to the last peer address seen.
//!
//! Scope note (honest): Initial-space packets are fully specified here —
//! their keys derive from the DCID alone (RFC 9001 section 5.2), so endpoints can
//! exchange protected Initial traffic without the TLS 1.3 driver. The
//! full handshake driver remains the open item tracked separately.
//!
//! References:
//!   - RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport
//!   - RFC 9001 — Using TLS to Secure QUIC

const std = @import("std");
const Allocator = std.mem.Allocator;
const udp_mod = @import("../../sockets/udp.zig");
const conn_mod = @import("connection.zig");
const sync_mod = @import("../../common/sync.zig");
const clock_mod = @import("../../common/clock.zig");
const Connection = conn_mod.Connection;

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
/// the deadline; `stop` wakes the reader via socket close, joins it, and
/// drains the queue. Stopping consumes the endpoint's socket: one `Pump`
/// spans the whole connection use (handshake through exchange).
pub const Pump = struct {
    ep: *Endpoint,
    allocator: Allocator,
    thread: std.Thread = undefined,
    running: bool = false,
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Set by `stop()`: in-flight and future `next()` calls fail fast
    /// with `error.PumpStopped` instead of polling to their deadline.
    /// This is what makes server-thread teardown instant.
    dead: std.atomic.Value(bool) = .init(false),
    mu: sync_mod.Spinlock = .{},
    queue: std.ArrayList(Queued) = .empty,
    /// Hard cap: beyond this, newest datagrams drop (receive path has no
    /// loss recovery yet, so shedding under flood matches wire reality).
    max_queued: usize = 256,

    const Queued = struct {
        data: []u8,
        from: std.Io.net.IpAddress,
    };

    pub fn start(self: *Pump, ep: *Endpoint, allocator: Allocator) !void {
        self.* = .{
            .ep = ep,
            .allocator = allocator,
            .thread = undefined,
        };
        self.stop_flag.store(false, .release);
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
        const t0: u64 = @intCast(clock_mod.millisNow());
        while (true) {
            if (self.dead.load(.acquire)) return error.PumpStopped;
            self.mu.lock();
            const item = self.queue.pop();
            self.mu.unlock();
            if (item) |q| return .{ .data = q.data, .from = q.from };
            const now: u64 = @intCast(clock_mod.millisNow());
            if (now -| t0 >= deadlineMs) return null;
            clock_mod.sleepMillis(1);
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
        self.stop_flag.store(true, .release);
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
        while (!self.stop_flag.load(.acquire)) {
            const rx = self.ep.sock.receive(&buf) catch {
                // Socket closed (stop) or ICMP/transport noise: back off
                // briefly, then re-check the flag. Never hot-spins: a
                // persistently failing socket still yields the CPU.
                clock_mod.sleepMillis(1);
                continue;
            };
            const owned = self.allocator.dupe(u8, rx.data) catch {
                clock_mod.sleepMillis(1);
                continue;
            };
            self.mu.lock();
            if (self.queue.items.len >= self.max_queued) {
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
    sock: udp_mod.UdpSocket,
    /// Last peer address observed (set on first received datagram).
    peer: ?std.Io.net.IpAddress = null,
    io: std.Io,

    /// Binds an ephemeral local port for `conn`.
    pub fn init(allocator: Allocator, io: std.Io, conn: *Connection) !Endpoint {
        return initPort(allocator, io, conn, 0);
    }

    /// Binds `port` (0 = ephemeral) for `conn`. Servers bind a known
    /// port so clients can address them; clients use ephemeral ports.
    pub fn initPort(allocator: Allocator, io: std.Io, conn: *Connection, port: u16) !Endpoint {
        _ = allocator;
        const sock = try udp_mod.UdpSocket.bind(io, port);
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
    pub fn flush(self: *Endpoint, dest: ?std.Io.net.IpAddress) !usize {
        const d = dest orelse self.peer orelse return error.NoRoute;
        var sent: usize = 0;
        while (self.conn.outbuf.items.len > 0) {
            const take = @min(MAX_DATAGRAM, self.conn.outbuf.items.len);
            try self.sock.sendTo(&d, self.conn.outbuf.items[0..take]);
            self.conn.outbuf.replaceRange(self.conn.allocator, 0, take, &.{}) catch
                return error.OutOfMemory;
            sent += take;
            // A coalesced burst beyond one datagram needs explicit pacing;
            // this adapter intentionally stays simple and returns after
            // draining what fits without blocking.
            if (self.conn.outbuf.items.len == 0) break;
        }
        return sent;
    }
};

// Loopback integration: two Endpoints over REAL kernel UDP sockets
// exchanging protected Initial-space traffic (RFC 9001 initial secrets).

test "quic endpoints exchange protected initial packets over real udp" {
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;

    defer ctx.deinit();

    var client = try conn_mod.Connection.init(a, .client, .{}, 11);
    defer client.deinit();
    var server = try conn_mod.Connection.init(a, .server, .{}, 22);
    defer server.deinit();

    // Queue a real Initial-space flight (keys derive from DCID alone, so
    // no TLS driver is needed at this level).
    try client.installInitialKeys();
    const PingC = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) conn_mod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch
                return conn_mod.Error.OutOfMemory;
        }
    };
    try client.sendFrames(.initial, PingC.build, 50);
    try server.acceptInitial(client.dcid[0..8]);

    var ce = try Endpoint.init(a, ctx.io, client);
    defer ce.deinit();
    var se = try Endpoint.init(a, ctx.io, server);
    defer se.deinit();

    const cport = ce.localPort();
    const sport = se.localPort();
    try std.testing.expect(cport != 0 and sport != 0);

    const cdest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;

    // Client -> server over the kernel; fail fast if nothing was queued.
    const sent = try ce.flush(cdest);
    try std.testing.expect(sent > 0);
    const got_in = try se.pumpIn(1, 100);
    try std.testing.expect(got_in >= 1);

    // Server -> client reply (ACK-bearing ping injected via sendFrames).
    const Ping = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) conn_mod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch return conn_mod.Error.OutOfMemory;
        }
    };
    try server.sendFrames(.initial, Ping.build, 150);

    // Flush BEFORE reading localPort-independent peer info: server learned
    // the client's address from its received datagram.
    _ = try se.flush(null);
    const got_back = try ce.pumpIn(1, 200);
    try std.testing.expect(got_back >= 1);
}
