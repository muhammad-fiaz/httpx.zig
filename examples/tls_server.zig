const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn apiHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .status = "ok",
        .message = "Served over TLS with custom implementation",
    });
}

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from TLS server!");
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .tls_enabled = true,
        .tls_cert_path = "examples/certs/server_ec.crt",
        .tls_key_path = "examples/certs/server_ec.key",
        .tls_alpn_protocols = &.{ "h3", "h2", "http/1.1" },
        .http2_enabled = true,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/api/data", apiHandler);
    try server.get("/hello", helloHandler);

    const server_thread = try server.listenInBackground();

    const port = server.config.port;
    sleepMs(200);

    var sock = httpx.Socket.create() catch |err| {
        std.debug.print("  Socket create error: {}\n", .{err});
        return;
    };
    defer sock.close();

    sock.connectHost("127.0.0.1", port) catch |err| {
        std.debug.print("  Connect error: {}\n", .{err});
        return;
    };

    const tls_config = tls.TlsConfig.insecureWithH2(allocator);
    var session = tls.TlsSession.init(tls_config);
    session.socket = &sock;

    session.handshake("127.0.0.1") catch |err| {
        std.debug.print("  TLS handshake error: {}\n", .{err});
        return;
    };

    std.debug.print("  Protocol: {s}\n", .{session.negotiatedProtocol() orelse "none"});
    std.debug.print("  HTTP/2 negotiated: {}\n", .{session.isHTTP2()});

    const request = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    session.writeAll(request) catch |err| {
        std.debug.print("  Write error: {}\n", .{err});
        return;
    };

    var response_buf: [4096]u8 = undefined;
    const n = session.read(&response_buf) catch |err| {
        std.debug.print("  Read error: {}\n", .{err});
        return;
    };
    if (n > 0) {
        std.debug.print("  Received {d} bytes\n", .{n});
        const response = response_buf[0..n];
        if (std.mem.indexOf(u8, response, "200")) |_| {
            std.debug.print("  Response: HTTP/1.1 200 OK\n", .{});
        }
    }

    server.stop();
    server_thread.join();
}
