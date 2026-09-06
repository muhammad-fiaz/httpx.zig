# Custom Headers

Send requests with explicit authentication and tracing headers.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    var res = try client.get("https://httpbun.com/headers", .{
        .headers = &.{
            .{ "Authorization", "Bearer demo-token" },
            .{ "X-Request-ID", "req-001" },
            .{ "X-Client", "httpx.zig" },
        },
    });
    defer res.deinit();

    std.debug.print("status={d}\n", .{res.status.code});
    std.debug.print("body={s}\n", .{res.text() orelse ""});
}
```

## Run

```bash
zig build run-all-custom_headers
```

## What to Verify

- Response shows the custom headers echoed by server.
- Authorization and trace headers are transmitted correctly.
