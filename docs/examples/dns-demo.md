# Example: DNS Demo

Demonstrates advanced client DNS capabilities including dual-stack resolution, address family filtering (`.family = .ipv4`), and URL-based resolution.

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

    // 2. Dual-stack DNS resolution with default options (.{})
    std.debug.print("--- Dual-Stack Resolution (httpbun.com:443) ---\n", .{});
    var addresses = client.resolve("httpbun.com", .{ .port = 443 }) catch |err| {
        std.debug.print("DNS lookup failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer addresses.deinit();

    for (addresses.items) |addr| {
        std.debug.print("  Address: {f}:{d} (family: {s})\n", .{ addr, addr.port, @tagName(addr.family) });
    }

    // 3. IPv4-only resolution
    std.debug.print("\n--- IPv4-Only Resolution (httpbun.com:443) ---\n", .{});
    var v4_addresses = client.resolve("httpbun.com", .{ .port = 443, .family = .ipv4 }) catch |err| {
        std.debug.print("IPv4 lookup failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer v4_addresses.deinit();

    for (v4_addresses.items) |addr| {
        std.debug.print("  IPv4: {f}:{d}\n", .{ addr, addr.port });
    }

    // 4. URL-based resolution
    std.debug.print("\n--- URL Resolution (https://httpbun.com/get) ---\n", .{});
    var url_addresses = client.resolveUrl("https://httpbun.com/get", .{}) catch |err| {
        std.debug.print("URL resolution failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer url_addresses.deinit();

    for (url_addresses.items) |addr| {
        std.debug.print("  Target address: {f}:{d}\n", .{ addr, addr.port });
    }
}
```

## How to Run

```bash
zig build run-dns-demo
```

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: Hostname Resolution](/examples/resolve)
* [All Examples](/examples/)
