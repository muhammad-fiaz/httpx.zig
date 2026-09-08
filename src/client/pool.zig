//! Connection pool: bounded reuse of plain-TCP connections.
//!
//! v1 semantics (documented honestly):
//!   * The pool PARKS healthy keep-alive connections and hands them back.
//!   * `maxConnections` caps total parked sockets.
//!   * `maxPerHost` caps parked sockets per origin ("host", port).
//!   * Parked sockets expire after `idleTimeoutMs`, or after
//!     `maxLifetimeMs` measured from FIRST parking (v1 measures parked
//!     lifespan; a full connection-lifetime ledger arrives with the
//!     HTTP/2 pool work).
//!   * Everything dropped goes through drainThenClose — no socket leaks.
//!
//! Thread-safety: internally synchronized; shareable across threads.
//!
//! References:
//!   - RFC 9110 Section 9.3.4 — Connection Management (keep-alive)
//!   - RFC 9112 Section 9.6 — Persistence (connection reuse)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const sync = @import("../common/sync.zig");
const clock = @import("../common/clock.zig");

pub const PoolConfig = struct {
    /// Hard ceiling across all origins.
    maxConnections: u32 = 256,
    /// Ceiling per origin.
    maxPerHost: u16 = 16,
    /// Parked connections older than this are dropped.
    idleTimeoutMs: i64 = 30_000,
    /// Max time a connection may stay parked. 0 disables.
    maxParkedMs: i64 = 300_000,
};

pub const Snapshot = struct {
    hits: u64,
    misses: u64,
    released: u64,
    parkedNow: u64,
    droppedStale: u64,
    droppedLimit: u64,
};

pub const Stats = struct {
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    released: std.atomic.Value(u64) = .init(0),
    parkedNow: std.atomic.Value(u64) = .init(0),
    droppedStale: std.atomic.Value(u64) = .init(0),
    droppedLimit: std.atomic.Value(u64) = .init(0),

    pub fn snapshot(self: *const Stats) Snapshot {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .released = self.released.load(.monotonic),
            .parkedNow = self.parkedNow.load(.monotonic),
            .droppedStale = self.droppedStale.load(.monotonic),
            .droppedLimit = self.droppedLimit.load(.monotonic),
        };
    }
};

const ConnKey = struct {
    host: [64]u8,
    hostLen: u8,
    port: u16,

    fn init(host: []const u8, port: u16) ?ConnKey {
        if (host.len == 0 or host.len > 64) return null;
        var k = ConnKey{ .host = undefined, .hostLen = @intCast(host.len), .port = port };
        @memcpy(k.host[0..host.len], host);
        return k;
    }

    fn eql(a: ConnKey, b: ConnKey) bool {
        return a.port == b.port and a.hostLen == b.hostLen and
            std.mem.eql(u8, a.host[0..a.hostLen], b.host[0..b.hostLen]);
    }
};

const IdleConn = struct {
    socket: tcp.Socket,
    key: ConnKey,
    parkedAtMs: i64,
};

pub const Pool = struct {
    allocator: Allocator,
    io: std.Io,
    cfg: PoolConfig,
    mu: sync.Spinlock = .{},
    idle: std.ArrayList(IdleConn),
    stats: Stats = .{},

    pub fn init(allocator: Allocator, io: std.Io, cfg: PoolConfig) Pool {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .idle = .empty,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.purge();
        self.idle.deinit(self.allocator);
    }

    pub fn statsSnapshot(self: *const Pool) Snapshot {
        return self.stats.snapshot();
    }

    pub fn parkedCount(self: *Pool) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.idle.items.len;
    }

    /// Pop a healthy reusable connection for this origin, or null (miss).
    pub fn acquire(self: *Pool, host: []const u8, port: u16) ?tcp.Socket {
        const key = ConnKey.init(host, port) orelse {
            _ = self.stats.misses.fetchAdd(1, .monotonic);
            return null;
        };
        const now = clock.millisNow();
        self.mu.lock();
        defer self.mu.unlock();

        var i: usize = 0;
        while (i < self.idle.items.len) {
            const c = &self.idle.items[i];
            if (!c.key.eql(key)) {
                i += 1;
                continue;
            }
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const parkedExpired = self.cfg.maxParkedMs != 0 and
                now - c.parkedAtMs > self.cfg.maxParkedMs;
            if (idleExpired or parkedExpired) {
                self.dropAt(i);
                continue; // same index now holds a different entry
            }
            if (!c.socket.isAlive()) {
                self.dropAt(i);
                continue;
            }
            const sock = c.socket;
            _ = self.idle.swapRemove(i);
            _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
            _ = self.stats.hits.fetchAdd(1, .monotonic);
            return sock;
        }
        _ = self.stats.misses.fetchAdd(1, .monotonic);
        return null;
    }

    /// True when another connection may still be parked for this origin.
    pub fn canPark(self: *Pool, host: []const u8, port: u16) bool {
        const key = ConnKey.init(host, port) orelse return false;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.idle.items.len >= self.cfg.maxConnections) return false;
        var n: u32 = 0;
        for (self.idle.items) |*c| {
            if (c.key.eql(key)) n += 1;
        }
        return n < self.cfg.maxPerHost;
    }

    /// Return a healthy connection for future reuse. Drops it instead when
    /// any cap is hit. Never leaks.
    pub fn release(self: *Pool, host: []const u8, port: u16, socket: tcp.Socket) void {
        const key = ConnKey.init(host, port) orelse {
            socket.drainThenClose();
            return;
        };
        const now = clock.millisNow();
        self.mu.lock();
        defer self.mu.unlock();

        if (!self.canParkLocked(key)) {
            socket.drainThenClose();
            _ = self.stats.droppedLimit.fetchAdd(1, .monotonic);
            return;
        }
        self.idle.append(self.allocator, .{
            .socket = socket,
            .key = key,
            .parkedAtMs = now,
        }) catch {
            socket.drainThenClose();
            return;
        };
        _ = self.stats.released.fetchAdd(1, .monotonic);
        _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
    }

    fn canParkLocked(self: *Pool, key: ConnKey) bool {
        if (self.idle.items.len >= self.cfg.maxConnections) return false;
        var n: u32 = 0;
        for (self.idle.items) |*c| {
            if (c.key.eql(key)) n += 1;
        }
        return n < self.cfg.maxPerHost;
    }

    /// Close everything immediately.
    pub fn purge(self: *Pool) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.idle.items) |*c| {
            c.socket.drainThenClose();
        }
        self.idle.clearRetainingCapacity();
        _ = self.stats.parkedNow.store(0, .monotonic);
    }

    /// Drop stale/expired entries opportunistically.
    pub fn sweepExpired(self: *Pool) void {
        const now = clock.millisNow();
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const c = &self.idle.items[i];
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const parkedExpired = self.cfg.maxParkedMs != 0 and
                now - c.parkedAtMs > self.cfg.maxParkedMs;
            if (idleExpired or parkedExpired) {
                self.dropAt(i);
            } else {
                i += 1;
            }
        }
    }

    fn dropAt(self: *Pool, i: usize) void {
        const c = self.idle.items[i];
        c.socket.drainThenClose();
        _ = self.idle.swapRemove(i);
        _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
        _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
    }
};

