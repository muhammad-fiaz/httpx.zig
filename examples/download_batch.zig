const std = @import("std");
const httpx = @import("httpx");

const DownloadTask = struct {
    task_id: usize,
    url: []const u8,
    dest: []const u8,

    fn run(ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        var c = httpx.Client.init(std.heap.smp_allocator, .{}) catch return;
        defer c.deinit();

        _ = c.download(self.url, self.dest, .{
            .progress = .enabled,
            .existing = .overwrite,
            .cancel_flag = cancel,
            .create_dirs = true,
        }) catch {};
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_url = "https://httpbun.com/bytes/90";

    var tasks = [_]DownloadTask{
        .{ .task_id = 1, .url = sample_url, .dest = "downloads/batch_file1.bin" },
        .{ .task_id = 2, .url = sample_url, .dest = "downloads/batch_file2.bin" },
        .{ .task_id = 3, .url = sample_url, .dest = "downloads/batch_file3.bin" },
    };

    var pool = try httpx.WorkerPool.init(allocator, .{
        .workers = 4,
    });
    defer pool.deinit();

    std.debug.print("==> Starting concurrent batch download with built-in zero-config progress bar...\n", .{});

    for (&tasks) |*task| {
        try pool.submit(DownloadTask.run, task, null);
    }

    pool.shutdownDrain();
    pool.join();

    std.debug.print("Batch download completed successfully.\n", .{});
}






