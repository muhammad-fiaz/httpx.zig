//! TLS Server Example
//!
//! Demonstrates the custom TLS server implementation built from scratch.
//! Shows how to:
//! - Configure a server with TLS enabled using cert/key PEM files
//! - Accept TLS connections with ALPN negotiation
//! - Handle HTTP/1.1, HTTP/2, and HTTP/3 over TLS
//! - Connect a TLS client to the server

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

    std.debug.print("=== TLS Server Example ===\n\n", .{});

    // 1. Create a server with TLS enabled
    std.debug.print("--- Server Configuration ---\n", .{});
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

    std.debug.print("  TLS: enabled (custom implementation)\n", .{});
    std.debug.print("  Cert: examples/certs/server_ec.crt\n", .{});
    std.debug.print("  Key:  examples/certs/server_ec.key\n", .{});
    std.debug.print("  ALPN: h3, h2, http/1.1\n", .{});
    std.debug.print("  HTTP/2: enabled\n", .{});
    std.debug.print("  HTTP/3: enabled\n", .{});

    // 2. Start the TLS server in background
    const server_thread = try server.listenInBackground();

    const port = server.config.port;
    sleepMs(200);
    std.debug.print("  Server listening on port {d}\n", .{port});

    // 3. TLS client handshake demonstration
    std.debug.print("\n--- TLS Client Handshake ---\n", .{});

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

    std.debug.print("  Connecting to 127.0.0.1:{d}...\n", .{port});
    session.handshake("127.0.0.1") catch |err| {
        std.debug.print("  TLS handshake error: {}\n", .{err});
        return;
    };

    std.debug.print("  TLS handshake complete!\n", .{});
    std.debug.print("  Protocol: {s}\n", .{session.negotiatedProtocol() orelse "none"});
    std.debug.print("  HTTP/2 negotiated: {}\n", .{session.isHttp2()});

    // 4. Send HTTP request over TLS
    std.debug.print("\n--- HTTP Request over TLS ---\n", .{});

    const request = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    session.writeAll(request) catch |err| {
        std.debug.print("  Write error: {}\n", .{err});
        return;
    };
    std.debug.print("  Sent: GET /hello\r\n", .{});

    // Read response
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

    // 5. Show the TLS record layer details
    std.debug.print("\n--- TLS Record Layer ---\n", .{});
    std.debug.print("  Our custom TLS implementation provides:\n", .{});
    std.debug.print("  - TLS 1.2: ECDHE_RSA_WITH_AES_128_GCM_SHA256\n", .{});
    std.debug.print("  - TLS 1.3: AES_128_GCM_SHA256, AES_256_GCM_SHA384\n", .{});
    std.debug.print("  - ALPN negotiation for protocol selection\n", .{});
    std.debug.print("  - AEAD encryption with proper nonce handling\n", .{});
    std.debug.print("  - Record-level fragmentation and reassembly\n", .{});

    // 6. Server config summary
    std.debug.print("\n--- Server Config Summary ---\n", .{});
    std.debug.print("  Host: {s}\n", .{server.config.host});
    std.debug.print("  Port: {d}\n", .{server.config.port});
    std.debug.print("  TLS: {}\n", .{server.config.tls_enabled});
    std.debug.print("  HTTP/2: {}\n", .{server.config.http2_enabled});
    std.debug.print("  Keep-alive: {}\n", .{server.config.keep_alive});

    std.debug.print("\n=== TLS Server Example Complete ===\n", .{});

    server.stop();
    server_thread.join();
}
