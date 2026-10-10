# Example: Download Info

Demonstrates downloadInfo.zig using the canonical HTTPX API.

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
    std.debug.print("==> Inspecting remote file info without downloading: {s}\n", .{sampleUrl});

    const info = client.lookupFileInfo(sampleUrl, .{}) catch |err| {
        std.debug.print("Lookup handled: {s}\n", .{@errorName(err)});
        return;
    };

    var sizeBuf: [32]u8 = undefined;
    std.debug.print("Remote File Metadata:\n", .{});
    std.debug.print("  - Status:           {d}\n", .{info.status});
    std.debug.print("  - File Name:        {s}\n", .{info.fileName()});
    std.debug.print("  - File Size:        {?d} bytes ({s})\n", .{ info.fileSize, info.formatSize(&sizeBuf) });
    std.debug.print("  - Content Type:     {?s}\n", .{info.contentType()});
    std.debug.print("  - Accepts Ranges:   {any}\n", .{info.acceptsRanges});
    std.debug.print("  - ETag:             {?s}\n", .{info.etag()});
    std.debug.print("  - Last-Modified:    {?s}\n", .{info.lastModified()});
}
```

## Expected Output

```text
==> Inspecting remote file info without downloading: https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf
Remote File Metadata:
  - Status:           200
  - File Name:        sample-local-pdf.pdf
  - File Size:        12345 bytes (12.1 KiB)
  - Content Type:     application/pdf
  - Accepts Ranges:   true
  - ETag:             "abc123"
  - Last-Modified:    Wed, 01 Jan 2025 00:00:00 GMT
```

Status, sizes, ETags, and timestamps vary with the remote server and file; only the line format above is stable. Missing headers print as `null`.

## How to Run

```bash
zig build run-download-info
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
