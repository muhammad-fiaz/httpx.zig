const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Updating local application asset from {s} with rollback backup...\n", .{sample_url});

    const res = client.updateFile(
        sample_url,
        .{
            .path = "downloads/app-asset.pdf",
            .backupExisting = true,
            .backupSuffix = ".bak",
            .verify = .{
                .minSize = 100,
            },
        },
    ) catch |err| {
        std.debug.print("Update handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Update succeeded: {s} ({d} bytes)\n", .{ res.destination, res.downloadedBytes });
}
