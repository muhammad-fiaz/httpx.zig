# Changelog

All notable changes to this project are documented in this file.


## [0.1.4] - 30-07-2026

### Added


## [0.1.3] - 12-07-2026

### Added
- HTTP/2: ALPN negotiation — client and server now advertise `["h2", "http/1.1"]` during the TLS handshake. The client inspects the negotiated protocol after the handshake and automatically selects HTTP/2 or HTTP/1.1 accordingly; if ALPN is unavailable the connection falls back to HTTP/1.1.
- HTTP/2: CONTINUATION frame sending — header blocks that exceed `MAX_FRAME_SIZE` are automatically split across HEADERS + CONTINUATION frames.
- HTTP/2: SETTINGS enforcement — peer `MAX_CONCURRENT_STREAMS`, `MAX_FRAME_SIZE`, and `INITIAL_WINDOW_SIZE` values are now parsed and enforced. DATA frames are chunked to respect the peer's max frame size; send windows are checked before sending data.
- HTTP/2: GOAWAY and RST_STREAM sending — the server sends GOAWAY with `no_error` on clean shutdown or `internal_error` on handler failure. Both client and server handle incoming RST_STREAM gracefully and can send RST_STREAM to cancel individual streams without tearing down the entire connection.
- HTTP/2: HPACK `Without Indexing` and `Never Indexed` header representations — new `encodeHeaderWithoutIndexing` and `encodeHeaderNeverIndexed` functions ensure volatile headers (e.g. `Authorization`, `Cookie`) are encoded without dynamic table insertion, preventing HPACK bomb attacks and accidental cache pollution.
- HTTP/2: Connection pooling — HTTP/2 connections are now pooled and reused across requests. A new `Http2Connection` wrapper manages the TLS session, HPACK contexts, stream manager, and connection-level flow control state.
- HTTP/2: Trailer support — servers can send HTTP/2 trailers via `sendHttp2Trailers()` (HEADERS frame with END_STREAM after DATA). Clients decode incoming trailers after END_STREAM and attach them to the `Response.trailers` field.
- HTTP/2: Connection preface timeout — the client and server now detect if the peer never sends its initial SETTINGS frame after the connection preface, preventing indefinite hangs.
- HTTP/3: QPACK decoder stream decode functions — added `decodeSectionAck`, `decodeStreamCancel`, `decodeInsertCountIncrement`, and `decodeSetCapacity` for decoding decoder stream instructions; added `decodeInsertWithNameRef`, `decodeInsertLiteral`, `decodeDuplicate`, and `decodeEncoderDataSetCapacity` for decoding encoder stream instructions (13 new tests).
- HTTP/3: Flow control frame handling — MAX_DATA and MAX_STREAM_DATA frames are now parsed and processed. Connection-level and per-stream flow control windows are tracked and enforced when sending DATA.
- HTTP/3: GOAWAY and CONNECTION_CLOSE — both client and server handle incoming GOAWAY gracefully and can send GOAWAY or CONNECTION_CLOSE (transport and application variants) on unrecoverable errors.
- HTTP/3: Stream cancellation — RESET_STREAM and STOP_SENDING frames can be sent to cancel individual streams without tearing down the connection.
- New unit tests: `canOpenStream respects max_concurrent_streams`, `validateFrameSize catches oversized frames`, `applyPeerSettings updates max_concurrent_streams and window size`, `buildGoawayFrame produces correct wire format`, `buildRstStreamFrame produces correct wire format`, `HTTP/2 SETTINGS payload roundtrip with custom values`, `RESET_STREAM frame encode/decode`, `STOP_SENDING frame encode/decode`, `RESET_STREAM rejects wrong frame type`, `STOP_SENDING rejects wrong frame type`.
- New examples: `http2_advanced.zig` (SETTINGS enforcement, GOAWAY/RST_STREAM, HPACK security, trailers) and `http3_advanced.zig` (QPACK stream instructions, QUIC stream cancellation, transport parameters).

### Changed
- Bumped project version to `0.1.3`.

