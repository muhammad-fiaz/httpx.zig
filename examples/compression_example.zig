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

    for (httpx.ContentEncoding.ALL) |enc| {
        std.debug.print("  {s} (enum: .{s})\n", .{ enc.toString(), @tagName(enc) });
    }

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

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer server.deinit();

    try server.use(httpx.middleware.compression());
    try server.get("/data", compressHandler);

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

    server.stop();
    server_thread.join();
}
