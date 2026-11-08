# TLS Custom CA Certificate

Demonstrates TLS with self-signed certificates for development and testing,
using `httpx.Server` with PEM identity material.

## Covers

- Self-signed certificate PEM blocks
- `httpx.Server` with `.tls` identity
- Development-only verification bypass via `.tls = .{ .verify = .none }`

## Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn handler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "Served with custom CA cert", .contentType = "text/plain; charset=utf-8" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Self-signed identity, explicit allocator and io, one inline .{} config.
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

    try server.get("/secure", .{ .handler = handler });

    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

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

## Expected Output

```text
Response: 26 bytes
```

The byte count reflects the `Served with custom CA cert` body and varies with the served content; the ephemeral loopback port varies per run. Requires local `cert.pem`/`key.pem` self-signed identity material. Development-only `.verify = .none` bypass; never use in production.

## Run

```bash
zig build run-tls-server
```

## Production CA Workflow

1. Generate CA: `openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 365 -subj '/CN=MyCA'`
2. Embed in Zig: `const caPem = @embedFile("ca.crt");`
3. Serve via `httpx.Server` with `.tls`, and verify with a
   populated CA bundle (never `.verify = .none` in production).
