# Example: Download Resume

Demonstrates downloadResume.zig using the canonical HTTPX API.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = try ctx.allocator.alloc(u8, 2048);
    @memset(data, '%');
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/pdf",
        .headers = &.{
            .{ .name = "Accept-Ranges", .value = "bytes" },
        },
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();
    try server.router.add(.GET, "/sample-local-pdf.pdf", pdfHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/sample-local-pdf.pdf", .{port});

    // Uses .resumePartial (short canonical resume policy)
    const result = client.download(
        sampleUrl,
        .{
            .path = "downloads/resumable-sample.pdf",
            .existing = .resumePartial,
            .progress = .auto,
            .maxRetries = 3,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Resume download handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    std.debug.print("Download status: resumed={any}, downloaded={d} bytes to {s}\n", .{
        result.resumed,
        result.downloadedBytes,
        result.destination,
    });

    server.requestShutdown();
    thread.join();
}
```

## Expected Output

```text
==> Downloading https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf with Range resume policy (.resumePartial)...
Download status: resumed=false, downloaded=12345 bytes to downloads/resumable-sample.pdf
```

The `resumed` flag, byte count, and destination vary with local partial-file state and the remote file; only the line format above is stable.

## How to Run

```bash
zig build run-download-resume
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
