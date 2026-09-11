# Client API

The `httpx.zig` client provides a high-level HTTP client for making requests over HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3. HTTPS is supported via a fully custom TLS 1.2/1.3 implementation built on `std.crypto` primitives (AES-GCM, ChaCha20-Poly1305, X25519, HKDF, SHA-256/384/512) with ALPN negotiation for HTTP/2 and HTTP/3.

## Protocol Support

| Protocol | Status | Transport | Notes |
|----------|--------|-----------|-------|
| HTTP/1.0 | ✅ Full | TCP | Legacy support |
| HTTP/1.1 | ✅ Full | TCP/TLS | Default protocol |
| HTTP/2 | ✅ Client Runtime + Primitives | TCP/TLS | High-level client request execution path plus full framing/HPACK/stream primitives |
| HTTP/3 | ✅ Client Runtime + Primitives | QUIC/UDP | High-level client runtime over UDP + QUIC/HTTP3/QPACK primitives (suitable for local/integration endpoints) |

HTTP/3 runtime mode is available in the high-level client and uses QUIC packet/stream framing primitives directly. Interoperability with endpoints that require full TLS-in-QUIC handshake negotiation may vary depending on deployment expectations.

The protocol module provides HTTP/2 and HTTP/3 building blocks (HPACK/QPACK, framing, and transport primitives). See [Protocol API](protocol.md) for details.

## Proxy Modes

`httpx.zig` supports two client proxy modes:

| Kind | Behavior | DNS resolution |
|------|----------|----------------|
| `http` | Standard forward proxy or HTTPS CONNECT tunnel | Client resolves the target host unless the proxy protocol performs the tunnel itself |
| `socks5h` | SOCKS5 proxy with remote host resolution | Proxy resolves the hostname and connects on behalf of the client |

Use `socks5h` when you want to avoid local DNS lookups or when the proxy has access to names that are not visible on the client network.

## Client

The `Client` struct is the main entry point for making requests. It manages connection pooling, cookies, and interceptors.

### Initialization

```zig
const std = @import("std");
const httpx = @import("httpx");

const io = std.Io.Threaded.global_single_threaded.io();

// Initialize with default configuration (returns Client by value)
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

// Initialize with custom configuration
var client = httpx.Client.init(allocator, io, .{
    .httpVersion = .auto, // or .http10, .http11, .http2, .http3
    .timeoutMs = 10_000,
    .followRedirects = true,
});
defer client.deinit();

// Out-of-the-box convenience (zero initialization needed):
var response = try httpx.get("https://api.example.com/users");
defer response.deinit();

// Dot notation module access:
var post_res = try httpx.post("https://api.example.com/users", .{ .json = .{ .name = "Alice", .role = "developer" },
});
defer post_res.deinit();
```

`ClientConfig` is an idiomatic Zig struct where omitted fields use standard defaults.
It matches `httpx.ClientConfig` in `src/client/client.zig` exactly:

```zig
const io = std.Io.Threaded.global_single_threaded.io();
const cfg: httpx.ClientConfig = .{
    .timeoutMs = 10_000,
    .followRedirects = true,
    .maxRedirects = 5,
    .maxRetries = 3,
    .retryDelayMs = 500,
    .retryStatusCodes = &.{ 502, 503, 504 },
    .httpVersion = .http2,
    .pool = .{ .maxConnections = 64, .maxPerHost = 16 },
    .proxy = null,
    .cookies = true,
};

var client = httpx.Client.init(allocator, io, cfg);
defer client.deinit();
```

