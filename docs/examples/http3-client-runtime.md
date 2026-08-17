# HTTP/3 Client Runtime Example

Run a full local end-to-end HTTP/3 request using the high-level client runtime (`http3_enabled = true`).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.initWithConfig(allocator, .{
        .http3_enabled = true,
    });
    defer client.deinit();

    // See examples/http3_client_runtime.zig for full local UDP server + client setup.
    var response = try client.get("http://127.0.0.1:8080/runtime", .{});
    defer response.deinit();

    std.debug.print("version={s} status={d}\n", .{ response.version.toString(), response.status.code });
}
```

## Run

```bash
zig build run-all-http3_client_runtime
```

## What to Verify

- The response version prints `HTTP/3`.
- The local UDP loopback server receives QUIC STREAM frames for control/request streams.
- The client decodes HTTP/3 HEADERS/DATA frames into a standard `Response`.
