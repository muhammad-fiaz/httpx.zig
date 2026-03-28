# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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

### Fixed

- Fixed `zig build run-all-examples` failure in `examples/tcp_local.zig` by restoring stream-style compatibility methods (`read`, `writeAll`) on `httpx.Socket`.
- Fixed UDP local example address output formatting for Zig 0.15 by using explicit `{f}` formatter.
- Implemented missing client alias methods `Client.del(...)` and `Client.opts(...)` to match documented API coverage.
- Fixed x86-windows cross-target link failure by using target-safe UDP/TCP receive paths in `src/net/socket.zig`.
- Fixed client retry behavior to fail fast on TLS/protocol parse errors (instead of retrying deterministic failures), resolving [Issue #11](https://github.com/muhammad-fiaz/httpx.zig/issues/11) where requests could appear hung.
- Fixed Zig 0.15.2 TLS PEM parsing compatibility by using allocator-aware `ArrayList` APIs.
- Fixed HTTP response parser test fixture by including explicit `Content-Length` in the test response.

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

## [0.0.3] - 2026-03-20

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
