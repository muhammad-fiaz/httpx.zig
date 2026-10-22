//! Independent HTTP/2 (h2c) server used by the interoperability runner.
//!
//! Speaks cleartext prior-knowledge HTTP/2 only and prints the bound port
//! on stdout so an external client (Python `h2`) can dial it.

const std = @import("std");
const httpx = @import("httpx");

fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.method != .GET) return .{ .status = 405, .body = "method" };
    return .{
        .status = 200,
        .body = "hello-from-zig-h2",
        .contentType = "text/plain",
    };
}

fn echo(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.method != .POST) return .{ .status = 405, .body = "method" };
    return .{
        .status = 200,
        .body = ctx.body,
        .contentType = "application/octet-stream",
    };
}

fn large(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.method != .GET) return .{ .status = 405, .body = "method" };
    const body = try ctx.allocator.alloc(u8, 256 * 1024);
    for (body, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    return .{ .status = 200, .body = body, .contentType = "application/octet-stream" };
}

fn hostEcho(ctx: *httpx.Context) anyerror!httpx.Response {
    var host: []const u8 = "";
    for (ctx.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    return .{ .status = 200, .body = host, .contentType = "text/plain" };
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const port_arg = if (argv.len > 1) argv[1] else "0";
    const port = try std.fmt.parseInt(u16, port_arg, 10);

    var server = try httpx.Server.init(a, io, .{
        .host = "127.0.0.1",
        .port = port,
        .httpVersion = .http2,
        .enableDocs = false,
        .maxBody = 4 * 1024 * 1024,
    });
    defer server.deinit();

    try server.get("/hello", hello);
    try server.post("/echo", echo);
    try server.get("/large", large);
    try server.get("/host", hostEcho);

    std.debug.print("LISTEN {d}\n", .{server.localPort()});
    server.run();
}
