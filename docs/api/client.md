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
    .base_url = "https://api.example.com",
    .user_agent = "my-app/1.0",
    .httpVersion = .auto, // or .http10, .http11, .http2, .http3
});
defer client.deinit();

// Out-of-the-box convenience (zero initialization needed):
var response = try httpx.get("https://api.example.com/users");
defer response.deinit();

// Dot notation module access:
var post_res = try httpx.client.post("https://api.example.com/users", .{ .json = .{ .name = "Alice", .role = "developer" },
});
defer post_res.deinit();
```

`ClientConfig` is an idiomatic Zig struct where omitted fields use standard defaults:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
const cfg: httpx.ClientConfig = .{
    .base_url = "https://api.example.com",
    .timeouts = httpx.Timeouts.fast(),
    .retry_policy = httpx.RetryPolicy.noRetry(),
    .follow_redirects = false,
    .httpVersion = .http2,
    .pool_max_connections = 64,
    .pool_max_per_host = 16,
    .user_agent = "my-app/2.0",
};

var client = httpx.Client.init(allocator, io, cfg);
defer client.deinit();
```

### Configuration (`ClientConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base_url` | `?[]const u8` | `null` | Base URL prepended to all requests. |
| `timeouts` | `Timeouts` | `{}` | Connection and read/write timeouts. |
| `retry_policy` | `RetryPolicy` | `{}` | Configuration for automatic retries. |
| `redirect_policy` | `RedirectPolicy` | `{}` | Configuration for handling redirects. |
| `default_headers` | `?[]const [2][]const u8` | `null` | Headers added to every request. |
| `user_agent` | `[]const u8` | `"httpx.zig/0.2.0"` | User-Agent header value. |
| `max_response_size` | `usize` | `100MB` | Maximum allowed response body size. |
| `max_request_size` | `usize` | `10MB` | Maximum allowed outgoing request body size. Raises `RequestTooLarge` error when exceeded (excluded from retry logic). |
| `follow_redirects` | `bool` | `true` | Whether to automatically follow redirects. |
| `verify_ssl` | `bool` | `true` | Whether to verify SSL certificates. |
| `httpVersion` | `?HttpVersion` | `null` | Preferred HTTP version (`.auto`, `.http10`, `.http11`, `.http2`, `.http3`). |
| `http10` | `bool` | `true` | Fast toggle to enable HTTP/1.0 protocol. |
| `http11` | `bool` | `true` | Fast toggle to enable HTTP/1.1 protocol. |
| `http2` | `bool` | `false` | Fast toggle to use HTTP/2 as default protocol. |
| `http3` | `bool` | `false` | Fast toggle to use HTTP/3 as default protocol. |
| `cookies` | `bool` | `true` | Enable cookie jar handling. |
| `http2_settings` | `Http2Settings` | `{}` | HTTP/2 SETTINGS values sent during connection setup (`header_table_size`, `max_frame_size`, etc.). |
| `http3_settings` | `Http3Settings` | `{}` | HTTP/3/QPACK settings sent on the control stream (`max_field_section_size`, `qpack_max_table_capacity`, `qpack_blocked_streams`, etc.). |
| `keep_alive` | `bool` | `true` | Reuse TCP connections when possible. |
| `allow_push` | `bool` | `true` | Accept HTTP/2 server push (PUSH_PROMISE) from the server. |
| `pool_max_connections` | `u32` | `20` | Maximum connections in the pool. |
| `pool_max_per_host` | `u32` | `5` | Maximum connections to a single host. |
| `proxy` | `?Proxy` | `null` | Optional forward proxy configuration for client requests. Use `.kind = .socks5h` for SOCKS5h tunneling; the default kind is HTTP. |
| `unix_socket_path` | `?[]const u8` | `null` | Optional Unix Domain Socket (AF_UNIX) path for client connections. |
| `log_fn` | `?LogFn` | `null` | Optional logging callback. When set, `Client.log()` delegates formatted messages to this function. Leave unset to disable client-side logging. |

If you do not set a field, the implicit default value is used. Builder helpers only override the fields you call.

### Timeouts (`Timeouts`)

Client timeouts are configured through `ClientConfig.timeouts` or `ClientConfig.withTimeouts(...)`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `connect_ms` | `u64` | `30_000` | Maximum time to establish a TCP connection. |
| `read_ms` | `u64` | `30_000` | Maximum time to wait for response data on the socket. |
| `write_ms` | `u64` | `30_000` | Maximum time to wait while sending request data. |
| `keep_alive_ms` | `u64` | `60_000` | Reserved keep-alive timeout budget. |
| `idle_ms` | `u64` | `120_000` | Reserved idle timeout budget. |
| `request_ms` | `u64` | `0` | Reserved total request budget (`0` = disabled). |

