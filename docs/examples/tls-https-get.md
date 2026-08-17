# TLS HTTPS GET

Simple HTTPS GET request via a local TLS server demonstrating HTTP/1.1, HTTP/2, and HTTP/3 support.

## Features Demonstrated

- TLS server with self-signed certificates
- TLS client handshake with ALPN negotiation
- HTTP request/response over TLS
- HTTP/1.1, HTTP/2, and HTTP/3 protocol support

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello over TLS!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start local TLS server with dummy certs (HTTP/1.1 + HTTP/2 + HTTP/3)
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
    defer server_thread.join();
    defer server.stop();

    const port = server.config.port;

    // Connect TLS client
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
zig build run-all-tls_https_get
```
