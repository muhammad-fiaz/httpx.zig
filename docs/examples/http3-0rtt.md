# Example: HTTP/3 0-RTT

Demonstrates TLS 1.3 session resumption with 0-RTT early data over HTTP/3 and
QUIC. The first request performs a full 1-RTT handshake and the server issues a
`NewSessionTicket`. The client stores the ticket in its session cache, closes
the first QUIC connection gracefully, and then resumes a new connection with
0-RTT early data.

## Complete Example

```zig
//! HTTP/3 TLS 1.3 0-RTT Early Data Resumption Example.
//!
//! Run with: `zig build run-http3-0rtt`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // One init owns the listener, router, and HTTP/3 endpoint.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .protocols = .{ .http3 = true },
        .tls = .{
            .certificatePem = demoCertPem,
            .privateKeyPem = demoKeyPem,
        },
    });
    defer server.deinit();

    try server.get("/initial", initialHandler);
    try server.get("/early-data", earlyHandler);

    const port = server.http3.port() orelse return error.Http3Disabled;

    const Runner = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const srvThread = try std.Thread.spawn(.{}, Runner.run, .{&server});

    // One init owns the pool, DNS cache, and session cache.
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/initial", .{port});

    var res1 = try client.get(url1, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
        .timeoutMs = 15_000,
    });
    defer res1.deinit();

    // Inspect the cached ticket before resuming.
    var cached = client.session.cache("127.0.0.1", port, .{
        .alpn = "h3",
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
    });
    if (cached) |*c| {
        defer c.deinit(allocator);
    } else {
        server.requestShutdown();
        srvThread.join();
        return error.MissingSessionTicket;
    }

    // Close the first QUIC session gracefully. `close` drains the pool and
    // sends CONNECTION_CLOSE, releasing the server's accept loop immediately.
    client.close();
    var settled: usize = 0;
    while (server.isHttp3Ready() and settled < 200) : (settled += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    const url2 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/early-data", .{port});
    var res2 = client.get(url2, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
        .earlyData = .{ .enabled = true },
        .timeoutMs = 15_000,
    }) catch |err| {
        std.debug.print("Second request failed: {any}\n", .{err});
        server.requestShutdown();
        srvThread.join();
        return err;
    };
    defer res2.deinit();

    server.requestShutdown();
    srvThread.join();
}
```

The handlers used by the example return small JSON bodies:

```zig
fn initialHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ok", .mode = "1-RTT-initial" });
}

fn earlyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ok", .mode = "0-RTT-early-data" });
}
```

## What It Demonstrates

| Step | Behavior |
| --- | --- |
| 1 | Full 1-RTT HTTP/3 handshake and a request over the resulting QUIC connection. |
| 2 | `NewSessionTicket` captured into `client.session` with `maxEarlyData`. |
| 3 | Graceful `client.close()` sends an application `CONNECTION_CLOSE`. |
| 4 | A fresh connection resumes the ticket and sends the request as 0-RTT early data. |

Safe methods (`GET`, `HEAD`, `OPTIONS`) use 0-RTT automatically once a ticket is
cached. Replay-sensitive methods require `.earlyData = .{ .enabled = true,
.allowUnsafeMethods = true }`.

Server-side ticket keys and the anti-replay cache live on `httpx.Server`, not
on an individual connection, so tickets remain valid across reconnects for the
lifetime of the server. Configure explicit keys with `.tls = .{ .ticketKeys =
... }` when running more than one server instance behind the same identity.

## How to Run

```bash
zig build run-http3-0rtt
```

## Expected Output

```text
=================================================================
   HTTPX - TLS 1.3 0-RTT Early Data Resumption over HTTP/3 & QUIC
=================================================================

Listening on https://127.0.0.1:52139

Step 1: Sending first request (cold connection, 1-RTT)...
  -> Status: 200
  -> Body: {"status":"ok","mode":"1-RTT-initial"}
  -> NewSessionTicket received and cached with maxEarlyData=16384.

Step 2: Verified session cache entry: ALPN='h3', maxEarlyData=16384

Step 3: Sending second request with 0-RTT early data enabled...
  -> Status: 200
  -> Body: {"status":"ok","mode":"0-RTT-early-data"}
  -> 0-RTT early data request verified successfully!

Step 4: Safe methods (GET, HEAD, OPTIONS) use 0-RTT by default.
        Replay-sensitive methods require allowUnsafeMethods=true.

=== TLS 1.3 0-RTT Early Data Demonstration Completed Successfully ===
```

The port varies per run. During the graceful close the server logs
`peer closed the connection: code=256 application=true ... reason=client closing`,
which is the expected application `CONNECTION_CLOSE` from `client.close()`.

## Related

* [HTTP/3 Protocol Guide](/guide/http3)
* [HTTP/3 Client Runtime](/examples/http3-client-runtime)
* [HTTP/3 Server Runtime](/examples/http3-server-runtime)
