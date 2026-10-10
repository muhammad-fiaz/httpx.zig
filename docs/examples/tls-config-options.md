# TLS Configuration Options

TLS configuration structures and verification modes used across HTTPX.

## Client options (`TlsOptions`)

Per-request and client-level TLS options:

```zig
// Default: verify against CA bundle with truncation tolerance.
const strict = httpx.TlsOptions{};

// Development only: accept self-signed certificates.
const dev = httpx.TlsOptions{ .verify = .selfSigned };

// Tests only: skip verification entirely.
const insecure = httpx.TlsOptions{ .verify = .none };
```

`VerifyMode` is `.caBundle`, `.selfSigned`, or `.none`.

## Server config (`ServerConfig`)

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

This page shows configuration shapes only; there is no runnable output. Ports, certificates, and negotiated ALPN/TLS versions vary by deployment. TLS 1.2 and 1.3 are supported by default with no version fields to set.

## Related

- [TLS Guide](/guide/tls)
- [TLS API](/api/tls)
