# Simple Get Deserialize

Parse JSON responses into typed Zig structs.

This example now defaults to an offline-safe path so it completes quickly even in restricted network environments.
Set `HTTPX_EXAMPLE_ONLINE=1` when you want to run a live request to `https://httpbun.com/get`.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

const HttpbinResponse = struct {
    args: std.json.Value,
    headers: Headers,
    origin: []const u8,
    url: []const u8,

    const Headers = struct {
        Accept: ?[]const u8 = null,
        Host: ?[]const u8 = null,
        @"User-Agent": ?[]const u8 = null,
        @"X-Amzn-Trace-Id": ?[]const u8 = null,
    };
};

const offline_sample_json =
    \\{
    \\  "args": {},
    \\  "headers": {
    \\    "Accept": "application/json",
    \\    "Host": "example.local",
    \\    "User-Agent": "httpx.zig/offline-demo",
    \\    "X-Amzn-Trace-Id": "Root=1-offline-demo"
    \\  },
    \\  "origin": "127.0.0.1",
    \\  "url": "https://httpbun.com/get"
    \\}
;

fn shouldUseLiveNetwork(environ: std.process.Environ, allocator: std.mem.Allocator) bool {
    const value = environ.getAlloc(allocator, "HTTPX_EXAMPLE_ONLINE") catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const live_mode = shouldUseLiveNetwork(init.minimal.environ, allocator);

    if (!live_mode) {
        const parsed = try std.json.parseFromSlice(HttpbinResponse, allocator, offline_sample_json, .{});
        defer parsed.deinit();
        std.debug.print("url={s}\n", .{parsed.value.url});
        return;
    }

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    var res = try client.request(.GET, "https://httpbun.com/get", .{ .timeout_ms = 5_000 });
    defer res.deinit();

    // Use response.json() helper for clean automatic JSON deserialization
    const parsed = try res.json(HttpbinResponse, .{});
    defer parsed.deinit();
    std.debug.print("url={s}\n", .{parsed.value.url});
}
```

## Run

```bash
zig build run-all-simple_get_deserialize
```

Live network mode:

```powershell
$env:HTTPX_EXAMPLE_ONLINE = "1"
zig build run-all-simple_get_deserialize
```

```bash
HTTPX_EXAMPLE_ONLINE=1 zig build run-all-simple_get_deserialize
```

## What to Verify

- Default run completes quickly without external network dependency.
- Live mode performs an actual HTTP request and parses typed JSON.