Helpers:

- `Timeouts.uniform(ms)` — set connect/read/write uniformly
- `Timeouts.fast()` — 5 second connect/read/write defaults
- `Timeouts.slow()` — 120 second connect/read/write defaults
- `Timeouts.none()` — disable socket timeouts

Per-request `RequestOptions.timeout_ms` overrides all three active phases (`connect_ms`, `read_ms`, `write_ms`) for that request.

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var client = httpx.Client.init(allocator, io, .{
    .timeouts = httpx.Timeouts.fast(),
});
defer client.deinit();

const res = try client.get("https://example.com/slow", .{ .timeout_ms = 2_000 });
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
| `isClientError() bool` | Returns true if status code is in 400..499 range. |
| `isServerError() bool` | Returns true if status code is in 500..599 range. |

### Methods & Convenience Aliases

| Method | Description |
|--------|-------------|
| `fetch(url, options)` | **Primary unified HTTP request operation** |
| `get(options)` | HTTP GET request |
| `post(options)` | HTTP POST request |
| `put(options)` | HTTP PUT request |
| `delete(options)` | HTTP DELETE request |
| `del(options)` | Alias for HTTP DELETE request |
| `patch(options)` | HTTP PATCH request |
| `head(options)` | HTTP HEAD request |
| `trace(options)` | HTTP TRACE request |
| `connect(options)` | HTTP CONNECT request |
| `options(options)` | HTTP OPTIONS request |
| `opts(options)` | Alias for HTTP OPTIONS request |
| `request(options)` | Generic request (method set via `options.method`) |
| `post(url, options)` | HTTP POST request |
| `put(url, options)` | HTTP PUT request |
| `delete(url, options)` | HTTP DELETE request |
| `del(url, options)` | Alias for HTTP DELETE request |
| `patch(url, options)` | HTTP PATCH request |
| `head(url, options)` | HTTP HEAD request |
| `trace(url, options)` | HTTP TRACE request |
| `connect(url, options)` | HTTP CONNECT request |
| `options(url, options)` | HTTP OPTIONS request |
| `opts(url, options)` | Alias for HTTP OPTIONS request |
| `send(method, url, options)` | Alias for generic request |
| `getJson(T, url, parse_opts)` | Zero-copy JSON GET, returns `JsonBorrowedResult(T)` |
| `getJsonBorrowed(T, url)` | JSON GET with default parse options |
| `postJsonAndParse(T, url, body, parse_opts)` | POST JSON and parse response |
| `postJsonBorrowed(T, url, body)` | POST JSON with default parse options |
| `putJson(T, url, body, parse_opts)` | PUT JSON and parse response |
| `patchJson(T, url, body, parse_opts)` | PATCH JSON and parse response |
| `deleteJson(T, url, parse_opts)` | DELETE and parse JSON response |
| `addInterceptor(interceptor)` | Add request/response interceptor |
| `cleanupIdleConnections()` | Evict idle/exhausted pooled connections |
| `poolStats()` | Snapshot total/active/idle pool counts |
| `hostPoolConnectionCount(host, port)` | Count pooled connections for one host:port |
| `log(level, format, args)` | Log a formatted message. If `config.log_fn` is set, delegates to it. |

### Cookie Jar API

The client keeps an in-memory cookie jar and automatically:

- Adds a `Cookie` header to outgoing requests (domain-filtered per RFC 6265).
- Stores `Set-Cookie` values from incoming responses with domain association.
- Cookies with a `Domain` attribute are only sent to matching hosts.
- Cookies without a `Domain` attribute are sent to all hosts.

