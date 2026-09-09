# Reverse Proxy Middleware Example

HTTPX has no server-side reverse proxy middleware. To front a backend,
either deploy a dedicated proxy (Nginx, HAProxy) or forward explicitly in a
handler with the URL-first client:

```zig
fn proxyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    var res = try client.get("http://127.0.0.1:9001/api/data", .{});
    defer res.deinit();
    const body = try ctx.allocator.dupe(u8, res.body);
    return .{ .status = res.status, .body = body, .contentType = res.contentType() };
}
```

For client-side forward proxies (including SOCKS5h), see
[Proxy Example](/examples/proxy-example) and `examples/proxy_demo.zig`.
