# Connection Pool API

The `ConnectionPool` manages reusable TCP connections to optimize performance. While the `Client` uses this internally, you can use it directly for custom implementations.

## ConnectionPool

### Initialization

```zig
const httpx = @import("httpx");

// Initialize with default configuration
var pool = httpx.ConnectionPool.init(allocator);
defer pool.deinit();

// Initialize with custom configuration
var pool = httpx.ConnectionPool.initWithConfig(allocator, .{
    .max_connections = 100,
    .max_per_host = 10,
});
```

### methods

#### `getConnection`

Gets an existing healthy connection or creates a new one.

```zig
pub fn getConnection(self: *Self, host: []const u8, port: u16) !*Connection
```

#### `releaseConnection`

Returns a connection to the pool.

```zig
pub fn releaseConnection(self: *Self, conn: *Connection) void
```

#### `cleanup`

Removes idle connections that have exceeded the timeout.

```zig
pub fn cleanup(self: *Self) void
```

#### Statistics

- `activeCount() usize`: Number of connections currently in use.
- `totalCount() usize`: Total connections managed by the pool.
- `idleCount() usize`: Number of available connections.
- `hostConnectionCount(host, port) usize`: Connections tracked for a specific host/port.
- `stats() PoolStats`: Snapshot of total/active/idle counters.

### PoolStats

```zig
pub const PoolStats = struct {
    total: usize,
    active: usize,
    idle: usize,
};
```

## PoolConfig

Configuration options for the connection pool.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_connections` | `u32` | `20` | Maximum total connections in the pool. |
| `max_per_host` | `u32` | `5` | Maximum connections allowed per host. |
| `idle_timeout_ms` | `i64` | `60_000` | Time before an idle connection is closed. |
| `max_requests_per_connection` | `u32` | `1000` | Max requests before a connection is retired. |
| `health_check_interval_ms` | `i64` | `30_000` | Interval for checking connection health. |

## Connection

Represents a pooled TCP connection.

```zig
pub const Connection = struct {
    socket: Socket,
    host: []const u8,
    port: u16,
    in_use: bool,
    created_at: i64,
    last_used: i64,
    requests_made: u32,
};
```

### Methods

- `isHealthy(max_idle_ms: i64) bool`: Checks if the connection is valid and not timed out.
- `close()`: Closes the underlying socket.
