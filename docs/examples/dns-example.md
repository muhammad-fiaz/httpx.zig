# DNS Resolution Example

## What it Demonstrates

Hostname resolution using the normal HTTPX client (`httpx.Client`).

A normal HTTPX user does not need to understand low-level resolver construction, allocator ownership, internal DNS wire packets, or raw address buffers merely to resolve a hostname. The reusable client initializes its resolver and thread-safe cache once and manages resolution internally.

## Basic Example

The standard way to resolve a hostname is via `client.resolve(host, .{ .port = 443 })`:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Initialize client once
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Resolve hostname to candidate addresses
    var addresses = try client.resolve("httpbun.com", .{ .port = 443 });
    defer addresses.deinit();

    // Iterate through returned addresses
    for (addresses.items) |address| {
        std.debug.print("Address: {f}:{d} (family: {s})\n", .{
            address,
            address.port,
            @tagName(address.family),
        });
    }
}
```

## IPv4 and IPv6 Selection

By default, resolution returns dual-stack addresses in system order. You can restrict resolution to IPv4 or IPv6 via `ResolveOptions`:

```zig
// Force IPv4 only
var v4 = try client.resolve("httpbun.com", .{
    .port = 443,
    .family = .ipv4,
});
defer v4.deinit();

// Force IPv6 only
var v6 = try client.resolve("httpbun.com", .{
    .port = 443,
    .family = .ipv6,
});
defer v6.deinit();
```

## URL Resolution

You can also resolve directly from a full URL string:

```zig
var addrs = try client.resolveUrl("https://httpbun.com/get", .{});
defer addrs.deinit();
```

The client automatically extracts the hostname and default port (80 for HTTP, 443 for HTTPS).

## DNS Cache

The client caches DNS results in memory with positive and negative TTL:

```zig
var client = httpx.Client.init(allocator, io, .{
    .dnsCache = .{
        .enable = true,
        .ttlMs = 60_000,          // Positive cache: 60 seconds
        .negativeTtlMs = 5_000,  // Negative cache: 5 seconds
        .maxEntries = 1024,       // Bounded cache capacity
    },
});
defer client.deinit();
```

To bypass the cache for a single query:

```zig
var fresh = try client.resolve("httpbun.com", .{
    .port = 443,
    .useCache = false,
});
defer fresh.deinit();
```

## Proxy and SOCKS5H Remote Resolution

When communicating through proxies:
* **Direct connection**: DNS is resolved locally via the client's resolver.
* **HTTP Proxy**: The client connects to the proxy; HTTPS tunnels use HTTP `CONNECT` where the proxy resolves the destination.
* **SOCKS5** (`socks5://`): Hostnames are resolved locally before connecting to the SOCKS proxy.
* **SOCKS5H** (`socks5h://`): Hostnames are **not** resolved locally; the unresolved domain name is sent to the proxy server to resolve remotely.

See the [Proxy Protocol Documentation](/protocols/proxies) and [SOCKS5H Guide](/protocols/socks5h) for details.

## Related Resources

* [API: Client](/api/client)
* [API: DNS](/api/dns)
* [API: Address](/api/net)
* [Guide: DNS](/guide/dns)
* [Protocol: DNS](/protocols/dns)
