# TLS Server Example

Demonstrates the custom TLS server implementation built from scratch. Shows TLS configuration with certificate/key PEM files, ALPN negotiation, HTTP/1.1 and HTTP/2 over TLS, and TLS client handshake.

## Demo Program

```zig
// Create a server with TLS enabled
var server = httpx.Server.initWithConfig(allocator, .{
    .host = "127.0.0.1",
    .port = port,
    .tls_enabled = true,
    .tls_cert_path = "examples/certs/server.crt",
    .tls_key_path = "examples/certs/server.key",
    .tls_alpn_protocols = &.{ "h2", "http/1.1" },
    .http2_enabled = true,
});

// TLS client handshake
var session = tls.TlsSession.init(tls_config);
session.socket = &sock;
session.handshake("127.0.0.1");
const protocol = session.negotiatedProtocol();
```

## Run

```
zig build run-tls_server
```

## Checklist

- [ ] Server starts with TLS enabled
- [ ] Certificate and key PEM files are loaded
- [ ] TLS handshake completes successfully
- [ ] ALPN negotiates h2 or http/1.1
- [ ] HTTP/2 is detected via ALPN
- [ ] HTTP request over TLS returns 200 OK
- [ ] Supports TLS 1.2 and 1.3 cipher suites
- [ ] Record-level fragmentation works correctly
