# Reverse Proxy Middleware Example

HTTPX has no server-side reverse proxy middleware. To front a backend,
either deploy a dedicated proxy (Nginx, HAProxy) or forward explicitly in a
handler with the URL-first client:

```zig
fn proxyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var res = try client.get("http://127.0.0.1:9001/api/data", .{});
    defer res.deinit();
    const body = try ctx.allocator.dupe(u8, res.body);
    return .{ .status = res.status, .body = body, .contentType = res.contentType() };
}
```

For client-side forward proxies (including SOCKS5h), see
[Proxy Example](/examples/proxy-example) and `examples/proxyDemo.zig`.

## Expected Output

The handler itself prints nothing; the forwarded client response carries
fields in this format (representative values shown):

```text
status=200 body={"key":"value"} content-type=application/json
```

Status codes, bodies, and content types vary with the backend at `127.0.0.1:9001` and the request path.
