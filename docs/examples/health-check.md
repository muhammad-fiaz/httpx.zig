# Example: Health Check

Demonstrates healthCheck.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Health, readiness, and metrics endpoints.
//!
//! Run with: `zig build run-health-check`
//!
//! Demonstrates the health check helpers, custom metrics, and a
//! readiness probe that gates traffic.

const std = @import("std");
const httpx = @import("httpx");

fn healthzHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = httpx.health.Status.healthy.httpStatus(),
        .body = httpx.health.Status.healthy.jsonBody(),
        .contentType = "application/json",
    };
}

fn readyzHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = httpx.health.Status.ready.httpStatus(),
        .body = httpx.health.Status.ready.jsonBody(),
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
    });
    defer server.deinit();

    try server.router.add(.GET, "/healthz", &healthzHandler, .{});
    try server.router.add(.GET, "/readyz", &readyzHandler, .{});

    const port = server.localPort();
    std.debug.print("endpoints on 127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.server.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const healthUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/healthz", .{port});
    defer allocator.free(healthUrl);
    var healthRes = try client.get(healthUrl, .{});
    defer healthRes.deinit();
    std.debug.print("GET /healthz -> {d} {s}\n", .{ healthRes.status, healthRes.body });

    const readyUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/readyz", .{port});
    defer allocator.free(readyUrl);
    var readyRes = try client.get(readyUrl, .{});
    defer readyRes.deinit();
    std.debug.print("GET /readyz -> {d} {s}\n", .{ readyRes.status, readyRes.body });

    t.join();
}
```

## Expected Output

```text
endpoints on 127.0.0.1:54321
GET /healthz -> 200 {"status":"healthy"}
GET /readyz -> 200 {"status":"ready"}
```

The port is ephemeral and varies on every run; only the line format above is stable.

## How to Run

```bash
zig build run-health-check
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