### Configuration (`ClientConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `timeoutMs` | `?u64` | `null` | Default request timeout in milliseconds. |
| `followRedirects` | `bool` | `true` | Whether to automatically follow redirects. |
| `maxRedirects` | `u8` | `10` | Maximum redirects to follow per request. |
| `maxRetries` | `u32` | `0` | Retry attempts for failed requests (`0` = disabled). |
| `retryDelayMs` | `u64` | `1000` | Base delay between retries in milliseconds. |
| `retryStatusCodes` | `[]const u16` | `&.{ 502, 503, 504 }` | Status codes that trigger a retry. |
| `httpVersion` | `?HttpVersion` | `null` | Preferred HTTP version (`.auto`, `.http10`, `.http11`, `.http2`, `.http3`). |
| `http10` | `bool` | `true` | Fast toggle to enable HTTP/1.0 protocol. |
| `http11` | `bool` | `true` | Fast toggle to enable HTTP/1.1 protocol. |
| `http2` | `bool` | `false` | Fast toggle to use HTTP/2 as default protocol. |
| `http3` | `bool` | `false` | Fast toggle to use HTTP/3 as default protocol. |
| `cookies` | `bool` | `true` | Enable cookie jar handling. |
| `pool` | `PoolConfig` | `{}` | Connection pool limits (`maxConnections`, `maxPerHost`, `idleTimeoutMs`, `maxParkedMs`). |
| `dnsCache` | `DnsCacheOptions` | `{}` | DNS cache settings (`enable`, `ttlMs`, `negativeTtlMs`, `maxEntries`). |
| `tls` | `?TlsOptions` | `null` | Default TLS options for `https://` requests. |
| `proxy` | `?[]const u8` | `null` | Default proxy URL (`http://`, `socks5://`, `socks5h://`). |
| `maxResponseSize` | `?usize` | `null` | Default maximum response body size. |
| `allowLfLineEndings` | `bool` | `false` | Accept bare LF line endings from non-compliant peers. |
| `eventCallback` | `?ClientEventCallback` | `null` | Application callback for client events (silent by default). |

If you do not set a field, the implicit default value is used. `.{}` is the safe default.

### Timeouts

The client uses a single uniform timeout model. `ClientConfig.timeoutMs`
sets the default deadline applied to requests; per-request
`RequestOptions.timeoutMs` overrides it for that request.

```zig
const io = std.Io.Threaded.global_single_threaded.io();
var client = httpx.Client.init(allocator, io, .{
    .timeoutMs = 10_000,
});
defer client.deinit();

const res = try client.get("https://example.com/slow", .{ .timeoutMs = 2_000 });
defer res.deinit();
```

### Client Initialization

| Function | Description |
|----------|-------------|
| `Client.init(allocator, io, config)` | Initialize client with allocator, io, and configuration (or `.{}` for defaults). |

### Primary Unified API: `fetch`

`client.fetch(url, options)` is the primary high-level HTTP client operation. It supports all HTTP methods, strongly typed JSON serialization, custom headers, query parameters, timeouts, and body streaming in a single call:

```zig
// Simple GET
var res = try client.fetch("https://api.example.com/data", .{});
defer res.deinit();

// POST with strongly typed Zig struct (automatically serialized via std.json)
const CreateUser = struct { name: []const u8, email: []const u8 };
const User = struct { id: u64, name: []const u8, email: []const u8 };

var res2 = try client.fetch("https://api.example.com/users", .{
    .method = .POST,
    .headers = .{ .Authorization = "Bearer secret_token" },
    .json = CreateUser{ .name = "Fiaz", .email = "fiaz@example.com" },
});
defer res2.deinit();

// Strongly typed response deserialization:
const user = try res2.json(User);
std.debug.print("User created: id={d} name={s}\n", .{ user.id, user.name });

// Managed lifecycle deserialization with explicit allocator:
const parsed = try res2.jsonAlloc(User, allocator);
defer parsed.deinit();
```

### Response Methods

| Method | Description |
|--------|-------------|
| `json(comptime T: type) !T` | Parses response body as JSON into type `T` using the response's allocator. |
| `jsonAlloc(comptime T: type, allocator: Allocator) !std.json.Parsed(T)` | Parses response body as JSON with explicit allocator and managed lifecycle. |
| `bytes() []const u8` | Returns response body as a raw byte slice. |
| `text() []const u8` | Returns response body as a UTF-8 text string. |
| `writeTo(writer: anytype) !void` | Streams or writes response body directly to any writer (file, stdout, buffer). |
| `header(name: []const u8) ?[]const u8` | Case-insensitive header lookup. |
| `status u16` | Returns HTTP status code integer. |
| `isSuccess() bool` | Returns true if status code is in 200..299 range. |
| `isRedirect() bool` | Returns true if status code is in 300..399 range. |
| `isInformational() bool` | Returns true if status code is in 100..199 range. |

