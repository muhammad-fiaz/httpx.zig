# Client API

The `httpx.zig` client provides a high-level HTTP client for making requests over HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3. HTTPS is supported via a fully custom TLS 1.2/1.3 implementation built on `std.crypto` primitives (AES-GCM, ChaCha20-Poly1305, X25519, P-256, P-384, HKDF, SHA-256/384/512) with ALPN negotiation for HTTP/2 and HTTP/3.

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
const httpx = @import("httpx");

// Initialize with default configuration
var client = httpx.Client.init(allocator);
defer client.deinit();

// Initialize with custom configuration
var client = httpx.Client.initWithConfig(allocator, .{
    .base_url = "https://api.example.com",
    .user_agent = "my-app/1.0",
});
defer client.deinit();

// Initialize with default config + base URL helper
var api = httpx.Client.initForBaseUrl(allocator, "https://api.example.com");
defer api.deinit();
```

For optional explicit customization, `ClientConfig` supports chainable helpers:

```zig
const cfg = httpx.ClientConfig.defaults()
    .withBaseUrl("https://api.example.com")
    .withTimeouts(httpx.Timeouts.fast())
    .withRetryPolicy(httpx.RetryPolicy.noRetry())
    .withFollowRedirects(false)
    .withHttp2Settings(.{ .max_concurrent_streams = 100 })
    .withHttp3Settings(.{ .enable_datagrams = true })
    .withPoolLimits(64, 16)
    .withUserAgent("my-app/2.0");

var client = httpx.Client.initWithConfig(allocator, cfg);
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
| `user_agent` | `[]const u8` | `"httpx.zig/0.1.4"` | User-Agent header value. |
| `max_response_size` | `usize` | `100MB` | Maximum allowed response body size. |
| `follow_redirects` | `bool` | `true` | Whether to automatically follow redirects. |
| `verify_ssl` | `bool` | `true` | Whether to verify SSL certificates. |
| `http2_enabled` | `bool` | `false` | Enable high-level HTTP/2 execution path for client requests. |
| `http3_enabled` | `bool` | `false` | Enable high-level HTTP/3 execution path over UDP/QUIC stream framing. |
| `http2_settings` | `Http2Settings` | `{}` | HTTP/2 SETTINGS values sent during connection setup (`header_table_size`, `max_frame_size`, etc.). |
| `http3_settings` | `Http3Settings` | `{}` | HTTP/3/QPACK settings sent on the control stream (`max_field_section_size`, `qpack_max_table_capacity`, `qpack_blocked_streams`, etc.). |
| `keep_alive` | `bool` | `true` | Reuse TCP connections when possible. |
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
var client = httpx.Client.initWithConfig(allocator, .{
    .timeouts = httpx.Timeouts.fast(),
});
defer client.deinit();