| Method | Description |
|--------|-------------|
| `setCookie(name, value)` | Add or replace a cookie in the jar |
| `getCookie(name)` | Read a cookie value |
| `removeCookie(name)` | Remove one cookie |
| `clearCookies()` | Remove all cookies |
| `hasCookie(name)` | Check whether a cookie exists |
| `cookieCount()` | Get total cookie count |

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
    .timeout_ms = 30000, // 30 seconds
});
defer timeout_response.deinit();
```

### Client Usage Recipes

For complete copy/paste demos, see these example pages:

- [Simple Get](/examples/simple-get)
- [Simple Get Deserialize](/examples/simple-get-deserialize)
- [JSON API](/examples/json-api-example) - getJson, postJsonAndParse, Response.json, server ctx.jsonBody + ctx.json
- [Post JSON](/examples/post-json)
- [Custom Headers](/examples/custom-headers)
- [Concurrent Requests](/examples/concurrent-requests)
- [Connection Pool](/examples/connection-pool)
- [Interceptors](/examples/interceptors)
- [Cookies Demo](/examples/cookies-demo)
- [HTTP Auth Helpers](/examples/http-auth-helpers)
- [Simplified API Aliases](/examples/simplified-api-aliases)

### Request Options (`RequestOptions`)

Per-request overrides for configuration.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `headers` | `?[]const [2][]const u8` | `null` | Additional headers for this request. |
| `query_params` | `?[]const [2][]const u8` | `null` | Percent-encoded query params appended to the request URL. |
| `body` | `?[]const u8` | `null` | Raw request body. |
| `json` | `?[]const u8` | `null` | JSON string body (sets Content-Type). |
| `form_fields` | `?[]const [2][]const u8` | `null` | Form fields encoded as `application/x-www-form-urlencoded`. |
| `bearer_token` | `?[]const u8` | `null` | Sets `Authorization: Bearer <token>`. |
| `basic_auth` | `?BasicAuth` | `null` | Sets `Authorization: Basic ...` using username/password credentials. |
| `timeout_ms` | `?u64` | `null` | Request-specific uniform timeout override across connect, read, and write phases. |
| `connect_timeout_ms` | `?u64` | `null` | Request-specific connect phase timeout override (ms). |
| `read_timeout_ms` | `?u64` | `null` | Request-specific read phase timeout override (ms). |
| `write_timeout_ms` | `?u64` | `null` | Request-specific write phase timeout override (ms). |
| `timeouts` | `?Timeouts` | `null` | Explicit request-specific `Timeouts` struct override. |
| `follow_redirects` | `?bool` | `null` | Override client redirect setting. |
| `version` | `?Version` | `null` | Force a request over a specific protocol runtime (`.HTTP_1_1`, `.HTTP_2`, `.HTTP_3`). |
| `proxy` | `?Proxy` | `null` | Per-request forward proxy override. |
| `verify_ssl` | `?bool` | `null` | Per-request SSL verification toggle override. |
| `keep_alive` | `?bool` | `null` | Per-request connection pool reuse toggle override. |
| `unix_socket_path` | `?[]const u8` | `null` | Per-request Unix Domain Socket path routing override. |

Unset request-option fields stay `null`, meaning client-level defaults are used implicitly.

When multiple body-style fields are provided, precedence is:

1. `body`
2. `json`
3. `form_fields`

Authentication helper precedence when both are set directly in a literal:

1. `basic_auth`
2. `bearer_token` (applied last)

Request options are configured directly using `RequestOptions` struct literals:

```zig
var res = try client.get("/users", .{ .headers = &.{.{ "Accept", "application/json" }, .{ "Authorization", "Bearer demo-token" }},
    .query_params = &.{.{ "page", "1" }},
    .timeout_ms = 10_000,
    .httpVersion = .http2,
    .follow_redirects = true,
});
defer res.deinit();
```

### Multipart File Uploads

Use `multipart_fields` and `multipart_files` to send `multipart/form-data` bodies.
The client automatically assembles the body and sets the `Content-Type` header.

```zig
const fields = [_]httpx.MultipartField{
    .{ .name = "user",  .value = "alice" },
    .{ .name = "part",  .value = "1" },
};
const files = [_]httpx.MultipartFile{
    .{ .name = "file", .filename = "data.bin", .data = chunk_slice },
};

