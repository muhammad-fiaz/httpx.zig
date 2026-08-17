//! Simplified API Aliases Demo
//!
//! Default mode runs against a local loopback server so alias calls succeed
//! without requiring external internet access.
//! Set HTTPX_EXAMPLE_ONLINE=1 to run live requests against httpbin.

const std = @import("std");
const httpx = @import("httpx");

const DemoUrls = struct {
    fetch: []const u8,
    get: []const u8,
    delete: []const u8,
    trace: []const u8,
    connect: []const u8,
    post: []const u8,
};

fn shouldUseLiveNetwork(environ: std.process.Environ, allocator: std.mem.Allocator) bool {
    const value = environ.getAlloc(allocator, "HTTPX_EXAMPLE_ONLINE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.InvalidWtf8 => return false,
        else => return false,
    };
    defer allocator.free(value);

    return std.mem.eql(u8, value, "1");
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

fn okHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("ok");
}

fn buildLocalUrls(allocator: std.mem.Allocator, port: u16) !DemoUrls {
    return .{
        .fetch = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/anything", .{port}),
        .get = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/get", .{port}),
        .delete = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/delete", .{port}),
        .trace = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/trace", .{port}),
        .connect = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/anything", .{port}),
        .post = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/post", .{port}),
    };
}

fn freeLocalUrls(allocator: std.mem.Allocator, urls: DemoUrls) void {
    allocator.free(urls.fetch);
    allocator.free(urls.get);
    allocator.free(urls.delete);
    allocator.free(urls.trace);
    allocator.free(urls.connect);
    allocator.free(urls.post);
}

fn printResult(label: []const u8, result: anyerror!httpx.Response) void {
    if (result) |resp| {
        var response = resp;
        defer response.deinit();
        std.debug.print("{s} status: {d}\n", .{ label, response.status.code });
    } else |err| {
        std.debug.print("{s} error: {s}\n", .{ label, @errorName(err) });
    }
}

fn runAliasCalls(allocator: std.mem.Allocator, urls: DemoUrls) void {
    const request_timeout: u64 = 5_000;

    // Compile-time alias checks so this demo validates the API surface.
    const fetch_ptr: *const fn ([]const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.fetch;
    const send_ptr: *const fn (httpx.Method, []const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.send;
    const delete_ptr: *const fn ([]const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.delete;
    const opts_ptr: *const fn ([]const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.opts;
    const trace_ptr: *const fn ([]const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.trace;
    const connect_ptr: *const fn ([]const u8, httpx.RequestOptions) anyerror!httpx.Response = httpx.connect;
    _ = fetch_ptr;
    _ = send_ptr;
    _ = delete_ptr;
    _ = opts_ptr;
    _ = trace_ptr;
    _ = connect_ptr;
    std.debug.print("Top-level alias symbols are available: fetch, send, delete, opts, trace, connect\n", .{});

    // Use explicit allocator + POST so default retry policy does not add backoff delays.
    printResult("httpx.sendWithAllocator(POST)", httpx.sendWithAllocator(allocator, .POST, urls.post, .{
        .timeout_ms = request_timeout,
        .json = "{\"ok\":true}",
    }));

    printResult("httpx.fetch", httpx.fetch(urls.fetch, .{ .timeout_ms = request_timeout }));
    printResult("httpx.send(GET)", httpx.send(.GET, urls.get, .{ .timeout_ms = request_timeout }));
    printResult("httpx.delete", httpx.delete(urls.delete, .{ .timeout_ms = request_timeout }));
    printResult("httpx.opts", httpx.opts(urls.get, .{ .timeout_ms = request_timeout }));
    printResult("httpx.trace", httpx.trace(urls.trace, .{ .timeout_ms = request_timeout }));
    printResult("httpx.connect", httpx.connect(urls.connect, .{ .timeout_ms = request_timeout }));

    // Client aliases.
    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withPoolLimits(32, 8);

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    printResult("client.fetch", client.fetch(urls.fetch, .{ .timeout_ms = request_timeout }));
    printResult("client.options", client.options(urls.get, .{ .timeout_ms = request_timeout }));
    printResult("client.del", client.del(urls.delete, .{ .timeout_ms = request_timeout }));
    printResult("client.opts", client.opts(urls.get, .{ .timeout_ms = request_timeout }));
    printResult("client.trace", client.trace(urls.trace, .{ .timeout_ms = request_timeout }));
    printResult("client.connect", client.connect(urls.connect, .{ .timeout_ms = request_timeout }));
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const live_mode = shouldUseLiveNetwork(init.minimal.environ, allocator);

    std.debug.print("=== Simplified API Aliases Demo ===\n\n", .{});
    std.debug.print("Mode: {s}\n", .{if (live_mode) "online (httpbin)" else "local loopback"});

    if (live_mode) {
        const urls = DemoUrls{
            .fetch = "http://httpbun.com/anything",
            .get = "http://httpbun.com/get",
            .delete = "http://httpbun.com/delete",
            .trace = "http://httpbun.com/trace",
            .connect = "http://httpbun.com/anything",
            .post = "http://httpbun.com/post",
        };
        runAliasCalls(allocator, urls);
        return;
    }

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
        .request_timeout_ms = 10_000,
    });
    defer server.deinit();

    try server.get("/get", okHandler);
    try server.get("/anything", okHandler);
    try server.post("/post", okHandler);
    try server.delete("/delete", okHandler);
    try server.options("/get", okHandler);
    try server.trace("/trace", okHandler);
    try server.connect("/anything", okHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);
    std.debug.print("Local demo server: http://127.0.0.1:{d}\n", .{port});

    const urls = try buildLocalUrls(allocator, port);
    defer freeLocalUrls(allocator, urls);

    runAliasCalls(allocator, urls);

    server.stop();
    server_thread.join();
}
