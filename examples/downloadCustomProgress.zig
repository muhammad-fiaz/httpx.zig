const std = @import("std");
const httpx = @import("httpx");

const DownloadObserver = struct {
    taskId: u32,

    fn onProgress(info: httpx.client.progressInfo, userData: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userData.?));
        const pct = if (info.percentage) |p| p else 0.0;
        const stateColor: []const u8 = switch (info.state) {
            .completed => "\x1b[32m",
            .downloading => "\x1b[36m",
            .verifying => "\x1b[35m",
            .failed => "\x1b[31m",
            .cancelled => "\x1b[33m",
            .starting => "\x1b[34m",
        };
        const reset = "\x1b[0m";

        std.debug.print("[Observer Task {d}] State: {s}{s}{s} | Progress: {d:.1}% ({d} bytes) | Speed: {d:.2} KB/s | ETA: {?d}s\n", .{
            self.taskId,
            stateColor,
            @tagName(info.state),
            reset,
            pct,
            info.downloadedBytes,
            info.speedBps / 1024.0,
            info.etaSeconds,
        });
    }
};

fn bytesHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const data = try ctx.allocator.alloc(u8, 90);
    @memset(data, 'X');
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/octet-stream",
    };
}

fn notFoundHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{ .status = 404, .body = "not found" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();
    try server.router.add(.GET, "/bytes/90", bytesHandler, .{});
    try server.router.add(.GET, "/status/404", notFoundHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var observer = DownloadObserver{
        .taskId = 101,
    };

    // 1. Successful download test
    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/bytes/90", .{port});
    std.debug.print("==> Downloading {s} with custom progress callback observer...\n", .{sampleUrl});

    _ = client.download(
        sampleUrl,
        .{
            .path = "downloads/observed_download.bin",
            .progress = .custom,
            .onProgress = DownloadObserver.onProgress,
            .userData = &observer,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download error handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    // 2. Error handling test: 404 Not Found
    const notFoundUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/status/404", .{port});
    std.debug.print("\n==> Testing 404 Not Found error handling on {s}...\n", .{notFoundUrl});
    _ = client.download(
        notFoundUrl,
        .{
            .path = "downloads/not_found.bin",
            .progress = .quiet,
        },
    ) catch |err| {
        std.debug.print("Correctly caught error for 404: {s}\n", .{
            @errorName(err),
        });
    };

    // 3. Error handling test: Invalid URL
    std.debug.print("\n==> Testing invalid URL error handling...\n", .{});
    _ = client.download(
        "http://invalid.nonexistent.domain.xyz12345/nonexistent",
        .{
            .path = "downloads/invalid.bin",
            .progress = .quiet,
            .maxRetries = 0,
        },
    ) catch |err| {
        std.debug.print("Correctly caught network/URL error: {s}\n", .{
            @errorName(err),
        });
    };

    server.requestShutdown();
    thread.join();
}
