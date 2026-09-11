# DNS API Reference

The DNS subsystem in HTTPX provides high-level client resolution methods, structured IP address types, thread-safe resolution caching, and low-level resolver controls.

---

## Architecture Overview

```text
                 httpx.Client
                      │
          ┌───────────┴───────────┐
          │                       │
      Normal API            Advanced API
          │                       │
    client.resolve()      httpx.resolve.Resolver
          │               httpx.dns.Cache
          └───────────┬───────────┘
                      │
              Canonical DNS
                Subsystem
```

---

## 1. High-Level Client API (Recommended)

Normal applications resolve hostnames through `httpx.Client`. The client manages allocator ownership, background I/O handles, and caching automatically.

### `client.resolve(host, options)`

Resolves a hostname or IP address to candidate addresses.

```zig
pub fn resolve(
    self: *Client,
    host: []const u8,
    opts: anytype,
) Error!ResolvedAddresses
```

* **Parameters**:
  * `host`: Hostname string (e.g., `"httpbun.com"`) or numeric IP literal (e.g., `"127.0.0.1"`, `"::1"`).
  * `opts`: Struct of `ResolveOptions` (`.port`, `.family`, `.useCache`, `.timeoutMs`) or `.{}` for defaults.
* **Returns**: `ResolvedAddresses` owning the returned slice.
* **Errors**: `error.DnsFailed`, `error.OutOfMemory`.

#### Default Options Semantics

Passing `.{}` uses documented HTTPX defaults:
* Dual-stack resolution (`.family = .any`) in system preference order (RFC 3484).
* In-memory cache enabled (`.useCache = true`).
* Default timeout inherited from client config.

### `client.resolveUrl(url_str, options)`

Extracts the hostname and effective port from a URL string (e.g. 80 for `http://`, 443 for `https://`) and resolves it:

```zig
var addrs = try client.resolveUrl("https://httpbun.com/get", .{});
defer addrs.deinit();
```

### `client.resolve(host, options)` without a long-lived client

If you need one-off resolution, create a short-lived client:

```zig
var tmp = httpx.Client.init(allocator, io, .{});
defer tmp.deinit();
var addrs = try tmp.resolve("httpbun.com", .{});
defer addrs.deinit();
```

---

## 2. DNS Options & Result Types

### `ResolveOptions`

Configuration passed to `client.resolve`:

```zig
pub const ResolveOptions = struct {
    family: AddressFamilyPreference = .any,
    useCache: bool = true,
    timeoutMs: ?u64 = null,
    port: u16 = 443,
};
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `family` | `AddressFamilyPreference` | `.any` | Address family filter (`.any`, `.ipv4`, `.ipv6`) |
| `useCache` | `bool` | `true` | When true, queries and updates the client's cache |
| `timeoutMs` | `?u64` | `null` | Optional lookup timeout override |
| `port` | `u16` | `443` | Port stamped onto every returned address |

### `AddressFamilyPreference`

```zig
pub const AddressFamilyPreference = enum {
    any,  // Dual-stack: both IPv4 and IPv6
    ipv4, // IPv4 addresses only
    ipv6, // IPv6 addresses only
};
```

### `ResolvedAddresses`

A collection of resolved addresses with a clear lifecycle API:

```zig
pub const ResolvedAddresses = struct {
    allocator: Allocator,
    items: []Address,

    pub fn deinit(self: *ResolvedAddresses) void;
    pub fn slice(self: *const ResolvedAddresses) []const Address;
    pub fn first(self: *const ResolvedAddresses) ?Address;
    pub fn len(self: *const ResolvedAddresses) usize;
    pub fn format(self: ResolvedAddresses, writer: anytype) !void;
};
```

* **Memory Ownership**: Caller owns `ResolvedAddresses` and must call `defer addresses.deinit();`.
* **Iteration**: Iterate over `addresses.items` or `addresses.slice()`.
* **Printing**: Implements native Zig formatting:
  ```zig
  std.debug.print("Addresses: {f}\n", .{addresses});
  ```

---

## 3. Client DNS Configuration

Client-wide DNS parameters are configured in `Client.Config.dnsCache` during `Client.init`:

```zig
pub const DnsCacheOptions = struct {
    enable: bool = true,
    ttlMs: i64 = 60_000,
    negativeTtlMs: i64 = 5_000,
    maxEntries: u32 = 1024,
};
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `enable` | `true` | Activates internal resolution caching |
| `ttlMs` | `60_000` (60s) | Lifetime for successful lookups |
| `negativeTtlMs` | `5_000` (5s) | Lifetime for failed lookups |
| `maxEntries` | `1024` | Maximum bounded entries before eviction |

