const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello over TLS!");
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
        .http3_enabled = true,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/hello", handler);

    const server_thread = try server.listenInBackground();
    sleepMs(200);

    const port = server.config.port;

    var sock = httpx.Socket.create() catch |err| {
        std.debug.print("Socket error: {}\n", .{err});
        return;
    };
    defer sock.close();

    sock.connectHost("127.0.0.1", port) catch |err| {
        std.debug.print("Connect error: {}\n", .{err});
        return;
    };

    const tls_config = tls.TlsConfig.insecureWithH2(allocator);
    var session = tls.TlsSession.init(tls_config);
    session.socket = &sock;

    session.handshake("127.0.0.1") catch |err| {
        std.debug.print("TLS handshake error: {}\n", .{err});
        return;
    };

    const request = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    session.writeAll(request) catch |err| {
        std.debug.print("Write error: {}\n", .{err});
        return;
    };

    var response_buf: [4096]u8 = undefined;
    const n = session.read(&response_buf) catch |err| {
        std.debug.print("Read error: {}\n", .{err});
        return;
    };
    std.debug.print("Received {d} bytes over TLS\n", .{n});

    server.stop();
    server_thread.join();
}
