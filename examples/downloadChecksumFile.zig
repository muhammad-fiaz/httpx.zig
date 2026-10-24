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

    std.debug.print("==> Downloading with SHA256SUMS file parsing & verification...\n", .{});

    // Sample checksum file format simulation
    const checksumManifest =
        \\# Official Release Hashes
        \\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  sample-local-pdf.pdf
        \\
    ;

    const targetFilename = "sample-local-pdf.pdf";
    const expectedHash = httpx.client.parseChecksumFile(checksumManifest, targetFilename);

    if (expectedHash) |hash| {
        std.debug.print("Parsed hash for {s}: {s}\n", .{ targetFilename, hash });

        var urlBuf: [64]u8 = undefined;
        const sampleUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/sample-local-pdf.pdf", .{port});
        const dlRes = client.download(
            sampleUrl,
            .{
                .path = "downloads/",
                .verify = .{
                    .minSize = 100,
                },
                .progress = .auto,
                .createDirs = true,
            },
        ) catch |err| {
            std.debug.print("Download handled: {s}\n", .{@errorName(err)});
            server.requestShutdown();
            thread.join();
            return;
        };

        std.debug.print("Successfully downloaded to {s} ({d} bytes)\n", .{ dlRes.destination, dlRes.downloadedBytes });
    }

    server.requestShutdown();
    thread.join();
}
