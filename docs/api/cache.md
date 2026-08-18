# Cache API

HTTP caching with LRU eviction, TTL expiry, and conditional GET support.

Located in `src/cache/`.

## HttpCache

Thread-safe LRU in-memory HTTP cache with TTL expiry.

| Method | Returns | Description |
|--------|---------|-------------|
| `init(allocator, config)` | `HttpCache` | Create a cache with the given config |
| `deinit()` | `void` | Release all resources |
| `get(key)` | `?CacheEntry` | Get a cached entry; returns null if not found or expired |
| `put(key, entry)` | `void` | Store an entry in the cache |
| `remove(key)` | `bool` | Remove an entry; returns true if it existed |
| `clear()` | `void` | Clear all entries |
| `count()` | `usize` | Number of entries in the cache |
| `stats()` | `CacheStats` | Get cache statistics (hits, misses, evictions) |

## CacheConfig

| Field | Default | Description |
|-------|---------|-------------|
| `max_entries` | `1024` | Maximum number of cached entries |
| `default_ttl_ms` | `300_000` | Default TTL in milliseconds (5 minutes) |
| `evict_on_full` | `true` | Whether to evict LRU entry when cache is full |

## CacheEntry

| Field | Type | Description |
|-------|------|-------------|
| `status` | `u16` | HTTP status code |
| `headers` | `[]const u8` | Raw response headers |
| `body` | `[]const u8` | Response body |
| `created_at` | `u64` | Timestamp when entry was created |
| `expires_at` | `u64` | Timestamp when entry expires |

## CacheStats

| Field | Type | Description |
|-------|------|-------------|
| `hits` | `u64` | Cache hits |
| `misses` | `u64` | Cache misses |
| `evictions` | `u64` | Entries evicted |

## ConditionalGet

ETag/If-None-Match conditional GET support.

- `checkNotModified(etag, if_none_match)` — returns true if the resource has not been modified
- `generateEtag(body)` — generate an ETag from response body

Root-level aliases: `httpx.HttpCache`, `httpx.CacheConfig`, `httpx.CacheEntry`, `httpx.ConditionalGet`.
