# Concurrent Requests

Execute multiple requests in parallel using dynamic thread workers, sequential execution, or explicit executors.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn mockHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Start a local loopback server
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 45235,
        .keep_alive = false,
    });
    defer server.deinit();
    try server.get("/data", mockHandler);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *httpx.Server) void {
            s.listen() catch {};
        }
    }.run, .{&server});
    defer server_thread.join();
    defer server.stop();

    std.time.sleep(20 * std.time.ns_per_ms);

    // 2. Build a batch of request specifications
    var builder = httpx.concurrency.BatchBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.get("http://127.0.0.1:45235/data");
    _ = try builder.get("http://127.0.0.1:45235/data");
    _ = try builder.get("http://127.0.0.1:45235/data");

    var client = httpx.Client.initWithConfig(allocator, .{});
    defer client.deinit();

    // 3. Multi-threaded Mode (with at most 2 concurrent workers)
    std.debug.print("Executing with multi_thread mode (2 workers)...\n", .{});
    const mt_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .multi_thread,
        .workers = 2,
    });
    defer {
        for (mt_results) |*r| r.deinit();
        allocator.free(mt_results);
    }
    std.debug.print("Success: {d}/{d}\n\n", .{ httpx.successfulCount(mt_results), mt_results.len });

    // 4. Single-threaded Mode (sequentially on calling thread)
    std.debug.print("Executing with single_thread mode (sequential)...\n", .{});
    const st_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .single_thread,
    });
    defer {
        for (st_results) |*r| r.deinit();
        allocator.free(st_results);
    }
    std.debug.print("Success: {d}/{d}\n\n", .{ httpx.successfulCount(st_results), st_results.len });

    // 5. Explicit Workers Mode (reusing a started Executor)
    std.debug.print("Executing with explicit_workers mode...\n", .{});
    var exec = httpx.Executor.initWithConfig(allocator, .{ .num_threads = 3 });
    defer exec.deinit();
    try exec.start();

    const ex_results = try httpx.all(allocator, &client, builder.requests.items, .{
        .mode = .explicit_workers,
        .executor = &exec,
    });
    defer {
        for (ex_results) |*r| r.deinit();
        allocator.free(ex_results);
    }
    std.debug.print("Success: {d}/{d}\n\n", .{ httpx.successfulCount(ex_results), ex_results.len });
}
```

## Run

```bash
zig build run-concurrent_requests
```

## What to Verify

- Request batch executes successfully across all three execution modes.
- Parallel worker counts can be configured dynamically using `ConcurrencyConfig`.
- Custom thread pools/executors are supported for explicit worker execution.
