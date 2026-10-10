# Example: Download Checksum File

Demonstrates downloadChecksumFile.zig using the canonical HTTPX API.

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

    std.debug.print("==> Downloading with SHA256SUMS file parsing & verification...\n", .{});

    // Sample checksum file format simulation
    const checksumManifest =
        \\# Official Release Hashes
        \\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  sample-local-pdf.pdf
        \\
    ;

    const targetFilename = "sample-local-pdf.pdf";
    const expectedHash = httpx.parseChecksumFile(checksumManifest, targetFilename);

    if (expectedHash) |hash| {
        std.debug.print("Parsed hash for {s}: {s}\n", .{ targetFilename, hash });

        const sampleUrl = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
        const dlRes = client.download(
            sampleUrl,
            .{
                .path = "downloads/",
                .verify = .{
                    .minSize = 100,
                },
                .progress = .auto,
                .createDirs = true,
            },
        ) catch |err| {
            std.debug.print("Download handled: {s}\n", .{@errorName(err)});
            return;
        };

        std.debug.print("Successfully downloaded to {s} ({d} bytes)\n", .{ dlRes.destination, dlRes.downloadedBytes });
    }
}
```

## Expected Output

```text
==> Downloading with SHA256SUMS file parsing & verification...
Parsed hash for sample-local-pdf.pdf: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Successfully downloaded to downloads/sample-local-pdf.pdf (12345 bytes)
```

The destination path, byte count, and file size vary with the remote file; only the line format above is stable.

## How to Run

```bash
zig build run-download-checksum-file
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