### Methods

All methods are URL-first (`url`, then options):

| Method | Description |
|--------|-------------|
| `fetch(url, options)` | **Primary unified HTTP request operation** |
| `get(url, options)` | HTTP GET request |
| `post(url, options)` | HTTP POST request |
| `put(url, options)` | HTTP PUT request |
| `delete(url, options)` | HTTP DELETE request |
| `patch(url, options)` | HTTP PATCH request |
| `head(url, options)` | HTTP HEAD request |
| `trace(url, options)` | HTTP TRACE request |
| `connect(url, options)` | HTTP CONNECT request |
| `options(url, options)` | HTTP OPTIONS request |
| `request(url, options)` | Generic request (method set via `options.method`) |
| `getAll(urls)` | Concurrent GETs; deinit each response, free the slice |
| `requestAll(reqs)` | Concurrent requests; same ownership |
| `download(url, options)` | Streaming file download with resume/verify (destination via `options.path`) |
| `downloadBatch(tasks, options)` | Concurrent downloads |
| `lookupFileInfo(url, options)` | Remote metadata without body download |
| `updateFile(url, options)` | Atomic file update with rollback (target via `options.path`) |
| `graphql(url, query, variables, options)` | GraphQL request |
| `fetchDocument/fetchHtml/fetchXml/fetchFeed/fetchRobots/fetchSitemap(url, options)` | Fetch + parse documents |
| `resolve(host, options)` / `resolveUrl(url, options)` | DNS resolution (port via `options.port`) |
| `close()` | Purge the connection pool |
| `reset()` | Close + clear DNS cache |

### Cookie Jar API

The standalone `httpx.CookieJar` keeps cookies across requests
(domain-filtered per RFC 6265). Per-request cookies use the `cookie` option.

| Method | Description |
|--------|-------------|
| `CookieJar.init(allocator)` / `deinit()` | Lifecycle |
| `setFromHeader(setCookie, host)` | Store a `Set-Cookie` value |
| `cookieHeader(host, path, secure, buf)` | Render the `Cookie` header (`secure` gates `Secure` cookies) |
| `purgeExpired()` | Drop expired cookies |

### Quick Examples

```zig
const std = @import("std");
const httpx = @import("httpx");

const io = std.Io.Threaded.global_single_threaded.io();
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

// Simple GET
const response = try client.get("https://api.example.com/users", .{});
defer response.deinit();
std.debug.print("Status: {d}\n", .{response.status});
std.debug.print("Body: {s}\n", .{response.body});

// POST with JSON
const json_response = try client.post("https://api.example.com/users", .{
    .json = "{\"name\": \"John\", \"email\": \"john@example.com\"}",
});
defer json_response.deinit();

// Custom headers
const auth_response = try client.get("https://api.example.com/protected", .{
    .headers = &.{
        .{ "Authorization", "Bearer token123" },
        .{ "X-Custom-Header", "value" },
    },
});
defer auth_response.deinit();

// Built-in auth helpers
const bearer_response = try client.get("https://api.example.com/protected", .{ .headers = &.{.{ "Authorization", "Bearer token123" }, .{ "Accept", "application/json" }},
});
defer bearer_response.deinit();

// With timeout
const timeout_response = try client.get("https://slow-api.com/data", .{
    .timeoutMs = 30000, // 30 seconds
});
defer timeout_response.deinit();
```

### Client Usage Recipes

For complete copy/paste demos, see these example pages:

- [Simple Get](/examples/simple-get)
- [Simple Get Deserialize](/examples/simple-get-deserialize)
- [JSON API](/examples/json-api-example) - typed `.json` bodies, `Response.json(r)`, server `ctx.json(r)` + `ctx.renderJson(value)`
- [Post JSON](/examples/post-json)
- [Custom Headers](/examples/custom-headers)
- [Concurrent Requests](/examples/concurrent-requests)
- [Connection Pool](/examples/connection-pool)
- [Interceptors](/examples/interceptors)
- [Cookies Demo](/examples/cookies-demo)
- [HTTP Auth Helpers](/examples/http-auth-helpers)
- [Simplified API Aliases](/examples/simplified-api-aliases)

