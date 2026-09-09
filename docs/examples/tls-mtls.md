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
    const io = std.Io.Threaded.global_single_threaded.io();

    // Load client certificate and key (using the same dummy certs for demo)
    const client_cert = @embedFile("certs/server_ec.crt");
    const client_key = @embedFile("certs/server_ec.key");
    const ca_cert = @embedFile("certs/server_ec.crt");

    std.debug.print("Client certificate: {d} bytes\n", .{client_cert.len});
    std.debug.print("Client key:         {d} bytes\n", .{client_key.len});
    std.debug.print("CA certificate:     {d} bytes\n", .{ca_cert.len});

    // Start a local TLS listener with a self-signed identity.
    // mTLS client-certificate enforcement is configured via
    // ServerConfig.clientAuth / clientCa (see the TLS guide).
    var listener = try httpx.tls.Listener.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .defaultIdentity = .{
            .certChainPem = client_cert,
            .privateKeyPem = client_key,
        },
    });
    defer listener.deinit();
    const port = listener.localPort();
    std.debug.print("mTLS-capable TLS listening on {d}\n", .{port});
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
