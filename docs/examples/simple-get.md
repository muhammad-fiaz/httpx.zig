# Simple Get

Perform a minimal HTTP GET request with `httpx.Client`.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.initForBaseUrl(allocator, "https://httpbin.org");
    defer client.deinit();

    // Request defaults are implicit when using .{}
    var res = try client.get("/get", .{});
    defer res.deinit();

    std.debug.print("status={d}\n", .{res.status.code});
    std.debug.print("body={s}\n", .{res.text() orelse ""});
}
```

## Run

```bash
zig build run-simple_get
```

## What to Verify

- Successful HTTP status code.
- Non-empty response body text.
- Defaults are implicit unless explicitly overridden.
