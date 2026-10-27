const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = try ctx.allocator.alloc(u8, 1024);
    @memset(data, '%');
    return .{
        .status = 200,
        .body = data,
        .contentType = "application/pdf",
        .headers = &.{
            .{ .name = "Accept-Ranges", .value = "bytes" },
            .{ .name = "ETag", .value = "\"etag-xyz\"" },
            .{ .name = "Last-Modified", .value = "Wed, 21 Oct 2026 07:28:00 GMT" },
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
    try server.router.add(.HEAD, "/sample-local-pdf.pdf", pdfHandler, .{});
    try server.router.add(.GET, "/sample-local-pdf.pdf", pdfHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/sample-local-pdf.pdf", .{port});
    std.debug.print("==> Inspecting remote file info without downloading: {s}\n", .{sampleUrl});

    const info = client.lookupFileInfo(sampleUrl, .{}) catch |err| {
        std.debug.print("Lookup handled: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };

    var sizeBuf: [32]u8 = undefined;
    std.debug.print("Remote File Metadata:\n", .{});
    std.debug.print("  - Status:           {d}\n", .{info.status});
    std.debug.print("  - File Name:        {s}\n", .{info.fileName()});
    std.debug.print("  - File Size:        {?d} bytes ({s})\n", .{ info.fileSize, info.formatSize(&sizeBuf) });
    std.debug.print("  - Content Type:     {?s}\n", .{info.contentType()});
    std.debug.print("  - Accepts Ranges:   {any}\n", .{info.acceptsRanges});
    std.debug.print("  - ETag:             {?s}\n", .{info.etag()});
    std.debug.print("  - Last-Modified:    {?s}\n", .{info.lastModified()});

    server.requestShutdown();
    thread.join();
}
