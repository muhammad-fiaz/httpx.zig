const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> Downloading file over FTP with progress and verification...\n", .{});

    const res = httpx.ftpDownload(allocator, .{
        .host = "127.0.0.1",
        .port = 21,
        .user = "anonymous",
        .password = "anonymous@",
        .remote_path = "/pub/archive.tar.gz",
        .destination_path = "downloads/archive.tar.gz",
        .progress = .auto,
        .verify = .{
            .min_size = 10,
        },
    }) catch |err| {
        std.debug.print("FTP download handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("FTP download finished: {s} ({d} bytes)\n", .{ res.destination, res.downloaded_bytes });
}
