# Client API

The `httpx.zig` client provides a high-level HTTP client for making requests with support for HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 protocols. HTTPS is supported via Zig's standard library TLS (`std.crypto.tls`).

## Protocol Support

| Protocol | Status | Transport | Notes |
|----------|--------|-----------|-------|
| HTTP/1.0 | ✅ Full | TCP | Legacy support |
| HTTP/1.1 | ✅ Full | TCP/TLS | Default protocol |
| HTTP/2 | ⚠️ Partial | TCP/TLS | Protocol primitives available; high-level client currently uses HTTP/1.1 |
| HTTP/3 | ⚠️ Partial | QUIC/UDP | Protocol primitives available; high-level client currently uses HTTP/1.1 |

The protocol module provides HTTP/2 and HTTP/3 building blocks (HPACK/QPACK, framing, and transport primitives). See [Protocol API](protocol.md) for details.

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
```

### Configuration (`ClientConfig`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base_url` | `?[]const u8` | `null` | Base URL prepended to all requests. |
| `timeouts` | `Timeouts` | `{}` | Connection and read/write timeouts. |
| `retry_policy` | `RetryPolicy` | `{}` | Configuration for automatic retries. |
| `redirect_policy` | `RedirectPolicy` | `{}` | Configuration for handling redirects. |
| `default_headers` | `?[]const [2][]const u8` | `null` | Headers added to every request. |
| `user_agent` | `[]const u8` | `"httpx.zig/0.0.3"` | User-Agent header value. |
| `max_response_size` | `usize` | `100MB` | Maximum allowed response body size. |
| `follow_redirects` | `bool` | `true` | Whether to automatically follow redirects. |
| `verify_ssl` | `bool` | `true` | Whether to verify SSL certificates. |
| `http2_enabled` | `bool` | `false` | Enable HTTP/2 protocol (requires ALPN negotiation). See [HPACK](protocol.md#hpack-header-compression) for header compression. |
| `http3_enabled` | `bool` | `false` | Enable HTTP/3 protocol (requires QUIC transport). See [QPACK](protocol.md#qpack-header-compression) and [QUIC](protocol.md#quic-transport). |
| `pool_max_connections` | `u32` | `20` | Maximum connections in the pool. |
| `pool_max_per_host` | `u32` | `5` | Maximum connections to a single host. |

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

#### Convenience Methods

| Method | Description |
|--------|-------------|
| `get(url, options)` | HTTP GET request |
| `fetch(url, options)` | Alias for GET request |
| `post(url, options)` | HTTP POST request |
| `put(url, options)` | HTTP PUT request |
| `delete(url, options)` | HTTP DELETE request |
| `patch(url, options)` | HTTP PATCH request |
| `head(url, options)` | HTTP HEAD request |
| `httpOptions(url, options)` | HTTP OPTIONS request |
| `options(url, options)` | Alias for HTTP OPTIONS request |
| `send(method, url, options)` | Alias for generic request |
| `addInterceptor(interceptor)` | Add request/response interceptor |

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

// With timeout
const timeout_response = try client.get("https://slow-api.com/data", .{
    .timeout_ms = 30000, // 30 seconds
});
defer timeout_response.deinit();
```

### Request Options (`RequestOptions`)

Per-request overrides for configuration.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `headers` | `?[]const [2][]const u8` | `null` | Additional headers for this request. |
| `body` | `?[]const u8` | `null` | Raw request body. |
| `json` | `?[]const u8` | `null` | JSON string body (sets Content-Type). |
| `timeout_ms` | `?u64` | `null` | Request-specific timeout. |
| `follow_redirects` | `?bool` | `null` | Override client redirect setting. |

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
    pub fn json(self: *const Response, comptime T: type) !T
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
| `json(T)` | Parse response body as JSON |

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
var a = try httpx.fetch(allocator, "https://example.com");
defer a.deinit();

var b = try httpx.send(allocator, .GET, "https://example.com/health", .{});
defer b.deinit();

var c = try httpx.post(allocator, "https://example.com/items", .{ .json = "{\"name\":\"demo\"}" });
defer c.deinit();
```

## See Also

- [Protocol API](protocol.md) - HTTP/2, HTTP/3, HPACK, QPACK
- [Connection Pool](pool.md) - Connection pooling
- [Concurrency](concurrency.md) - Parallel requests
- [Client Guide](/guide/client-basics) - Usage guide
