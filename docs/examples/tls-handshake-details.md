# TLS Handshake Details

Demonstrates TLS handshake with detailed information about negotiated protocol, cipher suites, and key exchange groups.

## Features Demonstrated

- TLS handshake execution
- Protocol negotiation (HTTP/1.1, HTTP/2, HTTP/3)
- Cipher suite information
- Key exchange group details
- HTTP/2 detection via `isHttp2()`

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn handler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello from TLS server!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Start a local TLS listener with a self-signed identity.
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
    std.debug.print("TLS listening on {d} (TLS 1.2/1.3, ALPN h2 + http/1.1)\n", .{port});
}
```

## Run

```bash
zig build run-all-tls_handshake_details
```
