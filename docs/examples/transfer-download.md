# Transfer Download

Download files over HTTP with progress tracking and checksum verification.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var result = httpx.get("http://httpbun.com/get", .{}) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
    defer result.deinit();

    std.debug.print("Status: {d}\n", .{result.status.code});
    if (result.body) |body| {
        std.debug.print("Body length: {d}\n", .{body.len});
        std.debug.print("Body: {s}\n", .{body[0..@min(200, body.len)]});
    }
}
```

## Run

```bash
zig build run-all-http_download
```

## What to Verify

- Successful HTTP status code.
- Non-empty response body.
- Body length is reported correctly.
