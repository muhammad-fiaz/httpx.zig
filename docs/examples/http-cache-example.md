# HTTP Cache

Demonstrates HTTP caching with CacheControl, HttpCache, and ConditionalGet (ETag).

## Demo Program

```zig
// Cache-Control header parsing
const cc = httpx.CacheControl.parse("max-age=3600, must-revalidate");

// HTTP cache with ETag
var cache = httpx.HttpCache.init(allocator);
try cache.put("/api/data", etag, body);

// Conditional GET
if (cache.get("/api/data")) |entry| {
    if (entry.matches(etag)) return .not_modified;
}
```

## Run

```
zig build run-all-http_cache_example
```

## Checklist

- [x] Cache-Control header parsing
- [x] ETag generation and matching
- [x] Conditional GET (304 Not Modified)
- [x] Cache invalidation
