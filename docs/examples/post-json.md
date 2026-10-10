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

    var response = try client.fetch("http://httpbun.com/post", .{
        .method = .POST,
        .json = CreateUser{ .name = "Alice", .role = "developer" },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.bytes()});
}
```

## Expected Output

```text
Status: 200
Body: {"json":{"name":"Alice","role":"developer"},...}
```

The status code and echoed body depend on the remote server's response; the body shape varies with what the server echoes back.

## Run

```bash
zig build run-post-json
```

## What to Verify

- Response status is successful.
- Echoed body includes sent JSON payload.
