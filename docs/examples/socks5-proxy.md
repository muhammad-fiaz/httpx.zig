# SOCKS5h Proxy Example

Route HTTP client requests through a SOCKS5h proxy with remote DNS
resolution. See `examples/proxy_demo.zig`.

```zig
// Client-level proxy (URL form).
var client = httpx.Client.init(allocator, io, .{
    .proxy = "socks5h://127.0.0.1:1080",
});
defer client.deinit();

// Per-request proxy override.
var response = try client.get("http://target.example.com/data", .{
    .proxy = "socks5h://127.0.0.1:1080",
});
defer response.deinit();
```

`socks5h://` delegates hostname resolution to the proxy; `socks5://`
resolves locally. `http://` selects an HTTP forward proxy.

## Run

```bash
zig build run-proxy-demo
```

## What to Verify

- Requests route through the configured proxy.
- SOCKS5h performs DNS resolution on the proxy side (remote DNS).