---

## 4. Address Representation (`Address`)

Defined in `src/net/address.zig` and re-exported as `httpx.Address`:

```zig
pub const Address = struct {
    family: Family,
    bytes: [16]u8,
    port: u16,
    zone: u32 = 0,

    pub fn format(self: Address, writer: anytype) !void;
    pub fn formatBuf(self: *const Address, buf: []u8) []const u8;
    pub fn formatWithPort(self: *const Address, buf: []u8) []const u8;
    pub fn toString(self: Address, allocator: Allocator) ![]u8;
    pub fn isV4Mapped(self: *const Address) bool;
};
```

### Native Formatting

Formats addresses per RFC 5952:

```zig
// Native {f} format specifier:
std.debug.print("Target: {f}:{d}\n", .{ addr, addr.port });

// Zero-allocation buffer format:
var buf: [64]u8 = undefined;
const s = addr.formatBuf(&buf);

// Address with port:
var port_buf: [64]u8 = undefined;
const hp = addr.formatWithPort(&port_buf); // e.g. "127.0.0.1:443" or "[::1]:443"
```

---

## 5. Advanced Resolver API

For applications requiring direct control over low-level resolvers without instantiating an HTTP client:

### `httpx.resolve.Resolver`

Resolver owning its allocator and IO backend (`std.Io` first, OS fallback):

```zig
var resolver = httpx.resolve.Resolver.init(allocator, io);
const addrs = try resolver.lookup("httpbun.com", 443);
defer allocator.free(addrs);
```

### `httpx.dns` Wire Protocol

Low-level RFC 1035 message encoder and decoder for raw DNS packets:

* `buildQuery(allocator, id, name, qtype)`
* `parseResponse(allocator, msg)`
* `resolveA(allocator, io, name)`
* `resolveAAAA(allocator, io, name)`

---

## 6. Concurrency & Stampede Prevention

* **Thread-Safety**: Lookups through `httpx.Client` are fully thread-safe.
* **Single-Flight Coalescing**: When multiple threads or concurrent requests resolve the same domain concurrently, only a single network query is dispatched; subsequent callers await and share the result.
* **Non-Blocking Locks**: Network I/O is never executed while holding cache mutexes.

---

## 7. Proxy & SOCKS5 DNS Semantics

| Connection Type | Resolution Location | Behavior |
|-----------------|---------------------|----------|
| Direct | Local | Resolved via client DNS subsystem |
| HTTP Proxy (`http://`) | Local / Proxy | Proxy connects; TLS uses HTTP `CONNECT` |
| SOCKS5 (`socks5://`) | Local | Host resolved locally prior to connection |
| SOCKS5H (`socks5h://`) | Remote (Proxy) | Unresolved hostname sent to SOCKS5 proxy |

---

## 8. Platform Resolver Differences

* **Windows**: Direct native `ws2_32.GetAddrInfoW` API; requires no libc dependency.
* **Linux / macOS**: Uses libc `getaddrinfo` when linked with libc; std.Io HostName lookup when freestanding.
* **RFC 3484**: Both Windows and POSIX OS resolvers perform address sorting according to default address selection rules.
