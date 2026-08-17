//! Server-Side Session Store for httpx.zig
//!
//! Provides a simple in-memory session store with automatic expiry.
//! Sessions are identified by a random session ID stored in a cookie.
//!
//! ## Features
//! - Thread-safe insert/get/delete via mutex
//! - Automatic TTL-based expiry
//! - Session ID generation using std.Io random
//! - Per-session arbitrary string key/value data
//!
//! ## Usage
//! ```zig
//! var store = httpx.SessionStore.init(allocator, .{ .ttl_ms = 30 * 60 * 1000 });
//! defer store.deinit();
//!
//! // On login:
//! const sid = try store.create();
//! try store.set(sid, "user_id", "42");
//!
//! // On request:
//! if (try store.get(sid, "user_id")) |uid| {
//!     std.debug.print("user={s}\n", .{uid});
//! }
//!
//! // On logout:
//! store.delete(sid);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const io_util = @import("any_io.zig");
const defaultIo = io_util.defaultIo;
const threadIo = io_util.threadIo;
const common = @import("common.zig");
const dbg = @import("debug.zig");

pub const SESSION_ID_LEN = 32;
pub const DEFAULT_TTL_MS: u64 = 30 * 60 * 1000; // 30 minutes

/// Session store configuration.
pub const SessionConfig = struct {
    /// Session time-to-live in milliseconds.
    ttl_ms: u64 = DEFAULT_TTL_MS,
    /// Cookie name used to store the session ID.
    cookie_name: []const u8 = "session_id",
    /// Maximum number of sessions to hold (0 = unlimited).
    max_sessions: usize = 0,
};

