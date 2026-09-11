# API: Proxy

The `httpx.proxy` module defines proxy representations, URL parsing, and protocol negotiation for HTTP CONNECT tunneling, SOCKS5, and SOCKS5H remote DNS proxies.

## Overview

HTTPX transparently routes client requests through forward proxies. Proxies can be configured globally on `Client.init` or per request in request options.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // SOCKS5H with remote DNS: target hostnames resolved by proxy
    var client = httpx.Client.init(allocator, io, .{
        .proxy = "socks5h://user:pass@127.0.0.1:1080",
    });
    defer client.deinit();

    const resp = try client.get("https://api.ipify.org?format=json", .{});
    defer resp.deinit();
}
```

## Proxy Schemes

| Scheme | Protocol | DNS Resolution | Description |
|---|---|---|---|
| `http://` | HTTP CONNECT | Local | Standard HTTP proxy tunnel; `http://user:pass@host:port` sends `Proxy-Authorization: Basic` on CONNECT, `407` surfaces as `error.ProxyAuthRequired` |
| `socks5://` | SOCKS5 | Local | SOCKS5 protocol with local client DNS resolution |
| `socks5h://` | SOCKS5H | Remote | SOCKS5 protocol with proxy-side DNS resolution |
| `socks4://` | SOCKS4 | Local | IPv4 destinations only; USERID informational, no password |
| `socks4a://` | SOCKS4a | Remote | Hostnames forwarded unresolved (SOCKS5H idea for v4) |

> Note: `https://` proxy URLs are not accepted (`parseProxyUrl` returns
> `null`); SOCKS4 has no IPv6 representation (rejected loudly). TLS runs
> end-to-end *through* the CONNECT tunnel to the origin server.

## Types

```zig
pub const ProxyKind = enum {
    httpConnect,
    socks5,
    socks4,
    direct,
};

pub const ProxyInfo = struct {
    kind: ProxyKind,
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    remoteDns: bool = false,
};

pub fn parseProxyUrl(urlStr: []const u8) ?ProxyInfo;
```

## Functions

### `httpx.proxy.parseProxyUrl(urlStr) ?ProxyInfo`
Parses proxy URI strings into a structured `ProxyInfo` struct. Extracts protocol kind, host, port, credentials, and remote DNS flags. Returns `null` if malformed.

## SOCKS5 Negotiation Sequence

1. **Client Greeting**: Sends supported authentication methods (No Auth, Username/Password).
2. **Server Choice**: Server selects method or rejects.
3. **Authentication**: If username/password required, client sends sub-negotiation credentials.
4. **Connect Request**: Client requests connection to destination host:port (domain name format for `socks5h`, IPv4/IPv6 for `socks5`).
5. **Connection Established**: Subsequent traffic is forwarded transparently.

## Related

* [Protocol: SOCKS5 & SOCKS5H](/protocols/socks5h)
* [Protocol: Proxies](/protocols/proxies)
* [Guide: Proxies](/guide/proxies)
