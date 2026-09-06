const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Demonstrating existing-file policies (.skip, .verify_existing, .fail)...\n", .{});

    // Policy 1: Verify on-disk file size/checksum first; if valid, skip downloading!
    const res1 = client.download(
        sample_url,
        "downloads/existing-sample.pdf",
        .{
            .existing = .verify_existing,
            .verify = .{
                .min_size = 100,
            },
            .create_dirs = true,
        },
    ) catch |err| {
        std.debug.print("Download 1: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("Download 1 result: skipped={any}, verified={any}\n", .{ res1.skipped, res1.verified });

    // Policy 2: Fail if destination already exists
    const res2 = client.download(
        sample_url,
        "downloads/existing-sample.pdf",
        .{
            .existing = .fail,
        },
    );
    if (res2) |_| {} else |err| {
        std.debug.print("Download 2 (expect fail): caught {s}\n", .{@errorName(err)});
    }
}
