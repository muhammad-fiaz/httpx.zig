# Example: Connectivity

Demonstrates connectivity.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Internet connectivity check example.
//!
//! Demonstrates explicit connectivity probes and the client convenience API.
//!
//! Run with: `zig build run-connectivity`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Explicit I/O connectivity probe
    std.debug.print("\n=== Connectivity check ===\n", .{});
    if (httpx.connectivity.isOnline(io)) {
        std.debug.print("Internet is available.\n", .{});
    } else {
        std.debug.print("No internet connection detected.\n", .{});
    }

    // 2. Detailed result
    std.debug.print("\n=== Detailed connectivity probe ===\n", .{});
    const result = httpx.connectivity.checkConnectivity(io, .{ .timeoutMs = 3000 });
    if (result.online) {
        const famStr: []const u8 = if (result.family) |f| switch (f) {
            .ip4 => "IPv4",
            .ip6 => "IPv6",
        } else "?";
        std.debug.print(
            "Online: endpoint={s} family={s} latency={?d}ms\n",
            .{ result.endpointStr(), famStr, result.latencyMs },
        );
    } else {
        std.debug.print("Offline: all probes failed.\n", .{});
    }

    // 3. Via an explicit Client
    std.debug.print("\n=== Via Client ===\n", .{});
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const clientResult = client.checkConnectivity(.{});
    if (clientResult.online) {
        std.debug.print("Client: online via {s} ({?d}ms)\n", .{
            clientResult.endpointStr(),
            clientResult.latencyMs,
        });
    } else {
        std.debug.print("Client: offline.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}
```

## Expected Output

```text
=== Zero-config check ===
Internet is available.

=== Detailed connectivity probe ===
Online: endpoint=1.1.1.1:443 family=IPv4 latency=42ms

=== Via Client ===
Client: online via 1.1.1.1:443 (42ms)

Done.
```

The endpoint address, family, and latency values vary with the network path; when offline the corresponding `No internet connection detected.` / `Offline: all probes failed.` / `Client: offline.` lines print instead.

## How to Run

```bash
zig build run-connectivity
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
