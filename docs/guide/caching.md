# HTTP Caching Guide

HTTPX provides standards-compliant HTTP caching (RFC 9111) for client requests and server responses, optimizing latency and bandwidth usage with conditional requests and expiration controls.

## Overview

HTTP caching allows clients and intermediary proxies to store response representations and reuse them in subsequent requests.

Key mechanisms supported:
* **Freshness**: Determined by `Cache-Control: max-age=N` and `Expires`.
* **Validation**: Conditional requests via `If-None-Match` (ETag) and `If-Modified-Since` (Last-Modified).
* **304 Not Modified**: Server confirms the cached copy is valid without retransmitting the body payload.

---

## Client-Side Caching

HTTPX does not yet implement an HTTP response cache (RFC 9111 client cache):
there is no `enable_cache` option on `Client.init` — the client exposes DNS
caching only (`ClientConfig.dnsCache`). Send conditional headers (`If-None-Match`,
`If-Modified-Since`) explicitly per request and handle `304` responses in the
caller:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var res = try client.get("https://api.example.com/items", .{
    .headers = &.{.{ .name = "If-None-Match", .value = cached_etag }},
});
defer res.deinit();
// 304 here means "use your stored copy".
```

---

## Server-Side Caching & ETag Generation

In server handlers, you can easily attach ETags and cache headers:

```zig
fn catalogHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const etag = "\"catalog-v1.4\"";

    // Check if client provided matching If-None-Match
    if (ctx.header("If-None-Match")) |client_etag| {
        if (std.mem.eql(u8, client_etag, etag)) {
            return .{ .status = 304 };
        }
    }

    return .{
        .status = 200,
        .body = "{\"products\":[\"Widget A\",\"Widget B\"]}",
        .contentType = "application/json",
        .headers = &.{
            .{ .name = "Cache-Control", .value = "public, max-age=300, must-revalidate" },
            .{ .name = "ETag", .value = etag },
        },
    };
}

// try server.get("/api/catalog", catalogHandler);
```

Static file serving (`server.static`) automatically computes and attaches ETags based on file modification times and file size.

## Related

* [API: Cache](/api/cache)
* [Example: HTTP Cache](/examples/http-cache-example)
* [Guide: Static Files](/guide/static-files)
