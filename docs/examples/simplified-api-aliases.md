# Simplified API Aliases

Use concise top-level aliases for common client operations.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var a = try httpx.fetch(allocator, "https://httpbin.org/get");
    defer a.deinit();

    var b = try httpx.send(allocator, .GET, "https://httpbin.org/headers", .{});
    defer b.deinit();

    var c = try httpx.post(allocator, "https://httpbin.org/post", .{ .json = "{\"ok\":true}" });
    defer c.deinit();

    var d = try httpx.delete(allocator, "https://httpbin.org/delete", .{});
    defer d.deinit();

    var e = try httpx.opts(allocator, "https://httpbin.org/get", .{});
    defer e.deinit();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    var f = try client.del("https://httpbin.org/delete", .{});
    defer f.deinit();

    var g = try client.opts("https://httpbin.org/get", .{});
    defer g.deinit();

    std.debug.print("statuses: {d}, {d}, {d}, {d}, {d}, {d}, {d}\n", .{ a.status.code, b.status.code, c.status.code, d.status.code, e.status.code, f.status.code, g.status.code });
}
```

## Run

```bash
zig build run-simplified_api_aliases
```

## What to Verify

- Alias helpers behave the same as direct client methods.
- Both top-level and client shortcut aliases are available (`delete/del`, `options/opts`).
- Request/response lifecycle remains correct with deinit calls.
