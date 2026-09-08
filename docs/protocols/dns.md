# DNS Resolution Protocol & Architecture

HTTPX features a centralized, robust DNS resolution subsystem supporting IPv4 (A records), IPv6 (AAAA records), RFC 1035 packet encoding/decoding, TTL-aware caching, and Happy Eyeballs address ordering.

## Resolution Pipeline

```text
Request Hostname -> DNS Cache Lookup
                    │
                    ├── Valid cached entry found?
                    │      Yes: Return cached address list
                    │      No:  Check for in-flight query (Single-Flight)
                    │             │
                    │             ├── Existing query active?
                    │             │     Yes: Await in-flight result (No stampede)
                    │             │     No:  Invoke OS Resolver (getaddrinfo)
                    │             │            │
                    │             │            ├── Store in DNS Cache with TTL
                    │             │            └── Return candidate Address list
```

## Protocol Features

* **RFC 1035 Message Engine**: Full binary encoder and decoder for DNS header, questions, answers, and name compression pointers.
* **Positive & Negative TTL Caching**: Respects positive TTL (default 60s) and negative failure TTL (default 5s).
* **Single-Flight Coalescing**: Concurrent requests to the same hostname share a single network query.
* **Dual-Stack Sorting (RFC 3484)**: System default address ordering with Happy Eyeballs fallback.
* **Thread-Safe**: Safely accessible across concurrent client requests without lock contention during network I/O.

## Client Configuration

```zig
var client = httpx.Client.init(allocator, io, .{
    .dnsCache = .{
        .enable = true,
        .ttlMs = 60_000,
        .negativeTtlMs = 5_000,
        .maxEntries = 1024,
    },
});
defer client.deinit();
```

## High-Level Resolution

```zig
var addrs = try client.resolve("httpbun.com", 443, .{});
defer addrs.deinit();
```

## Related

* [Guide: DNS Resolution](/guide/dns)
* [API: DNS](/api/dns)
* [Example: DNS Cache](/examples/dns-cache)
* [Example: DNS Configuration](/examples/dns-configuration)