const res = try client.get("https://example.com/slow", .{ .timeout_ms = 2_000 });
defer res.deinit();
```

### Config Helper Methods

| Helper | Description |
|--------|-------------|
| `ClientConfig.defaults()` | Returns default config (`.{}`). |
| `ClientConfig.forBaseUrl(url)` | Returns defaults with `base_url` set. |
| `withBaseUrl(url_or_null)` | Override base URL on a copy. |
| `withTimeouts(timeouts)` | Override timeout bundle (`Timeouts`). |
| `withRetryPolicy(policy)` | Override retry behavior (`RetryPolicy`). |
| `withRedirectPolicy(policy)` | Override redirect behavior (`RedirectPolicy`). |
| `withDefaultHeaders(headers_or_null)` | Override default client headers. |
| `withUserAgent(ua)` | Override `User-Agent` string. |
| `withFollowRedirects(enabled)` | Override client-level redirect following. |
| `withProtocols(http2, http3)` | Override protocol runtime toggles. |
| `withHttp2Settings(settings)` | Override HTTP/2 SETTINGS values. |
| `withHttp3Settings(settings)` | Override HTTP/3 SETTINGS values. |
| `withSslVerification(enabled)` | Toggle TLS certificate verification. |
| `withKeepAlive(enabled)` | Toggle keep-alive connection reuse. |
| `withMaxResponseSize(bytes)` | Override maximum response body size. |
| `withPoolLimits(max_connections, max_per_host)` | Override pool sizing limits. |
| `withProxy(proxy_or_null)` | Configure or clear a forward proxy. Set `.kind = .socks5h` for SOCKS5h tunneling. |
| `withUnixSocket(path_or_null)` | Configure or clear a Unix Domain Socket (AF_UNIX) connection path. |
| `withLogFn(log_fn)` | Set a custom logging callback for client-side log output. |

### Client Initialization Helpers

| Helper | Description |
|--------|-------------|
| `Client.init(allocator)` | Default client config. |
| `Client.initWithConfig(allocator, cfg)` | Explicit config. |
| `Client.initForBaseUrl(allocator, url)` | Default config with base URL set. |

### Methods

#### `request`

Makes a generic HTTP request.

```zig
pub fn request(self: *Self, method: Method, url: []const u8, options: RequestOptions) !Response
```

#### `send` (alias)

Alias for `request` with shorter naming.

```zig
pub fn send(self: *Self, method: Method, url: []const u8, options: RequestOptions) !Response
```

#### Short aliases

```zig
pub fn del(self: *Self, url: []const u8, options: RequestOptions) !Response
pub fn opts(self: *Self, url: []const u8, options: RequestOptions) !Response
```

#### Convenience Methods

| Method | Description |
|--------|-------------|
| `get(url, options)` | HTTP GET request |
| `fetch(url, options)` | Alias for GET request |
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
| `addInterceptor(interceptor)` | Add request/response interceptor |
| `cleanupIdleConnections()` | Evict idle/exhausted pooled connections |
| `poolStats()` | Snapshot total/active/idle pool counts |
| `hostPoolConnectionCount(host, port)` | Count pooled connections for one host:port |
| `log(level, format, args)` | Log a formatted message. If `config.log_fn` is set, delegates to it. |

### Cookie Jar API

The client keeps an in-memory cookie jar and automatically:

- Adds a `Cookie` header to outgoing requests.
- Stores `Set-Cookie` values from incoming responses.

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
const httpx = @import("httpx");

var client = httpx.Client.init(allocator);
defer client.deinit();

// Simple GET
const response = try client.get("https://api.example.com/users", .{});
defer response.deinit();
std.debug.print("Status: {d}\n", .{response.status.code});
std.debug.print("Body: {s}\n", .{response.text() orelse ""});

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
const bearer_opts = httpx.RequestOptions.defaults()
    .withBearerToken("token123")
    .withHeaders(&.{.{ "Accept", "application/json" }});

const bearer_response = try client.get("https://api.example.com/protected", bearer_opts);
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
| `timeout_ms` | `?u64` | `null` | Request-specific timeout override for connect, read, and write phases. |
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

Optional builder helpers are available for concise per-request setup when you want explicit overrides:

```zig
const opts = httpx.RequestOptions.defaults()
    .withHeaders(&.{ .{ "Accept", "application/json" } })
    .withBearerToken("demo-token")
    .withQueryParams(&.{ .{ "page", "1" } })
    .withTimeoutMs(10_000)
    .withHttp2()
    .withFollowRedirects(true)
    .withSslVerification(false)
    .withKeepAlive(false);

var res = try client.get("/users", opts);
defer res.deinit();
```

Available helpers:

- `RequestOptions.defaults()`
- `withHeaders(headers)`
- `withQueryParams(params)`
- `withBody(body)`
- `withJson(json)`
- `withFormUrlEncoded(fields)`
- `withBearerToken(token)`
- `withBasicAuth(username, password)`
- `withTimeoutMs(ms)`
- `withFollowRedirects(bool)`
- `withVersion(version)`
- `withHttp2()`
- `withHttp3()`
- `withProxy(proxy)`
- `withSslVerification(bool)`
- `withKeepAlive(bool)`
- `withUnixSocket(path)`

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

## Simplified Top-Level Aliases

The root module also exposes simple aliases for common client usage:

```zig
var a = try httpx.fetch("https://example.com");
defer a.deinit();

var b = try httpx.send(.GET, "https://example.com/health", .{});
defer b.deinit();

var c = try httpx.post("https://example.com/items", .{ .json = "{\"name\":\"demo\"}" });
defer c.deinit();

var d = try httpx.delete("https://example.com/items/42", .{});
defer d.deinit();

var e = try httpx.opts("https://example.com/items", .{});
defer e.deinit();

var f = try httpx.trace("https://example.com/trace", .{});
defer f.deinit();

var g = try httpx.connect("https://example.com/tunnel", .{});
defer g.deinit();

// Optional explicit allocator override
var h = try httpx.sendWithAllocator(allocator, .GET, "https://example.com/health", .{ .timeout_ms = 10_000 });
defer h.deinit();
```

## See Also

- [Protocol API](protocol.md) - HTTP/2, HTTP/3, HPACK, QPACK
- [Connection Pool](pool.md) - Connection pooling
- [Concurrency](concurrency.md) - Parallel requests
- [Client Guide](/guide/client-basics) - Usage guide
