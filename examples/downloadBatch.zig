//! Concurrent downloads of multiple files with one shared client.
//!
//! The worker pool runs each task through `client.download`; the client
//! connection pool, DNS cache, and TLS session cache are all internally
//! synchronized, so a single client is safe across threads.
//!
//! Run with: `zig build run-download-batch`

const std = @import("std");
const httpx = @import("httpx");

const Job = struct {
    client: *httpx.Client,
    task: httpx.client.download.Task,

    fn run(ctx: ?*anyopaque, cancel: *std.atomic.Value(bool)) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        _ = try self.client.download(self.task.url, .{
            .path = self.task.dest,
            .progress = .disabled,
            .existing = .overwrite,
            .cancel = cancel,
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
    try server.get("/bytes/90", .{ .handler = bytesHandler });
    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/bytes/90", .{port});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var jobs = [_]Job{
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file1.bin" } },
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file2.bin" } },
        .{ .client = &client, .task = .{ .url = sampleUrl, .dest = "downloads/batch_file3.bin" } },
    };

    var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 3 });
    defer pool.deinit();

    for (&jobs) |*job| {
        try pool.submit(Job.run, job, null);
    }

    pool.shutdownDrain();
    pool.join();
}
