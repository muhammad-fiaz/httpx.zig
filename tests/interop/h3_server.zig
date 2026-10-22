//! Independent HTTP/3 server used by the interoperability runner.
//!
//! Binds the native QUIC/TLS endpoint, prints the TCP and UDP ports, and
//! serves HTTP/3 routes to external clients (Python `aioquic`, curl, or the
//! Zig interop client). Pass `--retry` after the key path to require a Retry
//! token and exercise address validation.

const std = @import("std");
const httpx = @import("httpx");

fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    if (ctx.method != .GET) return .{ .status = 405, .body = "method" };
    return .{
        .status = 200,
        .body = "hello-from-zig-h3",
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
    const cert_path = if (argv.len > 1) argv[1] else "src/protocols/tls/testdata/localhostCert.pem";
    const key_path = if (argv.len > 2) argv[2] else "src/protocols/tls/testdata/localhostKey.pem";
    const retry = argv.len > 3 and std.mem.eql(u8, argv[3], "--retry");
    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, cert_path, a, .limited(64 * 1024));
    defer a.free(cert_pem);
    const key_pem = try std.Io.Dir.cwd().readFileAlloc(io, key_path, a, .limited(64 * 1024));
    defer a.free(key_pem);

    var server = try httpx.Server.init(a, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .http3Retry = retry,
        .http2 = false,
        .http11 = false,
        .http10 = false,
        .tls = .{
            .certificatePem = cert_pem,
            .privateKeyPem = key_pem,
        },
        .enableDocs = false,
        .maxBody = 4 * 1024 * 1024,
    });
    defer server.deinit();

    try server.get("/hello", hello);
    try server.post("/echo", echo);
    try server.get("/host", hostEcho);

    const udp = server.http3.port() orelse return error.Http3Unavailable;
    std.debug.print("LISTEN {d} {d}\n", .{ server.localPort(), udp });
    server.run();
}
