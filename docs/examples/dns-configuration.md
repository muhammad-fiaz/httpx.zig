# DNS Configuration Example

Demonstrates DNS configuration in HTTPX: cache sizing, TTL tuning, negative caching, address-family preferences, and reusable Client integration.

## Client-Wide DNS Configuration

DNS cache settings that apply across all requests are configured on `Client.init`:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Configure client with custom DNS cache settings
    var client = httpx.Client.init(allocator, io, .{
        .dnsCache = .{
            .enable = true,
            .ttlMs = 30_000,          // 30 seconds positive TTL
            .negativeTtlMs = 2_000,  // 2 seconds negative TTL (failed queries)
            .maxEntries = 512,        // Maximum LRU entries
        },
    });
    defer client.deinit();

    // 2. Dual-stack lookup using client defaults (.{})
    var addrs = try client.resolve("httpbun.com", 443, .{});
    defer addrs.deinit();

    std.debug.print("Resolved {d} address(es):\n", .{addrs.len()});
    for (addrs.items) |addr| {
        std.debug.print("  {f}:{d}\n", .{ addr, addr.port });
    }

    // 3. Per-lookup address family override
    var v4_only = try client.resolve("httpbun.com", 443, .{
        .family = .ipv4,
        .useCache = true,
    });
    defer v4_only.deinit();

    std.debug.print("\nIPv4 addresses:\n", .{});
    for (v4_only.items) |addr| {
        std.debug.print("  {f}:{d}\n", .{ addr, addr.port });
    }
}
```

## Configuration Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `.dnsCache.enabled` | `bool` | `true` | Enables thread-safe in-memory resolution caching |
| `.dnsCache.ttlMs` | `i64` | `60_000` (60s) | Cache lifetime for successful resolutions |
| `.dnsCache.negativeTtlMs` | `i64` | `5_000` (5s) | Cache lifetime for failed host resolutions |
| `.dnsCache.maxEntries` | `u32` | `1024` | Maximum bounded entries before eviction |

## Per-Lookup Options (`ResolveOptions`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `.family` | `AddressFamilyPreference` | `.any` | `.any` (dual-stack), `.ipv4`, or `.ipv6` |
| `.use_cache` | `bool` | `true` | Whether to consult/populate the client's cache |
| `.timeoutMs` | `?u64` | `null` | Optional lookup timeout override |

Passing `.{}` uses HTTPX defaults.

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: Hostname Resolution](/examples/resolve)
* [All Examples](/examples/)
