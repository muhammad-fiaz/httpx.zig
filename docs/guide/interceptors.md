# Interceptors

HTTPX does not expose a client interceptor registry or an `addInterceptor` API.
Cross-cutting client behavior is composed from per-request options, small
wrapper functions, and the client event callback.

## Auth and Header Wrappers

Use the built-in request options for standard auth and headers:

```zig
fn authedGet(client: *httpx.Client, url: []const u8, token: []const u8) !httpx.Response {
    return client.get(url, .{
        .bearerAuth = token,
        .headers = &.{
            .{ .name = "X-Request-Source", .value = "my-app" },
        },
    });
}
```

Wrappers can also translate responses:

```zig
fn fetchUserName(client: *httpx.Client, url: []const u8) ![]u8 {
    var res = try client.get(url, .{});
    defer res.deinit();
    return res.allocator.dupe(u8, res.text());
}
```

## Logging and Lifecycle Events

Set `eventCallback` in the `Client.init` options to observe completed and
failed requests without wrapping individual calls. See
[Structured Lifecycle Events](/observability/events).

## Server-Side Hooks

Server middleware remains the supported way to apply cross-cutting behavior to
routes. See [Middleware Guide](/guide/middleware) and
[API: Middleware](/api/middleware).

## Related

* [Example: Interceptors](/examples/interceptors)
* [Observability: Events](/observability/events)
