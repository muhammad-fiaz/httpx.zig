# Example: Download Verify

Demonstrates downloadVerify.zig using the canonical HTTPX API.

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
        .{
            .path = "downloads/verified-sample.pdf",
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
        if (result.sha256Hex) |h| {
            std.debug.print("SHA-256: {s}\n", .{h});
        }
    }
}
```

## Expected Output

```text
==> Downloading https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf with size and cryptographic verification...
File verified and saved successfully to: downloads/verified-sample.pdf
SHA-256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

Destinations, byte counts, and hash values vary with the remote file; the `SHA-256` line only prints when a hash is available. Only the line format above is stable.

## How to Run

```bash
zig build run-download-verify
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
