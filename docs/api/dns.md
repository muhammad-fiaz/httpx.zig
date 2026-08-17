# DNS API

The `httpx.dns` module provides a thread-safe in-memory DNS resolution cache with TTL tracking, negative caching, eviction, and observability statistics. It wraps `std.net.getAddressList` and caches resolved addresses to avoid repeated DNS lookups.

## Types

### `DnsCache`

A thread-safe DNS resolution cache.

```zig
pub const DnsCache = struct {
    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(DnsEntry) = .{},
    lock: std.Io.Mutex = .init,
    default_ttl_ms: i64 = 60_000,
    negative_ttl_ms: i64 = 5_000,
    max_entries: u32 = 0,
    stats: DnsStats = .{},
};
```

### `DnsEntry`

A cached DNS resolution entry.

```zig
pub const DnsEntry = struct {
    address: net.Address,
    expires_at_ms: i64,
    failed: bool = false,
};
```

### `DnsStats`

Cache statistics for observability.

```zig
pub const DnsStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    failures: u64 = 0,
    evictions: u64 = 0,
};
```

| Method | Returns | Description |
|--------|---------|-------------|
| `hitRate()` | `f64` | Cache hit ratio (0.0 to 1.0) |

## Methods

### `DnsCache.init`

Creates a new DNS cache with default 60-second TTL.

```zig
pub fn init(allocator: Allocator) DnsCache
```

### `DnsCache.deinit`

Frees all cached entries and the cache structure.

```zig
pub fn deinit(self: *DnsCache) void
```

### `DnsCache.resolve`

Resolves a hostname to an address, using the cache when the entry is still valid. On cache miss, performs a system DNS lookup and stores the result. Failed lookups are cached briefly (5 seconds by default) to prevent repeated DNS hammering.

```zig
pub fn resolve(self: *DnsCache, host: []const u8, port: u16) !net.Address
```

Returns `error.DnsLookupFailed` if the cached entry represents a failed resolution.

### `DnsCache.evictExpired`

Removes all expired entries from the cache. Safe to call periodically to free memory.

```zig
pub fn evictExpired(self: *DnsCache) void
```

### `DnsCache.count`

Returns the number of cached entries.

```zig
pub fn count(self: *DnsCache) u32
```

### `DnsCache.clear`

Removes all cached entries (expired or not).

```zig
pub fn clear(self: *DnsCache) void
```

### `DnsCache.getStats`

Returns a snapshot of cache statistics.

```zig
pub fn getStats(self: *DnsCache) DnsStats
```

## Usage

```zig
const httpx = @import("httpx");

var dns_cache = httpx.DnsCache.init(allocator);
defer dns_cache.deinit();

// First call performs a real DNS lookup
const addr1 = try dns_cache.resolve("example.com", 443);

// Second call within TTL returns the cached address
const addr2 = try dns_cache.resolve("example.com", 443);

// Check cache hit rate
const stats = dns_cache.getStats();
std.debug.print("hit rate: {d:.1}%\n", .{stats.hitRate() * 100});
```

## Configuration

```zig
var dns_cache = httpx.DnsCache.init(allocator);
defer dns_cache.deinit();

dns_cache.default_ttl_ms = 300_000;    // 5 minutes for positive lookups
dns_cache.negative_ttl_ms = 10_000;    // 10 seconds for failed lookups
dns_cache.max_entries = 1000;          // Evict oldest when full
```

## Negative Caching

Failed DNS lookups are cached for `negative_ttl_ms` (default 5 seconds) to prevent repeated hammering of invalid hostnames. The `DnsEntry.failed` field distinguishes positive from negative cache entries.

## Eviction

When `max_entries > 0`, the cache evicts the oldest entry before inserting a new one when the cache is full. Call `evictExpired()` periodically to clean up expired entries without waiting for lookups.

## Thread Safety

`DnsCache` uses a mutex to protect concurrent access. Multiple threads can safely call `resolve` on the same cache instance.
