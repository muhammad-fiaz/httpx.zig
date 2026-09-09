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
    const io = std.Io.Threaded.global_single_threaded.io();

    // Start a local TLS listener with a self-signed identity.
    // (See examples/tls_server.zig for the runnable version.)
    var listener = try httpx.tls.Listener.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .defaultIdentity = .{
            .certChainPem = @embedFile("cert.pem"),
            .privateKeyPem = @embedFile("key.pem"),
        },
    });
    defer listener.deinit();

    const port = listener.localPort();
    std.debug.print("TLS listening on {d}\n", .{port});
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
