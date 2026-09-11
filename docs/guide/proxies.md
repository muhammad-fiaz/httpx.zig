# Proxies & SOCKS5 Guide

`httpx.zig` routes client requests through forward proxies: HTTP
CONNECT tunnels and SOCKS5 / SOCKS5h (remote DNS). Configure globally
on the client or per request.

## Forward Proxying (Client)

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Global proxy for every request from this client.
    var client = httpx.Client.init(allocator, io, .{
        .proxy = "http://127.0.0.1:8080",
    });
    defer client.deinit();

    var resp = try client.get("https://httpbun.com/get", .{});
    defer resp.deinit();
}
```

Per-request override uses the same `.proxy` field:

```zig
var resp = try client.get("http://internal/", .{
    .proxy = "http://127.0.0.1:8080",
});
```

### 1. HTTP CONNECT Proxy (with authentication)

Plain `http://host:port` tunnels via `CONNECT host:port`, keeping the
tunneled request in origin-form (`GET /path`, never an absolute URI).

Credentials in the proxy URL become `Proxy-Authorization: Basic` on
the CONNECT request only — they are never forwarded to the origin:

```zig
var resp = try client.get("http://internal/", .{
    .proxy = "http://user:pass@127.0.0.1:8080",
});
```

A `407 Proxy Authentication Required` response surfaces as
`error.ProxyAuthRequired`; other non-`200` CONNECT replies surface as
`error.ConnectFailed`. (`https://` proxy URLs are not accepted.)

### 2. SOCKS5 / SOCKS5h Proxy

```zig
var client = httpx.Client.init(allocator, io, .{
    // SOCKS5h delegates target name resolution to the proxy,
    // avoiding local DNS leaks for internal hostnames.
    .proxy = "socks5h://user:pass@127.0.0.1:1080",
});
defer client.deinit();
```

`socks5://` resolves the destination locally; `socks5h://` sends the
domain name to the proxy (`ATYP=0x03`). Username/password sub-
negotiation is supported for both. SOCKS4 (`socks4://`, IPv4 literals
only) and SOCKS4a (`socks4a://`, hostnames forwarded unresolved) are
supported the same way; SOCKS4 has no authentication and no IPv6.

## Server-side Middleware

Apply standard middleware to a server with `server.use(mw)` (CORS,
security headers, logging, rate limiting — see `/guide/middleware`).
There is no built-in reverse-proxy middleware; proxy *servers* are
outside the scope of this guide.
