# SOCKS5h Proxy Example

Demonstrates routing HTTP client requests through a SOCKS5h proxy with remote DNS resolution, username/password authentication, and IPv4/IPv6/domain target support.

## Demo Program

```zig
// Configure client with SOCKS5h proxy
const client_config = httpx.ClientConfig.defaults()
    .withTimeouts(httpx.Timeouts.fast())
    .withRetryPolicy(httpx.RetryPolicy.noRetry())
    .withProxy(.{
        .host = "127.0.0.1",
        .port = 1080,
        .kind = .socks5h,
        .username = "proxyuser",
        .password = "proxypass",
    });

var client = httpx.Client.initWithConfig(allocator, client_config);
defer client.deinit();

// Request through the SOCKS5h proxy
var response = try client.get("http://target.example.com/data", .{});
defer response.deinit();
```

## Run

```
zig build run-all-socks5_proxy
```

## What to Verify

- [x] Client config sets `.kind = .socks5h` for remote DNS resolution
- [x] Username and password authentication fields are accepted
- [x] Proxy host and port are configured correctly
- [x] SOCKS5h performs DNS resolution on the proxy side (remote DNS)
- [x] Request is routed through the proxy to the target backend
- [x] Response is returned correctly through the proxy chain
