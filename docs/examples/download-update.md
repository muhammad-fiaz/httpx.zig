# Example: Download Update

Demonstrates downloadUpdate.zig using the canonical HTTPX API.

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

    const sampleUrl = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Updating local application asset from {s} with rollback backup...\n", .{sampleUrl});

    const res = client.updateFile(
        sampleUrl,
        .{
            .path = "downloads/app-asset.pdf",
            .backupExisting = true,
            .backupSuffix = ".bak",
            .verify = .{
                .minSize = 100,
            },
        },
    ) catch |err| {
        std.debug.print("Update handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Update succeeded: {s} ({d} bytes)\n", .{ res.destination, res.downloadedBytes });
}
```

## Expected Output

```text
==> Updating local application asset from https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf with rollback backup...
Update succeeded: downloads/app-asset.pdf (12345 bytes)
```

Destinations, byte counts, and file sizes vary with the remote file; only the line format above is stable.

## How to Run

```bash
zig build run-download-update
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
