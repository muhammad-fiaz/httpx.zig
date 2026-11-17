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

fn getHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok-get" };
}

fn headersHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok-headers" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", getHandler, .{});
    try server.router.add(.GET, "/headers", headersHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{
        .dnsCache = .{
            .enable = true,
            .ttlMs = 60_000,
        },
    });
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/get", .{port});
    var r1 = client.get(url1, .{}) catch |err| {
        std.debug.print("R1 failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer r1.deinit();
    std.debug.print("R1 Status: {d}\n", .{r1.status});

    const url2 = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/headers", .{port});
    var r2 = client.get(url2, .{}) catch |err| {
        std.debug.print("R2 failed: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    defer r2.deinit();
    std.debug.print("R2 Status: {d}\n", .{r2.status});

    server.requestShutdown();
    thread.join();
}
```

## Advanced Direct Cache API

For specialized network applications, the standalone cache in `src/net/dns/dnsCache.zig` can be used directly:

```zig
const cacheMod = @import("httpx").dnsCache; // or @import("src/net/dns/dnsCache.zig")
```

The cache exposes atomic observability counters:
* `hits`: Number of lookups satisfied from cache.
* `misses`: Number of lookups that required network I/O.
* `lookups_started`: Number of network lookups initiated.
* `lookups_coalesced`: Number of concurrent requests joined to an in-flight lookup.

## Expected Output

```text
R1 Status: 200
R2 Status: 200
```

Statuses reflect the live endpoints; on DNS or connection failure the corresponding `R1 failed: <ErrorName>` / `R2 failed: <ErrorName>` line prints instead.

## How to Run

```bash
zig build run-dns-cache
```

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: DNS Configuration](/examples/dns-configuration)
