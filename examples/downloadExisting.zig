const std = @import("std");
const httpx = @import("httpx");

fn pdfHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const data = try ctx.allocator.alloc(u8, 1024);
    @memset(data, '%');
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
    std.debug.print("==> Demonstrating existing-file policies (.skip, .verifyExisting, .fail)...\n", .{});

    // Policy 1: Verify on-disk file size/checksum first; if valid, skip downloading!
    const res1 = client.download(
        sampleUrl,
        .{
            .path = "downloads/existing-sample.pdf",
            .existing = .verifyExisting,
            .verify = .{
                .minSize = 100,
            },
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Download 1: {s}\n", .{@errorName(err)});
        server.requestShutdown();
        thread.join();
        return;
    };
    std.debug.print("Download 1 result: skipped={any}, verified={any}\n", .{ res1.skipped, res1.verified });

    // Policy 2: Fail if destination already exists
    const res2 = client.download(
        sampleUrl,
        .{
            .path = "downloads/existing-sample.pdf",
            .existing = .fail,
        },
    );
    if (res2) |_| {} else |err| {
        std.debug.print("Download 2 (expect fail): caught {s}\n", .{@errorName(err)});
    }

    server.requestShutdown();
    thread.join();
}
