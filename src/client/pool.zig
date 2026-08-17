//! HTTP Connection Pool for httpx.zig
//!
//! Provides connection pooling for HTTP clients:
//!
//! - Reusable TCP connections with keep-alive
//! - Per-host connection limits
//! - Automatic connection health checking
//! - Idle connection timeout and cleanup
//! - Thread-safe access via mutex

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const Socket = @import("../net/socket.zig").Socket;
const address_mod = @import("../net/address.zig");
const types = @import("../core/types.zig");
const proxy_mod = @import("proxy.zig");
const common = @import("../util/common.zig");
const dbg = @import("../util/debug.zig");
const Proxy = types.Proxy;

pub const PoolError = error{
    PoolExhausted,
    PoolExhaustedForHost,
};

/// Pooled connection representing a reusable socket.
pub const Connection = struct {
    socket: Socket,
    host: []const u8,
    port: u16,
    proxy_host: ?[]const u8 = null,
    proxy_port: ?u16 = null,
    in_use: bool = false,
    created_at: i64,
    last_used: i64,
    requests_made: u32 = 0,

    const Self = @This();

    /// Marks the connection as in use.
    pub fn acquire(self: *Self) void {
        self.in_use = true;
        self.last_used = common.nowMillis();
    }

    /// Releases the connection back to the pool.
    pub fn release(self: *Self) void {
        self.in_use = false;
        self.last_used = common.nowMillis();
        self.requests_made += 1;
    }

    /// Returns true if the connection is healthy and reusable.
    pub fn isHealthy(self: *const Self, max_idle_ms: i64) bool {
        if (self.in_use) return false;
        if (!self.socket.isValid()) return false;
        const idle_time = common.nowMillis() - self.last_used;
        return idle_time < max_idle_ms;
    }

    /// Returns true if this connection should be evicted from the pool.
    pub fn shouldEvict(self: *const Self, idle_timeout_ms: i64, max_requests_per_connection: u32) bool {
        if (self.in_use) return false;
        if (!self.socket.isValid()) return true;
        if (self.requests_made >= max_requests_per_connection) return true;
        const idle_time = common.nowMillis() - self.last_used;
        return idle_time >= idle_timeout_ms;
    }

    /// Returns true if this connection matches the given host/port/proxy.
    pub fn matches(self: *const Self, host: []const u8, port: u16, proxy: ?Proxy) bool {
        if (!std.mem.eql(u8, self.host, host) or self.port != port) return false;
        if (proxy) |p| {
            if (self.proxy_host) |ph| {
                if (!std.mem.eql(u8, ph, p.host)) return false;
                if (self.proxy_port != p.port) return false;
            } else {
                return false;
            }
        } else if (self.proxy_host != null) {
            return false;
        }
        return true;
    }

    /// Closes the underlying socket.
    pub fn close(self: *Self) void {
        self.socket.close();
    }
};

/// Connection pool configuration.
pub const PoolConfig = struct {
    max_connections: u32 = 20,
    max_per_host: u32 = 5,
    idle_timeout_ms: i64 = 60_000,
    max_requests_per_connection: u32 = 1000,
    health_check_interval_ms: i64 = 30_000,
    connect_timeout_ms: u64 = 30_000,
};

/// Snapshot statistics for the connection pool.
pub const PoolStats = struct {
    total: usize,
    active: usize,
    idle: usize,
};

