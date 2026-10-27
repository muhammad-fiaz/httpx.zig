# Example: Full Integration

Demonstrates fullIntegration.zig using the canonical HTTPX API.

## Complete Example

```zig
//! End-to-end integration example verifying full server and client lifecycle:
//!
//! 1. Server initialization with explicit allocator, IO, and configuration
//! 2. Route registration (GET, POST with JSON, error handling)
//! 3. Server startup on background thread listening on ephemeral port
//! 4. Client initialization with explicit allocator, IO, and configuration
//! 5. Client dispatches GET and POST requests using canonical API:
//!      client.get("http://...", .{})
//!      client.post("http://...", .{ .json = payload })
//! 6. Server processes requests and returns framed responses
//! 7. Client reads and parses responses
//! 8. Graceful shutdown requested on server
//! 9. Server worker thread cleanly joins
//! 10. Client and server deinitialization with zero memory leaks
//!
//! Run with: `zig build run-full-integration`

const std = @import("std");
const httpx = @import("httpx");

const UserPayload = struct {
    name: []const u8,
    role: []const u8,
};

fn handleRoot(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "HTTPX production server running",
        .contentType = "text/plain; charset=utf-8",
    };
}

fn handleCreateUser(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const payload = try ctx.json(UserPayload);
    const formatted = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"created\":true,\"name\":\"{s}\",\"role\":\"{s}\"}}",
        .{ payload.name, payload.role },
    );
    return .{
        .status = 201,
        .body = formatted,
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = gpa.deinit();
        if (check != .ok) {
            std.debug.print("Leak detected in DebugAllocator!\n", .{});
        }
    }
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize server with allocator and IO
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
    });
    defer server.deinit();

    // 2. Register routes using server convenience methods
    try server.get("/", handleRoot);
    try server.post("/api/users", handleCreateUser);

    const port = server.localPort();
    std.debug.print("[integration] Server configured and listening on 127.0.0.1:{d}\n", .{port});

    // 3. Start server background worker
    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const worker = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    // Ensure accept loop is ready
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    // 4. Initialize client with allocator and IO
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 5. Client GET request
    const rootUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(rootUrl);

    std.debug.print("[integration] Client sending GET {s}...\n", .{rootUrl});
    var res1 = try client.get(rootUrl, .{});
    defer res1.deinit();

    std.debug.print("[integration] Response: status={d}, body=\"{s}\"\n", .{ res1.status, res1.body });
    if (res1.status != 200) return error.TestFailed;

    // 6. Client POST request with JSON payload
    const usersUrl = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/users", .{port});
    defer allocator.free(usersUrl);

    std.debug.print("[integration] Client sending POST {s} with JSON...\n", .{usersUrl});
    var res2 = try client.post(usersUrl, .{
        .json = UserPayload{
            .name = "Alice",
            .role = "Administrator",
        },
    });
    defer res2.deinit();

    std.debug.print("[integration] Response: status={d}, body=\"{s}\"\n", .{ res2.status, res2.body });
    if (res2.status != 201) return error.TestFailed;

    // 7. Request graceful shutdown and wait for server worker to join
    std.debug.print("[integration] Shutting down server and joining worker...\n", .{});
    server.requestShutdown();
    worker.join();

    std.debug.print("[integration] Complete integration cycle verified with zero leaks.\n", .{});
}
```

## Expected Output

```text
[integration] Server configured and listening on 127.0.0.1:54321
[integration] Client sending GET http://127.0.0.1:54321/...
[integration] Response: status=200, body="HTTPX production server running"
[integration] Client sending POST http://127.0.0.1:54321/api/users with JSON...
[integration] Response: status=201, body="{"created":true,"name":"Alice","role":"Administrator"}"
[integration] Shutting down server and joining worker...
[integration] Complete integration cycle verified with zero leaks.
```

The port is ephemeral and varies on every run; body lengths vary with the payload. Only the line format above is stable.

## How to Run

```bash
zig build run-full-integration
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
