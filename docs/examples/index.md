# Examples

This section contains practical `httpx.zig` demo programs for client, server, middleware, streaming, and protocol features.

## How to Use

1. Open an example page.
2. Review the `Demo Program` snippet.
3. Run the matching command from the `Run` section.
4. Verify behavior with the checklist.

For non-host targets, compile (without running) by adding `-Dtarget=...`:

```bash
zig build example-tcp_local -Dtarget=x86_64-linux
zig build example-http3_example -Dtarget=aarch64-macos
```

## Available Examples

- [Simple Get](/examples/simple-get): Basic GET request and response handling.
- [Simple Get Deserialize](/examples/simple-get-deserialize): Parse JSON into typed structs.
- [HTTP Auth Helpers](/examples/http-auth-helpers): Use built-in Bearer and Basic auth request helpers against a local loopback server.
- [Post JSON](/examples/post-json): Send JSON payloads with POST.
- [Custom Headers](/examples/custom-headers): Attach auth and custom metadata headers.
- [Concurrent Requests](/examples/concurrent-requests): Execute multiple requests in parallel.
- [Connection Pool](/examples/connection-pool): Reuse pooled connections efficiently.
- [Interceptors](/examples/interceptors): Apply request and response interceptors.
- [Cookies Demo](/examples/cookies-demo): Manage cookie jar values in client flows.
- [Logging Callback](/examples/logging-callback): Set up custom logging functions for both server and client.
- [Proxy and Reverse Proxy](/examples/proxy-example): Configure client forward proxies, including SOCKS5h tunnels, and register reverse proxy middleware.
- [SOCKS5h Proxy](/examples/socks5-proxy): Route requests through a SOCKS5h proxy with remote DNS resolution.
- [Simplified API Aliases](/examples/simplified-api-aliases): Use short top-level helper APIs with local loopback success mode by default.
- [Simple Server](/examples/simple-server): Start a minimal HTTP server.
- [Thread Pool / Async Server](/examples/async-server-example): Start a concurrent HTTP server with thread pool connection dispatching.
- [Router Example](/examples/router-example): Route params and grouped endpoints.
- [Middleware Example](/examples/middleware-example): Chain middleware with shared behavior.
- [Streaming](/examples/streaming): Stream data responses.
- [SSE Example](/examples/sse-example): Server-Sent Events formatting and streaming from server to client.
- [Static Files](/examples/static-files): Serve assets with content types, ETag headers, and conditional GET (`If-None-Match`) support.
- [Multi Page Website](/examples/multi-page-website): Serve multiple HTML pages.
- [HTTP/2 Example](/examples/http2-example): HTTP/2 framing and stream primitives.
- [HTTP/2 Client Runtime](/examples/http2-client-runtime): End-to-end high-level HTTP/2 client request against a local loopback server.
- [HTTP/2 Server Runtime](/examples/http2-server-runtime): End-to-end high-level HTTP/2 server route consumed by a local HTTP/2 client.
- [HTTP/3 Example](/examples/http3-example): HTTP/3, QPACK, and QUIC primitives.
- [HTTP/3 Client Runtime](/examples/http3-client-runtime): End-to-end high-level HTTP/3 client request against a local UDP loopback server.
- [HTTP/3 Server Runtime](/examples/http3-server-runtime): End-to-end high-level HTTP/3 server route consumed by a local HTTP/3 client over UDP.
- [HTTP/2 Advanced](/examples/http2-advanced): HTTP/2 production features (SETTINGS enforcement, GOAWAY/RST_STREAM, HPACK security, trailers).
- [HTTP/3 Advanced](/examples/http3-advanced): HTTP/3 production features (QPACK stream instructions, QUIC stream cancellation, transport parameters).
- [TCP Local](/examples/tcp-local): Local TCP listener/client round trip.
- [UDP Local](/examples/udp-local): Local UDP transport demo.
- [WebSocket Example](/examples/websocket-example): Read upgrade headers, handshake keys, and process frame inputs.
- [WebSocket Server](/examples/websocket-server): WebSocket handshake detection, frame encoding/decoding, and bidirectional messaging.
- [Multipart Form Data](/examples/multipart-example): Build and parse multipart payloads with text fields and file uploads.
- [Session Store](/examples/session-example): Set/get session data, evict sessions on TTL, and integrate with servers.
- [Metrics and Observability](/examples/metrics-example): Aggregate total requests, status codes, latency times, and success rates.
- [Unix Domain Sockets](/examples/unix-socket-example): Bind servers and connect clients over AF_UNIX sockets.
- [Health Check Probes](/examples/health-check-example): Configure liveness and readiness probe middlewares.
- [Cloud HTTPS Server](/examples/cloud-https-server): Production cloud deployment with TLS, middleware, and health checks.
- [TLS Server](/examples/tls-server): Custom TLS server with ALPN negotiation.
- [HTTPS Client](/examples/https-client): HTTPS client with custom TLS configuration.
- [Request Response Customization](/examples/request-response-customization): Customize request properties and response headers.
- [Compression](/examples/compression-example): Gzip, deflate, brotli, and zstd compression/decompression.
- [HTTP Methods](/examples/http-methods): GET, POST, PUT, DELETE, HEAD, OPTIONS.
- [Retry](/examples/retry-example): Retry with exponential backoff.
- [DNS Resolution](/examples/dns-example): DNS cache and resolution.
- [Redirect](/examples/redirect-example): Redirect following and policy.
- [Batch Concurrent](/examples/batch-concurrent): Batch concurrent requests.
- [Reverse Proxy Middleware](/examples/reverse-proxy-middleware): Server-side reverse proxy.
