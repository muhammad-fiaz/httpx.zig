# DNS Resolution

Demonstrates DNS helpers: IP address detection, `host:port` parsing, hostname resolution, and TTL-based DNS caching.

## Demo Program

```zig
// Check if a string is an IP address
httpx.isIpAddress("127.0.0.1");       // true
httpx.isIp4Address("example.com");    // false
httpx.isIp6Address("::1");            // true

// Parse "host:port" strings
const parsed = httpx.parseHostAndPort("127.0.0.1:8080", 0);

// Resolve a single address
const address = httpx.resolveAddress(allocator, "127.0.0.1", 80);

// Resolve all candidate addresses
const all_addrs = httpx.resolveAllAddresses(allocator, "127.0.0.1", 443);

// DNS cache with TTL-based expiration
var cache = httpx.dns.DnsCache.init(allocator);
const cached = try cache.resolve("127.0.0.1", 80);
```

## Run

```
zig build run-all-dns_example
```

## Checklist

- [x] `isIpAddress` correctly identifies IPv4, IPv6, and hostnames
- [x] `parseHostAndPort` splits "host:port" and "[::1]:port" correctly
- [x] `resolveAddress` returns a single `Address`
- [x] `resolveAllAddresses` returns all candidate addresses
- [x] `DnsCache` returns the same result on repeated lookups
- [x] Convenience function summary prints at the end
