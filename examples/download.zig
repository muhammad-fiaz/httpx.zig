const std = @import("std");
const httpx = @import("httpx");

fn bytesHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/bytes/90", .{port});
    std.debug.print("==> Downloading {s} with zero-config progress bar...\n", .{sampleUrl});

    // 1. Download to a specific directory (automatically uses URL basename "90")
    const result1 = client.download(
        sampleUrl,
        .{
            .path = "downloads/",
            .progress = .enabled,
            .existing = .overwrite,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download to directory handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    std.debug.print("Downloaded with auto filename: {s} ({d} bytes in {d} ms)\n", .{
        result1.destinationPath(),
        result1.downloadedBytes,
        result1.elapsedMs,
    });

    // 2. Download with explicit custom destination filename
    const result2 = client.download(
        sampleUrl,
        .{
            .path = "downloads/custom_named_doc.bin",
            .progress = .enabled,
            .existing = .overwrite,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download with explicit name handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    std.debug.print("Downloaded with explicit filename: {s} ({d} bytes)\n", .{
        result2.destinationPath(),
        result2.downloadedBytes,
    });

    server.requestShutdown();
    thread.join();
}