/// A single session entry.
pub const Session = struct {
    id: [SESSION_ID_LEN]u8,
    data: std.StringHashMap([]u8),
    created_at_ms: i64,
    last_accessed_ms: i64,
    allocator: Allocator,

    const Self = @This();

    fn init(allocator: Allocator, id: [SESSION_ID_LEN]u8, now_ms: i64) Self {
        return .{
            .id = id,
            .data = std.StringHashMap([]u8).init(allocator),
            .created_at_ms = now_ms,
            .last_accessed_ms = now_ms,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    fn isExpired(self: *const Self, now_ms: i64, ttl_ms: u64) bool {
        const age = now_ms - self.last_accessed_ms;
        return @as(u64, @intCast(@max(0, age))) > ttl_ms;
    }
};

/// Thread-safe in-memory session store.
pub const SessionStore = struct {
    allocator: Allocator,
    config: SessionConfig,
    sessions: std.HashMap([SESSION_ID_LEN]u8, Session, SessionIdContext, 80),
    mutex: std.Io.Mutex = .init,

    const Self = @This();
    const SessionIdContext = struct {
        pub fn hash(_: @This(), key: [SESSION_ID_LEN]u8) u64 {
            return std.hash.Fnv1a_64.hash(&key);
        }
        pub fn eql(_: @This(), a: [SESSION_ID_LEN]u8, b: [SESSION_ID_LEN]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    fn lock(self: *Self) void {
        const io = threadIo();
        self.mutex.lock(io) catch unreachable;
    }

    fn unlock(self: *Self) void {
        const io = threadIo();
        self.mutex.unlock(io);
    }

    /// Creates a new SessionStore.
    pub fn init(allocator: Allocator, config: SessionConfig) Self {
        dbg.entry("SESSION", "SessionStore.init");
        dbg.exit("SESSION", "SessionStore.init");
        return .{
            .allocator = allocator,
            .config = config,
            .sessions = std.HashMap([SESSION_ID_LEN]u8, Session, SessionIdContext, 80).init(allocator),
        };
    }

    /// Releases all resources.
    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.sessions.deinit();
    }

    /// Creates a new session and returns its ID as a hex string.
    pub fn create(self: *Self) ![SESSION_ID_LEN * 2]u8 {
        self.lock();
        defer self.unlock();

        var raw: [SESSION_ID_LEN]u8 = undefined;
        defaultIo().random(&raw);

        const session = Session.init(self.allocator, raw, common.nowMillis());
        try self.sessions.put(raw, session);

        return std.fmt.bytesToHex(raw, .lower);
    }

    fn parseId(hex_id: []const u8) ?[SESSION_ID_LEN]u8 {
        if (hex_id.len != SESSION_ID_LEN * 2) return null;
        var raw: [SESSION_ID_LEN]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, hex_id) catch return null;
        return raw;
    }

    /// Sets a key/value pair in the session. Value is duplicated.
    pub fn set(self: *Self, hex_id: []const u8, key: []const u8, value: []const u8) !void {
        dbg.entry("SESSION", "SessionStore.set");
        self.lock();
        defer self.unlock();

        const raw = parseId(hex_id) orelse return error.InvalidSessionId;
        const entry = self.sessions.getPtr(raw) orelse return error.SessionNotFound;
        if (entry.isExpired(common.nowMillis(), self.config.ttl_ms)) {
            entry.deinit();
            _ = self.sessions.remove(raw);
            return error.SessionExpired;
        }

        const duped = try self.allocator.dupe(u8, value);
        const old = try entry.data.fetchPut(key, duped);
        if (old) |o| self.allocator.free(o.value);
        entry.last_accessed_ms = common.nowMillis();
        dbg.exit("SESSION", "SessionStore.set");
    }

    /// Gets a value from the session. Returns null if not found or expired.
    /// Caller owns the returned slice and must free it with the allocator.
    pub fn get(self: *Self, hex_id: []const u8, key: []const u8) ?[]const u8 {
        self.lock();
        defer self.unlock();

        const raw = parseId(hex_id) orelse return null;
        const entry = self.sessions.getPtr(raw) orelse return null;
        if (entry.isExpired(common.nowMillis(), self.config.ttl_ms)) {
            entry.deinit();
            _ = self.sessions.remove(raw);
            return null;
        }
        entry.last_accessed_ms = common.nowMillis();
        const value = entry.data.get(key) orelse return null;
        return self.allocator.dupe(u8, value) catch null;
    }

    /// Deletes a session.
    pub fn delete(self: *Self, hex_id: []const u8) void {
        dbg.entry("SESSION", "SessionStore.delete");
        self.lock();
        defer self.unlock();

        const raw = parseId(hex_id) orelse return;
        if (self.sessions.getPtr(raw)) |entry| {
            entry.deinit();
        }
        _ = self.sessions.remove(raw);
        dbg.exit("SESSION", "SessionStore.delete");
    }

    /// Returns true if the session exists and is not expired.
    pub fn exists(self: *Self, hex_id: []const u8) bool {
        self.lock();
        defer self.unlock();

        const raw = parseId(hex_id) orelse return false;
        const entry = self.sessions.getPtr(raw) orelse return false;
        if (entry.isExpired(common.nowMillis(), self.config.ttl_ms)) {
            entry.deinit();
            _ = self.sessions.remove(raw);
            return false;
        }
        return true;
    }

    /// Removes all expired sessions. Call periodically for cleanup.
    pub fn evictExpired(self: *Self) usize {
        self.lock();
        defer self.unlock();

        const now = common.nowMillis();
        var to_remove = std.ArrayList([SESSION_ID_LEN]u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired(now, self.config.ttl_ms)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.getPtr(key)) |s| s.deinit();
            _ = self.sessions.remove(key);
        }

        return to_remove.items.len;
    }

    /// Returns the number of active sessions.
    pub fn count(self: *Self) usize {
        self.lock();
        defer self.unlock();
        return self.sessions.count();
    }
};

test "SessionStore create and get" {
    const allocator = std.testing.allocator;
    var store = SessionStore.init(allocator, .{});
    defer store.deinit();

    const id = try store.create();
    try store.set(&id, "user", "alice");
    const val = store.get(&id, "user");
    try std.testing.expect(val != null);
    defer allocator.free(val.?);
    try std.testing.expectEqualStrings("alice", val.?);

    store.delete(&id);
    try std.testing.expect(!store.exists(&id));
}

test "SessionStore evict expired" {
    const allocator = std.testing.allocator;
    var store = SessionStore.init(allocator, .{ .ttl_ms = 1 }); // 1ms TTL
    defer store.deinit();

    _ = try store.create();
    const evicted = store.evictExpired();
    try std.testing.expect(evicted >= 1);
}
