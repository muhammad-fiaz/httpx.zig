# Example: Download

Demonstrates download.zig using the canonical HTTPX API.

## Complete Example

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

    // Use httpbun.com /bytes/90 (or /payload) endpoint (default limit on httpbun.com is 90 bytes, or payload endpoint)
    const sampleUrl = "https://httpbun.com/bytes/90";
    std.debug.print("==> Downloading {s} with zero-config progress bar...\n", .{sampleUrl});

    // 1. Download to a specific directory (automatically uses URL basename "1048576")
    const result1 = client.download(
        sampleUrl,
        .{
            .path = "downloads/",
            .progress = .enabled,
            .existing = .overwrite,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download to directory handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Downloaded with auto filename: {s} ({d} bytes in {d} ms)\n", .{
        result1.destinationPath(),
        result1.downloadedBytes,
        result1.elapsedMs,
    });

    // 2. Download with explicit custom destination filename
    const result2 = client.download(
        sampleUrl,
        .{
            .path = "downloads/custom_named_doc.bin",
            .progress = .enabled,
            .existing = .overwrite,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download with explicit name handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Downloaded with explicit filename: {s} ({d} bytes)\n", .{
        result2.destinationPath(),
        result2.downloadedBytes,
    });
}
```

## Expected Output

```text
==> Downloading https://httpbun.com/bytes/90 with zero-config progress bar...
Downloaded with auto filename: downloads/90 (90 bytes in 123 ms)
Downloaded with explicit filename: downloads/custom_named_doc.bin (90 bytes)
```

Byte counts (90 bytes in this example), elapsed milliseconds, and auto-derived filenames vary with the endpoint and timing; only the line format above is stable.

## How to Run

```bash
zig build run-download
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
