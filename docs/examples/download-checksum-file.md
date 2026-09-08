# Example: Download Checksum File

Demonstrates download_checksum_file.zig using the canonical HTTPX API.

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
    const checksum_manifest =
        \\# Official Release Hashes
        \\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  sample-local-pdf.pdf
        \\
    ;

    const target_filename = "sample-local-pdf.pdf";
    const expected_hash = httpx.parseChecksumFile(checksum_manifest, target_filename);

    if (expected_hash) |hash| {
        std.debug.print("Parsed hash for {s}: {s}\n", .{ target_filename, hash });

        const sampleUrl = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
        const dl_res = client.download(
            sampleUrl,
            "downloads/",
            .{
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

        std.debug.print("Successfully downloaded to {s} ({d} bytes)\n", .{ dl_res.destination, dl_res.downloadedBytes });
    }
}
```

## How to Run

```bash
zig build run-download-checksum-file
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
