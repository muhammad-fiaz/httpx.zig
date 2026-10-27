const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = try ctx.allocator.alloc(u8, 64 * 1024);
    for (data, 0..) |*b, i| b.* = @truncate(i);
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/pdf",
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
    try server.router.add(.GET, "/sample-local-pdf.pdf", pdfHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/sample-local-pdf.pdf", .{port});
    std.debug.print("==> Updating local application asset from {s} with rollback backup...\n", .{sampleUrl});

    const res = client.updateFile(
        sampleUrl,
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
        server.requestShutdown();
        thread.join();
        return;
    };

    std.debug.print("Update succeeded: {s} ({d} bytes)\n", .{ res.destination, res.downloadedBytes });

    server.requestShutdown();
    thread.join();
}
