# Runnable Examples

Practical, fully verified demo programs for `httpx.zig` covering client operations, server routing, protocols, TLS, streaming, WebSockets, HTML parsing, templates, process signals, and observability.

Every example is backed by real source code in the repository and compiles directly with the Zig toolchain.

## Building and Running Examples

Compile and execute any example using `zig build run-<name>`:

```bash
zig build run-simple-get
zig build run-http11-server
zig build run-http2-client
zig build run-http3-client
zig build run-websocket-server
```

To build an example executable without running it (installing into `zig-out/bin/`):

```bash
zig build example-simple-get
zig build example-post-json
zig build example-rest-api
```

To cross-compile for another platform:

```bash
zig build example-simple-get -Dtarget=x86_64-linux-gnu
zig build example-http3-client -Dtarget=aarch64-macos
```

To build all 94 examples at once:

```bash
zig build build-all-examples
```

---

## 1. Getting Started & Core HTTP

- [Simple GET](/examples/simple-get) - Basic HTTP GET request and status/body extraction.
- [Simple GET Deserialize](/examples/simple-get-deserialize) - Decoding JSON response payloads into typed Zig structs.
- [POST JSON](/examples/post-json) - Sending JSON request payloads with POST.
- [JSON API](/examples/json-api-example) - Full round-trip typed JSON API workflows.
- [Custom Headers](/examples/custom-headers) - Attaching request headers and inspecting headers in route handlers.
- [Custom Responses](/examples/custom-responses) - Generating custom status codes, content types, and binary headers.
- [HTTP Methods](/examples/http-methods) - Demonstrating GET, POST, PUT, DELETE, HEAD, and OPTIONS helpers.
- [API Aliases](/examples/simplified-api-aliases) - High-level convenience aliases with production defaults.

## 2. Client Networking & Connection Pooling

- [Connection Pool](/examples/connection-pool) - Reusing pooled keep-alive TCP connections across sequential requests.
- [Concurrent Requests](/examples/concurrent-demo) - Executing multiple requests concurrently using worker pools.
- [Batch Concurrent](/examples/batch-concurrent) - Bounded batch request dispatching via `concurrency.Pool`.
- [Redirect Following](/examples/redirect) - Automatic redirect policies (`followRedirects`, `maxRedirects`).
- [Retries with Backoff](/examples/retry-demo) - Linear retry backoff and status-code filtering.
- [Forward & SOCKS5h Proxy](/examples/proxy-demo) - Forward HTTP and SOCKS5h proxy configuration.
- [SOCKS5h Remote DNS](/examples/socks5-proxy) - Remote DNS host resolution through SOCKS5h proxy tunnels.
- [DNS Resolution](/examples/dns-demo) - Synchronous and cached hostname resolution.
- [DNS Caching](/examples/dns-cache) - TTL-based DNS caching with negative result tracking.
- [Multi-Address DNS](/examples/dns-resolve-all) - Dual-stack IPv4/IPv6 candidate address resolution.
- [Connectivity Probes](/examples/connectivity) - TCP reachability checks with timeout bounds.
- [Interceptors](/examples/interceptor-example) - Custom client request/response interceptor chains.
- [Request & Response Customization](/examples/request-response-customization) - Setting per-request timeouts, headers, and credentials.

## 3. HTTP Protocols (HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3)

- [HTTP/1.0 Client](/examples/http10-client) - Legacy HTTP/1.0 client with close-delimited transfers.
- [HTTP/1.1 Client](/examples/http11-client) - Dedicated HTTP/1.1 client with keep-alive and chunked encoding.
- [HTTP/1.1 Server](/examples/http11-server) - Dedicated HTTP/1.1 server with persistent socket connections.
- [HTTP/2 Client](/examples/http2-client) - Cleartext and TLS HTTP/2 client runtime.
- [HTTP/2 Multiplexing](/examples/http2-multiplex) - Multiple concurrent logical streams over a single TCP connection.
- [HTTP/2 TLS with ALPN](/examples/http2-tls) - End-to-end HTTP/2 over TLS negotiated via ALPN.
- [HTTP/2 Framing & Primitives](/examples/http2-example) - Low-level HTTP/2 frame building and stream state management.
- [HTTP/2 Client Runtime](/examples/http2-client-runtime) - End-to-end H2 client against local server.
- [HTTP/2 Server Runtime](/examples/http2-server-runtime) - Native H2 server handler execution.
- [HTTP/2 Advanced](/examples/http2-advanced) - SETTINGS frame handling, RST_STREAM, and trailer processing.
- [HTTP/3 Client](/examples/http3-client) - HTTP/3 client runtime over QUIC and UDP.
- [HTTP/3 QUIC](/examples/http3-quic) - QUIC connection lifecycle, stream multiplexing, and loss recovery.
- [HTTP/3 0-RTT Resumption](/examples/http3-0rtt) - TLS 1.3 session tickets and 0-RTT early data exchange.
- [HTTP/3 Framing & Primitives](/examples/http3-example) - QPACK field section compression and HTTP/3 frames.
- [HTTP/3 Client Runtime](/examples/http3-client-runtime) - Live H3 client queries over UDP sockets.
- [HTTP/3 Server Runtime](/examples/http3-server-runtime) - Native H3 server endpoint serving UDP clients.
- [HTTP/3 Advanced](/examples/http3-advanced) - QPACK dynamic tables, flow control, and unidirectional control streams.

