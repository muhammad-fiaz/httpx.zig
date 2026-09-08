# SOCKS5 Protocol

RFC 1928 defines the SOCKS Protocol Version 5, a versatile circuit-level proxy framework operating between the transport layer and application layer.

## Connection Flow

1. Client connects to SOCKS5 server on port 1080.
2. Client offers authentication methods: `0x00` (No auth), `0x02` (Username/Password).
3. SOCKS5 server responds with chosen method.
4. If authentication succeeds, client sends `CONNECT` command with destination IPv4 or IPv6 address.
5. Server connects to remote host and relays raw TCP data.

In standard SOCKS5, the client resolves domain names locally before initiating the SOCKS connection.

## Client Configuration

```zig
var client = httpx.Client.init(allocator, io, .{
    .proxy = "socks5://user:pass@127.0.0.1:1080",
});
defer client.deinit();

const res = try client.get("http://example.com", .{});
defer res.deinit();
```

## Related

* [Protocol: SOCKS5H](/protocols/socks5h)
* [Example: SOCKS5 Proxy](/examples/socks5-proxy)
* [Guide: Proxies](/guide/proxies)
