//! Connection pool: bounded reuse of plain-TCP and HTTP/2 connections.
//!
//! v2 semantics (documented honestly):
//!   * The pool PARKS healthy keep-alive connections and hands them back.
//!   * `maxConnections` caps total parked entries (plain + H2 combined).
//!   * `maxPerHost` caps parked entries per origin ("host", port, scheme).
//!   * Parked entries expire after `idleTimeoutMs`, or after
//!     `maxParkedMs` measured from FIRST parking (plain) or from
//!     connection creation (H2, which carries its creation ledger).
//!   * HTTP/2 connections are pooled per origin+scheme (h2c vs h2-TLS
//!     never mix). A checked-out H2 connection is EXCLUSIVELY owned by
//!     its borrower until release — one request at a time per session,
//!     which reuses TCP+TLS+SETTINGS across sequential requests without
//!     any per-stream locking. Concurrent requests to one origin use
//!     multiple pooled sessions.
//!   * Everything dropped goes through drainThenClose (plain) or session
//!     deinit (H2) — no socket leaks.
//!
//! Thread-safety: internally synchronized; shareable across threads.
//! The pool spinlock is only ever held for list bookkeeping, never
//! across socket I/O.
//!
//! References:
//!   - RFC 9110 Section 9.3.4 — Connection Management (keep-alive)
//!   - RFC 9112 Section 9.6 — Persistence (connection reuse)
//!   - RFC 9113 Section 5.5 — HTTP/2 connection reuse across streams

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const sync = @import("../common/sync.zig");
const clock = @import("../common/clock.zig");
const h2Transport = @import("../protocols/http2/transport.zig");

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
    hits: std.atomic.Value(usize) = .init(0),
    misses: std.atomic.Value(usize) = .init(0),
    released: std.atomic.Value(usize) = .init(0),
    parkedNow: std.atomic.Value(usize) = .init(0),
    droppedStale: std.atomic.Value(usize) = .init(0),
    droppedLimit: std.atomic.Value(usize) = .init(0),

    pub fn snapshot(self: *const Stats) Snapshot {
        return .{
            .hits = @intCast(self.hits.load(.monotonic)),
            .misses = @intCast(self.misses.load(.monotonic)),
            .released = @intCast(self.released.load(.monotonic)),
            .parkedNow = @intCast(self.parkedNow.load(.monotonic)),
            .droppedStale = @intCast(self.droppedStale.load(.monotonic)),
            .droppedLimit = @intCast(self.droppedLimit.load(.monotonic)),
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

/// Origin key for a pooled HTTP/2 session. The `tls` bit keeps h2c and
/// h2-TLS sessions in disjoint lanes (different transports entirely).
const H2Key = struct {
    host: [64]u8,
    hostLen: u8,
    port: u16,
    tls: bool,

    fn init(host: []const u8, port: u16, tls: bool) ?H2Key {
        if (host.len == 0 or host.len > 64) return null;
        var k = H2Key{ .host = undefined, .hostLen = @intCast(host.len), .port = port, .tls = tls };
        @memcpy(k.host[0..host.len], host);
        return k;
    }

    fn eql(a: H2Key, b: H2Key) bool {
        return a.port == b.port and a.tls == b.tls and a.hostLen == b.hostLen and
            std.mem.eql(u8, a.host[0..a.hostLen], b.host[0..b.hostLen]);
    }
};

const IdleH2 = struct {
    client: *h2Transport.PooledConn,
    key: H2Key,
    parkedAtMs: i64,
    createdAtMs: i64,
};

pub const Pool = struct {
    allocator: Allocator,
    io: std.Io,
    cfg: PoolConfig,
    mu: sync.Spinlock = .{},
    idle: std.ArrayList(IdleConn),
    idleH2: std.ArrayList(IdleH2),
    stats: Stats = .{},

    pub fn init(allocator: Allocator, io: std.Io, cfg: PoolConfig) Pool {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .idle = .empty,
            .idleH2 = .empty,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.purge();
        self.idle.deinit(self.allocator);
        self.idleH2.deinit(self.allocator);
    }

    pub fn statsSnapshot(self: *const Pool) Snapshot {
        return self.stats.snapshot();
    }

    pub fn parkedCount(self: *Pool) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.idle.items.len + self.idleH2.items.len;
    }

    /// Pop a reusable HTTP/2 session for this origin+scheme, or null.
    /// The returned session is EXCLUSIVELY owned by the caller until
    /// `releaseH2` (or `deinit` when done). Stale (closed/GOAWAY/expired)
    /// sessions are destroyed instead of returned — never handed out.
    pub fn acquireH2(self: *Pool, host: []const u8, port: u16, tls: bool) ?*h2Transport.PooledConn {
        const key = H2Key.init(host, port, tls) orelse {
            _ = self.stats.misses.fetchAdd(1, .monotonic);
            return null;
        };
        const now = clock.millisNow();
        while (true) {
            self.mu.lock();
            self.sweepH2Locked(now);
            const idx: ?usize = blk: {
                for (self.idleH2.items, 0..) |*c, i| {
                    if (c.key.eql(key)) break :blk i;
                }
                break :blk null;
            };
            const i = idx orelse {
                self.mu.unlock();
                _ = self.stats.misses.fetchAdd(1, .monotonic);
                return null;
            };
            const entry = self.idleH2.swapRemove(i);
            _ = self.stats.parkedNow.store(self.idle.items.len + self.idleH2.items.len, .monotonic);
            self.mu.unlock();

            // Validate outside the spinlock: parked sessions are
            // untouched by anyone else, so no lock is needed to read
            // session state here.
            if (entry.client.isReusable()) {
                _ = self.stats.hits.fetchAdd(1, .monotonic);
                return entry.client;
            }
            entry.client.deinit();
            _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
        }
    }

    /// Return an H2 session for future reuse. Destroyed instead when any
    /// cap is hit, when expired, or when no longer reusable. Never leaks.
    pub fn releaseH2(self: *Pool, host: []const u8, port: u16, tls: bool, client: *h2Transport.PooledConn) void {
        const key = H2Key.init(host, port, tls) orelse {
            client.deinit();
            return;
        };
        if (!client.isReusable()) {
            client.deinit();
            return;
        }
        const now = clock.millisNow();
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.canParkH2Locked(key)) {
            client.deinit();
            _ = self.stats.droppedLimit.fetchAdd(1, .monotonic);
            return;
        }
        self.idleH2.append(self.allocator, .{
            .client = client,
            .key = key,
            .parkedAtMs = now,
            .createdAtMs = client.createdAtMs,
        }) catch {
            client.deinit();
            return;
        };
        _ = self.stats.released.fetchAdd(1, .monotonic);
        _ = self.stats.parkedNow.store(self.idle.items.len + self.idleH2.items.len, .monotonic);
    }

    fn canParkH2Locked(self: *Pool, key: H2Key) bool {
        if (self.idle.items.len + self.idleH2.items.len >= self.cfg.maxConnections) return false;
        var n: u32 = 0;
        for (self.idleH2.items) |*c| {
            if (c.key.eql(key)) n += 1;
        }
        return n < self.cfg.maxPerHost;
    }

    /// Drop H2 entries expired by idle time or by connection lifetime
    /// (measured from creation). Caller holds `mu`. H2 session deinit
    /// performs no blocking I/O (socket close + allocator frees only),
    /// so destroying inline — like the plain-socket sweep's close —
    /// cannot stall borrowers.
    fn sweepH2Locked(self: *Pool, now: i64) void {
        var i: usize = 0;
        while (i < self.idleH2.items.len) {
            const c = &self.idleH2.items[i];
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const lifeExpired = self.cfg.maxParkedMs != 0 and
                now - c.createdAtMs > self.cfg.maxParkedMs;
            if (idleExpired or lifeExpired) {
                const stale = self.idleH2.swapRemove(i);
                _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
                stale.client.deinit();
                _ = self.stats.parkedNow.store(self.idle.items.len + self.idleH2.items.len, .monotonic);
                continue;
            }
            i += 1;
        }
    }

    /// Pop a healthy reusable connection for this origin, or null (miss).
    /// Lazily sweeps globally-expired entries first, so idle connections to
    /// cold origins do not sit ESTABLISHED past idleTimeoutMs/maxParkedMs.
    pub fn acquire(self: *Pool, host: []const u8, port: u16) ?tcp.Socket {
        const key = ConnKey.init(host, port) orelse {
            _ = self.stats.misses.fetchAdd(1, .monotonic);
            return null;
        };
        const now = clock.millisNow();
        self.mu.lock();
        defer self.mu.unlock();

        // Global lazy sweep (no background thread): drop expired entries for
        // ANY origin. Uses non-blocking close here — draining stale sockets
        // under the pool spinlock would stall all borrowers.
        self.sweepH2Locked(now);
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const c = &self.idle.items[i];
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const parkedExpired = self.cfg.maxParkedMs != 0 and
                now - c.parkedAtMs > self.cfg.maxParkedMs;
            if (idleExpired or parkedExpired or !c.socket.isAlive()) {
                const stale = self.idle.swapRemove(i);
                _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
                stale.socket.close();
                _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
                continue;
            }
            i += 1;
        }

        i = 0;
        while (i < self.idle.items.len) {
            const c = &self.idle.items[i];
            if (!c.key.eql(key)) {
                i += 1;
                continue;
            }
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const parkedExpired = self.cfg.maxParkedMs != 0 and
                now - c.parkedAtMs > self.cfg.maxParkedMs;
            if (idleExpired or parkedExpired or !c.socket.isAlive()) {
                const stale = self.idle.swapRemove(i);
                _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
                stale.socket.close();
                _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
                continue; // same index now holds a different entry
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

    /// Close everything immediately. Pops entries under lock, then closes
    /// outside the lock so a blocking drain never stalls other borrowers.
    pub fn purge(self: *Pool) void {
        self.mu.lock();
        const owned = self.idle.toOwnedSlice(self.allocator) catch &.{};
        self.idle.clearRetainingCapacity();
        const ownedH2 = self.idleH2.toOwnedSlice(self.allocator) catch &.{};
        self.idleH2.clearRetainingCapacity();
        _ = self.stats.parkedNow.store(0, .monotonic);
        self.mu.unlock();
        for (owned) |*c| {
            c.socket.drainThenClose();
        }
        if (owned.len > 0) self.allocator.free(owned);
        for (ownedH2) |*c| {
            c.client.deinit();
        }
        if (ownedH2.len > 0) self.allocator.free(ownedH2);
    }

    /// Drop stale/expired entries opportunistically (plain and H2).
    pub fn sweepExpired(self: *Pool) void {
        const now = clock.millisNow();
        self.mu.lock();
        self.sweepH2Locked(now);
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const c = &self.idle.items[i];
            const idleExpired = now - c.parkedAtMs > self.cfg.idleTimeoutMs;
            const parkedExpired = self.cfg.maxParkedMs != 0 and
                now - c.parkedAtMs > self.cfg.maxParkedMs;
            if (idleExpired or parkedExpired or !c.socket.isAlive()) {
                const stale = self.idle.swapRemove(i);
                _ = self.stats.droppedStale.fetchAdd(1, .monotonic);
                // Non-blocking close: never drain under the spinlock.
                stale.socket.close();
                _ = self.stats.parkedNow.store(self.idle.items.len, .monotonic);
            } else {
                i += 1;
            }
        }
        self.mu.unlock();
    }

    fn dropAt(self: *Pool, i: usize) void {
        const c = self.idle.items[i];
        // Caller holds mu: use non-blocking close to avoid stalling the pool.
        c.socket.close();
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

test "lazy sweep evicts expired idle connections without a reaper thread" {
    var ctx = tTcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var l = tTcp.Listener.bind(ctx.io, 0) catch return;
    const th = spawnEchoServer(&l, ctx.io, 1);
    defer l.close(ctx.io);
    defer th.join();

    const a = std.testing.allocator;
    // Negative idle timeout: every parked connection is instantly stale,
    // so the sweep is fully deterministic (no sleeps, no wall-clock race).
    var p = Pool.init(a, ctx.io, .{ .idleTimeoutMs = -1 });
    defer p.deinit();

    const port = l.localPort();
    p.release("127.0.0.1", port, tTcp.connect(ctx.io, "127.0.0.1", port) catch return);
    try std.testing.expectEqual(@as(usize, 1), p.parkedCount());

    p.sweepExpired();
    try std.testing.expectEqual(@as(usize, 0), p.parkedCount());
    const st = p.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.droppedStale);

    // A fresh acquire after the sweep misses (nothing reusable remains).
    try std.testing.expect(p.acquire("127.0.0.1", port) == null);
    const st2 = p.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st2.misses);
}
