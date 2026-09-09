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
fn createUser(ctx: *httpx.Context) anyerror!httpx.Response {
    const verbose = ctx.queryParam("verbose") orelse "0";
    _ = verbose;
    const auth = ctx.header("Authorization");
    _ = auth;
    return ctx.renderJsonStatus(201, .{ .created = true });
}
```

See `examples/custom_headers.zig`, `examples/custom_responses.zig`, and
`examples/custom_server.zig`.

## Run

```bash
zig build run-custom-headers
zig build run-custom-responses
zig build run-custom-server
```

## What to Verify

- Custom headers, query params, and auth round-trip.
- Response accessors return status, content type, and body text.
