# Example: Hostname Resolution

Demonstrates user-friendly hostname resolution using the HTTPX client's integrated DNS subsystem.

The client initializes its DNS resolver and thread-safe cache once upon creation, reusing resources across all lookups without requiring manual resolver construction, buffer management, or raw address formatting.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize reusable client once
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 2. High-level DNS resolution using the client's cached resolver
    var addresses = client.resolve("httpbun.com", .{ .port = 443 }) catch |err| {
        std.debug.print("DNS lookup failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer addresses.deinit();

    // 3. User-friendly address iteration and native {f} formatting
    std.debug.print("Resolved {d} address(es) for httpbun.com:\n", .{addresses.len()});
    for (addresses.items) |addr| {
        std.debug.print("  {f}:{d} (family: {s})\n", .{ addr, addr.port, @tagName(addr.family) });
    }
}
```

## How to Run

```bash
zig build run-resolve
```

## Key Features

- **No Allocator on Lookups**: The client manages memory internally; returned `ResolvedAddresses` is cleaned up via `defer addresses.deinit()`.
- **Default Options**: Pass `.{}` to use documented defaults (dual-stack, cached lookup).
- **Native Formatting**: Formats addresses according to RFC 5952 using Zig's native `{f}` format specifier without requiring caller-provided buffers.

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: DNS Demo](/examples/dns-demo)
* [All Examples](/examples/)
