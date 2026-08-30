const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Downloading {s} with size and cryptographic verification...\n", .{sample_url});

    const result = client.download(
        sample_url,
        "downloads/verified-sample.pdf",
        .{
            .verify = .{
                .min_size = 100,
                .max_size = 50 * 1024 * 1024,
            },
            .progress = .auto,
            .atomic = true,
            .create_dirs = true,
        },
    ) catch |err| {
        std.debug.print("Verified download handled: {s}\n", .{@errorName(err)});
        return;
    };

    if (result.verified) {
        std.debug.print("File verified and saved successfully to: {s} (SHA-256: {?s})\n", .{
            result.destination,
            if (result.sha256_hex) |*h| h[0..] else null,
        });
    }
}
