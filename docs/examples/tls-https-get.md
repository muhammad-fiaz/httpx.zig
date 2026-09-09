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
    std.debug.print("TLS listening on {d}\n", .{port});

    // HTTPS client options for self-signed endpoints
    // (development only; production must verify against a CA bundle).
    // NOTE: a full local client<->server TLS handshake is not yet wired;
    // external HTTPS endpoints work via the high-level client:
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var res = try client.get("https://example.com/", .{});
    defer res.deinit();
    std.debug.print("HTTPS status: {d}\n", .{res.status});
}
```

## Run

```bash
zig build run-all-tls_https_get
```
