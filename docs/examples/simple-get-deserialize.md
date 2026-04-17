# Simple Get Deserialize

Parse JSON responses into typed Zig structs.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

const Echo = struct {
    url: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    var res = try client.get("https://httpbin.org/get", .{});
    defer res.deinit();

    const parsed = try res.json(Echo);
    std.debug.print("url={s}\n", .{parsed.url});
}
```

## Run

```bash
zig build run-simple_get_deserialize
```

## What to Verify

- JSON parsing succeeds without runtime errors.
- Parsed struct fields contain expected values.
