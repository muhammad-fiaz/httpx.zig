//! Streaming response body through `Response.reader()`.
//!
//! Run with: `zig build run-streaming`
//!
//! Demonstrates the zero-copy fixed-body reader. For chunked or large
//! streaming bodies, the client always buffers the full response up to
//! `maxResponseSize`; for long-running streams use the lower-level
//! HTTP/1 transport instead.

const std = @import("std");
const httpx = @import("httpx");

fn bytesHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const data = try ctx.allocator.alloc(u8, 4096);
    @memset(data, 'A');
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
        .maxConnections = 1,
    });
    defer server.deinit();
    try server.router.add(.GET, "/bytes/4096", bytesHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/bytes/4096", .{port});

    var response = try client.get(url, .{
        .maxResponseSize = 8 * 1024 * 1024,
    });
    defer response.deinit();

    // `Response.reader()` returns a `std.Io.Reader` over the buffered body
    // (Zig 0.16 `std.Io.Reader.fixed`). A short read is the natural
    // end-of-stream signal: `readSliceShort` returns the number of bytes
    // actually read, and a zero return means the stream is exhausted.
    var buf: [1024]u8 = undefined;
    var reader = response.reader();
    var total: usize = 0;
    while (true) {
        const n = reader.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    std.debug.print("streamed {d} bytes\n", .{total});
}
