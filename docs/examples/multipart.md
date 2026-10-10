# Example: Multipart

Demonstrates multipart.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Multipart/form-data upload using the client-side API.
//!
//! Run with: `zig build run-multipart`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const fileData = "hello, world!";

    var response = try client.post("http://httpbun.com/post", .{
        .multipart = .{
            .name = "upload",
            .filename = "hello.txt",
            .contentType = "text/plain",
            .data = fileData,
        },
    });
    defer response.deinit();

    std.debug.print("status: {d}\n", .{response.status});
    std.debug.print("body: {s}\n", .{response.body});
}
```

## Expected Output

```text
status: 200
body: {"files":{"upload":"hello, world!"},"form":{...}}
```

The status code and echoed body depend on the remote server's response; the body shape varies with what the server echoes back.

## How to Run

```bash
zig build run-multipart
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
