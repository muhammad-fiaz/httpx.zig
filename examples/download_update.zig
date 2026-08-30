const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Updating local application asset from {s} with rollback backup...\n", .{sample_url});

    const res = client.updateFile(
        sample_url,
        "downloads/app-asset.pdf",
        .{
            .backup_existing = true,
            .backup_suffix = ".bak",
            .verify = .{
                .min_size = 100,
            },
        },
    ) catch |err| {
        std.debug.print("Update handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Update succeeded: {s} ({d} bytes)\n", .{ res.destination, res.downloaded_bytes });
}
