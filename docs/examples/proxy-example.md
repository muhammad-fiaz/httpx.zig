# Proxy and Reverse Proxy

Client-side forward proxying. There is no server-side reverse proxy in
HTTPX. See `examples/proxy_demo.zig`.

## Forward Proxy (Client)

```zig
// Client-level proxy (URL form).
var client = httpx.Client.init(allocator, io, .{
    .proxy = "http://127.0.0.1:8080",
});
defer client.deinit();

// Per-request override, including SOCKS5h for remote DNS.
var res = try client.get("http://target.example.com/data", .{
    .proxy = "socks5h://127.0.0.1:1080",
});
defer res.deinit();
```

With `http://`, the client keeps forward-proxy behavior and supports
CONNECT tunnels for TLS endpoints. With `socks5h://`, the proxy resolves
the target host remotely.

## Run

```bash
zig build run-proxy-demo
```

## What to Verify

- Requests route through the configured proxy.
- SOCKS5h delegates DNS to the proxy side.
