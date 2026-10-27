# TLS Configuration Options

TLS verification modes used across HTTPX.

## Client options

Pass TLS options inline with `.tls`:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

// Default: verify against the CA bundle; TLS truncation is rejected.
var strict = try client.get(url, .{});
defer strict.deinit();

// Development only: accept self-signed certificates.
var dev = try client.get(url, .{ .tls = .{ .verify = .selfSigned } });
defer dev.deinit();

// Tests only: skip verification entirely.
var insecure = try client.get(url, .{ .tls = .{ .verify = .none } });
defer insecure.deinit();
```

`VerifyMode` is `.caBundle`, `.selfSigned`, or `.none`.

## Server options

```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8443,
    .tls = .{
        .certificatePem = @embedFile("cert.pem"),
        .privateKeyPem = @embedFile("key.pem"),
        .alpn = &.{ .h2, .@"http/1.1" },
        .allowPlainHttp = false,
    },
});
```

## Listener identity (`Identity`)

```zig
var listener = try httpx.tls.Listener.init(allocator, io, .{
    .port = 8443,
    .defaultIdentity = .{
        .certChainPem = @embedFile("cert.pem"),
        .privateKeyPem = @embedFile("key.pem"),
    },
});
```

## Expected Output

```text
(no output - configuration snippets only)
```

This page shows configuration shapes only; there is no runnable output. Ports, certificates, and negotiated ALPN/TLS versions vary by deployment. Client HTTPS/1.1 negotiates TLS 1.2 or 1.3; the native TLS server is TLS 1.3 only.

## Related

- [TLS Guide](/guide/tls)
- [TLS API](/api/tls)
