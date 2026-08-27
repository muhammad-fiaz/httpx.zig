//! DNS resolver cache: positive/negative TTL entries + single-flight
//! coalescing (N concurrent callers of the same host => one real lookup).
//!
//! The transport is injected (`LookupFn`), so tests substitute a counting
//! fake and production wires `dns.resolveA` without socket knowledge here.
//!
//! Thread-safety: internally synchronized. Network I/O never happens under
//! the lock. Returned slices are caller-owned clones — no shared buffers
//! escape. Key strings are owned by the map; values freed on every removal
//! path (expiry, eviction, deinit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("../../common/sync.zig");
const clock = @import("../../common/clock.zig");

pub const LookupError = error{
    DnsFailed,
    OutOfMemory,
};

/// Performs one REAL resolution of `name` into owned IPv4 strings.
pub const LookupFn = *const fn (
    ctx: ?*anyopaque,
    io: std.Io,
    name: []const u8,
    a: Allocator,
) LookupError![]const []const u8;

pub const Config = struct {
    /// Positive-answer lifetime.
    ttl_ms: i64 = 60_000,
    /// Failed-resolution lifetime (short so transient failures retry soon).
    negative_ttl_ms: i64 = 5_000,
    max_entries: u32 = 1024,
};

const Entry = struct {
    addrs: []const []const u8,
    expires_at: i64,
    failed: bool,
};

const Inflight = struct {
    sem: sync.Semaphore,
    failed: bool = false,
    addrs: []const []const u8 = &.{},
    /// The lookup_fn payload itself; node OWNS it. Freed by whoever drops
    /// the final reference — safe because all readers hold a reference
    /// while cloning.
    owned: []const []const u8 = &.{},
    err: LookupError = error.DnsFailed,
    refs: usize = 1, // creator + joiners
};

