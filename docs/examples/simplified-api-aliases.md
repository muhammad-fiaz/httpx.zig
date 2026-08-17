# Simplified API Aliases

Use concise top-level aliases for common client operations.

This example defaults to a local loopback mode that starts a tiny in-process server and executes alias calls against it, so the demo stays deterministic without external internet.
Set `HTTPX_EXAMPLE_ONLINE=1` to run the same alias calls against live `httpbin` endpoints.

## Demo Program

The full runnable source is in `examples/simplified_api_aliases.zig`.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const live_mode = shouldUseLiveNetwork(init.minimal.environ, allocator);

    if (live_mode) {
        const urls = DemoUrls{
            .fetch = "https://httpbun.com/anything",
            .get = "https://httpbun.com/get",
            .delete = "https://httpbun.com/delete",
            .trace = "https://httpbun.com/trace",
            .connect = "https://httpbun.com/anything",
            .post = "https://httpbun.com/post",
        };
        runAliasCalls(allocator, urls);
        return;
    }

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
        .request_timeout_ms = 10_000,
    });
    defer server.deinit();

    try server.get("/get", okHandler);
    try server.get("/anything", okHandler);
    try server.post("/post", okHandler);
    try server.delete("/delete", okHandler);
    try server.options("/get", okHandler);
    try server.trace("/trace", okHandler);
    try server.connect("/anything", okHandler);

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server});
    defer server_thread.join();

    sleepMs(50);

    const urls = try buildLocalUrls(allocator, port);
    defer freeLocalUrls(allocator, urls);

    runAliasCalls(allocator, urls);
    server.stop();
}
```

## Run

```bash
zig build run-all-simplified_api_aliases
```

Live network mode:

```powershell
$env:HTTPX_EXAMPLE_ONLINE = "1"
zig build run-all-simplified_api_aliases
```

```bash
HTTPX_EXAMPLE_ONLINE=1 zig build run-all-simplified_api_aliases
```

## What to Verify

- Default run prints successful status codes for top-level and client alias methods against loopback.
- Live mode executes the same alias set against `httpbin`.
