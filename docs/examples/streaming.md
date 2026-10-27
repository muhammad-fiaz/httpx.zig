# Streaming

Read the buffered response body incrementally through `Response.reader()`.

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

    var response = try client.get("https://httpbun.com/bytes/4096", .{
        .maxResponseSize = 8 * 1024 * 1024,
    });
    defer response.deinit();

    // `Response.reader()` returns a `std.Io.Reader` over the buffered body.
    // A short read is the natural end-of-stream signal: `readSliceShort`
    // returns the number of bytes actually read, and a zero return means
    // the stream is exhausted.
    var buf: [1024]u8 = undefined;
    var reader = response.reader();
    var total: usize = 0;
    while (true) {
        const n = reader.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    std.debug.print("streamed {d} bytes\n", .{total});
}
```

## Expected Output

```text
streamed 4096 bytes
```

The byte count reflects the requested `/bytes/4096` payload and varies with the URL and `maxResponseSize`. Requires network access to the external `httpbun.com` service.

## Run

```bash
zig build run-streaming
```

## What to Verify

- The buffered body can be read incrementally through `Response.reader()`.
- Total byte count matches the requested payload size.