### Request Options (`RequestOptions`)

Per-request overrides for configuration. The client accepts these fields
directly (plus duck-typed extras such as `multipart` and `graphql`
handled via `anytype` opts). Unset optional fields fall back to
client-level defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `method` | `?Method` | `null` | Explicit method for generic `request`/`fetch` (wrappers supply their own). |
| `headers` | `[]const Header` | `&.{}` | Additional headers (`{ .name, .value }` pairs). |
| `query` | `[]const Header` | `&.{}` | Percent-encoded query params appended to the URL. |
| `body` | `?[]const u8` | `null` | Raw request body. |
| `json` | `?[]const u8` | `null` | JSON string body (sets Content-Type). |
| `form` | `?[]const u8` | `null` | Pre-encoded `application/x-www-form-urlencoded` body. |
| `text` | `?[]const u8` | `null` | Plain-text body. |
| `contentType` | `?[]const u8` | `null` | Explicit Content-Type override. |
| `basicAuth` | `?[]const u8` | `null` | `"user:pass"` encoded as `Authorization: Basic ...`. |
| `bearerAuth` | `?[]const u8` | `null` | Sets `Authorization: Bearer <token>`. |
| `cookie` | `?[]const u8` | `null` | Cookie header value for this request. |
| `timeoutMs` | `?u64` | `null` | Request-specific timeout override. |
| `maxResponseSize` | `?usize` | `null` | Request-specific max response body size. |
| `followRedirects` | `?bool` | `null` | Override client redirect setting. |
| `maxRedirects` | `?u8` | `null` | Override client max-redirect limit. |
| `allowLfLineEndings` | `bool` | `false` | Accept bare LF line endings in the response. |
| `httpVersion` | `?HttpVersion` | `null` | Force a request over a specific protocol runtime. |
| `http10` / `http11` / `http2` / `http3` | `?bool` | `null` | Per-request protocol toggles. |
| `tls` | `?TlsOptions` | `null` | Per-request TLS options for `https://`. |
| `proxy` | `?[]const u8` | `null` | Per-request proxy URL override. |

Request options are configured directly using struct literals:

```zig
var res = try client.get("/users", .{
    .headers = &.{.{ .name = "Accept", .value = "application/json" }},
    .query = &.{.{ .name = "page", .value = "1" }},
    .timeoutMs = 10_000,
    .httpVersion = .http2,
    .followRedirects = true,
});
defer res.deinit();
```

### Multipart File Uploads

Use the `multipart` option to send `multipart/form-data` bodies.
The client assembles the body and sets the `Content-Type` header
(see `examples/multipart.zig`).

```zig
var resp = try client.post("https://example.com/upload", .{
    .multipart = .{
        .name = "upload",
        .filename = "data.bin",
        .contentType = "application/octet-stream",
        .data = chunk_slice,
    },
});
defer resp.deinit();
```

