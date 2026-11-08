# TLS Server Example

Demonstrates a TLS server using ECDSA certificate/key PEM files, served through the direct `httpx.Server` API with the TLS identity passed in the `.tls` config.

## Covers

- TLS server with ECDSA P-256 certificates (custom implementation)
- ALPN negotiation for protocol selection (h2 or http/1.1 over TLS)
- TLS client handshake with certificate verification bypass
- HTTP request/response over TLS 1.3
- HTTP/2 ALPN detection

## Example

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.protocols.tls;

fn helloHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.text("Hello from TLS server!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Start an HTTPS server with a self-signed identity.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .tls = .{
            .certificatePem = @embedFile("cert.pem"),
            .privateKeyPem = @embedFile("key.pem"),
        },
    });
    defer server.deinit();
    try server.get("/", .{ .handler = helloHandler });

    const port = server.localPort();
}
```

## Expected Output

```text
GET / -> 200 Hello from TLS server!
```

The ephemeral loopback port varies per run; certificate material and handshake details vary by deployment. Loopback only with a self-signed identity, no external service required.

## Run

```bash
zig build run-tls-server
```
