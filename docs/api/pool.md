# Connection Pool API

The `ConnectionPool` (`httpx.pool.Pool`, re-exported as `httpx.ConnectionPool`) reuses plain-TCP keep-alive connections. The `Client` uses it internally, but you can also use it directly.

## PoolConfig

```zig
pub const PoolConfig = struct {
    maxConnections: u32 = 256,
    maxPerHost: u16 = 16,
    idleTimeoutMs: i64 = 30_000,
    maxParkedMs: i64 = 300_000,
};
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `maxConnections` | `u32` | `256` | Hard ceiling across all origins |
| `maxPerHost` | `u16` | `16` | Ceiling per origin |
| `idleTimeoutMs` | `i64` | `30_000` | Parked connections older than this are dropped |
| `maxParkedMs` | `i64` | `300_000` | Max time a connection may stay parked. 0 disables |

## Pool

```zig
var pool = httpx.ConnectionPool.init(allocator, io, .{
    .maxConnections = 100,
    .maxPerHost = 10,
    .idleTimeoutMs = 30_000,
});
defer pool.deinit();
```

| Method | Description |
|--------|-------------|
| `init(allocator, io, cfg)` | Create a pool |
| `deinit()` | Purge all parked connections |
| `acquire(host, port)` | Pop a healthy reusable connection, or `null` on miss |
| `canPark(host, port)` | True when another connection may still be parked for this origin |
| `release(host, port, socket)` | Return a healthy connection for reuse (drops it when caps hit) |
| `purge()` | Close everything immediately |
| `sweepExpired()` | Drop stale/expired entries opportunistically |
| `parkedCount()` | Number of currently parked connections |
| `statsSnapshot()` | Copy of pool counters |

## Snapshot / Stats

```zig
pub const Snapshot = struct {
    hits: u64,
    misses: u64,
    released: u64,
    parkedNow: u64,
    droppedStale: u64,
    droppedLimit: u64,
};
```

Use `pool.statsSnapshot()` for observability. `Stats.snapshot()` returns the same shape.

## Direct Usage Example

```zig
const httpx = @import("httpx");

var pool = httpx.ConnectionPool.init(allocator, io, .{
    .maxConnections = 20,
    .maxPerHost = 5,
    .idleTimeoutMs = 60_000,
});
defer pool.deinit();

// Print statistics
const s = pool.statsSnapshot();
std.debug.print("hits={d} misses={d} parked={d}\n", .{ s.hits, s.misses, s.parkedNow });

// Drop expired entries without destroying the pool
pool.sweepExpired();
```

## See Also

- [Client API](client.md) — High-level client with built-in pooling
- [Pooling Guide](/guide/pooling) — Pooling configuration patterns
