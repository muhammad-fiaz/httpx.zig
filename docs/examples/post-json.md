# Post JSON

Send JSON request bodies and inspect structured responses.

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

    var res = try client.post("https://httpbin.org/post", .{
        .json = "{\"name\":\"httpx\",\"kind\":\"demo\"}",
    });
    defer res.deinit();

    std.debug.print("status={d}\n", .{res.status.code});
    std.debug.print("json={s}\n", .{res.text() orelse ""});
}
```

## Run

```bash
zig build run-post_json
```

## What to Verify

- Response status is successful.
- Echoed body includes sent JSON payload.
