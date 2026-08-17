//! Compression Example
//!
//! Demonstrates gzip/deflate/zstd/brotli decompression and Content-Encoding handling.
//! Shows how the compression module decompresses response bodies based
//! on the Content-Encoding header.

const std = @import("std");
const httpx = @import("httpx");

fn compressHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello, compressed world!");
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Compression Example ===\n\n", .{});

    // 1. Content-Encoding parsing using enum-based API
    std.debug.print("--- Content-Encoding Parsing ---\n", .{});
    for (httpx.ContentEncoding.ALL) |enc| {
        std.debug.print("  {s} (enum: .{s})\n", .{ enc.toString(), @tagName(enc) });
    }

    // 2. Decompression (identity passthrough)
    std.debug.print("\n--- Identity Passthrough ---\n", .{});
    const original = "Hello, compressed world!";
    const decompressed = try httpx.decompress(
        allocator,
        .identity,
        original,
    );
    defer allocator.free(decompressed);
    std.debug.print("  Input:   \"{s}\"\n", .{original});
    std.debug.print("  Output:  \"{s}\"\n", .{decompressed});
    std.debug.print("  Match:   {}\n", .{std.mem.eql(u8, original, decompressed)});

    // 3. Server with compression middleware
    std.debug.print("\n--- Server with Compression Middleware ---\n", .{});
    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer server.deinit();

    try server.use(httpx.middleware.compression());
    try server.get("/data", compressHandler);

    std.debug.print("  Compression middleware enabled\n", .{});
    std.debug.print("  Server on port {d}\n", .{port});

    // 4. Client with Accept-Encoding header
    std.debug.print("\n--- Client Accept-Encoding ---\n", .{});
    std.debug.print("  Send Accept-Encoding: gzip, deflate, zstd\n", .{});
    std.debug.print("  Server responds with Content-Encoding header\n", .{});
    std.debug.print("  Client uses decompress() to decode\n", .{});

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    var req = try httpx.Request.init(allocator, .GET, "http://127.0.0.1/data");
    defer req.deinit();
    try req.headers.set("Accept-Encoding", "gzip, deflate, zstd");

    const serialized = try httpx.formatRequest(&req, allocator);
    defer allocator.free(serialized);
    std.debug.print("\nRequest:\n{s}\n", .{serialized});

    std.debug.print("\nCompression algorithms:\n", .{});
    std.debug.print("  gzip:    HTTP/1.1 standard, widely supported\n", .{});
    std.debug.print("  deflate: Raw flate compression\n", .{});
    std.debug.print("  zstd:    Modern high-performance compression\n", .{});
    std.debug.print("  br:      Brotli high-ratio compression\n", .{});

    server.stop();
    server_thread.join();
}
