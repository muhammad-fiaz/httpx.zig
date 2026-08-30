//! Streaming response body through `Response.reader()`.
//!
//! Run with: `zig build run-streaming`
//!
//! Demonstrates the zero-copy fixed-body reader. For chunked or large
//! streaming bodies, the client always buffers the full response up to
//! `max_response_size`; for long-running streams use the lower-level
//! HTTP/1 transport instead.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var response = try client.get(.{
        .url = "http://httpbun.com/bytes/4096",
        .max_response_size = 8 * 1024 * 1024,
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
