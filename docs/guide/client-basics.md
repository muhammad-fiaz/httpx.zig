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
const response = try client.get("https://httpbin.org/get", .{});
defer response.deinit();

if (response.status.isSuccess()) {
    std.debug.print("Body: {s}\n", .{response.body.?});
}
```

### GET with explicit timeout and error handling

For external endpoints, prefer an explicit per-request timeout and `catch` handler so errors are visible immediately:

```zig
var response = client.get("https://httpbin.org/get", .{
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

var response = try client.get("https://httpbin.org/get", opts);
defer response.deinit();
```

### POST JSON

You can easily send JSON using the `.json` option, which automatically sets the `Content-Type` header to `application/json`.

```zig
const body = "{\"name\": \"Alice\", \"role\": \"admin\"}";
const response = try client.post(
    "https://httpbin.org/post",
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

The client automatically stores `Set-Cookie` values and sends a `Cookie` header on subsequent requests.

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
var res = try httpx.fetch("https://httpbin.org/get");
defer res.deinit();

var custom = try httpx.send(.GET, "https://httpbin.org/headers", .{});
defer custom.deinit();

// Optional explicit allocator override.
var custom_alloc = try httpx.sendWithAllocator(allocator, .GET, "https://httpbin.org/headers", .{ .timeout_ms = 10_000 });
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
};
```

All fields are optional customizations. Passing `.{}` keeps defaults implicit.

## Response Handling

The `Response` object provides helpers to access data:

```zig
// Check status
if (response.ok()) { ... }

// Get headers
if (response.headers.get("Content-Type")) |ct| { ... }

// Parse JSON response
const MyStruct = struct { id: u32, name: []const u8 };
const data = try response.json(MyStruct);
```
