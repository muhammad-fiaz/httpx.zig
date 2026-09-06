# Proxies & SOCKS5h Guide

`httpx.zig` includes comprehensive forward and reverse proxy capabilities, supporting HTTP proxies, HTTPS CONNECT tunneling, SOCKS5h proxies (with remote DNS resolution), and server-side reverse proxy middleware.

## Forward Proxying (Client)

A forward proxy intercepts outbound client requests and routes them to target servers on behalf of the client.

### 1. HTTP/HTTPS Proxy

Configure standard HTTP or HTTPS forward proxies on `ClientConfig`:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withProxy(.{
            .kind = .http,
            .host = "proxy.example.com",
            .port = 8080,
            .username = "user", // Optional credentials
            .password = "secret",
        })
    );
    defer client.deinit();

    var resp = try client.get("https://httpbun.com/get", .{});
    defer resp.deinit();
}
```

### 2. SOCKS5h Proxy

The SOCKS5h protocol delegates target name resolution directly to the proxy server, avoiding local DNS leaks and resolving internal hostnames:

```zig
var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
    .withProxy(.{
        .kind = .socks5h,
        .host = "127.0.0.1",
        .port = 1080,
    })
);
```

---

## Reverse Proxying (Server)

A reverse proxy sits in front of backend servers, receiving incoming client requests and forwarding them downstream.

Use the built-in `reverseProxy` middleware to configure routing to backend services:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var server = httpx.Server.init(allocator);
    defer server.deinit();

    // Route all incoming requests on /api/* downstream to the backend service
    try server.use(httpx.middleware.reverseProxy("http://backend-service.local:9000"));

    try server.listen();
}
```
