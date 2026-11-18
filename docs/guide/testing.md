# Testing Server

`httpx.testing.Server` is the production `httpx.Server` with testing-oriented
initialization. It binds a real loopback socket, runs the normal server
pipeline, and can be driven by the regular `httpx.Client`. There is no mock
transport and no second HTTP implementation.

```zig
var server = try httpx.testing.Server.init(allocator, io, .{});
defer server.deinit();

try server.route("/get", .{
    .method = .GET,
    .status = 200,
    .body = "Hello!",
});

try server.start();

const url = try server.url("/get");
defer allocator.free(url);

var response = try client.get(url, .{});
defer response.deinit();
try std.testing.expectEqualStrings("Hello!", response.body);
```

## Defaults

`.{}` binds `127.0.0.1` on port `0` (an OS-assigned port) instead of the
production defaults `0.0.0.0:8080`. Every other field is the production
configuration schema: same names, types, validation, feature dependencies, and
security behavior. Testing defaults never bind publicly; an explicit `.host`
is required to change that.

```zig
var server = try httpx.testing.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .keepAlive = true,
    .maxBody = 64 * 1024,
    .compression = .{}, // production compression schema
});
```

Use `server.localPort()` for the actual bound port. The listener is bound during
`init`, so `start()` has deterministic readiness with no sleep or polling.

## Routes

```zig
try server.route("/text", httpx.testing.text("plain"));
try server.route("/json", httpx.testing.json("{\"ok\":true}"));
try server.route("/html", httpx.testing.html("<h1>Hi</h1>"));
try server.route("/bytes", httpx.testing.binary("\x00\x01", "application/octet-stream"));
try server.route("/redirect", httpx.testing.redirect("/text", 302));
try server.route("/missing", httpx.testing.empty(404));
try server.route("/slow", httpx.testing.delayed(25, httpx.testing.text("later")));
try server.route("/multi", .{
    .methods = &.{ .PUT, .PATCH, .DELETE },
    .body = "multi",
});
```

Registering the same method and path twice returns `error.DuplicateRoute` and
leaves the existing route intact. Static bodies, content types, and headers are
copied at registration. `.closeConnection = true` adds `Connection: close`.

## Dynamic handlers

Handlers receive the production `httpx.router.Context`, so they can inspect the
method, path, query string, headers, parsed body, content length, peer address,
TLS state, and request-scoped allocator.

```zig
fn inspect(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const body = try std.fmt.allocPrint(ctx.allocator, "{s} {s}?{s}", .{
        ctx.method.toString(),
        ctx.path,
        ctx.query,
    });
    return .{ .status = 200, .body = body, .contentType = "text/plain" };
}

try server.route("/inspect", .{ .handler = inspect });
```

`httpx.testing.echo` mirrors the request body and content type.

## Request capture

Every request that reaches the production transport observer is counted. Retained
requests are bounded by entry count, body bytes, and header bytes.

```zig
try server.capture(.{
    .enabled = true,
    .maxEntries = 128,
    .maxBody = 32 * 1024,
    .maxHeader = 8 * 1024,
});

const requests = try server.requests(allocator);
defer httpx.testing.freeCaptured(allocator, requests);

for (requests) |request| {
    // request.method, .path, .query, .headers, .body, .bodySize,
    // .bodyTruncated, .headersTruncated, .header(name)
}
```

`server.requestCount()` counts every observed request, including 404s and
evicted entries. `server.routeRequestCount(path)` counts requests handled by
`route()` registrations at that path. `server.lastRequest(allocator)` copies the
most recent retained request, and `server.resetRequests()` clears retention and
the total.

## Lifecycle and multiple instances

`start()` spawns the production serving thread and returns. `stop()` stops
accepting, interrupts active connections, and joins the thread; it is safe to
call repeatedly and safe before `start()`. `deinit()` stops first, then releases
routes, capture, and the production server.

Each instance owns its listener, port, configuration, routes, middleware,
connections, capture state, and shutdown. Stopping one server never stops
another.

```zig
var first = try httpx.testing.Server.init(allocator, io, .{});
defer first.deinit();
var second = try httpx.testing.Server.init(allocator, io, .{});
defer second.deinit();

try first.start();
try second.start();
first.stop(); // second keeps serving
```

## Production API parity

All applicable production server methods forward to the same canonical server:
verb registration (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`,
`add`), `group`, `mount`, `register`, `use`, static files, SPA fallback,
templates, metrics, custom error/status/not-found handlers, GraphQL, TLS,
HTTP/3 readiness, pause/resume, blocking run/serve, `localPort`, and
`localAddress`. Use `server.router()` for direct router access and
`server.production()` when an API requires `*httpx.Server`.

Routes registered through forwarded production verbs participate in normal
production behavior and global request capture. Per-route counters apply to
`route()` registrations.

## Protocols and limitations

The testing server uses whatever protocols the production configuration
enables. HTTP/1.0, HTTP/1.1, compression, keep-alive, redirects, multipart,
chunked writes, and static files work as in production. HTTP/2, HTTP/3, and TLS
require the same build features, certificates, and ALPN setup as production;
they are not advertised when prerequisites are absent. Custom method tokens
outside the production `Method` enum are rejected by the production parser.
