# HTTP/2 Protocol

RFC 9113 defines HTTP/2, introducing a binary framing layer that multiplexes multiple concurrent request/response streams over a single TCP connection, eliminating head-of-line blocking at the transport layer.

## Architecture

Unlike HTTP/1.x plaintext protocols, HTTP/2 is a binary framed protocol. All HTTP semantics (methods, status codes, URIs, and headers) remain identical, but messages are divided into discrete typed frames:

```text
+-----------------------------------------------+
|                 Length (24)                   |
+---------------+---------------+---------------+
|   Type (8)    |   Flags (8)   |
+-+-------------+---------------+-------------------------------+
|R|                 Stream Identifier (31)                      |
+=+=============================================================+
|                   Frame Payload (0...)                      ...
+---------------------------------------------------------------+
```

### Core Frame Types
* `HEADERS`: Transmits request and response headers with HPACK compression.
* `DATA`: Transmits body payloads (payload chunks can be interleaved across active streams).
* `SETTINGS`: Negotiates connection parameters (initial window size, max frame size, max concurrent streams).
* `WINDOW_UPDATE`: Implements stream-level and connection-level credit flow control.
* `PING`: Measures round-trip time and verifies connection liveness.
* `GOAWAY`: Signals graceful connection shutdown.
* `RST_STREAM`: Cancels an individual stream without closing the underlying TCP socket.

## HPACK Header Compression (RFC 7541)

HTTP/2 uses HPACK compression to drastically reduce header overhead:
* **Static Table**: Pre-defined table of 61 common header names and values.
* **Dynamic Table**: Stores newly encountered headers in an in-memory sliding window.
* **Huffman Encoding**: Compresses individual header literals with static Huffman codes.

## Prior Knowledge vs ALPN

HTTPX supports two methods for establishing HTTP/2 connections:
1. **`h2` via TLS ALPN**: During TLS 1.3/1.2 handshake, the client requests `h2` and the server agrees.
2. **`h2c` via Prior Knowledge**: On cleartext TCP, the client sends the 24-byte magic connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) followed immediately by a `SETTINGS` frame.

## Client Usage Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var response = try client.get("https://nghttp2.org/httpbin/get", .{
        .httpVersion = .http2,
    });
    defer response.deinit();

    std.debug.print("HTTP/2 Status: {d}\n", .{response.status});
}
```

## Related

* [Guide: HTTP/2](/guide/http2)
* [Protocol: ALPN](/protocols/alpn)
* [Example: HTTP/2 Client](/examples/http2-example)