## 4. TLS & Transport Security

- [TLS Server](/examples/tls-server) - Custom TLS 1.3 server with certificate and private key loading.
- [HTTPS Client](/examples/https-client) - HTTPS requests with CA bundle verification.
- [TLS 1.2 Client](/examples/tls12-client) - Explicit TLS 1.2 handshake and backward-compatible cipher suites.
- [TLS 1.3 Client](/examples/tls13-client) - Modern TLS 1.3 client with ChaCha20-Poly1305 and AES-GCM.
- [Mutual TLS (mTLS)](/examples/tls-mtls) - Client certificate authentication and mutual identity verification.
- [TLS GET](/examples/tls-get) - Lightweight secure GET over loopback.
- [TLS Custom CA](/examples/tls-custom-ca) - Pinning and trusting custom root authority certificates.
- [TLS HTTPS GET](/examples/tls-https-get) - End-to-end HTTPS transaction with explicit certificate authority.
- [TLS Handshake Details](/examples/tls-handshake-details) - Inspecting negotiated protocol versions, ciphers, and key exchange groups.
- [TLS Configuration Options](/examples/tls-config-options) - Setting verification policies, SNI hostnames, and ALPN lists.
- [HTTP Auth Helpers](/examples/http-auth-helpers) - Basic and Bearer authentication helper integration.
- [Cloud HTTPS Server](/examples/cloud-https-server) - Production server configuration behind TLS reverse proxies.

## 5. Server, Routing & Middleware

- [Simple Server](/examples/simple-server) - Minimal HTTP server startup, routing, and graceful shutdown.
- [Framework Routing Demo](/examples/routing-demo) - Path parameters, slugs, wildcards, route groups, and struct binding.
- [Custom Server](/examples/custom-server) - Multi-route server with custom headers, query strings, and logging.
- [Browser Demo Server](/examples/browser-demo-server) - Interactive demo server with live endpoints for browser testing.
- [Middleware Pipeline](/examples/middleware-example) - Chaining pre- and post-processing middleware functions.
- [CORS Middleware Server](/examples/cors-server) - Handling Cross-Origin Resource Sharing headers and preflight OPTIONS.
- [Rate Limiting Server](/examples/rate-limit-server) - Token bucket and sliding window rate limiting.
- [Security Headers (Helmet)](/examples/helmet-server) - Content-Security-Policy, HSTS, X-Content-Type-Options, and frame guards.
- [Body Parser Server](/examples/body-parser-server) - Parsing JSON, urlencoded, and text request bodies with size caps.
- [Cookie Management Server](/examples/cookie-server) - Setting, reading, and expiring secure HTTP cookies.
- [Session Management Server](/examples/session-server) - In-memory session store with cookie-backed session tokens.
- [Auth & Error Handling](/examples/auth-and-errors) - Authentication validation and centralized error handlers.
- [Pre-Route Logic](/examples/pre-route-example) - Global request interception and custom 404 fallback routing.
- [Reverse Proxy Middleware](/examples/reverse-proxy-middleware) - Forwarding client requests to backend services.

## 6. Web Framework, HTML & Templates

- [Static Files](/examples/static-files) - Serving files from disk with ETags and 304 Not Modified caching.
- [Static Site with Live Reload](/examples/static-site) - Serving multi-page websites with development hot reload.
- [Single-File Server with Embedded Assets](/examples/static-embedded) - Zero disk I/O using `@embedFile` compiled assets.
- [SPA Server with Fallback](/examples/spa-server) - Single-Page Application server routing unmapped paths to `index.html`.
- [SPA Fallback Helper](/examples/spa-fallback) - Custom SPA fallback rules for HTML5 history API navigation.
- [File-Based Website Server](/examples/website) - Full-featured file-based dynamic and static website hosting via `.site`.
- [HTML Client](/examples/html-client) - Fetching web pages and parsing them into a DOM document.
- [HTML CSS Selectors](/examples/html-select) - Querying DOM trees with CSS selectors.
- [HTML Metadata Extraction](/examples/html-extract) - Extracting OpenGraph, Twitter Cards, canonical links, and form fields.
- [Streaming HTML Parsing](/examples/html-stream) - Incremental streaming parsing from `std.Io.Reader`.
- [HTML File Parsing](/examples/html-file) - Reading and parsing HTML files directly from local storage.
- [HTML DOM Transformation](/examples/html-transform) - Mutating element attributes, adding nodes, and serializing DOM.
- [Parse HTML](/examples/parse-html) - Fast, safe DOM parser usage with Tree-sitter backing.
- [Filesystem Watcher](/examples/file-watcher) - Native OS file notifications with debouncing and polling fallback.
- [Live Reload with SSE](/examples/live-reload) - Server-Sent Events broadcasting file modifications to connected browsers.
- [Live Static Watcher](/examples/live-static-watcher) - Combining directory monitoring with static asset serving.
- [Development Server](/examples/development-server) - Unified local development server with live reload and watcher.
- [Templates: Basic](/examples/template-basic) - Native template rendering with variables, conditionals, and loops.
- [Templates: Inheritance](/examples/template-inheritance) - Reusable master layouts with block overrides (`{% block %}`, `{% extends %}`).
- [Templates: Loops](/examples/template-loops) - Iterating collections with `loop.index`, `loop.first`, and `loop.last`.
- [Templates: Includes](/examples/template-includes) - Composing pages with reusable partial components (`{% include %}`).
- [Templates: Live Reload](/examples/template-live-reload) - Hot template reloading with cache invalidation.
- [Templates: Advanced Jinja](/examples/template-jinja) - Advanced layout inheritance, macros, and filtering.

