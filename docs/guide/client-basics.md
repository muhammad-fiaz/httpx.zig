# Basic Requests

The `httpx.zig` client supports all standard HTTP methods and provides convenient wrappers for common operations.

## Creating a Client

For simple usage, create a client with the default configuration:

```zig
var client = httpx.Client.init(allocator);
defer client.deinit();
```

For more control, use `ClientConfig`:

```zig
const config = httpx.ClientConfig{
    .base_url = "https://api.github.com",
    .user_agent = "MyApp/1.0",
    .timeouts = .{
        .connect_ms = 5000,
        .read_ms = 10000,
    },
    .http2_enabled = true,
    .http2_settings = .{
        .max_frame_size = 16 * 1024,
    },
};
var client = httpx.Client.initWithConfig(allocator, config);
defer client.deinit();
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

### POST JSON

You can easily send JSON using the `.json` option, which automatically sets the `Content-Type` header to `application/json`.

```zig
const body = "{\"name\": \"Alice\", \"role\": \"admin\"}";
const response = try client.post("https://httpbin.org/post", .{
    .json = body,
});
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
var res = try httpx.fetch(allocator, "https://httpbin.org/get");
defer res.deinit();

var custom = try httpx.send(allocator, .GET, "https://httpbin.org/headers", .{});
defer custom.deinit();
```

## Request Options

The second argument to request methods is `RequestOptions`:

```zig
pub const RequestOptions = struct {
    headers: ?[]const [2][]const u8 = null, // Custom headers
    body: ?[]const u8 = null,              // Raw body
    json: ?[]const u8 = null,              // JSON body
    timeout_ms: ?u64 = null,               // Request-specific timeout
    follow_redirects: ?bool = null,        // Override redirect policy
};
```

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
