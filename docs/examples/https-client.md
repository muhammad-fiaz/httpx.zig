# HTTPS Client

Demonstrates a raw TLS 1.2/1.3 handshake using the built-in TLS implementation, including ALPN negotiation and encrypted HTTP request/response over the session.

## Demo Program

```zig
// Configure TLS with ALPN for h2 + http/1.1
const tls_config = tls.TlsConfig.insecureWithH2(allocator);

// Connect to the server
const address = httpx.address.resolve(allocator, host, port);
var socket = httpx.Socket.createForAddress(address);
socket.connectWithTimeout(address, 10_000);

// Perform TLS handshake
var session = tls.TlsSession.init(tls_config);
session.attachSocket(&socket);
session.handshake(host);

// Read negotiated protocol
const proto = session.negotiatedProtocol();

// Send HTTP request over the encrypted channel
session.writeAll("GET / HTTP/1.1\r\nHost: example.com\r\n...\r\n");

// Read response
var buf: [4096]u8 = undefined;
const n = session.read(&buf);
```

## Run

```
zig build example-https-client
```

## Checklist

- [ ] TLS config created with ALPN (h2, http/1.1)
- [ ] Socket connects to `example.com:443`
- [ ] TLS handshake completes (or offline demo prints cipher suites)
- [ ] ALPN protocol is printed if negotiated
- [ ] HTTP response is read and printed (first 512 bytes)
- [ ] Session closes gracefully with `close_notify`
