# Example: Download Verify

Demonstrates download_verify.zig using the canonical HTTPX API.

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
    std.debug.print("==> Downloading {s} with size and cryptographic verification...\n", .{sampleUrl});

    const result = client.download(
        sampleUrl,
        "downloads/verified-sample.pdf",
        .{
            .verify = .{
                .minSize = 100,
                .maxSize = 50 * 1024 * 1024,
            },
            .progress = .auto,
            .atomic = true,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Verified download handled: {s}\n", .{@errorName(err)});
        return;
    };

    if (result.verified) {
        std.debug.print("File verified and saved successfully to: {s}\n", .{
            result.destinationPath(),
        });
        if (result.sha256_hex) |h| {
            std.debug.print("SHA-256: {s}\n", .{h});
        }
    }
}
```

## How to Run

```bash
zig build run-download-verify
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
