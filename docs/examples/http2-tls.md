# HTTP/2 over TLS with ALPN

Demonstrates end-to-end HTTP/2 over TLS on loopback: the server negotiates h2 via ALPN behind the native TLS engine, and the client verifies the certificate chain and hostname before exchanging an HTTP/2 request and response.

## Complete Example

```zig
//! HTTP/2 over TLS end to end over loopback: the server negotiates `h2`
//! via ALPN behind the native TLS engine, and the client verifies the
//! chain + hostname before exchanging an H2 request/response.
//!
//! Run with: `zig build run-http2-tls`

const std = @import("std");
const httpx = @import("httpx");

const certPem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBmTCCAT+gAwIBAgIURhx0CMJWTUTFJXV9z2OlmW/cNlcwCgYIKoZIzj0EAwIw
    \\FDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDkwOTE4MTczOFoXDTM2MDkwNjE4
    \\MTczOFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0D
    \\AQcDQgAE71D4pM0SAPK8sdt+xlEESZX/EJoKHUC+4IpPuSlOiQuCXOkN04ozVGKA
    \\mrmUtDqQCdvmdjHbjqGY6TCszXTCnKNvMG0wHQYDVR0OBBYEFFjYJYGodkVKyvXf
    \\4qrn7rvQx+PFMB8GA1UdIwQYMBaAFFjYJYGodkVKyvXf4qrn7rvQx+PFMA8GA1Ud
    \\EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYcEfwAAAYIJbG9jYWxob3N0MAoGCCqGSM49
    \\BAMCA0gAMEUCIQD0sAcuw/jdWdfBrxLXY1ur2cU8F0CAkPCvS2qKn7XK4QIgAP71
    \\95toW+Gsh8/VZlNoHL2s14olRp5zl3cYDPzKM10=
    \\-----END CERTIFICATE-----
;

const keyPem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

fn secureHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "secure-h2" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .protocols = .{ .http2 = true },
        .tls = .{
            .certificatePem = certPem,
            .privateKeyPem = keyPem,
        },
    });
    defer server.deinit();

    try server.router.add(.GET, "/secure", secureHandler, .{});

    const port = server.localPort();
    std.debug.print("TLS server on 127.0.0.1:{d} (h2 over ALPN)\n", .{port});

    const thread = try server.start();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/secure", .{port});
    var res = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = certPem },
        .timeoutMs = 15_000,
    });
    defer res.deinit();

    std.debug.print("client.get: status={d} body={s} version={s}\n", .{ res.status, res.body, res.version.wireNameResolved() });
    if (res.status != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, res.body, "secure-h2")) return error.UnexpectedBody;

    server.requestShutdown();
    thread.join();

    std.debug.print("H2-TLS DEMO VERIFICATION PASSED\n", .{});
}
```

## Expected Output

```text
TLS server on 127.0.0.1:PORT (h2 over ALPN)
client.get: status=200 body=secure-h2 version=h2
H2-TLS DEMO VERIFICATION PASSED
```

Actual port numbers and timings vary with environment allocation.

## How to Run

```bash
zig build run-http2-tls
```

## Related

* [Server Guide](/guide/routing)
* [All Examples](/examples/)
