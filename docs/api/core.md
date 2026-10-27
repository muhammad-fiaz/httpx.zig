# Core API

The core module holds the fundamental types used throughout the library:
requests, responses, headers, URIs, methods, and status codes
(`src/common/`, `src/client/requestBuilder.zig`, `src/web/router/router.zig`).

## Client request

The high-level client API is URL-first; a fluent `RequestBuilder` is
available separately for method-chained assembly:

```zig
var res = try client.post("https://api.example.com/data", .{
    .headers = &.{.{ .name = "Accept", .value = "application/json" }},
    .json = "{\"foo\":\"bar\"}",
    .query = &.{.{ .name = "page", .value = "1" }},
    .bearerAuth = "token",
    .timeoutMs = 10_000,
});
defer res.deinit();
```

See [Client](/api/client) and [Request](/api/request).

## Client response

`Response` (`src/client/requestBuilder.zig`):

| Member | Description |
|--------|-------------|
| `status: u16` | Numeric status code |
| `headers: []Header` | Response headers |
| `body: []u8` | Owned body bytes |
| `deinit()` | Free headers and body |
| `header(name)` | Header lookup (case-insensitive) |
| `text()` / `bytes()` | Body bytes |
| `writeTo(writer)` | Write the buffered body bytes |
| `contentType()` | Content-Type value |
| `json(T)` / `jsonAlloc(T, allocator)` | JSON decoding |
| `isInformational()` / `isSuccess()` / `isRedirect()` | Status class checks |

## Server response

Handlers return `httpx.router.Response` literals or `Context` helpers
(`ctx.html`, `ctx.text`, `ctx.renderJson`, `ctx.redirect`, ...).
See [Server](/api/server).

## Headers

`httpx.headers.Headers` (`src/common/headers.zig`) is an ordered multi-map:

| Method | Description |
|--------|-------------|
| `init(allocator)` / `deinit()` | Lifecycle |
| `set(name, value)` | Set/overwrite value |
| `append(name, value)` | Append value (multi-value headers) |
| `get(name)` | First value, case-insensitive |
| `getAll(allocator, name)` | All values |
| `remove(name)` | Remove header |
| `contains(name)` | Presence check |
| `count()` / `clear()` | Size and reset |

Plain `[]Header` (`{ .name, .value }`) slices are used for per-request headers.

## URI

`httpx.Uri.parse(...)` parses RFC 3986 URIs:

```zig
const uri = try httpx.Uri.parse("https://user:pass@example.com:8080/path?query=1");
```

| Field | Type | Description |
|-------|------|-------------|
| `scheme` | `[]const u8` | `"http"`, `"https"`, or empty |
| `userinfo` | `[]const u8` | User info before `@`, or empty |
| `host` | `[]const u8` | Hostname or IP |
| `port` | `u16` | Explicit port (`0` when absent; see `effectivePort()`) |
| `path` | `[]const u8` | Resource path (defaults to `/`) |
| `query` | `[]const u8` | Query string, or empty |
| `fragment` | `[]const u8` | Fragment identifier, or empty |