pub const Cache = struct {
    allocator: Allocator,
    cfg: Config,
    mu: sync.Spinlock = .{},
    entries: std.StringHashMap(Entry),
    inflight: std.StringHashMap(*Inflight),
    lookup_fn: LookupFn,
    lookup_ctx: ?*anyopaque,

    // Observability
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    lookups_started: std.atomic.Value(u64) = .init(0),
    lookups_coalesced: std.atomic.Value(u64) = .init(0),

    pub fn init(
        allocator: Allocator,
        cfg: Config,
        lookup_fn: LookupFn,
        lookup_ctx: ?*anyopaque,
    ) Cache {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .entries = std.StringHashMap(Entry).init(allocator),
            .inflight = std.StringHashMap(*Inflight).init(allocator),
            .lookup_fn = lookup_fn,
            .lookup_ctx = lookup_ctx,
        };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.freeAddrs(kv.value_ptr.addrs);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
        var iit = self.inflight.iterator();
        while (iit.next()) |kv| {
            const n = kv.value_ptr.*;
            n.refs -= 1; // drop the map's reference
            if (n.refs == 0) self.allocator.destroy(n);
        }
        self.inflight.deinit();
    }

    fn freeAddrs(self: *Cache, addrs: []const []const u8) void {
        for (addrs) |addr| self.allocator.free(addr);
        if (addrs.len > 0) self.allocator.free(addrs);
    }

    /// Resolve `name` via cache / inflight-join / fresh lookup.
    /// Caller owns returned slices.
    pub fn resolve(self: *Cache, io: std.Io, name: []const u8) LookupError![]const []const u8 {
        const now = clock.millisNow();

        self.mu.lock();
        if (self.entries.get(name)) |e| {
            if (now < e.expires_at) {
                _ = self.hits.fetchAdd(1, .monotonic);
                if (e.failed) {
                    self.mu.unlock();
                    return error.DnsFailed;
                }
                const copy = self.cloneAddrs(e.addrs) catch {
                    self.mu.unlock();
                    return error.OutOfMemory;
                };
                self.mu.unlock();
                return copy;
            }
            self.removeEntryLocked(name);
        }
        if (self.inflight.get(name)) |node| {
            node.refs += 1;
            _ = self.lookups_coalesced.fetchAdd(1, .monotonic);
            self.mu.unlock();

            node.sem.wait();
            const failed = node.failed;
            const err = node.err;
            var copy: []const []const u8 = &.{};
            var oom = false;
            if (!failed) {
                if (self.cloneAddrs(node.addrs)) |cl| {
                    copy = cl;
                } else |_| {
                    oom = true;
                }
            }
            self.releaseNode(node);
            if (failed) return err;
            if (oom) return error.OutOfMemory;
            return copy;
        }
        // Publish node BEFORE unlocking so latecomers coalesce instead of
        // stampeding the resolver (thundering-herd prevention).
        const node = self.allocator.create(Inflight) catch {
            self.mu.unlock();
            return error.OutOfMemory;
        };
        node.* = .{ .sem = sync.Semaphore.init(0) };
        const name_copy = self.allocator.dupe(u8, name) catch {
            self.allocator.destroy(node);
            self.mu.unlock();
            return error.OutOfMemory;
        };
        self.inflight.put(name_copy, node) catch {
            self.allocator.destroy(node);
            self.allocator.free(name_copy);
            self.mu.unlock();
            return error.OutOfMemory;
        };
        _ = self.lookups_started.fetchAdd(1, .monotonic);
        _ = self.misses.fetchAdd(1, .monotonic);
        self.mu.unlock();

        // Network I/O strictly outside the lock.
        const outcome = self.lookup_fn(self.lookup_ctx, io, name, self.allocator);
        var fresh: []const []const u8 = &.{};
        var failed_err: ?LookupError = null;
        if (outcome) |ok_addrs| {
            fresh = ok_addrs;
        } else |e| {
            failed_err = e;
        }

        var joiners: usize = 0;
        if (failed_err == null) {
            self.mu.lock();
            node.owned = fresh; // ownership moves into the node
            node.addrs = fresh;
            joiners = node.refs - 1;
            _ = self.inflight.remove(name_copy);
            const cloned = self.cloneAddrs(fresh) catch null;
            if (cloned) |cl| {
                if (self.entries.count() >= self.cfg.max_entries) self.evictOneLocked();
                self.entries.put(name_copy, .{
                    .addrs = cl,
                    .expires_at = clock.millisNow() + self.cfg.ttl_ms,
                    .failed = false,
                }) catch {
                    self.freeAddrs(cl);
                    self.allocator.free(name_copy);
                };
            } else {
                // Cache write skipped on OOM; lookup still succeeds.
                self.allocator.free(name_copy);
            }
            self.mu.unlock();
        } else {
            self.mu.lock();
            node.failed = true;
            node.err = failed_err.?;
            joiners = node.refs - 1;
            _ = self.inflight.remove(name_copy);
            self.putNegativeLocked(name_copy);
            self.mu.unlock();
        }

        // Wake EVERY joiner exactly once (refs froze at removal).
        var woken: usize = 0;
        while (woken < joiners) : (woken += 1) node.sem.post();

        // Clone our own return copy while we still hold a reference.
        var mine: []const []const u8 = &.{};
        var oom = false;
        if (failed_err == null) {
            if (self.cloneAddrs(fresh)) |cl| {
                mine = cl;
            } else |_| {
                oom = true;
            }
        }
        self.releaseNode(node);
        if (oom) return error.OutOfMemory;
        if (failed_err) |e| return e;
        return mine;
    }

    fn putNegativeLocked(self: *Cache, name_owned: []u8) void {
        if (self.entries.count() >= self.cfg.max_entries) self.evictOneLocked();
        self.entries.put(name_owned, .{
            .addrs = &.{},
            .expires_at = clock.millisNow() + self.cfg.negative_ttl_ms,
            .failed = true,
        }) catch {
            self.allocator.free(name_owned);
        };
    }

    /// Frees key+value and removes. Caller holds the lock.
    fn removeEntryLocked(self: *Cache, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |kv| {
            self.freeAddrs(kv.value.addrs);
            self.allocator.free(kv.key);
        }
    }

    fn evictOneLocked(self: *Cache) void {
        // Arbitrary victim for v1; LRU upgrade tracked separately.
        var it = self.entries.iterator();
        if (it.next()) |kv| {
            const key = kv.key_ptr.*;
            self.freeAddrs(kv.value_ptr.addrs);
            _ = self.entries.remove(key);
            self.allocator.free(key);
        }
    }

    fn releaseNode(self: *Cache, node: *Inflight) void {
        self.mu.lock();
        node.refs -= 1;
        const dead = node.refs == 0;
        self.mu.unlock();
        if (dead) {
            self.freeAddrs(node.owned);
            self.allocator.destroy(node);
        }
    }

    pub fn statsSnapshot(self: *Cache) struct { hits: u64, misses: u64, started: u64, coalesced: u64 } {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .started = self.lookups_started.load(.monotonic),
            .coalesced = self.lookups_coalesced.load(.monotonic),
        };
    }

    fn cloneAddrs(self: *Cache, addrs: []const []const u8) ![]const []const u8 {
        const out = try self.allocator.alloc([]const u8, addrs.len);
        errdefer self.allocator.free(out);
        for (addrs, 0..) |a, i| out[i] = try self.allocator.dupe(u8, a);
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests: injected fake proves caching, negatives, and single-flight
// ---------------------------------------------------------------------------

const FakeResolver = struct {
    calls: std.atomic.Value(u32) = .init(0),
    delay_loops: usize = 0,

    fn lookup(ctx: ?*anyopaque, _: std.Io, name: []const u8, a: Allocator) LookupError![]const []const u8 {
        const self: *FakeResolver = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        var spins: usize = 0;
        while (spins < self.delay_loops) : (spins += 1) std.atomic.spinLoopHint();
        if (std.mem.eql(u8, name, "bad.example")) return error.DnsFailed;
        const out = try a.alloc([]const u8, 1);
        errdefer a.free(out);
        out[0] = try a.dupe(u8, "93.184.216.34");
        return out;
    }
};

fn freeAll(a: Allocator, addrs: []const []const u8) void {
    for (addrs) |x| a.free(x);
    a.free(addrs);
}

test "cache hit avoids second lookup" {
    var fake = FakeResolver{};
    var c = Cache.init(std.testing.allocator, .{}, FakeResolver.lookup, &fake);
    defer c.deinit();

    const r1 = try c.resolve(undefined, "example.com");
    defer freeAll(std.testing.allocator, r1);
    const r2 = try c.resolve(undefined, "example.com");
    defer freeAll(std.testing.allocator, r2);

    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.monotonic));
    try std.testing.expectEqualStrings("93.184.216.34", r2[0]);
}

