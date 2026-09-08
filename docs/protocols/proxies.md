# HTTP Proxies & Tunnels

RFC 9110 specifies HTTP proxy forwarding and the `CONNECT` method for establishing end-to-end encrypted TCP tunnels through intermediary proxies.

## HTTP CONNECT Tunneling

When connecting to an HTTPS destination through an HTTP proxy:
1. Client connects to proxy IP:port via TCP.
2. Client sends plaintext:
```http
CONNECT httpbun.com:443 HTTP/1.1
Host: httpbun.com:443
```
3. Proxy establishes TCP connection to destination and returns `200 Connection Established`.
4. Client performs TLS 1.3 handshake directly with destination through the proxy tunnel.

The proxy never sees the plaintext TLS payload or cryptographic keys.

## Forward Proxy vs Reverse Proxy

* **Forward Proxy**: Client-side proxy directing outgoing traffic to external destinations.
* **Reverse Proxy**: Server-side gateway terminating client requests and forwarding them to internal upstream microservices.

## Client Usage

```zig
var client = httpx.Client.init(allocator, io, .{
    .proxy = "http://corporate-proxy.corp:8080",
});
defer client.deinit();

const res = try client.get("https://httpbun.com/get", .{});
defer res.deinit();
```

## Related

* [API: Proxy](/api/proxy)
* [Protocol: SOCKS5](/protocols/socks5)
* [Guide: Proxies](/guide/proxies)
