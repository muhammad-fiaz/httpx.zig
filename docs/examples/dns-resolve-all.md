# DNS Resolve All

Demonstrates resolving all candidate addresses for a hostname, including IP literals and multi-address resolution.

## Demo Program

```zig
// IP literal passthrough
const addr = httpx.resolveAddress(allocator, "127.0.0.1", 80);

// Resolve all candidates
const all = httpx.resolveAllAddresses(allocator, "127.0.0.1", 443);

// IPv6 literal
const ipv6 = httpx.resolveAddress(allocator, "::1", 80);
```

## Run

```
zig build run-all-dns_resolve_all
```

## Checklist

- [x] IP literal passthrough
- [x] IPv6 literal support
- [x] resolve vs resolveAll behavior
- [x] Address enumeration
