# Thread Pool / Async Server

Start a concurrent HTTP server configured with a bounded thread pool to offload slow/blocking request tasks safely.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from the worker pool thread!");
}

fn asyncTaskHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const start = std.time.milliTimestamp();
    // Simulate a slow blocking computation/I/O task.
    // Since the server configures threads > 0, this request runs on a background worker thread.
    // It does not block other connections from being accepted or processed by other threads.
    httpx.sleepMs(50);
    const elapsed = std.time.milliTimestamp() - start;

    const msg = try std.fmt.allocPrint(ctx.allocator, "Processed blocking task in {d}ms on worker thread pool!\n", .{elapsed});
    defer ctx.allocator.free(msg);

    return ctx.text(msg);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_conflict = .increment,
        .threads = 4, // Enables the Executor thread pool
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/", helloHandler);
    try server.get("/async", asyncTaskHandler);

    try server.listen();
}
```

## Run

```bash
zig build run-all-async_server_example
```

## What to Verify

- `GET /` returns "Hello from the worker pool thread!".
- `GET /async` simulates a blocking workload without stalling other concurrent requests.
- The server processes up to 4 connection jobs concurrently in background threads.
