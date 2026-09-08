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
    .base_url = "https://api.github.com",
    .user_agent = "MyApp/1.0",
    .timeouts = .{
        .connect_ms = 5000,
        .read_ms = 10000,
    },
    .http2 = true,
    .http3 = false,
    .http2_settings = .{ .max_concurrent_streams = 100 },
    .http3_settings = .{ .qpack_blocked_streams = 16 },
    .verify_ssl = true,
    .keep_alive = true,
    .max_response_size = 32 * 1024 * 1024,
    .pool_max_connections = 64,
    .pool_max_per_host = 16,
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
    .timeout_ms = 10_000,
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

The client automatically stores `Set-Cookie` values and sends a `Cookie` header on subsequent requests. Cookies are domain-aware per RFC 6265 — cookies with a `Domain` attribute are only sent to matching hosts.

```zig
try client.setCookie("session", "abc123");
if (client.getCookie("session")) |session| {
    std.debug.print("session={s}\n", .{session});
}
_ = client.removeCookie("session");
client.clearCookies();
```

For top-level convenience in smaller programs, use functions from the root module:

```zig
var res = try httpx.get("https://httpbun.com/get", .{});
defer res.deinit();

var custom = try httpx.request(.{
    .method = .GET,
    .url = "https://httpbun.com/headers",
    .timeout_ms = 10_000,
});
defer custom.deinit();
```

## Auth Helpers

Use built-in request auth helpers instead of manually building `Authorization` headers:

```zig
var bearer_res = try client.get("/protected", .{ .headers = &.{.{ "Authorization", "Bearer demo-token" }, .{ "Accept", "application/json" }},
});
defer bearer_res.deinit();

var basic_res = try client.get("/admin", .{ .basic_auth = .{ .username = "demo", .password = "pass" },
    .headers = &.{.{ "Accept", "application/json" }},
});
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
    const io = std.Io.Threaded.global_single_threaded.io();
const config: httpx.ClientConfig = .{
    .proxy = .{
        .host = "127.0.0.1",
        .port = 8080,
        .username = "user", // Optional authentication
        .password = "pass", // Optional authentication
    },
};

var client = httpx.Client.init(allocator, io, config);
defer client.deinit();
```

For SOCKS5h, set the proxy kind explicitly:

```zig
const socks_config: httpx.ClientConfig = .{
    .proxy = .{
        .kind = .socks5h,
        .host = "127.0.0.1",
        .port = 1080,
    },
};
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
