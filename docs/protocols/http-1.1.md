# HTTP/1.1 Protocol

RFC 9112 defines HTTP/1.1, the foundational workhorse protocol of the World Wide Web. HTTP/1.1 introduced persistent TCP connections, chunked transfer encoding, pipelining, and virtual hosting via mandatory `Host` headers.

## Overview

HTTP/1.1 addresses the connection latency issues of HTTP/1.0 by keeping TCP connections open across multiple requests (persistent connections or "Keep-Alive"). This eliminates the repeated three-way TCP handshake and TLS negotiation penalty on subsequent requests to the same origin.

## Wire Message Format

### Request
```http
GET /api/users?page=1 HTTP/1.1

Host: api.example.com

User-Agent: httpx/0.2.0

Accept: application/json

Accept-Encoding: gzip, br, zstd

Connection: keep-alive



```

### Response
```http
HTTP/1.1 200 OK

Date: Mon, 07 Sep 2026 08:30:00 GMT

Content-Type: application/json; charset=utf-8

Transfer-Encoding: chunked

Connection: keep-alive



1a

{"users":[{"id":1,"name":"Alice"}]}

0



```

## Key HTTP/1.1 Features in HTTPX

1. **Persistent Connection Pooling**: The HTTPX client retains idle TCP sockets in an internal pool. Sockets are reused automatically bounded by `pool.maxConnections`, `pool.maxPerHost`, and `pool.idleTimeoutMs`.
2. **Chunked Transfer Encoding**: Allows sending and receiving streaming dynamic payloads of unknown length without pre-computing a `Content-Length` header.
3. **100 Continue Handling**: The client automatically handles `Expect: 100-continue` for large file uploads, verifying server authorization before transmitting large request bodies.
4. **Header Normalization**: Headers are parsed case-insensitively while preserving RFC 9110 formatting.

## Client Usage Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .pool = .{ .maxConnections = 32 },
    });
    defer client.deinit();

    // Explicit HTTP/1.1 request
    var response = try client.get("http://httpbun.com/get", .{
        .httpVersion = .http11,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Protocol Version: {s}\n", .{@tagName(response.version)});
}
```

## Related

* [Protocol: HTTP/1.0](/protocols/http-1.0)
* [Protocol: HTTP/2](/protocols/http-2)
* [Guide: Requests](/guide/requests)
* [Example: Dedicated HTTP/1.1 Client](/examples/http11-client)
