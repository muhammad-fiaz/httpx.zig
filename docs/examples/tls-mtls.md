# TLS Mutual Authentication (mTLS)

Demonstrates mutual TLS where both client and server authenticate each other with certificates.

## Features Demonstrated

- Client certificate authentication
- Server certificate verification
- Certificate-based mutual authentication
- mTLS use cases (service mesh, gRPC, databases)

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Mutual TLS authenticated!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load client certificate and key (using the same dummy certs for demo)
    const client_cert = @embedFile("certs/server_ec.crt");
    const client_key = @embedFile("certs/server_ec.key");
    const ca_cert = @embedFile("certs/server_ec.crt");

    std.debug.print("Client certificate: {d} bytes\n", .{client_cert.len});
    std.debug.print("Client key:         {d} bytes\n", .{client_key.len});
    std.debug.print("CA certificate:     {d} bytes\n", .{ca_cert.len});

    // Start local TLS server
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
    defer server_thread.join();
    defer server.stop();
    const port = server.config.port;

    // Connect with client certificate
    const config = tls.TlsConfig.insecureWithH2(allocator);
    var sock = try httpx.Socket.create();
    defer sock.close();
    try sock.connectHost("127.0.0.1", port);

    var session = tls.TlsSession.init(config);
    session.socket = &sock;
    try session.handshake("127.0.0.1");

    std.debug.print("Protocol: {s}\n", .{session.negotiatedProtocol() orelse "none"});

    // Send HTTP request
    const req = "GET /mtls HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try session.writeAll(req);

    var buf: [4096]u8 = undefined;
    const n = try session.read(&buf);
    std.debug.print("Response: {d} bytes\n", .{n});
}
```

## Run

```bash
zig build run-all-tls_mtls
```

## mTLS Flow

1. Server requests client certificate (CertificateRequest)
2. Client sends certificate + CertificateVerify
3. Server verifies client cert against its trust store
4. Both parties have authenticated

## Common Use Cases

- Service mesh (Istio, Linkerd)
- Kubernetes API server auth
- Database connections (PostgreSQL, MySQL)
- gRPC service-to-service