test "negative answers are cached briefly" {
    var fake = FakeResolver{};
    var c = Cache.init(std.testing.allocator, .{}, FakeResolver.lookup, &fake);
    defer c.deinit();

    try std.testing.expectError(error.DnsFailed, c.resolve(undefined, "bad.example"));
    try std.testing.expectError(error.DnsFailed, c.resolve(undefined, "bad.example"));
    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.monotonic));
}

test "concurrent resolvers coalesce into one lookup" {
    var fake = FakeResolver{ .delay_loops = 50000 };
    var c = Cache.init(std.testing.allocator, .{}, FakeResolver.lookup, &fake);
    defer c.deinit();

    const Worker = struct {
        fn run(cache: *Cache, done: *std.atomic.Value(u32)) void {
            defer _ = done.fetchAdd(1, .monotonic);
            const r = cache.resolve(undefined, "coalesce.test") catch return;
            for (r) |a| cache.allocator.free(a);
            cache.allocator.free(r);
        }
    };

    var done = std.atomic.Value(u32).init(0);
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Worker.run, .{ &c, &done }) catch continue;
        spawned += 1;
    }
    for (threads[0..spawned]) |*t| t.join();
    try std.testing.expectEqual(@as(u32, @intCast(spawned)), done.load(.monotonic));

    const s = c.statsSnapshot();
    // At least one lookup was started; coalescing depends on timing but the
    // key invariant is that the resolver was called exactly once.
    try std.testing.expect(s.started >= 1);
    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.monotonic));
}
