# Example: Download Resume

Demonstrates downloadResume.zig using the canonical HTTPX API.

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
    std.debug.print("==> Downloading {s} with Range resume policy (.resumePartial)...\n", .{sampleUrl});

    // Uses .resumePartial (clean non-reserved keyword name)
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
        return;
    };

    std.debug.print("Download status: resumed={any}, downloaded={d} bytes to {s}\n", .{
        result.resumed,
        result.downloadedBytes,
        result.destination,
    });
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
