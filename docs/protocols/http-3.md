# HTTP/3 Protocol

> Status: implemented for reliable paths. The high-level client performs a
> real QUIC + TLS 1.3 handshake (ALPN `h3`, verified chain) over UDP; the
> high-level server can serve routes over the same transport. Loopback
> integration tests cover the client/server path, including dynamic QPACK.
> QUIC ACK tracking, PTO/loss recovery, NewReno congestion control, flow
> control, transport parameters, and 0-RTT resumption are wired in.
>
> Deliberate limits: the high-level HTTP/3 client performs one request per
> QUIC connection (no pooling), and the QUIC driver does not handle
> HelloRetryRequest or connection migration. There is no server
> push/datagrams support, and the high-level API buffers request/response
> bodies rather than streaming them. Retry/token validation, v1/v2 version
> negotiation, and 1-RTT key updates are implemented.

## Motivation

While HTTP/2 eliminated head-of-line blocking at the application level, TCP head-of-line blocking remained: when a single TCP packet is dropped, all interleaved HTTP/2 streams stall until the missing segment is retransmitted. HTTP/3 resolves this fundamentally by running over QUIC and UDP.

## Architecture Comparison

```text
       HTTP/1.1 & HTTP/2                  HTTP/3
   +-----------------------+     +-----------------------+
   |  HTTP/1.1  |  HTTP/2  |     |        HTTP/3         |
   +-----------------------+     +-----------------------+
   |         TLS           |     |         QPACK         |
   +-----------------------+     +-----------------------+
   |         TCP           |     |     QUIC (TLS 1.3)    |
   +-----------------------+     +-----------------------+
   |          IP           |     |          UDP          |
   +-----------------------+     +-----------------------+
```

## Core Advantages

1. **Zero Transport Head-of-Line Blocking**: Each stream is delivered independently. Packet loss in stream A has zero impact on stream B.
2. **0-RTT Handshakes**: Combines transport connection setup and TLS 1.3 encryption keys into a single round trip.
3. **Connection Migration**: Mobile devices moving between Wi-Fi and Cellular networks maintain downloads seamlessly using 64-bit Connection IDs.
4. **QPACK Header Compression (RFC 9204)**: Dynamic table compression designed specifically for out-of-order packet delivery without deadlock.

## Client Usage Example

`client.get` with `.httpVersion = .http3` performs a real QUIC + TLS 1.3
handshake (ALPN `h3`, verified chain) over UDP, with QPACK dynamic-table
encoding, response trailers, and loss recovery. Runnable end to end in
`examples/http3Client.zig`:

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

    var response = try client.get("https://127.0.0.1:8443/", .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = ca_pem },
        .timeoutMs = 15_000,
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
}
```

## Related

* [Protocol: QUIC](/protocols/quic)
* [Guide: HTTP/3](/guide/http3)
* [Example: HTTP/3 Client](/examples/http3-example)