> **Windows — buffer limit (issue #26)**
>
> On Windows the Winsock kernel send buffer is typically 8–64 KB. When sending
> large multipart data as a single body, `winsock.send()` may stall.
>
> httpx.zig 0.1.8+ automatically caps each send call to 64 KB, so most uploads
> now work without application changes. For extra safety — especially for payloads
> larger than a few hundred KB — build the body with
> `httpx.multipart.encoder.Multipart` (or post a single part inline with the
> `.multipart` request option) and issue one request per slice.
> See the [Multipart Guide](../guide/multipart.md#large-file-uploads--windows-compatibility)
> for a complete resumable upload example.


## Response

The `Response` struct contains the server's response
(`src/client/request.zig`).

```zig
pub const Response = struct {
    allocator: Allocator,
    status: u16,
    version: HttpVersion,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Response) void
    pub fn header(self: *const Response, name: []const u8) ?[]const u8
    pub fn text(self: *const Response) []const u8
    pub fn bytes(self: *const Response) []const u8
    pub fn writeTo(self: *const Response, writer: anytype) !void
    pub fn contentType(self: *const Response) []const u8
    pub fn json(self: *const Response, comptime T: type) !T
    pub fn jsonAlloc(self: *const Response, comptime T: type, allocator: Allocator) !std.json.Parsed(T)
    pub fn isInformational(self: *const Response) bool
    pub fn isSuccess(self: *const Response) bool
    pub fn isRedirect(self: *const Response) bool
};
```

### Response Methods

| Method | Description |
|--------|-------------|
| `deinit()` | Free response resources |
| `header(name)` | Get header value by name (case-insensitive) |
| `text()` / `bytes()` | Get response body bytes |
| `writeTo(writer)` | Stream body bytes to any writer |
| `contentType()` | Response Content-Type value |
| `json(T)` | Parse body as JSON into `T` (ignores unknown fields) |
| `jsonAlloc(T, allocator)` | Parse body as JSON, returning `std.json.Parsed(T)` |
| `isInformational()` | Status 100-199 |
| `isSuccess()` | Status 200-299 |
| `isRedirect()` | Status 300-399 |

## Middleware

HTTPX has no client interceptor registry. Cross-cutting request/response
behavior belongs in server middleware (`httpx.middleware.*`) or in small
wrappers around the URL-first client calls. The
`examples/interceptor_example.zig` demo exercises a plain server route plus
a client GET against it.

## Error Handling

```zig
const response = client.get("https://example.com", .{}) catch |err| switch (err) {
    error.ConnectionRefused => {
        std.debug.print("Server not available\n", .{});
        return;
    },
    error.Timeout => {
        std.debug.print("Request timed out\n", .{});
        return;
    },
    error.TlsError => {
        std.debug.print("TLS handshake failed\n", .{});
        return;
    },
    else => return err,
};
```

## Convenience Functions

The root module exposes zero-config convenience helpers for simple requests:

```zig
var a = try httpx.get("https://example.com", .{});
defer a.deinit();

var b = try httpx.post("https://example.com/items", .{ .json = "{\"name\":\"demo\"}",
});
defer b.deinit();

var c = try httpx.delete("https://example.com/items/42", .{});
defer c.deinit();

var d = try httpx.put("https://example.com/items", .{ .json = "{\"name\":\"updated\"}",
});
defer d.deinit();

var e = try httpx.patch("https://example.com/items", .{ .json = "{\"name\":\"patched\"}",
});
defer e.deinit();

var f = try httpx.head("https://example.com/items", .{});
defer f.deinit();

var g = try httpx.options("https://example.com/items", .{});
defer g.deinit();

var h = try httpx.request("https://example.com/health", .{
    .method = .GET,
});
defer h.deinit();
```

Top-level request functions (all URL-first):

| Function | Description |
|----------|-------------|
| `httpx.get(url, opts)` | HTTP GET |
| `httpx.post(url, opts)` | HTTP POST |
| `httpx.put(url, opts)` | HTTP PUT |
| `httpx.patch(url, opts)` | HTTP PATCH |
| `httpx.delete(url, opts)` | HTTP DELETE |
| `httpx.head(url, opts)` | HTTP HEAD |
| `httpx.options(url, opts)` | HTTP OPTIONS |
| `httpx.trace(url, opts)` | HTTP TRACE |
| `httpx.connect(url, opts)` | HTTP CONNECT |
| `httpx.fetch(url, opts)` | Unified fetch (any method via `.method`) |
| `httpx.request(url, opts)` | General HTTP request (any method via `.method`) |
| `httpx.getAll(&urls)` | Concurrent GET requests |
| `httpx.requestAll(&requests)` | Concurrent custom requests |

## See Also

- [Protocol API](protocol.md) - HTTP/2, HTTP/3, HPACK, QPACK
- [Connection Pool](pool.md) - Connection pooling
- [Concurrency](concurrency.md) - Parallel requests
- [Client Guide](/guide/client-basics) - Usage guide
