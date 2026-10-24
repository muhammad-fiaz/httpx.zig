const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
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

    var server = try httpx.server.Server.init(allocator, io, .{
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
    std.debug.print("==> Downloading {s} with size and cryptographic verification...\n", .{sampleUrl});

    const result = client.download(
        sampleUrl,
        .{
            .path = "downloads/verified-sample.pdf",
            .verify = .{
                .minSize = 100,
                .maxSize = 50 * 1024 * 1024,
            },
            .progress = .auto,
            .atomic = true,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Verified download handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    if (result.verified) {
        std.debug.print("File verified and saved successfully to: {s}\n", .{
            result.destinationPath(),
        });
        if (result.sha256Hex) |h| {
            std.debug.print("SHA-256: {s}\n", .{h});
        }
    }

    server.requestShutdown();
    thread.join();
}
