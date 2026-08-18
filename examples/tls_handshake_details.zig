const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from TLS server!");
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

    {
        const config = tls.TlsConfig.insecureWithH2(allocator);
        var sock = try httpx.Socket.create();
        defer sock.close();
        try sock.connectHost("127.0.0.1", port);

        var session = tls.TlsSession.init(config);
        session.socket = &sock;

        session.handshake("127.0.0.1") catch |err| {
            std.debug.print("  Handshake failed: {}\n\n", .{err});
            return;
        };

        std.debug.print("  Handshake:    OK\n", .{});
        std.debug.print("  Protocol:     {s}\n", .{session.negotiatedProtocol() orelse "none"});
        std.debug.print("  HTTP/2:       {}\n", .{session.isHTTP2()});

        const req = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        try session.writeAll(req);

        var buf: [4096]u8 = undefined;
        const n = try session.read(&buf);
        std.debug.print("  Response:     {d} bytes\n", .{n});
    }

    server.stop();
    server_thread.join();
}
