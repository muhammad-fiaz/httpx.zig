const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const data = try ctx.allocator.alloc(u8, 2048);
    @memset(data, '%');
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/pdf",
        .headers = &.{
            .{ .name = "Accept-Ranges", .value = "bytes" },
        },
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
    std.debug.print("==> Downloading {s} with Range resume policy (.resumePartial)...\n", .{sampleUrl});

    // Uses .resumePartial (short canonical resume policy)
    const result = client.download(
        sampleUrl,
        .{
            .path = "downloads/resumable-sample.pdf",
            .existing = .resumePartial,
            .progress = .auto,
            .maxRetries = 3,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Resume download handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    std.debug.print("Download status: resumed={any}, downloaded={d} bytes to {s}\n", .{
        result.resumed,
        result.downloadedBytes,
        result.destination,
    });

    server.requestShutdown();
    thread.join();
}
