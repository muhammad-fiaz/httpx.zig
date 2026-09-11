# DNS Resolution Guide

This guide explains how HTTPX handles hostname resolution, how to resolve hostnames manually, how to configure caching and address families, and how resolution integrates with proxies.

---

## 1. How Does HTTPX Resolve a Hostname?

When you make a request like:

```zig
var response = try client.get("https://httpbun.com/get", .{});
defer response.deinit();
```

HTTPX executes the following resolution sequence:

1. **Numeric IP Check**: If the target host is an IPv4 or IPv6 literal (e.g. `127.0.0.1` or `[::1]`), DNS resolution is completely bypassed.
2. **DNS Cache Consultation**: If DNS caching is enabled (the default), HTTPX checks its thread-safe in-memory cache. If an unexpired entry exists, cached addresses are returned immediately without network I/O.
3. **Single-Flight Coalescing**: If concurrent requests require resolution for the same hostname simultaneously, only **one** network lookup is initiated. Other requests await and share the result, eliminating cache stampedes.
4. **OS Resolver**: If the entry is missing or expired, HTTPX queries the platform's OS resolver via `std.Io` (`ws2_32.GetAddrInfoW` on Windows, `libc getaddrinfo` on POSIX).
5. **Address Sorting**: Returned addresses follow RFC 3484 default address selection rules.
6. **Connection Attempt**: HTTPX tries connecting to each candidate address in order until one succeeds.

---

## 2. How Do I Use DNS Manually?

Normal users should never need to construct low-level resolvers or manage raw address buffers. Resolution is integrated directly into `httpx.Client`:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize client once
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 2. Resolve hostname using client's internal resources
    var addresses = try client.resolve("httpbun.com", .{ .port = 443 });
    defer addresses.deinit();

    // 3. Inspect candidate addresses
    for (addresses.items) |addr| {
        std.debug.print("Resolved IP: {f}:{d}\n", .{ addr, addr.port });
    }
}
```

### Zero-Config Standalone Resolution

If you do not already have a client instance, create a short-lived one:

```zig
var tmp = httpx.Client.init(allocator, io, .{});
defer tmp.deinit();
var addresses = try tmp.resolve("httpbun.com", .{});
defer addresses.deinit();
```

---

## 3. How Do I Configure DNS?

Client-wide DNS parameters are configured in `Client.init`:

```zig
var client = httpx.Client.init(allocator, io, .{
    .dnsCache = .{
        .enable = true,
        .ttlMs = 60_000,          // Positive cache lifetime (default 60s)
        .negativeTtlMs = 5_000,  // Failed resolution retry lifetime (default 5s)
        .maxEntries = 1024,       // Bounded cache capacity
    },
});
defer client.deinit();
```

---

## 4. How Do I Control IPv4 and IPv6?

By default, HTTPX performs dual-stack resolution (`.family = .any`). You can force IPv4-only or IPv6-only resolution per lookup using `ResolveOptions`:

### Force IPv4

```zig
var v4_addrs = try client.resolve("httpbun.com", .{
    .port = 443,
    .family = .ipv4,
});
defer v4_addrs.deinit();
```

### Force IPv6

```zig
var v6_addrs = try client.resolve("httpbun.com", .{
    .port = 443,
    .family = .ipv6,
});
defer v6_addrs.deinit();
```

Passing `.{}` retains the default dual-stack behavior.

---

## 5. How Does DNS Caching Work?

* **Positive Caching**: Successful resolutions are cached for `ttlMs` (default 60 seconds). Subsequent requests within this window return immediately with zero network delay.
* **Negative Caching**: Non-existent hostnames or failed lookups are cached for `negativeTtlMs` (default 5 seconds). This protects upstream DNS servers from repeated rapid failure storms while allowing transient outages to recover quickly.
* **Cache Bypass**: Pass `.useCache = false` on `client.resolve` to force a fresh lookup:
  ```zig
  var fresh = try client.resolve("httpbun.com", .{ .port = 443, .useCache = false });
  defer fresh.deinit();
  ```

---

## 6. How Does DNS Behave with Proxies and SOCKS5H?

### Direct Connection
DNS is resolved locally by the client before opening a TCP connection to the destination.

### HTTP Forward Proxy
The client connects to the proxy address. For HTTPS connections, HTTP `CONNECT host:port` is sent; the proxy performs DNS resolution for the remote target.

### SOCKS5 (`socks5://`)
The destination hostname is resolved **locally** on the client machine. The resulting IP address is sent in the SOCKS5 handshake (`ATYP=0x01` or `0x04`).

### SOCKS5H (`socks5h://`)
The destination hostname is **not resolved locally**. The unresolved domain name is sent directly to the SOCKS5 proxy (`ATYP=0x03` Domain Name). The SOCKS server resolves DNS remotely. This preserves privacy and bypasses local DNS poisoning or split-horizon firewalls.

---

## Advanced Resolver Control

For specialized applications that require manual DNS message encoding/decoding without an HTTP client:

* **OS Resolver**: `httpx.resolve.Resolver.init(allocator, io)`
* **RFC 1035 Packet Codec**: `httpx.dns.buildQuery`, `httpx.dns.parseResponse`
* **Raw UDP Query**: `httpx.dns.resolveA`, `httpx.dns.resolveAAAA`

See the [API: DNS](/api/dns) and [Protocol: DNS](/protocols/dns) references for complete signatures.
