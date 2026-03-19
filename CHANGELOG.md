# Changelog

All notable changes to this project are documented in this file.

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
