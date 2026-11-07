# Example: FTP Download

Downloads a file over FTP/FTPS with progress reporting and checksum verification.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> Downloading file over FTP with progress and verification...\n", .{});

    var ftp = try httpx.client.ftp.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 21,
        .user = "anonymous",
        .password = "anonymous@",
    });
    defer ftp.deinit();

    const res = try ftp.download(.{
        .remotePath = "/pub/archive.tar.gz",
        .destinationPath = "downloads/archive.tar.gz",
        .progress = .auto,
        .verify = .{
            .minSize = 10,
        },
    });

    std.debug.print("FTP download finished: {s} ({d} bytes)\n", .{ res.destination, res.downloadedBytes });
}
```

The allocator and `std.Io` belong to `Client.init`; every later `download`
reuses them. The same client can download multiple files before `deinit`.

## Expected Output

```text
==> Downloading file over FTP with progress and verification...
FTP download finished: downloads/archive.tar.gz (12345 bytes)
```

Destinations, byte counts, and file sizes vary with the remote file; only the line format above is stable.

## How to Run

```bash
zig build run-ftp-download
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
