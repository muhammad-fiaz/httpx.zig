# Request and Response Customization

Per-request options on the client and `Context` helpers on the server.

```zig
// Client: headers, query, auth, and JSON bodies in one call.
var res = try client.post("https://api.example.com/users", .{
    .headers = &.{.{ .name = "X-Request-Id", .value = "123" }},
    .query = &.{.{ .name = "verbose", .value = "1" }},
    .bearerAuth = "demo-token",
    .json = .{ .name = "Alice", .role = "admin" },
    .timeoutMs = 10_000,
});
defer res.deinit();

// Response accessors.
const status = res.status;
const contentType = res.contentType();
const bodyText = res.text();
```

```zig
// Server: inspect with Context helpers, respond with rich types.
fn createUser(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const verbose = ctx.queryParam("verbose") orelse "0";
    _ = verbose;
    const auth = ctx.header("Authorization");
    _ = auth;
    return ctx.renderJsonStatus(201, .{ .created = true });
}
```

See `examples/customHeaders.zig`, `examples/customResponses.zig`, and
`examples/customServer.zig`.

## Expected Output

The snippet itself prints nothing; the referenced examples print lines in
these formats (representative values shown):

```text
Status: 200
Body: {"headers":{"Authorization":"Bearer my-token","X-Custom":"my-value"}}
1. GET /html -> status=200, content-type=text/html; charset=utf-8
2. GET /json -> status=200, content-type=application/json, body={"status":"ok","version":"1.0.0"}
Server running on http://127.0.0.1:41237
GET / -> status=200, body={"message":"Custom request/response example"}
Custom server verification completed successfully.
```

Status codes, content types, bodies, URLs, and ports vary with the request, server config, and ephemeral port selected at runtime.

## Run

```bash
zig build run-custom-headers
zig build run-custom-responses
zig build run-custom-server
```

## What to Verify

- Custom headers, query params, and auth round-trip.
- Response accessors return status, content type, and body text.
