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
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Unified fetch request
    var response = try client.fetch("http://httpbun.com/get", .{});
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.bytes()});
}
```

## Expected Output

```text
Status: 200
Body: {"args":{},"headers":{"Host":"httpbun.com"},"url":"http://httpbun.com/get"}
```

The status code is the numeric HTTP status and the body is the raw response text; both vary with the target URL and network conditions.

## Run

```bash
zig build run-simple-get
```

## What to Verify

- Successful HTTP status code.
- Non-empty response body text.
- Defaults are implicit unless explicitly overridden.
