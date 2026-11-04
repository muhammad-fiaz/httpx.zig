# Client basics

`httpx.Client` sends HTTP requests and owns the connection pool, DNS cache,
and TLS session cache used by those requests. Initialize it with an allocator
and `std.Io`, then release it with `deinit()`.

## Initialize a client

```zig
const std = @import("std");
const httpx = @import("httpx");

var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();

const allocator = gpa.allocator();
const io = std.Io.Threaded.global_single_threaded.io();

var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();
```

`Client.init` returns a client value and does not return an error. The
allocator and I/O value must remain valid until `client.deinit()` completes.
See the [Client API](/api/client) for the complete configuration table.

## Send a GET request

```zig
var response = try client.get("https://example.com/", .{});
defer response.deinit();

if (!response.isSuccess()) {
    std.debug.print("request failed with status {d}\n", .{response.status});
    return;
}

std.debug.print("{s}\n", .{response.text()});
```

The convenience methods take the URL first and an options value second.
Responses own their headers and body; call `deinit()` exactly once.

## Send a JSON request

```zig
const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

const request_data = CreateUser{
    .name = "Alice",
    .email = "alice@example.com",
};

var response = try client.post("https://api.example.com/users", .{
    .json = request_data,
});
defer response.deinit();
```

The `json` option accepts a serializable Zig value. Httpx.zig serializes it
and selects `application/json` unless an explicit `contentType` or header
overrides it.

## Decode a JSON response

```zig
const User = struct {
    id: u64,
    name: []const u8,
};

var response = try client.get("https://api.example.com/users/1", .{});
defer response.deinit();

const user = try response.json(User);
std.debug.print("{d}: {s}\n", .{ user.id, user.name });
```

`Response.json(T)` parses using the response allocator and returns a value
whose borrowed strings remain valid until the response is released. Use
`jsonAlloc(T, allocator)` when the parsed value needs an independent managed
lifetime.

```zig
const parsed = try response.jsonAlloc(User, allocator);
defer parsed.deinit();
```

## Use headers and query parameters

```zig
var response = try client.get("https://api.example.com/search", .{
    .headers = &.{
        .{ .name = "Accept", .value = "application/json" },
    },
    .query = &.{
        .{ .name = "q", .value = "zig networking" },
        .{ .name = "page", .value = "2" },
    },
});
defer response.deinit();
```

Query values are encoded and appended to the request URL. Header names are
sent as supplied.

## Send other HTTP methods

Use the method helpers when the method is known at the call site:

```zig
var response = try client.put("https://api.example.com/users/1", .{
    .json = .{ .name = "Alice" },
});
defer response.deinit();
```

```zig
var response = try client.patch("https://api.example.com/users/1", .{
    .json = .{ .name = "Alice" },
});
defer response.deinit();
```

```zig
var response = try client.delete("https://api.example.com/users/1", .{});
defer response.deinit();
```

```zig
var response = try client.head("https://api.example.com/users/1", .{});
defer response.deinit();
```

`options`, `trace`, and `connect` are also available. For a method selected
at runtime, use `request`:

```zig
var response = try client.request("https://api.example.com/users", .{
    .method = .OPTIONS,
});
defer response.deinit();
```

## Send text or form data

```zig
var response = try client.post("https://api.example.com/message", .{
    .text = "hello from Zig",
    .contentType = "text/plain; charset=utf-8",
});
defer response.deinit();
```

```zig
var response = try client.post("https://api.example.com/login", .{
    .form = "username=alice&password=secret",
});
defer response.deinit();
```

The `form` value must already be URL-encoded. Use `body` for arbitrary
bytes and set `contentType` when the server requires a specific media type.

## Set authentication

```zig
var response = try client.get("https://api.example.com/profile", .{
    .bearerAuth = "token-value",
});
defer response.deinit();
```

```zig
var response = try client.get("https://api.example.com/admin", .{
    .basicAuth = "alice:password",
});
defer response.deinit();
```

For cookies, provide a cookie header value directly:

```zig
var response = try client.get("https://api.example.com/profile", .{
    .cookie = "session=abc123",
});
defer response.deinit();
```

For persistent, domain-aware cookie handling, use
`httpx.client.cookieJar`.

## Set timeouts and redirects

```zig
var response = try client.get("https://api.example.com/report", .{
    .timeoutMs = 10_000,
    .followRedirects = true,
    .maxRedirects = 5,
});
defer response.deinit();
```

Client defaults can be set with `timeoutMs`, `followRedirects`, and
`maxRedirects` in `Client.init`; request options override those defaults.

## Select an HTTP version

```zig
var response = try client.get("https://api.example.com/", .{
    .httpVersion = .http2,
});
defer response.deinit();
```

The supported selection values are `.auto`, `.http10`, `.http11`, `.http2`,
and `.http3`. Protocol availability also depends on the URL, TLS
configuration, and the peer.

## Stream a response

Use `requestStream` when the response should be consumed incrementally:

```zig
var stream = try client.requestStream("https://example.com/large-file", .{});
defer stream.deinit();

var buffer: [8192]u8 = undefined;
while (true) {
    const count = try stream.read(&buffer);
    if (count == 0) break;
    try std.fs.File.stdout().writeAll(buffer[0..count]);
}
```

The stream owns the connection and response resources until `deinit()`.
`readAllAlloc(allocator, maxBytes)` is available when a bounded buffered copy
is preferable.

## Stream an upload

Provide a `httpx.BodySource` through `bodySource` to send a request body
incrementally. See the [request API](/api/request) and
[streaming guide](/guide/streaming) for the available reader adapters.

## Handle errors and response data

Request methods return `httpx.client.Error!httpx.Response`. A successful
transport operation can still return an HTTP error status, so check
`isSuccess()`, `isClientError()`, or `isServerError()` before decoding an
application response.

```zig
var response = client.get("https://api.example.com/", .{}) catch |err| {
    std.debug.print("transport error: {s}\n", .{@errorName(err)});
    return;
};
defer response.deinit();

if (response.isServerError()) {
    std.debug.print("server returned {d}\n", .{response.status});
}

if (response.header("Content-Type")) |content_type| {
    std.debug.print("content type: {s}\n", .{content_type});
}
```

Use `bytes()`, `text()`, `header()`, `json()`, or `jsonAlloc()` according to
the response format.

## Related documentation

- [Client API](/api/client)
- [Request API](/api/request)
- [Response API](/api/response)
- [Streaming](/guide/streaming)
- [Authentication](/guide/authentication)
- [Connection pooling](/guide/pooling)
