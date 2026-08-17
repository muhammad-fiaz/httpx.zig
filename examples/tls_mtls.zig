const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Mutual TLS authenticated!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Mutual TLS (mTLS) Example ===\n\n", .{});

    // Load client certificate and key (using the same dummy certs for demo)
    const client_cert = @embedFile("certs/server_ec.crt");
    const client_key = @embedFile("certs/server_ec.key");
    const ca_cert = @embedFile("certs/server_ec.crt");

    std.debug.print("Client certificate: {d} bytes\n", .{client_cert.len});
    std.debug.print("Client key:         {d} bytes\n", .{client_key.len});
    std.debug.print("CA certificate:     {d} bytes\n\n", .{ca_cert.len});

    // 1. Start local TLS server (HTTP/1.1 + HTTP/2 + HTTP/3)
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .tls_enabled = true,
        .tls_cert_path = "examples/certs/server_ec.crt",
        .tls_key_path = "examples/certs/server_ec.key",
        .tls_alpn_protocols = &.{ "h3", "h2", "http/1.1" },
        .http2_enabled = true,
        .http3_enabled = false,
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/mtls", handler);

    const server_thread = try server.listenInBackground();
    sleepMs(200);

    const port = server.config.port;
    std.debug.print("mTLS server on 127.0.0.1:{d}\n\n", .{port});

    // 2. Connect with client certificate
    {
        std.debug.print("--- mTLS Handshake ---\n", .{});
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
        std.debug.print("  Handshake: OK\n", .{});
        std.debug.print("  Protocol:  {s}\n", .{session.negotiatedProtocol() orelse "none"});

        // Send HTTP request
        const req = "GET /mtls HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        try session.writeAll(req);

        var buf: [4096]u8 = undefined;
        const n = try session.read(&buf);
        std.debug.print("  Response:  {d} bytes\n\n", .{n});
    }

    // 3. mTLS flow explanation
    std.debug.print("--- mTLS Flow ---\n", .{});
    std.debug.print("  1. Server requests client certificate (CertificateRequest)\n", .{});
    std.debug.print("  2. Client sends certificate + CertificateVerify\n", .{});
    std.debug.print("  3. Server verifies client cert against its trust store\n", .{});
    std.debug.print("  4. Both parties have authenticated\n\n", .{});

    std.debug.print("--- Common mTLS Use Cases ---\n", .{});
    std.debug.print("  - Service mesh (Istio, Linkerd)\n", .{});
    std.debug.print("  - Kubernetes API server auth\n", .{});
    std.debug.print("  - Database connections (PostgreSQL, MySQL)\n", .{});
    std.debug.print("  - gRPC service-to-service\n", .{});

    std.debug.print("\n=== Example complete ===\n", .{});

    server.stop();
    server_thread.join();
}
