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
- [Post JSON](/examples/post-json): Send JSON payloads with POST.
- [Custom Headers](/examples/custom-headers): Attach auth and custom metadata headers.
- [Concurrent Requests](/examples/concurrent-requests): Execute multiple requests in parallel.
- [Connection Pool](/examples/connection-pool): Reuse pooled connections efficiently.
- [Interceptors](/examples/interceptors): Apply request and response interceptors.
- [Cookies Demo](/examples/cookies-demo): Manage cookie jar values in client flows.
- [Simplified API Aliases](/examples/simplified-api-aliases): Use short top-level helper APIs.
- [Simple Server](/examples/simple-server): Start a minimal HTTP server.
- [Router Example](/examples/router-example): Route params and grouped endpoints.
- [Middleware Example](/examples/middleware-example): Chain middleware with shared behavior.
- [Streaming](/examples/streaming): Stream data responses.
- [Static Files](/examples/static-files): Serve assets with content types.
- [Multi Page Website](/examples/multi-page-website): Serve multiple HTML pages.
- [HTTP/2 Example](/examples/http2-example): HTTP/2 framing and stream primitives.
- [HTTP/3 Example](/examples/http3-example): HTTP/3, QPACK, and QUIC primitives.
- [TCP Local](/examples/tcp-local): Local TCP listener/client round trip.
- [UDP Local](/examples/udp-local): Local UDP transport demo.