### Fixed
- Fixed HTTPS responses larger than ~16 KB (one TLS record) causing an infinite loop at 100% CPU. The `SocketIoReader.rebase` vtable function was a no-op, so after the internal buffer was fully consumed the reader never reclaimed buffer space and `readVec` kept returning zero bytes. `rebase` now compacts unread data to the front of the buffer, matching the standard library's `defaultRebase` behavior ([Issue #21](https://github.com/muhammad-fiaz/httpx.zig/issues/21)).
- Fixed `Host` request header omitting non-default port numbers. `Request.init` now includes the port in the `Host` header when it differs from the scheme default (80 for HTTP, 443 for HTTPS), matching RFC 7230 semantics and aligning with the existing `buildAuthority` logic used by HTTP/2 ([Issue #22](https://github.com/muhammad-fiaz/httpx.zig/issues/22)).
- Fixed `encodeInsertLiteral` in `qpack.zig` where the length field was encoding the original string length instead of the Huffman-encoded byte count, causing corrupted encoder stream output.


## [0.1.2] - 07-07-2026

### Added
- Added client-side `RequestOptions` multipart helpers (`withMultipartFields`, `withMultipartFiles`, `withMultipartBoundary`), enabling simple, python-like fluent syntax for form fields and file uploads with automatic out-of-the-box MIME type guessing.
- Added client-side `RequestOptions` configuration overrides (`withProxy`, `withSslVerification`, `withKeepAlive`, `withUnixSocket`) to customize connections, proxies, socket routing, and TLS validation behavior on a per-request basis.
- Added `trySubmit` non-blocking task submission and `submitWithCallback` asynchronous completion callbacks to the task `Executor` in `src/concurrency/executor.zig`.
- Added a full `async_server_example.zig` demonstrating server thread pool concurrency and request handling on background workers.

### Changed
- Bumped project version to `0.1.2`.
- Advanced the previous stable release version configuration from `0.1.0` to `0.1.1` across README, API, and installation guides.
- Expanded the Related Zig Projects list across README.md and documentation index.
- Simplified GitHub Actions `release.yml` workflow by removing testing and platform builds, relying on automatic release notes generation.
- Re-architected MIME resolution to be simple, direct, and zero-config out-of-the-box. Reverted the complex `MimeRegistry` and `DynamicMimeRegistry` class abstractions.
- Restored fast, zero-allocation root helpers `mimeTypeFromPath`, `mimeTypeFromPathOr`, and `mimeTypeFromPathWith` for out-of-the-box static-file serving and file resolution.
- Integrated the task `Executor` thread pool directly into `src/server/server.zig` connection listeners. When `config.threads > 0`, the server now routes connection tasks through the thread pool instead of spawning raw unbounded threads, preventing thread starvation and improving connection latency under high concurrency.
- Enhanced server listener loops to avoid rebinding sockets/listeners if already bound/initialized, enabling pre-bound testing patterns.
- Pre-bound server TCP/Unix listeners directly on caller thread in `listenInBackground()`, avoiding background thread binding race conditions and eliminating hardcoded sleep latency in test server initializations.
- Enhanced `Server.stop()` to shut down TCP listener via `Socket.shutdownBoth()` and Unix listener via `Socket.fromHandle().shutdownBoth()` before `deinit()`, ensuring blocking `accept()` calls are interrupted across all platforms.
- Replaced multi-byte UTF-8 arrows with ASCII `->` in console example outputs to fix mojibake on Windows.
- Formatted UDP source address as ip:port in `udp_local.zig`.
- Displayed binary multipart data as `<N bytes binary>` instead of garbage text in examples.
- Refined error reporting and platform check warnings for Unix sockets on Windows.
- Replaced manual bash example-build loop in CI with `zig build run-all-examples`, which runs all 28 self-contained examples sequentially using the build system's built-in dependency ordering.
- Added `timeout 600` guard on CI example runs and `timeout 900` on unit tests to prevent indefinite hangs.
- Hardened CI with `actions/cache@v6` and per-job cache keys to avoid cross-job cache contention.
- Added `request_response_customization` example and documentation to the build system.

### Fixed
- Fixed `posixRecv`, `posixSend`, and `posixSendTo` in `src/net/socket.zig` not retrying on `EINTR` (signal interruption), which could cause spurious read/write failures under load.
- Fixed Unix socket `INVALID_SOCKET` comparison on Windows to use integer comparison instead of pointer equality.
- Fixed backlog parameter type signature in Unix socket POSIX listener on Linux targets.
- Fixed `SO_RCVTIMEO`/`SO_SNDTIMEO` being set on TLS sockets before the TLS handshake completed, which caused spurious `EAGAIN` errors under Linux and produced misleading `ReadFailed` errors for GET requests ([Issue #19](https://github.com/muhammad-fiaz/httpx.zig/issues/19)).
- Fixed noisy "failed command" stderr output in `zig build test` by adding a no-op `log_fn` to the thread pool integration test in `src/server/server.zig`.
- Fixed server `stop()` not interrupting blocking `accept()` calls on background listener threads. TCP and Unix listener sockets are now shut down before closing, preventing test hangs on Linux/macOS.
- Fixed `request_response_customization.zig` example: corrected POST/GET method mismatch in the redirect assertion and disabled automatic redirect following to match expected 302 response.

### Removed
- Removed `src/util/mock.zig` and `MockServer` API entirely. All testing uses real localhost servers with actual TCP/UDP sockets — no mock or fake transport layer.
- Removed `FakeHttp2Transport` and `FakeHttp3Transport` protocol-level test fakes from `src/client/client.zig`. Protocol parsing coverage is maintained by the existing unit tests in `src/protocol/` and real integration via examples.

### Optimized
- Optimized `Http1Connection.writeRequest` in `src/protocol/http.zig` by buffering the formatted HTTP headers and performing a single write operation, reducing syscall overhead.
- Optimized `MultipartBuilder` to perform direct formatted writes using Zig 0.16.0 standard library `ArrayList.print` method, eliminating all temporary heap allocations (`allocPrint` followed by `appendSlice` and `free`) when compiling boundaries, fields, and headers.


## [0.1.1] - 27-06-2026

### Added
- Added RFC 6455 WebSocket support, including client/server upgrade detection, handshake key derivation, and low-level framing for control/data frames.
- Added Unix domain socket (AF_UNIX) client-server integration, allowing HTTP clients to connect via custom Unix socket paths and HTTP servers to bind and listen on Unix sockets.
- Added RFC 2046 Multipart Form Data support, offering a builder and parser for custom form fields and file uploads.
- Added in-memory Session Store management with TTL expiration, auto-eviction, and cookie helpers.
- Added Observability Metrics tracker supporting real-time traffic counts, status code classifications, latency metrics, and registering explicit custom callbacks (`MetricsCallbackFn` / `MetricsEvent`) to integrate with external/custom metrics services (e.g. Datadog or Prometheus).
- Added Health Check and Readiness Probe middlewares to support standard liveness/readiness probe routes.
- Added client-side forward proxy support (supporting HTTP/HTTPS proxies, custom proxy authentication, CONNECT tunnels for TLS/HTTP2, and absolute URLs for HTTP/1.x) for the request tracked in [Issue #15](https://github.com/muhammad-fiaz/httpx.zig/issues/15).
- Added SOCKS5h client proxy support for remote hostname resolution through the proxy server.
- Added server-side reverse proxy middleware `reverseProxy(comptime target_url: []const u8)` to forward incoming requests to backends.
- Added Zig 0.15 deprecation warnings in documentation.
- Added three execution modes for client-side requests (`single_thread`, `multi_thread` with dynamic background workers, and `explicit_workers` using an existing thread pool).
- Added `Server.listenInBackground()` to spin up the server event loop asynchronously in one call.
- Added customizable logging support via `ServerConfig.log_fn` and `loggerWithConfig()` middleware to support integrating custom logging frameworks.
- Added benchmark coverage for executor scheduling and proxy request formatting, and refreshed the published benchmark snapshot.

### Changed
- Bumped project version to `0.1.1`.
- Centralized canonical IO helpers in `src/util/any_io.zig` with re-exports from `src/util/common.zig` (`defaultIo`, `sleepMs`, `sleepMsI`) so library code shares one test/runtime IO selector.
- Client TCP connects now honor `Timeouts.connect_ms` through `Socket.connectWithTimeout()`; connection pool creation uses the same connect timeout budget.
- Cleaned up redundant and duplicate aliases to simplify the public API surface (removed type aliases `HttpClient`, `ReqOptions`, `HttpServer`, `Ctx`, utility function aliases `parseQueryValue`, `parseCookiePair`, `utils`, and client alias `httpOptions`).
- Updated minimum Zig version to `0.16.0`.
- Updated concurrent request functions (`all`, `allSettled`, `any`, `race`, `first`, `fastest`, `settled`) to accept a `ConcurrencyConfig`.
- Aligned top-level package request wrappers (`get`, `getWithAllocator`, `fetch`, `fetchWithAllocator`) to accept `RequestOptions` for consistency with all other HTTP verb wrappers.
- Expanded documentation coverage for client/server/network/protocol/sockets, proxy support, JSON helpers, logging callbacks, and the new `0.1.0` install path.
- Updated the docs home page SEO title/description, canonical handling, and sitemap coverage.
- `unix_socket_example.zig` now prints the current platform name and gives platform-specific guidance when Unix domain sockets are unavailable.
- Updated README.md feature table to note that Unix domain sockets on Windows require build 17061+ with Developer Mode.
- Updated `docs/index.md` examples list with all examples and the Unix socket platform note.
- Updated `docs/guide/installation.md` platform support table to document per-OS Unix domain socket availability.

### Fixed
- Fixed HTTPS GET requests hanging and returning `ReadFailed` error. The buffered request data in the TLS writer is now explicitly flushed to the network. This addresses [Issue #19](https://github.com/muhammad-fiaz/httpx.zig/issues/19).
- Fixed HTTPS client TLS handshakes on Zig `0.16` by honoring `std.Io.Reader.fillUnbuffered`'s empty-buffer `readVec` contract in `src/net/socket.zig`, resolving `error.TlsConnectionTruncated` on simple GET requests. This addresses [Issue #14](https://github.com/muhammad-fiaz/httpx.zig/issues/14).
- Fixed client connect timeouts being ignored: `Timeouts.connect_ms` was documented but not applied during TCP `connect()`, which could leave concurrent tests and unreachable-host requests waiting up to the read timeout instead of failing promptly.
- Fixed `concurrency.pool` `ConcurrencyConfig modes execution` test appearing to hang during `zig build test` by using short per-request timeouts and a closed local port instead of `127.0.0.1:0`.
- Fixed thread join hangs and socket/listener deinitialization sequence deadlocks in all runtime examples on scope exit.
- Added comprehensive end-to-end runnable `proxy_example` demonstrating client forward proxying and server reverse proxy middleware.
- Added unit tests for client-side proxy request formatting and base64 proxy authentication encoding.
- Fixed mojibake console output on Windows (`ΓåÆ` instead of `→`) in `websocket_example.zig`, `session_example.zig`, and `health_check_example.zig` by replacing multi-byte UTF-8 arrow characters with ASCII `->`. Windows PowerShell/cmd default to codepage 1252 which cannot render U+2192.
- Fixed `udp_local.zig` printing raw Zig struct for the UDP source address. The sender address is now formatted as a human-readable `ip:port` string using `Address.format`.
- Fixed `multipart_example.zig` printing raw binary bytes (PNG magic header) as text for non-text MIME parts. Binary parts are now displayed as `<N bytes binary>` instead of garbage characters.
- Fixed `unix.zig` `INVALID_SOCKET` comparison on Windows using pointer equality which could fail with certain Zig pointer-sized `socket_t` types. The comparison now uses integer arithmetic matching `socket.zig`'s approach.
- Improved `unix_socket_example.zig` error messages to distinguish Windows-specific AF_UNIX limitations (build 17061+ / Developer Mode) from generic socket failures.

## [0.1.0] - 18-04-2026

### Added

- Added Zig 0.16 compatibility adapters:
  - `src/net/compat.zig` to provide address resolution/parsing compatibility helpers.
  - `src/util/any_io.zig` for lightweight reader/writer adapters.
  - `src/util/list_writer.zig` for allocator-backed list writer helpers.
- Added explicit server port conflict configuration in `ServerConfig`:
  - `port_conflict` with `.fail` / `.increment` strategies.
  - `max_port_tries` to bound auto-increment attempts.
- Added `Server.listeningPort()` to expose the effective bound port after startup.
- Added user-friendly client config builders in `ClientConfig`:
  - `defaults()`, `forBaseUrl(...)`, `withBaseUrl(...)`
  - `withTimeouts(...)`, `withRetryPolicy(...)`, `withRedirectPolicy(...)`
  - `withUserAgent(...)`, `withProtocols(...)`, `withPoolLimits(...)`
- Added request option builders in `RequestOptions`:
  - `defaults()`, `withHeaders(...)`, `withBody(...)`, `withJson(...)`, `withTimeoutMs(...)`, `withFollowRedirects(...)`
- Added per-request protocol selection in `RequestOptions`:
  - `version` field
  - `withVersion(...)`, `withHttp2()`, `withHttp3()` helpers
- Added `Client.initForBaseUrl(...)` for concise base-URL client creation.
- Added expanded MIME helpers:
  - broader extension coverage in `mimeTypeFromPath(...)`
  - explicit fallback override via `mimeTypeFromPathOr(...)`
- Added `Context.fileWithOptions(path, options)` with production-oriented static response controls:
  - `cache_control`
  - `add_etag`
  - `add_nosniff`
  - `conditional_get` (`If-None-Match` -> `304 Not Modified`)
- Added `FileResponseOptions` export in `src/httpx.zig`.
- Added richer request body/query helpers in `src/core/request.zig`:
  - `Request.setFormUrlEncoded(...)`
  - `Request.addQueryParams(...)`
- Added request auth/content helpers in `src/core/request.zig`:
  - `Request.setBearerAuth(...)`
  - `Request.setBasicAuth(...)`
  - `Request.hasContentType(...)`, `Request.isJsonContent()`, `Request.isFormContent()`
  - `Request.accepts(...)`, `Request.acceptsJson()`
- Added header convenience utilities in `src/core/headers.zig`:
  - `getOr(...)`
  - `appendIfMissing(...)`
  - `mergeFrom(...)`
- Added additional `ClientConfig` optional customization helpers:
  - `withDefaultHeaders(...)`
  - `withFollowRedirects(...)`
- Added additional `RequestOptions` optional customization helpers:
  - `query_params` + `withQueryParams(...)`
  - `form_fields` + `withFormUrlEncoded(...)`
  - `bearer_token` + `withBearerToken(...)`
  - `basic_auth` + `withBasicAuth(...)`
- Added client pool inspection/maintenance helpers in `src/client/client.zig`:
  - `cleanupIdleConnections()`
  - `poolStats()`
  - `hostPoolConnectionCount(...)`
- Added server context request helpers in `src/server/server.zig`:
  - `Context.authorization()`, `Context.bearerToken()`
  - `Context.hasContentType(...)`, `Context.isJson()`, `Context.isFormUrlEncoded()`
  - `Context.accepts(...)`, `Context.acceptsJson()`
- Added concurrency enhancements in `src/concurrency/pool.zig`:
  - extended `RequestSpec` with `json`, `timeout_ms`, `follow_redirects`, and `version`
  - `BatchBuilder.postJson(...)`
  - `successfulCount(...)` and `errorCount(...)`
- Added executor convenience helpers in `src/concurrency/executor.zig`:
  - `executeAll(...)`
  - `isRunning()`
  - `queueCapacity()`
- Added server context response helpers in `src/server/server.zig`:
  - `Context.download(...)`
  - `Context.noContent()`
- Added root exports/helpers in `src/httpx.zig`:
  - `TaskFn`, `ExecutorConfig`
  - `httpx.successfulCount(...)`, `httpx.errorCount(...)`
- Added additional `ClientConfig` builder helpers:
  - `withHttp2Settings(...)`
  - `withHttp3Settings(...)`
  - `withSslVerification(...)`
  - `withKeepAlive(...)`
  - `withMaxResponseSize(...)`
- Added root-level MIME utility aliases in `src/httpx.zig`:
  - `httpx.mimeTypeFromPath(...)`
  - `httpx.mimeTypeFromPathOr(...)`
- Added `examples/http_auth_helpers.zig` and docs page `docs/examples/http-auth-helpers.md` for built-in Bearer/Basic auth helper usage.

### Changed

- Bumped project version to `0.1.0`.
- Updated minimum Zig version to `0.16.0` in package metadata.
- Migrated deprecated `std.ArrayListUnmanaged` usage to `std.ArrayList` across source, tests, and examples.
- Updated examples and benchmark allocator setup to `std.heap.DebugAllocator(.{})` for Zig 0.16 compatibility.
- Updated docs and metadata to reflect `0.1.0` and Zig `0.16.0` support.
- Updated CI/release workflows and issue templates to target Zig `0.16.0`.
- Updated server/runtime docs and examples to include explicit port-conflict startup behavior.
- Updated README, API docs, guide docs, and runnable examples to document and demonstrate the new client config/request-option builder syntax.
- Updated `Context.file(...)` and `Context.fileAs(...)` to route through `fileWithOptions(...)`.
- Updated server runtime to suppress response bodies for all `HEAD` requests.
- Updated server `Content-Length` auto-injection to skip status classes that must not carry a body (`1xx`, `204`, `304`).
- Updated static file example and API docs to demonstrate ETag-aware static serving and Zig 0.16-compatible usage patterns.
- Updated utilities/docs to include broader, case-insensitive MIME mapping behavior and fallback override usage.
- Updated README and API/guide docs to mark config/request option builders consistently as optional customization while keeping defaults implicit.
- Updated `examples/simplified_api_aliases.zig` and docs to run alias calls against a local loopback server by default, with optional live mode via `HTTPX_EXAMPLE_ONLINE=1`.
- Removed bundled `httpx-project-starter` template directory and related repository references.

### Fixed

- Removed remaining Zig 0.15-only API patterns from examples/runtime paths (`std.net.Address.parseIp`, `std.Thread.sleep`, deprecated ArrayList aliases).
- Fixed stale docs install snippets to avoid pointing at unpublished release tags.
- Fixed server startup behavior on occupied ports by supporting bounded auto-increment retry mode.
- Fixed IPv4 byte-order conversion in `src/net/compat.zig`, resolving intermittent local loopback `BindFailed`/`ConnectFailed` in local TCP/UDP and HTTP/2/HTTP/3 runtime examples.

## [0.0.7] - 28/03/2026

### Added

- Expanded explicit network API support in `src/net/socket.zig`:
  - TCP socket helpers: `createV4/createV6`, `connectHost`, `connectEndpoint`, `bindHost`, `shutdown`, `shutdownRead`, `shutdownWrite`, `shutdownBoth`, `getLocalAddress`, `getPeerAddress`, `setRecvBufferSize`, `setSendBufferSize`
  - UDP socket helpers: `createForAddress`, `bindHost`, `connectHost`, `connectEndpoint`, `write`, `read`, `sendToHost`, `setBroadcast`, `setRecvBufferSize`, `setSendBufferSize`, `getPeerAddress`
  - TCP listener host helpers: `initHost`, `initHostWithBacklog`
- Added explicit network API compile-check coverage in `src/net/socket.zig` tests.
- Added API overview page at `docs/api/index.md` to map root exports and convenience aliases.
- Expanded API alias coverage for client and top-level helpers:
  - Client aliases: `del(...)`, `opts(...)`
  - Top-level aliases: `delete(...)`, `opts(...)`, `first(...)`, `fastest(...)`, `settled(...)`
  - Utility aliases: `parseQueryValue`, `parseCookiePair`, `encodeVarInt`, `decodeVarInt`
- Added alias compile-check tests in `src/httpx.zig` and `src/client/client.zig`.
- Expanded network-layer APIs:
  - TCP socket helpers: `createV4/createV6`, `connectHost`, `connectEndpoint`, `bindHost`, `getLocalAddress`, `getPeerAddress`
  - TCP listener host helpers: `initHost`, `initHostWithBacklog`
  - UDP socket helpers: `createForAddress`, `bindHost`, `connectHost`, `connectEndpoint`, `sendToHost`, `getPeerAddress`
  - Address utilities: `resolveAll`, `parseAndResolve`
  - Root network aliases: `netInit`, `netDeinit`, `resolveAllAddresses`, `parseAndResolveAddress`, `isIpAddress`, `isIp4Address`, `isIp6Address`
- Added/expanded networking tests for new TCP/UDP/address helper APIs.
- Added/updated network API docs for host-based connect/bind/send and address utility coverage.
- Added high-level HTTP/2 client runtime support in `src/client/client.zig`:
  - HTTP/2 preface + SETTINGS handshake
  - HPACK HEADERS request encoding from high-level `Request`
  - DATA frame request body streaming
  - Response HEADERS/DATA decode into high-level `Response`
  - SETTINGS ACK, PING ACK, and CONTINUATION handling
- Added high-level HTTP/3 client runtime support in `src/client/client.zig`:
  - UDP transport execution path for HTTP/3 requests
  - QUIC long/short header packet exchange with STREAM frame transport
  - HTTP/3 control/request stream framing with SETTINGS, HEADERS, and DATA handling
  - QPACK request header encoding and response header decoding into high-level `Response`
- Added high-level HTTP/2 server runtime support in `src/server/server.zig`:
  - HTTP/2 request handling path with SETTINGS/HEADERS/DATA/ACK processing
  - Route execution + response serialization through HTTP/2 HEADERS/DATA frames
  - Shared high-level route/middleware execution across HTTP/1.x and HTTP/2 paths
- Added high-level HTTP/3 server runtime support in `src/server/server.zig`:
  - UDP listener and request handling path for HTTP/3 transactions
  - QUIC STREAM packet decoding with HTTP/3 control/request stream handling
  - QPACK header decode/encode integration for high-level route responses
- Added HTTP/2/HTTP/3 client protocol configuration fields in `ClientConfig`:
  - `http2_settings`
  - `http3_settings`
- Added HTTP/2/HTTP/3 server protocol configuration fields in `ServerConfig`:
  - `http2_enabled`
  - `http3_enabled`
  - `http2_settings`
  - `http3_settings`
- Added HTTP/2 runtime integration tests with an in-memory frame transport.
- Added HTTP/3 runtime integration tests with in-memory datagram transport.
- Added new runnable `examples/http2_client_runtime.zig` demonstrating end-to-end high-level HTTP/2 client execution against a local loopback server.
- Added new runnable `examples/http3_client_runtime.zig` demonstrating end-to-end high-level HTTP/3 client execution against a local UDP loopback server.
- Added new runnable `examples/http2_server_runtime.zig` demonstrating end-to-end high-level HTTP/2 server runtime behavior against a local client.
- Added new runnable `examples/http3_server_runtime.zig` demonstrating end-to-end high-level HTTP/3 server runtime behavior over local UDP.

### Changed

- Updated VitePress navigation and sidebar to surface API overview and changelog links.
- Updated README with explicit network and concurrency helper usage examples.
- Expanded API docs for network/server/concurrency parity and refreshed examples/docs build outputs.
- Added explicit validation matrix documentation for host checks and cross-target compile workflows.
- Bumped project version to `0.0.7`.
- Updated default User-Agent version to `httpx.zig/0.0.7`.
- Updated README/docs/install references and docs metadata to `0.0.7`.
- Updated benchmarks to use top-level varint alias (`httpx.encodeVarInt`).
- Updated CORS middleware factory to use `comptime` config capture for nested-handler compile compatibility.
- Updated README and docs protocol support descriptions to reflect:
  - high-level HTTP/2 client and server runtime support
  - high-level HTTP/3 client and server runtime support over UDP + QUIC/HTTP3/QPACK primitives
- Updated docs examples index/sidebar and added dedicated pages for HTTP/2 and HTTP/3 server runtime examples.
- Updated validation/support wording to the explicitly validated Linux/Windows/macOS 32-bit and 64-bit build matrix.

### Fixed

- Fixed `zig build run-all-examples` failure in `examples/tcp_local.zig` by restoring stream-style compatibility methods (`read`, `writeAll`) on `httpx.Socket`.
- Fixed UDP local example address output formatting for Zig 0.15 by using explicit `{f}` formatter.
- Implemented missing client alias methods `Client.del(...)` and `Client.opts(...)` to match documented API coverage.
- Fixed x86-windows cross-target link failure by using target-safe UDP/TCP receive paths in `src/net/socket.zig`.
- Fixed `Socket.reader()`/`Socket.writer()` adapter casting for alignment-safe `anyopaque` conversion on Zig 0.15.
- Fixed `Socket.reader()` adapter error handling by removing a non-existent `error.WouldBlock` branch.
- Fixed client retry behavior to fail fast on TLS/protocol parse errors (instead of retrying deterministic failures), resolving [Issue #11](https://github.com/muhammad-fiaz/httpx.zig/issues/11) where requests could appear hung.
- Fixed Zig 0.15.2 TLS PEM parsing compatibility by using allocator-aware `ArrayList` APIs.
- Fixed HTTP response parser test fixture by including explicit `Content-Length` in the test response.
- Fixed cross-target BSD-family compile compatibility for TCP_NODELAY socket options by adding a portable fallback when `std.posix.TCP.NODELAY` is unavailable.

## [0.0.6] - 2026-03-24

### Fixed

- Fixed Zig 0.15.2 dependency integration guidance to consistently use the standard `-Doptimize` build option in `build.zig` examples and docs.
  - This resolves [Issue #11](https://github.com/muhammad-fiaz/httpx.zig/issues/11).

### Changed

- Bumped project version to `0.0.6`.
- Updated default User-Agent version to `httpx.zig/0.0.6`.
- Updated README, docs, and installation references to `0.0.6`.
- Updated docs metadata (`package.json`, `package-lock.json`, and VitePress schema `softwareVersion`) to `0.0.6`.
- Updated `SECURITY.md` supported-version checklist for `0.0.6` and below.

## [0.0.5] - 2026-03-21

### Fixed

- Fixed HTTPS client panic on Zig 0.15.2 (`std.crypto.tls.Client` unreachable assertion) by ensuring TLS transport I/O buffers always satisfy `Client.min_buffer_len`.
  - This resolves [Issue #9](https://github.com/muhammad-fiaz/httpx.zig/issues/9).
- Fixed server listener initialization robustness by:
  - honoring configured `max_connections` as socket backlog,
  - clamping invalid `max_connections = 0` to a safe default,
  - applying safe fallback defaults for request and keep-alive timeouts.
  - This resolves [Issue #10](https://github.com/muhammad-fiaz/httpx.zig/issues/10).
- Updated simple server runnable examples to use explicit server config and to actually start listening.

### Changed

- Bumped project version to `0.0.5`.
- Updated default User-Agent version to `httpx.zig/0.0.5`.
- Updated README and VitePress installation/version references to `0.0.5`.

## [0.0.4] - 2026-03-20

### Added

- Server context cookie helpers:
  - `Context.cookie(name)` to read request cookies from the `Cookie` header.
  - `Context.setCookie(name, value, options)` for RFC 6265 style `Set-Cookie` generation.
  - `Context.removeCookie(name, options)` for cookie invalidation (`Max-Age=0`).
- New shared cookie utilities in `src/util/common.zig`:
  - `cookieValue(...)` for parsing `Cookie` header values.
  - `buildSetCookieHeader(...)` for generating `Set-Cookie` strings.
  - `CookieOptions` + `SameSite` enums for cookie attributes.
- Top-level exports for cookie types in `src/httpx.zig`:
  - `httpx.CookieOptions`
  - `httpx.SameSite`
- Server runtime enhancements:
  - Middleware stack is now executed in the request path.
  - `Server.preRoute(...)` hook support before route matching.
  - `Server.global(...)` fallback handler for unmatched routes.
  - `Server.any(path, handler)` convenience registration across standard methods.
  - `Context.sse(events)` one-shot Server-Sent Events response helper.
  - `Context.chunked(data, trailers)` chunked transfer response helper with optional trailers.
- Protocol utility additions:
  - `http.encodeChunkedBody(...)` helper for chunked transfer body encoding.
  - `http.isH2cUpgradeRequest(...)` helper for h2c header detection.
- Shared utility additions:
  - `mimeTypeFromPath(...)` for centralized extension-to-content-type mapping.

### Changed

- Improved CORS middleware behavior:
  - Uses `CorsConfig` values for allowed origins, methods, headers, credentials, exposed headers, and max-age.
  - Adds origin-aware headers and proper preflight (`OPTIONS`) handling.
- Updated docs protocol claims and support matrices to consistently distinguish HTTP/1.x runtime support from HTTP/2/HTTP/3 protocol primitive support.
- Bumped project version to `0.0.4`.
- Updated default User-Agent to `httpx.zig/0.0.4`.
- Updated README and VitePress docs install/version references to `0.0.4`.

## [0.0.3] - 17-04-2026

### Added

- Server routing behavior improvements:
  - Automatic `HEAD` fallback to matching `GET` route handlers (without a response body).
  - Automatic `OPTIONS` responses for matched paths with an `Allow` header.
  - `405 Method Not Allowed` responses with `Allow` header when path exists for other methods.
- Router utility for method discovery on a path via `allowedMethods`.
- Server test coverage for allowed-method discovery.
- QPACK protocol support improvements:
  - Dynamic-table and post-base header references in header block decoding.
  - Dynamic-table-aware header block encoding paths.
- QUIC protocol decode helpers for ACK, CONNECTION_CLOSE, and transport-parameter blocks.
- Protocol test coverage for new QPACK and QUIC decode paths.
- Public client cookie-jar APIs: `setCookie`, `getCookie`, `removeCookie`, and `clearCookies`.
- Additional client cookie-jar helpers: `hasCookie` and `cookieCount`.
- Simplified client aliases:
  - Client methods: `send`, `fetch`, `options`.
  - Root-level helpers: `fetch`, `send`, `post`, `put`, `del`, `patch`, `head`, `options`.
- New runnable examples:
  - `examples/cookies_demo.zig`
  - `examples/simplified_api_aliases.zig`
- Core convenience APIs:
  - `Request.addQueryParam(...)` for safe query-string appends.
  - `Response.redirect(...)`, `Response.fromText(...)`, `Response.fromJson(...)`.
- Connection pool introspection APIs:
  - `ConnectionPool.hostConnectionCount(...)`
  - `ConnectionPool.stats()` with `PoolStats` export.
- Shared utility module: `src/util/common.zig` (`queryValue`, `parseSetCookiePair`) reused by client/server code paths.

### Changed

- Bumped project version to `0.0.3`.
- Updated default User-Agent version to `httpx.zig/0.0.3`.
- Updated install references and release metadata across README and VitePress docs to `0.0.3`.
- Updated README project status note to reflect production-readiness goals for a newer project.
- Updated API docs to align with current implementation details (response fields/methods and server config/context tables).
- Included client cookie jar handling and Set-Cookie persistence details in release notes.
- Removed Express-style framework comparisons across maintained docs and source comments.
- Improved code reuse by centralizing repeated query/cookie parsing logic into shared utility helpers.
- Expanded static assets example coverage and docs:
  - `examples/static_files.zig` now demonstrates file-based static routes and directory-based wildcard mounts for CSS/JS/images, with redirects and safe path handling.
  - `examples/multi_page_website.zig` provides a dedicated multi-page website server demo for full page routing plus static asset serving.
  - README/docs example catalogs now list all runnable examples, including protocol and UDP demos.
  - Client API docs now explicitly document optional interceptor callbacks.

## [0.0.2] - 2026-03-20

### Added

- Added `CONTRIBUTING.md` with development, testing, and PR workflow guidance.
- Added `SECURITY.md` with supported-version and vulnerability-reporting policy.
- Added standardized issue form templates and workflow improvements in `.github`.

### Changed

- Updated project version references from `0.0.1` to `0.0.2` in source and docs.
- Updated README structure, links, and badges.
- Improved `build.zig` reuse and platform-link handling for cross-target consistency.
- Made test execution in `build.zig` host-aware for non-host targets.

### Fixed

- Zig 0.15.2 compatibility updates:
  - Replaced deprecated JSON allocation usage with portable JSON writer-based allocation.
  - Updated socket accept handling for stdlib signature differences.
  - Normalized accept return type to avoid anonymous-struct mismatch.
- Verified 32-bit and 64-bit target build coverage via `zig build build-all-targets`.

## [0.0.1] - Initial Release

### Added

- Initial release of `httpx.zig`.
- Core HTTP library foundations.
- Client and server functionality.
- Protocol modules including HTTP/1.1, HTTP/2, and HTTP/3 support components.
- Utilities, networking abstractions, and examples.
