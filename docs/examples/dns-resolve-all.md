# Multi-Address DNS Resolution Example

Demonstrates candidate address resolution for dual-stack hostnames and IP literal pass-through.

## Unified Candidate Resolution

In HTTPX, a single canonical method — `client.resolve(host, .{ .port = 443 })` — resolves and returns all candidate addresses in system preference order (RFC 3484). There is no need for separate `resolve` vs `resolveAll` functions:

* Access the primary address: `addresses.first()`
* Access all candidate addresses: `addresses.items` or `addresses.slice()`
* Count candidates: `addresses.len()`

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 1. Resolve host with multiple candidate IP addresses
    var candidates = try client.resolve("httpbun.com", .{ .port = 443 });
    defer candidates.deinit();

    std.debug.print("Found {d} candidate address(es):\n", .{candidates.len()});
    for (candidates.items, 0..) |addr, idx| {
        std.debug.print("  [{d}] {f}:{d} ({s})\n", .{
            idx,
            addr,
            addr.port,
            @tagName(addr.family),
        });
    }

    // 2. IP literal pass-through (bypasses DNS automatically)
    var literal = try client.resolve("127.0.0.1", .{ .port = 8080 });
    defer literal.deinit();

    if (literal.first()) |primary| {
        std.debug.print("\nDirect IP target: {f}:{d}\n", .{ primary, primary.port });
    }
}
```

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: DNS Demo](/examples/dns-demo)
