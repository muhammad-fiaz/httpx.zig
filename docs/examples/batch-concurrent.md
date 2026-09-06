# Batch Concurrent Requests

Demonstrates `httpx.all()`, `httpx.any()`, `httpx.race()`, and `httpx.allSettled()` for different concurrency patterns with batch HTTP requests.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start a local server
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .keep_alive = false,
    });
    defer server.deinit();
    try server.get("/data", helloHandler);

    const server_thread = try server.listenInBackground();
    defer server_thread.join();
    defer server.stop();
    std.time.sleep(100 * std.time.ns_per_ms);

    const port = server.listeningPort();
    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/data", .{port});
    defer allocator.free(base_url);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    // 1. httpx.all() - wait for all requests to complete
    std.debug.print("--- httpx.all() ---\n", .{});
    var batch1 = httpx.BatchBuilder.init(allocator);
    defer batch1.deinit();
    _ = try batch1.get(base_url);
    _ = try batch1.get(base_url);
    _ = try batch1.get(base_url);

    const all_results = try httpx.all(allocator, &client, batch1.requests.items, .{
        .mode = .multi_thread,
        .workers = 2,
    });
    defer {
        for (all_results) |*r| r.deinit();
        allocator.free(all_results);
    }
    std.debug.print("all(): {d}/{d} succeeded\n\n", .{ httpx.successfulCount(all_results), all_results.len });

    // 2. httpx.any() - return first successful (2xx) response
    std.debug.print("--- httpx.any() ---\n", .{});
    var batch2 = httpx.BatchBuilder.init(allocator);
    defer batch2.deinit();
    _ = try batch2.get(base_url);
    _ = try batch2.get(base_url);

    if (try httpx.any(allocator, &client, batch2.requests.items, .{ .mode = .multi_thread, .workers = 2 })) |resp| {
        defer resp.deinit();
        std.debug.print("any(): got status {d}\n\n", .{resp.status.code});
    }

    // 3. httpx.race() - return first to complete (success or error)
    std.debug.print("--- httpx.race() ---\n", .{});
    var batch3 = httpx.BatchBuilder.init(allocator);
    defer batch3.deinit();
    _ = try batch3.get(base_url);
    _ = try batch3.get(base_url);

    const race_result = try httpx.race(allocator, &client, batch3.requests.items, .{ .mode = .multi_thread, .workers = 2 });
    defer race_result.deinit();
    std.debug.print("race(): completed first\n\n", .{});

    // 4. httpx.allSettled() - return result for every request
    std.debug.print("--- httpx.allSettled() ---\n", .{});
    var batch4 = httpx.BatchBuilder.init(allocator);
    defer batch4.deinit();
    _ = try batch4.get(base_url);
    _ = try batch4.get(base_url);

    const settled_results = try httpx.allSettled(allocator, &client, batch4.requests.items, .{ .mode = .multi_thread, .workers = 2 });
    defer {
        for (settled_results) |*r| r.deinit();
        allocator.free(settled_results);
    }
    std.debug.print("allSettled(): {d}/{d} succeeded\n", .{ httpx.successfulCount(settled_results), settled_results.len });
}
```

## Run

```bash
zig build run-all-batch_concurrent
```

## What to Verify

- `httpx.all()` waits for every request and returns all results.
- `httpx.any()` returns the first 2xx response.
- `httpx.race()` returns the first to complete regardless of status.
- `httpx.allSettled()` returns a result for every request (no early return).
- All patterns support configurable concurrency via `ConcurrencyConfig`.
