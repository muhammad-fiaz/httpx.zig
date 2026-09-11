# Post JSON

Send JSON request bodies and inspect structured responses.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

const CreateUser = struct {
    name: []const u8,
    role: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var res = try client.fetch("https://httpbun.com/post", .{
        .method = .POST,
        .json = CreateUser{ .name = "httpx", .role = "demo" },
    });
    defer res.deinit();

    std.debug.print("status={d}\n", .{res.status});
    std.debug.print("json={s}\n", .{res.bytes()});
}
```

## Run

```bash
zig build run-post-json
```

## What to Verify

- Response status is successful.
- Echoed body includes sent JSON payload.
