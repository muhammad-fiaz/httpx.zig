# DNS Cache Example

Demonstrates HTTPX's thread-safe in-memory DNS caching subsystem with positive/negative TTL and single-flight stampede prevention.

## How DNS Caching Works

1. **Automatic Client Caching**: By default, `httpx.Client` initializes an internal `Cache` that caches successful lookups for 60,000 ms (60 seconds) and failed lookups for 5,000 ms (5 seconds).
2. **Single-Flight Coalescing**: If 50 concurrent requests simultaneously need to resolve `httpbun.com`, only **one** real DNS query is dispatched to the network. The other 49 callers await the result and receive clones, preventing cache stampedes.
3. **Thread Safety**: Internally synchronized via spinlocks. Network I/O is never performed while holding locks.
4. **Memory Bounds**: Entries are bounded by `maxEntries` (default: 1024) to prevent memory exhaustion.

## High-Level Usage via Client

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Initialize client with custom cache settings
    var client = httpx.Client.init(allocator, io, .{
        .dnsCache = .{
            .enable = true,
            .ttlMs = 120_000,         // 2 minutes positive TTL
            .negativeTtlMs = 3_000,  // 3 seconds negative TTL
            .maxEntries = 2048,
        },
    });
    defer client.deinit();

    // First lookup: queries DNS and populates cache
    var addrs1 = try client.resolve("httpbun.com", 443, .{});
    defer addrs1.deinit();

    // Second lookup: served instantly from cache
    var addrs2 = try client.resolve("httpbun.com", 443, .{});
    defer addrs2.deinit();

    // Force fresh lookup bypassing cache
    var fresh = try client.resolve("httpbun.com", 443, .{ .use_cache = false });
    defer fresh.deinit();
}
```

## Advanced Direct Cache API

For specialized network applications, the standalone cache in `src/net/dns/cache.zig` can be used directly:

```zig
const cache_mod = @import("httpx").dnsCache; // or @import("src/net/dns/cache.zig")
```

The cache exposes atomic observability counters:
* `hits`: Number of lookups satisfied from cache.
* `misses`: Number of lookups that required network I/O.
* `lookups_started`: Number of network lookups initiated.
* `lookups_coalesced`: Number of concurrent requests joined to an in-flight lookup.

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: DNS Configuration](/examples/dns-configuration)
