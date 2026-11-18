# Example: Connectivity

Demonstrates the high-level `net.connectivity` API and the client convenience methods. A check opens a TCP connection to a small set of documented default endpoints and stops at the first success; it does not require TLS or an HTTP exchange.

## Complete Example

```zig
//! Internet connectivity check example.
//!
//! Demonstrates the high-level connectivity API and the client convenience
//! methods. Both reuse the `io` passed to `Client.init(allocator, io, .{})`.
//!
//! Run with: `zig build run-connectivity`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Explicit connectivity check with the documented default endpoints.
    std.debug.print("\n=== Connectivity check ===\n", .{});
    if (httpx.net.connectivity.isOnline(io)) {
        std.debug.print("Internet is available.\n", .{});
    } else {
        std.debug.print("No internet connection detected.\n", .{});
    }

    // 2. Detailed result from the high-level `check`.
    std.debug.print("\n=== Detailed connectivity check ===\n", .{});
    const result = httpx.net.connectivity.check(io, .{ .timeoutMs = 3000 });
    if (result.isOnline()) {
        printResult("Online", &result);
    } else {
        std.debug.print("Offline: all endpoints failed.\n", .{});
    }

    // 3. Via an explicit Client. The client owns the allocator and io; both
    //    checks reuse them instead of asking the caller to pass them again.
    //    `isOnline` is the boolean shorthand; `checkConnectivity` returns the
    //    detailed result.
    std.debug.print("\n=== Via Client ===\n", .{});
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    if (client.isOnline(.{})) {
        std.debug.print("Client: online.\n", .{});
    } else {
        std.debug.print("Client: offline.\n", .{});
    }

    const clientResult = client.checkConnectivity(.{});
    if (clientResult.isOnline()) {
        printResult("Client detail", &clientResult);
    } else {
        std.debug.print("Client detail: offline.\n", .{});
    }

    // 4. Check endpoints you control. This is the high-level form: textual IP
    //    endpoints with an explicit port, no internal address types needed.
    std.debug.print("\n=== Custom endpoints ===\n", .{});
    const customResult = client.checkHosts(&.{ "1.1.1.1:53", "[2606:4700:4700::1111]:53" }, .{ .timeoutMs = 2000 });
    if (customResult.isOnline()) {
        printResult("Custom: online", &customResult);
    } else {
        std.debug.print("Custom: offline.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}

fn printResult(label: []const u8, result: *const httpx.net.connectivity.ConnectivityResult) void {
    const family: []const u8 = if (result.family) |f| switch (f) {
        .ip4 => "IPv4",
        .ip6 => "IPv6",
    } else "?";
    std.debug.print("{s}: endpoint={s} family={s} latency={?d}ms\n", .{
        label,
        result.endpointStr(),
        family,
        result.latencyMs,
    });
}
```

## API summary

| Call | Purpose |
| --- | --- |
| `httpx.net.connectivity.check(io, opts)` | Check the documented default endpoints. |
| `httpx.net.connectivity.isOnline(io)` | Boolean shorthand for `check(io, .{}).isOnline()`. |
| `httpx.net.connectivity.checkHosts(io, hosts, opts)` | Check textual IP endpoints such as `"10.0.0.5:443"`. |
| `ConnectivityResult.isOnline()` | Boolean outcome of a detailed `check`/`checkConnectivity` result. |
| `client.isOnline(opts)` | Boolean shorthand for `client.checkConnectivity(opts).isOnline()`. |
| `client.checkConnectivity(opts)` | Same defaults, reusing the client's allocator and `io`. |
| `client.checkHosts(hosts, opts)` | Check your own endpoints, reusing the client's `io`. |

`checkHosts` accepts IP literals with an explicit port. Entries that are malformed or omit the port are skipped, and no DNS lookup is performed; use `client.resolve` first if you need hostnames.

## Expected Output

```text
=== Connectivity check ===
Internet is available.

=== Detailed connectivity check ===
Online: endpoint=1.1.1.1 family=IPv4 latency=42ms

=== Via Client ===
Client: online.
Client detail: endpoint=1.1.1.1 family=IPv4 latency=42ms

=== Custom endpoints ===
Custom: online: endpoint=1.1.1.1 family=IPv4 latency=40ms

Done.
```

The endpoint address, family, and latency values vary with the network path; when offline the corresponding `No internet connection detected.` / `Offline: all endpoints failed.` / `Client: offline.` lines print instead.

`timeoutMs` is the budget for each endpoint attempt, so the worst case for the default options is `timeoutMs * maxProbes`. A successful connect only proves that the selected endpoint and port are reachable; firewalls, captive portals, and proxy requirements can still block other traffic.

## How to Run

```bash
zig build run-connectivity
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
