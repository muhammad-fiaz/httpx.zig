# DNS Cache

Demonstrates DNS cache operations: insert, lookup, invalidation, statistics, and expiration.

## Demo Program

```zig
const cache = httpx.dns.DnsCache.init(allocator);

// Insert entries
try cache.put("example.com", 80, &.{address}, 60000);

// Lookup
if (cache.get("example.com", 80)) |entry| { ... }

// Invalidate
cache.invalidate("example.com", 80);

// Statistics
const stats = cache.stats();

// Clear all
cache.clear();
```

## Run

```
zig build run-all-dns_cache
```

## Checklist

- [x] Cache insert and lookup
- [x] Cache invalidation
- [x] Cache statistics (hits, misses, evictions)
- [x] Cache clear
- [x] TTL-based expiration
