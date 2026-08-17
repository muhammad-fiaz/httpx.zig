# Basic Requests

The `httpx.zig` client supports all standard HTTP methods and provides convenient wrappers for common operations.

## Creating a Client

For simple usage, create a client with the default configuration:

```zig
var client = httpx.Client.init(allocator);
defer client.deinit();
```

For more control, use `ClientConfig`.
Defaults remain implicit unless you explicitly override fields:

```zig
const config = httpx.ClientConfig.defaults()
    .withBaseUrl("https://api.github.com")
    .withUserAgent("MyApp/1.0")
    .withTimeouts(.{
        .connect_ms = 5000,
        .read_ms = 10000,
    })
    .withProtocols(true, false)
    .withHttp2Settings(.{ .max_concurrent_streams = 100 })
    .withHttp3Settings(.{ .qpack_blocked_streams = 16 })
    .withSslVerification(true)
    .withKeepAlive(true)
    .withMaxResponseSize(32 * 1024 * 1024)
    .withPoolLimits(64, 16);

var client = httpx.Client.initWithConfig(allocator, config);
defer client.deinit();

// Equivalent shortcut when you only need a base URL:
var api = httpx.Client.initForBaseUrl(allocator, "https://api.github.com");
defer api.deinit();
```

## Protocol Selection

- Set `.http2_enabled = true` to use the high-level HTTP/2 request path.
- Set `.http3_enabled = true` to use the high-level HTTP/3 request path over UDP + QUIC/HTTP3/QPACK primitives.

## Making Requests

You can use either the full client methods (`request`, `get`, `post`, etc.) or simplified aliases (`send`, `fetch`, `options`).

### GET

```zig
const response = try client.get("https://httpbun.com/get", .{});
defer response.deinit();

if (response.status.isSuccess()) {
    std.debug.print("Body: {s}\n", .{response.body.?});
}
```

### GET with explicit timeout and error handling

For external endpoints, prefer an explicit per-request timeout and `catch` handler so errors are visible immediately:

```zig
var response = client.get("https://httpbun.com/get", .{
    .timeout_ms = 10_000,
}) catch |err| {
    std.debug.print("request failed: {s}\n", .{@errorName(err)});
    return;
};
defer response.deinit();
```

Optional: the same request using `RequestOptions` builder helpers:

```zig
const opts = httpx.RequestOptions.defaults()
    .withTimeoutMs(10_000)
    .withHttp2()
    .withFollowRedirects(true);

var response = try client.get("https://httpbun.com/get", opts);
defer response.deinit();
```

### POST JSON

You can easily send JSON using the `.json` option, which automatically sets the `Content-Type` header to `application/json`.

```zig
const body = "{\"name\": \"Alice\", \"role\": \"admin\"}";
const response = try client.post(
    "https://httpbun.com/post",
    .{ .json = body },
);
defer response.deinit();
```

### Other Methods

```zig
// PUT
_ = try client.put("/users/1", .{ .json = updated_json });

// DELETE
_ = try client.delete("/users/1", .{});

// Short alias for DELETE
_ = try client.del("/users/1", .{});

// HEAD
const head_res = try client.head("/large-file", .{});

// Alias helpers
const fetch_res = try client.fetch("/users", .{});
const opt_res = try client.options("/users", .{});
const opt_short = try client.opts("/users", .{});

_ = fetch_res;
_ = opt_res;
_ = opt_short;
```

## Cookie Jar

The client automatically stores `Set-Cookie` values and sends a `Cookie` header on subsequent requests. Cookies are domain-aware per RFC 6265 — cookies with a `Domain` attribute are only sent to matching hosts.

```zig
try client.setCookie("session", "abc123");
if (client.getCookie("session")) |session| {
    std.debug.print("session={s}\n", .{session});
}
_ = client.removeCookie("session");
client.clearCookies();
```

For top-level convenience in smaller programs, use aliases from the root module:

```zig
var res = try httpx.fetch("https://httpbun.com/get", .{});
defer res.deinit();

var custom = try httpx.send(.GET, "https://httpbun.com/headers", .{});
defer custom.deinit();

// Optional explicit allocator override.
var custom_alloc = try httpx.sendWithAllocator(allocator, .GET, "https://httpbun.com/headers", .{ .timeout_ms = 10_000 });
defer custom_alloc.deinit();
```

## Auth Helpers

Use built-in request auth helpers instead of manually building `Authorization` headers:

```zig
const bearer_opts = httpx.RequestOptions.defaults()
    .withBearerToken("demo-token")
    .withHeaders(&.{.{ "Accept", "application/json" }});

var bearer_res = try client.get("/protected", bearer_opts);
defer bearer_res.deinit();

const basic_opts = httpx.RequestOptions.defaults()
    .withBasicAuth("demo", "pass")
    .withHeaders(&.{.{ "Accept", "application/json" }});

var basic_res = try client.get("/admin", basic_opts);
defer basic_res.deinit();
```

## Request Options

The second argument to request methods is `RequestOptions`:

```zig
pub const RequestOptions = struct {
    headers: ?[]const [2][]const u8 = null,    // Custom headers
    query_params: ?[]const [2][]const u8 = null, // Optional URL query params
    body: ?[]const u8 = null,                  // Raw body (highest precedence)
    json: ?[]const u8 = null,                  // JSON body
    form_fields: ?[]const [2][]const u8 = null, // x-www-form-urlencoded body
    bearer_token: ?[]const u8 = null,          // Authorization: Bearer <token>
    basic_auth: ?httpx.BasicAuth = null,       // Authorization: Basic ...
    timeout_ms: ?u64 = null,                   // Request-specific timeout
    follow_redirects: ?bool = null,            // Override redirect policy
    version: ?httpx.Version = null,            // Optional per-request protocol override
    proxy: ?httpx.Proxy = null,                // Per-request forward proxy override
    verify_ssl: ?bool = null,                  // Per-request SSL verification toggle
    keep_alive: ?bool = null,                  // Per-request connection reuse control
    unix_socket_path: ?[]const u8 = null,      // Per-request Unix Domain Socket path
};
```

All fields are optional customizations. Per-request overrides allow complete control over proxy routing, security verification, connection persistence, and socket routing on a per-request basis without modifying the shared client config. Passing `.{}` keeps defaults implicit.

## Proxy Configuration

Configure forward proxies when initializing the client:

```zig
const config = httpx.ClientConfig.defaults()
    .withProxy(.{
        .host = "127.0.0.1",
        .port = 8080,
        .username = "user",  // Optional authentication
        .password = "pass",  // Optional authentication
    });

var client = httpx.Client.initWithConfig(allocator, config);
defer client.deinit();
```

For SOCKS5h, set the proxy kind explicitly:

```zig
const socks_config = httpx.ClientConfig.defaults()
    .withProxy(.{
        .kind = .socks5h,
        .host = "127.0.0.1",
        .port = 1080,
    });
```

## Response Handling

The `Response` object provides helpers to access data:

```zig
// Check status
if (response.ok()) { ... }

// Get headers
if (response.headers.get("Content-Type")) |ct| { ... }

// Parse JSON response safely (returns std.json.Parsed(T), caller owns memory)
const MyStruct = struct { id: u32, name: []const u8 };
const parsed = try response.json(MyStruct, .{ .ignore_unknown_fields = true });
defer parsed.deinit();
const data = parsed.value;

// Or use leaky JSON parsing directly into the struct (useful for simple structs)
const data_leaky = try response.jsonLeaky(MyStruct, .{});
```
