# Example: Download Info

Demonstrates download_info.zig using the canonical HTTPX API.

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

    var size_buf: [32]u8 = undefined;
    std.debug.print("Remote File Metadata:\n", .{});
    std.debug.print("  - Status:           {d}\n", .{info.status});
    std.debug.print("  - File Name:        {s}\n", .{info.fileName()});
    std.debug.print("  - File Size:        {?d} bytes ({s})\n", .{ info.fileSize, info.formatSize(&size_buf) });
    std.debug.print("  - Content Type:     {?s}\n", .{info.contentType()});
    std.debug.print("  - Accepts Ranges:   {any}\n", .{info.acceptsRanges});
    std.debug.print("  - ETag:             {?s}\n", .{info.etag()});
    std.debug.print("  - Last-Modified:    {?s}\n", .{info.lastModified()});
}
```

## How to Run

```bash
zig build run-download-info
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