/// HTTP connection pool with thread-safe access.
pub const ConnectionPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    connections: std.ArrayList(Connection) = .empty,
    lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Self = @This();

    fn acquireLock(self: *Self) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn releaseLock(self: *Self) void {
        self.lock.store(0, .release);
    }

    /// Creates a new connection pool.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates a connection pool with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: PoolConfig) Self {
        dbg.entry("POOL", "initWithConfig");
        defer dbg.exit("POOL", "initWithConfig");
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Releases all pool resources.
    pub fn deinit(self: *Self) void {
        dbg.entry("POOL", "deinit");
        defer dbg.exit("POOL", "deinit");
        self.acquireLock();
        defer self.releaseLock();
        for (self.connections.items) |*conn| {
            conn.close();
            self.allocator.free(conn.host);
            if (conn.proxy_host) |ph| self.allocator.free(ph);
        }
        self.connections.deinit(self.allocator);
    }

    /// Gets or creates a connection to the specified host.
    pub fn getConnection(self: *Self, host: []const u8, port: u16, proxy: ?Proxy, connect_timeout_ms: u64) !*Connection {
        dbg.entry("POOL", "getConnection");
        defer dbg.exit("POOL", "getConnection");
        dbg.log("POOL", "acquiring lock...", .{});
        self.acquireLock();
        dbg.log("POOL", "lock acquired", .{});
        defer self.releaseLock();

        for (self.connections.items) |*conn| {
            if (conn.matches(host, port, proxy)) {
                if (conn.isHealthy(self.config.idle_timeout_ms) and conn.requests_made < self.config.max_requests_per_connection) {
                    dbg.log("POOL", "reusing connection to {s}:{d}", .{ host, port });
                    conn.acquire();
                    return conn;
                }
            }
        }

        if (self.totalCountLocked() >= self.config.max_connections) return PoolError.PoolExhausted;

        var host_count: u32 = 0;
        for (self.connections.items) |conn| {
            if (conn.matches(host, port, proxy)) host_count += 1;
        }
        if (host_count >= self.config.max_per_host) return PoolError.PoolExhaustedForHost;

        return self.createConnection(host, port, proxy, connect_timeout_ms);
    }

    /// Creates a new connection.
    fn createConnection(self: *Self, host: []const u8, port: u16, proxy: ?Proxy, connect_timeout_ms: u64) !*Connection {
        dbg.entry("POOL", "createConnection");
        defer dbg.exit("POOL", "createConnection");
        const host_owned = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_owned);

        const connect_host = if (proxy) |p| p.host else host;
        const connect_port = if (proxy) |p| p.port else port;
        const addr = try address_mod.resolve(self.allocator, connect_host, connect_port);

        var socket = try Socket.createForAddress(addr);
        errdefer socket.close();
        try socket.connectWithTimeout(addr, if (connect_timeout_ms > 0) connect_timeout_ms else self.config.connect_timeout_ms);

        if (proxy) |p| {
            if (p.kind == .socks5h) {
                try proxy_mod.establishSocks5hTunnel(&socket, host, port, p);
            }
        }

        const now = common.nowMillis();

        const proxy_host_owned: ?[]const u8 = if (proxy) |p| try self.allocator.dupe(u8, p.host) else null;

        self.connections.append(self.allocator, .{
            .socket = socket,
            .host = host_owned,
            .port = port,
            .proxy_host = proxy_host_owned,
            .proxy_port = if (proxy) |p| p.port else null,
            .in_use = true,
            .created_at = now,
            .last_used = now,
        }) catch {
            if (proxy_host_owned) |ph| self.allocator.free(ph);
            return error.OutOfMemory;
        };

        return &self.connections.items[self.connections.items.len - 1];
    }

    /// Releases a connection back to the pool.
    pub fn releaseConnection(self: *Self, conn: *Connection) void {
        dbg.entry("POOL", "releaseConnection");
        defer dbg.exit("POOL", "releaseConnection");
        self.acquireLock();
        defer self.releaseLock();
        conn.release();
    }

    /// Marks a connection as closed and removes it from the pool.
    pub fn closeConnection(self: *Self, conn: *Connection) void {
        dbg.entry("POOL", "closeConnection");
        defer dbg.exit("POOL", "closeConnection");
        self.acquireLock();
        defer self.releaseLock();
        conn.close();
        self.allocator.free(conn.host);
        if (conn.proxy_host) |ph| self.allocator.free(ph);
        // Find and remove the connection
        for (self.connections.items, 0..) |*c, i| {
            if (std.meta.eql(c.socket, conn.socket)) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    /// Removes idle connections that have exceeded the timeout.
    pub fn cleanup(self: *Self) void {
        self.acquireLock();
        defer self.releaseLock();
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];
            if (conn.shouldEvict(self.config.idle_timeout_ms, self.config.max_requests_per_connection)) {
                conn.close();
                self.allocator.free(conn.host);
                if (conn.proxy_host) |ph| self.allocator.free(ph);
                _ = self.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Returns the number of active connections.
    pub fn activeCount(self: *Self) usize {
        self.acquireLock();
        defer self.releaseLock();
        var count: usize = 0;
        for (self.connections.items) |conn| {
            if (conn.in_use) count += 1;
        }
        return count;
    }

    /// Returns the total number of connections.
    fn totalCountLocked(self: *Self) usize {
        return self.connections.items.len;
    }

    fn idleCountLocked(self: *Self) usize {
        var active: usize = 0;
        for (self.connections.items) |conn| {
            if (conn.in_use) active += 1;
        }
        return self.connections.items.len - active;
    }

    fn hostConnectionCountLocked(self: *Self, host: []const u8, port: u16) usize {
        var count: usize = 0;
        for (self.connections.items) |conn| {
            if (std.mem.eql(u8, conn.host, host) and conn.port == port) {
                count += 1;
            }
        }
        return count;
    }

    fn statsLocked(self: *Self) PoolStats {
        var active: usize = 0;
        for (self.connections.items) |conn| {
            if (conn.in_use) active += 1;
        }
        const total = self.connections.items.len;
        return .{ .total = total, .active = active, .idle = total - active };
    }

    pub fn totalCount(self: *Self) usize {
        self.acquireLock();
        defer self.releaseLock();
        return self.totalCountLocked();
    }

    pub fn idleCount(self: *Self) usize {
        self.acquireLock();
        defer self.releaseLock();
        return self.idleCountLocked();
    }

    pub fn hostConnectionCount(self: *Self, host: []const u8, port: u16) usize {
        self.acquireLock();
        defer self.releaseLock();
        return self.hostConnectionCountLocked(host, port);
    }

    pub fn stats(self: *Self) PoolStats {
        self.acquireLock();
        defer self.releaseLock();
        return self.statsLocked();
    }
};

test "ConnectionPool initialization" {
    const allocator = std.testing.allocator;
    var pool = ConnectionPool.init(allocator);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.totalCount());
}

test "ConnectionPool config" {
    const allocator = std.testing.allocator;
    var pool = ConnectionPool.initWithConfig(allocator, .{
        .max_connections = 50,
        .max_per_host = 10,
    });
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 50), pool.config.max_connections);
    try std.testing.expectEqual(@as(u32, 10), pool.config.max_per_host);
}

test "Connection health check" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var conn = Connection{
        .socket = try Socket.create(),
        .host = "localhost",
        .port = 8080,
        .created_at = common.nowMillis(),
        .last_used = common.nowMillis(),
    };
    defer conn.socket.close();

    try std.testing.expect(conn.isHealthy(60_000));

    conn.in_use = true;
    try std.testing.expect(!conn.isHealthy(60_000));
}

test "ConnectionPool stats helpers" {
    const allocator = std.testing.allocator;
    var pool = ConnectionPool.init(allocator);
    defer pool.deinit();

    const s = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.active);
    try std.testing.expectEqual(@as(usize, 0), s.idle);
    try std.testing.expectEqual(@as(usize, 0), pool.hostConnectionCount("httpbun.com", 443));
}
