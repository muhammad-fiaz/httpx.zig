# TLS Server Example

Demonstrates the custom TLS server implementation built from scratch. Shows TLS configuration with ECDSA certificate/key PEM files, ALPN negotiation, HTTP/1.1 and HTTP/2 over TLS, and TLS client handshake with HTTP request/response.

## Features Demonstrated

- TLS server with ECDSA P-256 certificates (custom implementation)
- ALPN negotiation for protocol selection (h3, h2, http/1.1)
- TLS client handshake with certificate verification bypass
- HTTP request/response over TLS 1.3
- HTTP/2 ALPN detection

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
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
        .keep_alive = true,
    });
    defer server.deinit();

    try server.get("/hello", helloHandler);

    const server_thread = try server.listenInBackground();
    defer server_thread.join();
    defer server.stop();

    const port = server.config.port;

    // TLS client handshake
    var sock = try httpx.Socket.create();
    defer sock.close();
    try sock.connectHost("127.0.0.1", port);

    const tls_config = tls.TlsConfig.insecureWithH2(allocator);
    var session = tls.TlsSession.init(tls_config);
    session.socket = &sock;
    try session.handshake("127.0.0.1");

    // Send HTTP request over TLS
    const request = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try session.writeAll(request);

    // Read response
    var response_buf: [4096]u8 = undefined;
    const n = try session.read(&response_buf);
    std.debug.print("Received {d} bytes over TLS\n", .{n});
}
```

## Run

```bash
zig build run-all-tls_server
```

## Checklist

- [x] Server starts with TLS enabled using ECDSA P-256 certificates
- [x] Certificate and key PEM files are loaded
- [x] TLS handshake completes successfully (TLS 1.3)
- [x] ALPN negotiates h3, h2, or http/1.1
- [x] HTTP/2 is detected via ALPN
- [x] HTTP request over TLS returns 200 OK
- [x] Supports TLS 1.2 and 1.3 cipher suites
- [x] Record-level fragmentation works correctly
