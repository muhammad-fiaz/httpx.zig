# Connection Pool API

The `ConnectionPool` manages reusable TCP connections to improve throughput and reduce latency. The `Client` uses it internally, but you can also use it directly for custom implementations.

## ConnectionPool

### Initialization

```zig
const httpx = @import("httpx");

// Default configuration
var pool = httpx.ConnectionPool.init(allocator);
defer pool.deinit();

// Custom configuration
var pool = httpx.ConnectionPool.initWithConfig(allocator, .{
    .max_connections = 100,
    .max_per_host = 10,
    .idle_timeout_ms = 30_000,
    .max_requests_per_connection = 500,
});
defer pool.deinit();
```

### Methods

#### `getConnection`

Returns a healthy idle connection or opens a new one.

```zig
pub fn getConnection(
    self: *Self,
    host: []const u8,
    port: u16,
    proxy: ?Proxy,
    connect_timeout_ms: u64,
) !*Connection
```

Pass `0` for `connect_timeout_ms` to fall back to `PoolConfig.connect_timeout_ms`.

#### `releaseConnection`

Returns a connection to the pool after a request completes.

```zig
pub fn releaseConnection(self: *Self, conn: *Connection) void
```

#### `cleanup`

Evicts idle connections that have exceeded `PoolConfig.idle_timeout_ms` or `PoolConfig.max_requests_per_connection`.

```zig
pub fn cleanup(self: *Self) void
```

#### Statistics

| Method | Returns | Description |
|--------|---------|-------------|
| `activeCount()` | `usize` | Connections currently in use |
| `totalCount()` | `usize` | All connections tracked by the pool |
| `idleCount()` | `usize` | Available (not in-use) connections |
| `hostConnectionCount(host, port)` | `usize` | Connections for a specific host:port |
| `stats()` | `PoolStats` | Snapshot of total/active/idle counters |
| `closeConnection(conn)` | `void` | Close and remove a specific connection from the pool |

## PoolConfig

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_connections` | `u32` | `20` | Maximum total connections in the pool |
| `max_per_host` | `u32` | `5` | Maximum connections per host |
| `idle_timeout_ms` | `i64` | `60_000` | Idle time before a connection is evicted |
| `max_requests_per_connection` | `u32` | `1000` | Requests before a connection is retired |
| `health_check_interval_ms` | `i64` | `30_000` | Interval for health checks |
| `connect_timeout_ms` | `u64` | `30_000` | Default TCP connect timeout for new connections |

## PoolStats

Snapshot of pool counters returned by `pool.stats()`.

```zig
pub const PoolStats = struct {
    total: usize,   // All connections tracked
    active: usize,  // Currently in use
    idle: usize,    // Available for reuse
};
```

## Connection

Represents a single pooled TCP connection.

```zig
pub const Connection = struct {
    socket: Socket,
    host: []const u8,
    port: u16,
    proxy_host: ?[]const u8 = null,
    proxy_port: ?u16 = null,
    in_use: bool,
    created_at: i64,    // Unix timestamp (ms) when created
    last_used: i64,     // Unix timestamp (ms) of last acquire/release
    requests_made: u32, // Total requests served by this connection
};
```

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `acquire()` | `void` | Mark connection as in-use, update `last_used` |
| `release()` | `void` | Return to pool, increment `requests_made`, update `last_used` |
| `isHealthy(max_idle_ms)` | `bool` | True when socket is valid and idle time < `max_idle_ms` |
| `shouldEvict(idle_timeout_ms, max_requests)` | `bool` | True when socket is invalid, idle time exceeded, or request limit reached |
| `matches(host, port, proxy)` | `bool` | True when connection matches the given host/port/proxy tuple |
| `close()` | `void` | Close the underlying socket |

### Lifecycle

```
getConnection()
    ↓ calls acquire() internally
    ↓ returns *Connection
  [request executes]
releaseConnection(conn)
    ↓ calls release() internally
    ↓ returns conn to idle pool
```

## PoolError

```zig
pub const PoolError = error{
    PoolExhausted,        // Total connection limit reached
    PoolExhaustedForHost, // Per-host connection limit reached
};
```

## Direct Usage Example

```zig
const httpx = @import("httpx");

var pool = httpx.ConnectionPool.initWithConfig(allocator, .{
    .max_connections = 20,
    .max_per_host = 5,
    .idle_timeout_ms = 60_000,
    .max_requests_per_connection = 1000,
});
defer pool.deinit();

// Print configuration
std.debug.print("Max connections: {d}\n", .{pool.config.max_connections});
std.debug.print("Max per host:    {d}\n", .{pool.config.max_per_host});

// Print statistics
const s = pool.stats();
std.debug.print("Total: {d}  Active: {d}  Idle: {d}\n", .{
    s.total, s.active, s.idle,
});

// Manual connection lifecycle
const conn = try pool.getConnection("api.example.com", 443, null, 5_000);
// conn.acquire() was called internally
defer pool.releaseConnection(conn);

// Health check
const healthy = conn.isHealthy(60_000);
std.debug.print("Healthy: {}\n", .{healthy});

// Cleanup stale connections
pool.cleanup();
```

## See Also

- [Client API](client.md) — High-level client with built-in pooling
- [Pooling Guide](/guide/pooling) — Pooling configuration patterns