// Tests

const tTcp = tcp;

test "release then acquire reuses connection" {
    var ctx = tTcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var l = tTcp.Listener.bind(ctx.io, 0) catch return;
    // Defer order matters: th.join() is declared LAST so it runs FIRST in
    // LIFO — but the listener must be closed BEFORE join to wake a blocked
    // accept. So: declare close AFTER join (runs before it).
    const th = spawnEchoServer(&l, ctx.io, 1);
    defer th.join();
    defer l.close(ctx.io);

    const a = std.testing.allocator;
    var p = Pool.init(a, ctx.io, .{});
    defer p.deinit();

    const originPort = l.localPort();
    // Pool reuse means ONE physical connection: park it, pop it, close it.
    p.release("127.0.0.1", originPort, tTcp.connect(ctx.io, "127.0.0.1", originPort) catch return);

    const st1 = p.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st1.released);
    try std.testing.expectEqual(@as(usize, 1), p.parkedCount());

    const got = p.acquire("127.0.0.1", originPort);
    try std.testing.expect(got != null);
    got.?.close();

    const st2 = p.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st2.hits);
    try std.testing.expectEqual(@as(u64, 0), st2.misses);
}

/// Spawns a mock server accepting exactly `count` connections, reading once
/// per connection. Returns the thread; caller MUST `defer th.join()` and
/// `defer listener.close()` (close declared after join so LIFO closes first,
/// guaranteeing join can never hang on a blocked accept).
fn spawnEchoServer(l: *tTcp.Listener, io: std.Io, count: usize) std.Thread {
    // Each connection gets its OWN thread: a client that parks (never writes)
    // must not block acceptance/service of other connections.
    const ConnT = struct {
        fn run(io2: std.Io, s: tTcp.Socket) void {
            _ = io2;
            defer s.close();
            var b: [8]u8 = undefined;
            _ = s.read(&b) catch {};
        }
    };
    const Acceptor = struct {
        fn run(lst: *tTcp.Listener, io2: std.Io, nTarget: usize) void {
            var n: usize = 0;
            while (n < nTarget) : (n += 1) {
                const s = lst.accept(io2) catch return;
                const t = std.Thread.spawn(.{}, ConnT.run, .{ io2, s }) catch {
                    s.close();
                    return;
                };
                t.detach();
            }
        }
    };
    return std.Thread.spawn(.{}, Acceptor.run, .{ l, io, count }) catch unreachable;
}

test "maxPerHost parking cap enforced" {
    var ctx = tTcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var l = tTcp.Listener.bind(ctx.io, 0) catch return;
    // Two PHYSICAL connections here: the second release exceeds the cap and
    // must be dropped (drainThenClose), not parked.
    const th = spawnEchoServer(&l, ctx.io, 2);
    defer l.close(ctx.io);
    defer th.join();

    const a = std.testing.allocator;
    var p = Pool.init(a, ctx.io, .{ .maxPerHost = 1 });
    defer p.deinit();

    const port = l.localPort();
    const s1 = tTcp.connect(ctx.io, "127.0.0.1", port) catch return;
    p.release("h", port, s1);
    try std.testing.expectEqual(@as(usize, 1), p.parkedCount());
    try std.testing.expect(!p.canPark("h", port));
    const s2 = tTcp.connect(ctx.io, "127.0.0.1", port) catch return;

    p.release("h", port, s2);

    try std.testing.expectEqual(@as(usize, 1), p.parkedCount());
    const st = p.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.droppedLimit);

    // Different origin unaffected.
    try std.testing.expect(p.canPark("other", port));
}

test "total parking cap enforced" {
    const a = std.testing.allocator;
    var p = Pool.init(a, undefined, .{ .maxConnections = 0 });
    defer p.deinit();
    try std.testing.expect(!p.canPark("any", 80));
}
