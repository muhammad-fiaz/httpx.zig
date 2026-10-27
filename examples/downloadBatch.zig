const std = @import("std");
const httpx = @import("httpx");

const DownloadTask = struct {
    taskId: usize,
    url: []const u8,
    dest: []const u8,

    fn run(ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const io = std.Io.Threaded.global_single_threaded.io();
        var c = httpx.Client.init(std.heap.smp_allocator, io, .{});
        defer c.deinit();

        _ = try c.download(self.url, .{
            .path = self.dest,
            .progress = .enabled,
            .existing = .overwrite,
            .cancelFlag = cancel,
            .createDirs = true,
        });
    }
};

fn bytesHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = try ctx.allocator.alloc(u8, 90);
    @memset(data, 'X');
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/octet-stream",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();
    try server.router.add(.GET, "/bytes/90", bytesHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/bytes/90", .{port});

    var tasks = [_]DownloadTask{
        .{ .taskId = 1, .url = sampleUrl, .dest = "downloads/batch_file1.bin" },
        .{ .taskId = 2, .url = sampleUrl, .dest = "downloads/batch_file2.bin" },
        .{ .taskId = 3, .url = sampleUrl, .dest = "downloads/batch_file3.bin" },
    };

    var pool = try httpx.concurrency.Pool.init(allocator, io, .{
        .workers = 4,
    });
    defer pool.deinit();

    std.debug.print("==> Starting concurrent batch download with built-in zero-config progress bar...\n", .{});

    for (&tasks) |*task| {
        try pool.submit(DownloadTask.run, task, null);
    }

    pool.shutdownDrain();
    pool.join();

    server.requestShutdown();
    thread.join();

    std.debug.print("Batch download completed successfully.\n", .{});
}
