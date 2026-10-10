# Example: Download Existing

Demonstrates downloadExisting.zig using the canonical HTTPX API.

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
    std.debug.print("==> Demonstrating existing-file policies (.skip, .verifyExisting, .fail)...\n", .{});

    // Policy 1: Verify on-disk file size/checksum first; if valid, skip downloading!
    const res1 = client.download(
        sampleUrl,
        .{
            .path = "downloads/existing-sample.pdf",
            .existing = .verifyExisting,
            .verify = .{
                .minSize = 100,
            },
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download 1: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("Download 1 result: skipped={any}, verified={any}\n", .{ res1.skipped, res1.verified });

    // Policy 2: Fail if destination already exists
    const res2 = client.download(
        sampleUrl,
        .{
            .path = "downloads/existing-sample.pdf",
            .existing = .fail,
        },
    );
    if (res2) |_| {} else |err| {
        std.debug.print("Download 2 (expect fail): caught {s}\n", .{@errorName(err)});
    }
}
```

## Expected Output

```text
==> Demonstrating existing-file policies (.skip, .verifyExisting, .fail)...
Download 1 result: skipped=false, verified=true
Download 2 (expect fail): caught FileAlreadyExists
```

The `skipped`/`verified` flags and the exact error name vary with local file state; only the line format above is stable.

## How to Run

```bash
zig build run-download-existing
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
