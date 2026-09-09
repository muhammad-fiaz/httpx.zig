# Basic Requests

The `httpx.zig` client supports all standard HTTP methods and provides convenient wrappers for common operations.

## Creating a Client

For simple usage, create a client with the default configuration:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();
```

For more control, use `ClientConfig`.
Defaults remain implicit unless you explicitly override fields:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
const config: httpx.ClientConfig = .{
    .timeoutMs = 10_000,
    .followRedirects = true,
    .maxRedirects = 5,
    .maxRetries = 3,
    .retryDelayMs = 500,
    .http2 = true,
    .http3 = false,
    .maxResponseSize = 32 * 1024 * 1024,
    .pool = .{ .maxConnections = 64, .maxPerHost = 16 },
};

var client = httpx.Client.init(allocator, io, config);
defer client.deinit();
```

## Protocol Selection

- Set `.http2 = true` to use the high-level HTTP/2 request path.
- Set `.http3 = true` to use the high-level HTTP/3 request path over UDP + QUIC/HTTP3/QPACK primitives.

## Making Requests

### Primary API: `fetch`

`client.fetch(url, options)` is the primary unified HTTP operation. It supports all HTTP methods, strongly typed Zig struct serialization (via `std.json`), headers, and query parameters:

```zig
// Simple GET
var res = try client.fetch("https://httpbun.com/get", .{});
defer res.deinit();
std.debug.print("Status: {d}, Body: {s}\n", .{ res.status, res.bytes() });

// POST with typed JSON struct
const CreateUser = struct { name: []const u8, email: []const u8 };
const User = struct { id: u64, name: []const u8, email: []const u8 };

var post_res = try client.fetch("https://httpbun.com/post", .{
    .method = .POST,
    .json = CreateUser{ .name = "Alice", .email = "alice@example.com" },
});
defer post_res.deinit();

// Typed JSON response decoding
const user = try post_res.json(User);
std.debug.print("User: {s} ({s})\n", .{ user.name, user.email });
```

### GET with explicit timeout and error handling

For external endpoints, you can specify per-request timeouts:

```zig
var response = client.fetch("https://httpbun.com/get", .{
    .timeoutMs = 10_000,
}) catch |err| {
    std.debug.print("request failed: {s}\n", .{@errorName(err)});
    return;
};
defer response.deinit();
```

### Verb Shortcuts

For quick requests, convenience methods like `.get()` and `.post()` are also available:

```zig
var res = try client.get("https://httpbun.com/get", .{});
defer res.deinit();

var post = try client.post("https://httpbun.com/post", .{ .json = .{ .name = "Alice", .role = "admin" },
});
defer post.deinit();
```

### Other Methods

```zig
// PUT
_ = try client.put("/users/1", .{ .json = updated_json });

// DELETE
_ = try client.delete("/users/1", .{});

// Short alias for DELETE
// HEAD
const head_res = try client.head("/large-file", .{});

// OPTIONS
const opt_res = try client.options("/users", .{});

_ = head_res;
_ = opt_res;
```

## Cookie Jar

Pass cookies per request with the `cookie` option, or keep a standalone
`httpx.CookieJar` across requests (domain-aware per RFC 6265):

```zig
var jar = httpx.CookieJar.init(allocator);
defer jar.deinit();

if (loginRes.header("Set-Cookie")) |sc| {
    jar.setFromHeader(sc, "example.com");
}

var cookieBuf: [512]u8 = undefined;
const cookieHeader = jar.cookieHeader("example.com", "/profile", true, &cookieBuf);
var profileRes = try client.get("https://example.com/profile", .{ .cookie = cookieHeader });
defer profileRes.deinit();
```

For top-level convenience in smaller programs, use functions from the root module:

```zig
var res = try httpx.get("https://httpbun.com/get", .{});
defer res.deinit();

var custom = try httpx.request("https://httpbun.com/headers", .{
    .method = .GET,
    .timeoutMs = 10_000,
});
defer custom.deinit();
```

## Auth Helpers

Use built-in request auth helpers instead of manually building `Authorization` headers:

```zig
var bearer_res = try client.get("/protected", .{
    .bearerAuth = "demo-token",
    .headers = &.{.{ .name = "Accept", .value = "application/json" }},
});
defer bearer_res.deinit();

var basic_res = try client.get("/admin", .{
    .basicAuth = "demo:pass",
    .headers = &.{.{ .name = "Accept", .value = "application/json" }},
});
defer basic_res.deinit();
```

## Request Options

The second argument to request methods is `RequestOptions`:

```zig
pub const RequestOptions = struct {
    url: []const u8,
    method: ?httpx.Method = null,       // Explicit method for generic request
    headers: []const httpx.Header = &.{}, // Custom headers
    query: []const httpx.Header = &.{},   // Optional URL query params
    body: ?[]const u8 = null,           // Raw body
    json: ?[]const u8 = null,           // JSON body
    form: ?[]const u8 = null,           // x-www-form-urlencoded body
    text: ?[]const u8 = null,           // Plain-text body
    bearerAuth: ?[]const u8 = null,     // Authorization: Bearer <token>
    basicAuth: ?[]const u8 = null,      // Authorization: Basic ...
    timeoutMs: ?u64 = null,             // Request-specific timeout
    followRedirects: ?bool = null,      // Override redirect policy
    maxRedirects: ?u8 = null,           // Override redirect limit
    httpVersion: ?httpx.HttpVersion = null, // Optional per-request protocol override
    proxy: ?[]const u8 = null,          // Per-request proxy URL override
    tls: ?TlsOptions = null,            // Per-request TLS override
};
```

All fields except `url` are optional customizations. Passing `. {}` keeps defaults implicit.

## Proxy Configuration

Configure forward proxies when initializing the client:

```zig
    const io = std.Io.Threaded.global_single_threaded.io();
const config: httpx.ClientConfig = .{
    .proxy = "http://127.0.0.1:8080",
};

var client = httpx.Client.init(allocator, io, config);
defer client.deinit();
```

For SOCKS5h (remote DNS), use a `socks5h://` URL:

```zig
const socks_config: httpx.ClientConfig = .{
    .proxy = "socks5h://127.0.0.1:1080",
};
```

## Response Handling

The `Response` object provides helpers to access data:

```zig
// Check status
if (response.isSuccess()) { ... }

// Get headers
if (response.header("Content-Type")) |ct| { ... }

// Parse JSON response into a struct (ignores unknown fields)
const MyStruct = struct { id: u32, name: []const u8 };
const data = try response.json(MyStruct);

// Or parse with an explicit allocator (returns std.json.Parsed(T))
const parsed = try response.jsonAlloc(MyStruct, allocator);
defer parsed.deinit();
```
