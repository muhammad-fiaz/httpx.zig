# SOCKS5H (Remote DNS SOCKS5)

SOCKS5H extends SOCKS5 by delegating DNS resolution entirely to the proxy server, protecting user privacy and circumventing local DNS poisoning or censorship.

## Mechanism

Instead of sending an IPv4 or IPv6 address in the SOCKS5 `CONNECT` request, the client sets the address type field to `0x03` (Domain Name):
```text
+----+-----+-------+------+----------+----------+
|VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
+----+-----+-------+------+----------+----------+
| 1  |  1  | X'00' | X'03'| Variable |    2     |
+----+-----+-------+------+----------+----------+
```
The remote proxy resolves the domain name remotely and establishes the outbound TCP connection.

## Security Advantages

1. **DNS Leak Prevention**: Eliminates plaintext DNS queries across local network routers.
2. **Censorship Circumvention**: Evades ISP-level DNS blocking of target domains.
3. **Tor & Anonymous Networks**: Mandatory protocol format when routing traffic through the Tor SOCKS proxy on port 9050/9150.

## Client Configuration

```zig
var client = httpx.Client.init(allocator, io, .{
    .proxy = "socks5h://127.0.0.1:9050", // Tor SOCKS5h proxy
});
defer client.deinit();

const res = try client.get("https://check.torproject.org", .{});
defer res.deinit();
```

## Related

* [Protocol: SOCKS5](/protocols/socks5)
* [API: Proxy](/api/proxy)
* [Guide: Proxies](/guide/proxies)
