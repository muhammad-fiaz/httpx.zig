# HTTP/2 Client Runtime Example

Run a full local end-to-end HTTP/2 request using the high-level client runtime (`http2_enabled = true`).

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.initWithConfig(allocator, .{
        .http2_enabled = true,
    });
    defer client.deinit();

    // See examples/http2_client_runtime.zig for full local server + client setup.
    var response = try client.get("http://127.0.0.1:8080/runtime", .{});
    defer response.deinit();

    std.debug.print("version={s} status={d}\n", .{ response.version.toString(), response.status.code });
}
```

## Run

```bash
zig build run-http2_client_runtime
```

## What to Verify

- The response version prints `HTTP/2`.
- The local loopback server receives an HTTP/2 preface, SETTINGS, HEADERS, and DATA flow.
- The client decodes HTTP/2 response headers/body into a standard `Response`.
