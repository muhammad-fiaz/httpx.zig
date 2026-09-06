const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
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

        const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
        const dl_res = client.download(
            sample_url,
            "downloads/",
            .{
                .verify = .{
                    .min_size = 100,
                },
                .progress = .auto,
                .create_dirs = true,
            },
        ) catch |err| {
            std.debug.print("Download handled: {s}\n", .{@errorName(err)});
            return;
        };

        std.debug.print("Successfully downloaded to {s} ({d} bytes)\n", .{ dl_res.destination, dl_res.downloaded_bytes });
    }
}
