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
        .certPem = @embedFile("cert.pem"),
        .keyPem = @embedFile("key.pem"),
        .minVersion = .tls12,
        .maxVersion = .tls13,
        .alpnProtocols = &.{ .h2, .@"http/1.1" },
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

## Related

- [TLS Guide](/guide/tls)
- [TLS API](/api/tls)
