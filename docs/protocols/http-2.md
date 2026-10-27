# HTTP/2 Protocol

> **Status: native implementation with documented limits.** The repository has
> HTTP/2 framing, HPACK, a client transport, and server connection handlers.
> The client supports h2c prior knowledge and TLS with `h2` ALPN; the server
> supports h2c and TLS when its ALPN configuration selects `h2`. The server
> keeps one state per concurrent stream and answers them independently, and the
> transport client can keep several requests in flight on one connection
> (`beginRequest` / `awaitResponse`). The high-level client hands out pooled
> connections exclusively, so it runs one exchange at a time per connection.
>
> Both directions handle informational (1xx) responses, trailers,
> `content-length` framing, CONNECT requests, CONTINUATION chains,
> connection/stream flow control, and graceful or error GOAWAY. Server push,
> priority-based scheduling, and extended CONNECT (RFC 8441) are not
> implemented; extended CONNECT pseudo-headers are recognized but rejected
> because the setting stays disabled.

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
1. **`h2` via TLS ALPN**: The high-level client uses the native TLS 1.3 transport and requests `h2`; the server agrees or the request fails with `AlpnNegotiationFailed`.
2. **`h2c` via Prior Knowledge**: On cleartext TCP, the client sends the 24-byte magic connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) followed immediately by a `SETTINGS` frame.

## Message Semantics

The session layer enforces RFC 9113 message framing in both directions:

* **Informational responses** (`100`-`199`, except `101`) may precede the
  final response. They are validated and discarded rather than delivered to
  the application; `101` and any 1xx block carrying `content-length` or
  `END_STREAM` reset the stream.
* **Content-Length** values are digits-only and must agree across duplicates.
  A body length mismatch at `END_STREAM` resets the stream with
  `PROTOCOL_ERROR`; `HEAD`, `204`, `205`, and `304` responses are subject to
  the body-forbidden rules.
* **Trailers** are delivered as a final HEADERS block that must carry
  `END_STREAM`, may appear only once, and may not contain pseudo-headers or
  `content-length`.
* **CONNECT** requests use `:method` and `:authority` only. Extended CONNECT
  is recognized structurally but rejected while `SETTINGS_ENABLE_CONNECT_PROTOCOL`
  is disabled.
* **Authority** is exposed to transport handlers as a `host` field when the
  client did not send an explicit `host`, so HTTP/1-style handlers and
  `Context.host()` behave consistently.

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