## 7. WebSockets & Streaming

- [WebSocket Server](/examples/websocket-server) - RFC 6455 full-duplex WebSocket server over HTTP connection takeover.
- [WebSocket Client](/examples/websocket-client) - `ws://` client with authentication, messaging, and clean close handshake.
- [WebSocket Protocol Primitives](/examples/websocket-example) - Low-level frame encoding, decoding, masking, and handshake hashing.
- [Server-Sent Events (SSE) Server](/examples/sse-server) - Streaming events with `text/event-stream` format.
- [Streaming Response Reader](/examples/streaming) - Consuming large or unbounded response streams via `Response.reader()`.
- [Compression Demo](/examples/compression-demo) - Content-Encoding negotiation (gzip, deflate, zstd, brotli).
- [Streaming with Compression](/examples/streaming-compression-example) - Streaming decompressed payloads on the fly.
- [Multipart Form Data](/examples/multipart) - Building and parsing `multipart/form-data` uploads with fields and files.

## 8. APIs, Documentation & Testing

- [OpenAPI Specification Server](/examples/openapi) - Automated OpenAPI 3.1 JSON generation from registered routes.
- [Typed REST API](/examples/rest-api) - Type-safe REST routes with schema validation and Swagger/ReDoc/Scalar documentation.
- [Documentation Server](/examples/docs-server) - Serving embedded Swagger UI, ReDoc, Scalar, and GraphiQL interfaces.
- [GraphQL Server](/examples/graphql-server) - Native GraphQL query execution with schema definition and GraphiQL IDE.
- [Testing Server](/examples/testing-server) - Integration testing with ephemeral ports, request capture, and inspection.
- [Full Integration](/examples/full-integration) - Combining client, server, TLS, routing, and middleware in one program.

## 9. Process Lifecycle & Signals

- [Server Signals](/examples/server-signals) - Automatic Ctrl+C / SIGTERM signal handling with graceful drain deadlines.
- [Custom Signals](/examples/custom-signals) - Custom signal masks, per-server hooks, and multi-server shutdown.
- [Manual Signals](/examples/manual-signals) - Application-managed signal subscriptions driving graceful shutdown.

## 10. Observability & Sockets

- [Metrics Server](/examples/metrics-server) - Prometheus-compatible metrics registry tracking requests, latencies, and statuses.
- [Logging Callback](/examples/logging-callback) - Custom structured logging callbacks for client and server events.
- [Health Check Probes](/examples/health-check) - Liveness and readiness probe endpoints for orchestrators (Kubernetes).
- [Readiness Probes](/examples/readiness-probe-example) - Stateful readiness check integration.
- [TCP Local Socket](/examples/tcp-local) - Low-level TCP listener and client socket communication.
- [UDP Local Datagram](/examples/udp-local) - Low-level UDP datagram socket communication.
- [Unix Domain Sockets Alternative](/examples/unix-socket-example) - Same-machine loopback IPC configuration.

## 11. File Downloads & FTP

- [File Download](/examples/download) - Resumable streaming downloads with progress reporting.
- [Download Info](/examples/download-info) - Inspecting remote file headers, size, and accept-ranges support.
- [Download Verify](/examples/download-verify) - Cryptographic checksum verification (SHA-256, MD5) on downloaded files.
- [Download Resume](/examples/download-resume) - Resuming interrupted downloads with HTTP Range headers.
- [Download Existing](/examples/download-existing) - Efficient skipping of already downloaded local files.
- [Download Custom Progress](/examples/download-custom-progress) - Custom progress bars, transfer rates, and ETA callbacks.
- [Batch Downloads](/examples/download-batch) - Concurrent multi-file download manager with worker concurrency limits.
- [Download Update](/examples/download-update) - Conditional file updates (`replaceIfChanged` with ETag/Last-Modified).
- [Download Checksum File](/examples/download-checksum-file) - Parsing and validating standard checksum files (`SHA256SUMS`).
- [FTP Client](/examples/ftp-client) - FTP protocol client with directory listing and file retrieval.
- [FTP Server](/examples/ftp-server) - Lightweight FTP server implementation.
- [FTP Download](/examples/ftp-download) - Downloading files over FTP with stream tracking.
