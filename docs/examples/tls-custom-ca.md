# TLS Custom CA Certificate

Demonstrates using custom CA certificates with self-signed certificates for development and testing.

## Features Demonstrated

- Self-signed certificate generation
- `@embedFile` for embedding certificates
- `verify_ssl=false` for development mode
- Custom CA certificate workflow

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Served with custom CA cert");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load CA cert (self-signed, used as both server cert and CA)
    const ca_pem = @embedFile("certs/server_ec.crt");
    std.debug.print("Loaded CA cert: {d} bytes\n", .{ca_pem.len});

    // Start local TLS server with self-signed cert
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
    try server.get("/secure", handler);

    const server_thread = try server.listenInBackground();
    defer server_thread.join();
    defer server.stop();
    const port = server.config.port;

    // Connect with verify_ssl=false (trust the self-signed cert)
    const config = tls.TlsConfig.insecureWithH2(allocator);
    var sock = try httpx.Socket.create();
    defer sock.close();
    try sock.connectHost("127.0.0.1", port);

    var session = tls.TlsSession.init(config);
    session.socket = &sock;
    try session.handshake("127.0.0.1");

    const req = "GET /secure HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try session.writeAll(req);

    var buf: [4096]u8 = undefined;
    const n = try session.read(&buf);
    std.debug.print("Response: {d} bytes\n", .{n});
}
```

## Run

```bash
zig build run-all-tls_custom_ca
```

## Production CA Workflow

1. Generate CA: `openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 365 -subj '/CN=MyCA'`
2. Embed in Zig: `const ca_pem = @embedFile("ca.crt");`
3. Pass to TLS config for certificate verification
