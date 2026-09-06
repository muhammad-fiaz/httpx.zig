# DNS Configuration

Demonstrates DNS resolver configuration: TTL settings, bounded caches, IPv4/IPv6 preferences, and client integration.

## Demo Program

```zig
// Default config
var resolver = httpx.dns.DNSResolver.init(allocator, .{});

// Short TTL
var short = httpx.dns.DNSResolver.init(allocator, .{
    .positive_ttl_ms = 5000,
    .negative_ttl_ms = 1000,
});

// Bounded LRU cache
var bounded = httpx.dns.DNSResolver.init(allocator, .{
    .max_cache_entries = 64,
});

// IPv4 only
var ipv4 = httpx.dns.DNSResolver.init(allocator, .{
    .prefer_ipv6 = false,
});
```

## Run

```
zig build run-all-dns_configuration
```

## Checklist

- [x] Default configuration
- [x] Custom TTL settings
- [x] Bounded cache (LRU eviction)
- [x] IPv4-only preference
- [x] IPv6-preferred preference
- [x] Cache-only mode
- [x] Client integration
