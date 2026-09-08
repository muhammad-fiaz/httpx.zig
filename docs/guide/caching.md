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

When configured with client-side caching, HTTPX automatically manages an in-memory cache store:

```zig
var client = httpx.Client.init(allocator, io, .{
    .enable_cache = true,
});
defer client.deinit();

// First request: Cache miss -> 200 OK
const res1 = try client.get("https://api.example.com/items", .{});
defer res1.deinit();

// Second request: Evaluates Cache-Control. Revalidates with If-None-Match.
// If unmodified, returns cached body with 304 revalidation transparently.
const res2 = try client.get("https://api.example.com/items", .{});
defer res2.deinit();
```

---

## Server-Side Caching & ETag Generation

In server handlers, you can easily attach ETags and cache headers:

```zig
server.get("/api/catalog", struct {
    fn handle(ctx: *httpx.Context) !void {
        const etag = "\"catalog-v1.4\"";
        ctx.header("Cache-Control", "public, max-age=300, must-revalidate");
        ctx.header("ETag", etag);

        // Check if client provided matching If-None-Match
        if (ctx.header("If-None-Match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, etag)) {
                ctx.status(304);
                return;
            }
        }

        try ctx.json(.{ .products = &.{ "Widget A", "Widget B" } });
    }
}.handle);
```

Static file serving (`server.static`) automatically computes and attaches ETags based on file modification times and file size.

## Related

* [API: Cache](/api/cache)
* [Example: HTTP Cache](/examples/http-cache-example)
* [Guide: Static Files](/guide/static-files)