var resp = try client.post("https://example.com/upload", .{ .multipart_fields = &fields,
    .multipart_files = &files,
});
defer resp.deinit();
```

> **Windows — buffer limit (issue #26)**
>
> On Windows the Winsock kernel send buffer is typically 8–64 KB. When sending
> large multipart data as a single body, `winsock.send()` may stall.
>
> httpx.zig 0.1.8+ automatically caps each send call to 64 KB, so most uploads
> now work without application changes. For extra safety—especially for payloads
> larger than a few hundred KB—keep each `MultipartFile.data` slice under
> `httpx.MultipartMaxChunk` (64 KB) and issue one request per slice.
> See the [Multipart Guide](../guide/multipart.md#large-file-uploads--windows-compatibility)
> for a complete resumable upload example.


## Response

The `Response` struct contains the server's response.

```zig
pub const Response = struct {
    version: Version,
    status: Status,
    headers: Headers,
    body: ?[]const u8,

    pub fn deinit(self: *Response) void
    pub fn ok(self: *const Response) bool
    pub fn isRedirect(self: *const Response) bool
    pub fn isError(self: *const Response) bool
    pub fn text(self: *const Response) ?[]const u8
    pub fn json(self: *const Response, comptime T: type, options: std.json.ParseOptions) !std.json.Parsed(T)
    pub fn jsonLeaky(self: *const Response, comptime T: type, options: std.json.ParseOptions) !T
    pub fn location(self: *const Response) ?[]const u8
    pub fn contentType(self: *const Response) ?[]const u8
    pub fn contentLength(self: *const Response) ?u64
    pub fn isChunked(self: *const Response) bool
    pub fn header(self: *const Response, name: []const u8) ?[]const u8
};
```

### Response Methods

| Method | Description |
|--------|-------------|
| `deinit()` | Free response resources |
| `header(name)` | Get header value by name |
| `ok()` | Status 200-299 |
| `isRedirect()` | Status 300-399 |
| `isError()` | Status 400-599 |
| `text()` | Get response body text |
| `json(T, options)` | Parse response body as JSON, returning `std.json.Parsed(T)` |
| `jsonLeaky(T, options)` | Parse response body as JSON directly into type `T` (leaky) |
| `jsonBorrowed(T, parse_opts)` | Zero-copy JSON parsing returning `JsonBorrowedResult(T)` |
| `jsonValue(parse_opts)` | Parse body as dynamic `std.json.Value` with `ParsedJson` |
| `isJson()` | Returns true if body exists and Content-Type is JSON |

## Interceptors

Interceptors allow you to modify requests before they are sent or responses before they are returned.

### Structure

```zig
pub const RequestInterceptor = *const fn (*Request, ?*anyopaque) anyerror!void;
pub const ResponseInterceptor = *const fn (*Response, ?*anyopaque) anyerror!void;

pub const Interceptor = struct {
    request_fn: ?RequestInterceptor = null,
    response_fn: ?ResponseInterceptor = null,
    context: ?*anyopaque = null,
};
```

Both `request_fn` and `response_fn` are optional. You can register only one callback or both.

### Usage

```zig
// Logging interceptor
fn logRequest(request: *httpx.Request, _: ?*anyopaque) !void {
    std.debug.print("Request: {s} {s}\n", .{@tagName(request.method), request.uri.path});
}

fn logResponse(response: *httpx.Response, _: ?*anyopaque) !void {
    std.debug.print("Response: {d}\n", .{response.status.code});
}

// Add interceptor
try client.addInterceptor(.{
    .request_fn = logRequest,
    .response_fn = logResponse,
});

// Authentication interceptor with context
const AuthContext = struct {
    token: []const u8,
};

fn addAuth(request: *httpx.Request, ctx: ?*anyopaque) !void {
    if (ctx) |c| {
        const auth: *AuthContext = @ptrCast(@alignCast(c));
        try request.setHeader("Authorization", auth.token);
    }
}

var auth_ctx = AuthContext{ .token = "Bearer secret123" };
try client.addInterceptor(.{
    .request_fn = addAuth,
    .context = &auth_ctx,
});
```

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

var h = try httpx.request(.{
    .method = .GET,
    .url = "https://example.com/health",
});
defer h.deinit();
```

Top-level request functions:

| Function | Description |
|----------|-------------|
| `httpx.get(options)` | HTTP GET |
| `httpx.post(options)` | HTTP POST |
| `httpx.put(options)` | HTTP PUT |
| `httpx.patch(options)` | HTTP PATCH |
| `httpx.delete(options)` | HTTP DELETE |
| `httpx.head(options)` | HTTP HEAD |
| `httpx.options(options)` | HTTP OPTIONS |
| `httpx.trace(options)` | HTTP TRACE |
| `httpx.connect(options)` | HTTP CONNECT |
| `httpx.request(options)` | General HTTP request |
| `httpx.getAll(&urls)` | Concurrent GET requests |
| `httpx.requestAll(&requests)` | Concurrent custom requests |

## See Also

- [Protocol API](protocol.md) - HTTP/2, HTTP/3, HPACK, QPACK
- [Connection Pool](pool.md) - Connection pooling
- [Concurrency](concurrency.md) - Parallel requests
- [Client Guide](/guide/client-basics) - Usage guide
