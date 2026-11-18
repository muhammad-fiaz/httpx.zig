const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var ftp = httpx.client.ftp.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 21,
        .user = "anonymous",
        .password = "anonymous@",
    }) catch |err| {
        std.debug.print("FTP connection handled: {s}\n", .{@errorName(err)});
        return;
    };
    defer ftp.deinit();

    const res = ftp.download(.{
        .remotePath = "/pub/archive.tar.gz",
        .destinationPath = "downloads/archive.tar.gz",
        .progress = .auto,
        .verify = .{
            .minSize = 10,
        },
    }) catch |err| {
        std.debug.print("FTP download handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("FTP download finished: {s} ({d} bytes)\n", .{ res.destination, res.downloadedBytes });
}
