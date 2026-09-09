# TLS Custom CA Certificate

Demonstrates TLS with self-signed certificates for development and testing,
using `httpx.tls.Listener` with PEM identity material.

## Features Demonstrated

- Self-signed certificate PEM blocks
- `httpx.tls.Listener` with `defaultIdentity`
- Development-only verification bypass via `.tls = .{ .verify = .none }`

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn handler(_: httpx.tls.Request) anyerror!httpx.tls.Response {
    return .{ .status = 200, .body = "Served with custom CA cert" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Start a local TLS listener with a self-signed identity.
    var listener = try httpx.tls.Listener.init(allocator, io, .{
        .port = 0,
        .defaultIdentity = .{
            .certChainPem = @embedFile("cert.pem"),
            .privateKeyPem = @embedFile("key.pem"),
        },
    });
    defer listener.deinit();

    const port = listener.localPort();

    // Development-only client bypass for the self-signed chain.
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/secure", .{port});
    var res = try client.get(url, .{ .tls = .{ .verify = .none } });
    defer res.deinit();
    std.debug.print("Response: {d} bytes\n", .{res.body.len});
}
```

## Run

```bash
zig build run-tls-mtls
```

## Production CA Workflow

1. Generate CA: `openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 365 -subj '/CN=MyCA'`
2. Embed in Zig: `const ca_pem = @embedFile("ca.crt");`
3. Serve via `httpx.tls.Listener` with `defaultIdentity`, and verify with a
   populated CA bundle (never `.verify = .none` in production).
