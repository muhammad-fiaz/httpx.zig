# WebSockets Guide

`httpx.zig` implements RFC 6455 end to end: the opening handshake, masked
frames, fragmentation, control frames, UTF-8 validation, close handshakes,
subprotocols, permessage-deflate, TLS, and HTTP connection takeover.

Everything lives under `httpx.websocket`:

| Entry point | Purpose |
|---|---|
| `httpx.websocket.accept(ctx, .{})` | Upgrade a router handler to a WebSocket session. |
| `httpx.websocket.Client.init(allocator, io, .{})` | Reusable client for `ws://` and `wss://`. |
| `httpx.websocket.connect(allocator, io, url, .{})` | One-shot client connection. |
| `httpx.websocket.Session` | Full-duplex frame session. |
| `httpx.websocket.protocol` | Low-level handshake and frame codecs. |

## Server

Return from the route handler after calling `accept`. The HTTP worker hands the
connection to the session and stops writing HTTP bytes, so the same TCP
connection continues as WebSocket.

```zig
try server.get("/ws", wsHandler);

fn wsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    try httpx.websocket.accept(ctx, .{
        .callbacks = .{
            .onOpen = onOpen,
            .onMessage = onMessage,
            .onClose = onClose,
            .context = null,
        },
    });
    return .{};
}

fn onMessage(
    session: *httpx.websocket.Session,
    message: *httpx.websocket.Message,
    _: ?*anyopaque,
) anyerror!void {
    switch (message.kind) {
        .text => try session.sendText(message.data),
        .binary => try session.sendBinary(message.data),
    }
}
```

Handshake failures are written on the wire before the connection closes:

| Condition | Response |
|---|---|
| Missing or invalid upgrade headers | `400 Bad Request` |
| Wrong `Sec-WebSocket-Version` | `426 Upgrade Required` |
| Failed authentication | `401 Unauthorized` with `WWW-Authenticate` |
| Rejected origin | `403 Forbidden` |

### Server options

All options are passed inline; the option types are not exported.

```zig
httpx.websocket.accept(ctx, .{
    .subprotocols = &.{ "chat", "superchat" },
    .compression = true,
    .originCheck = checkOrigin,
    .auth = .{ .scheme = .bearer, .token = "secret" },
    .session = .{
        .maxMsgBytes = 4 * 1024 * 1024,
        .readMs = 60_000,
        .autoPong = true,
    },
});
```

| Field | Default | Meaning |
|---|---|---|
| `subprotocols` | `&.{}` | Server-supported subprotocols, in preference order. |
| `compression` | `false` | Negotiate permessage-deflate when offered. |
| `originCheck` | `null` | `fn (*httpx.router.Context) bool`; false produces 403. |
| `auth` | `.{}` | `scheme` (`none`, `basic`, `bearer`), credentials, realm. |
| `session` | `.{}` | Frame/message limits and timeouts. |
| `callbacks` | `.{}` | `context`, `onOpen`, `onMessage`, `onClose`. |

Authentication reuses the HTTP Basic and Bearer helpers. Credentials are
checked before the upgrade and compared in constant time.

## Client

```zig
var client = try httpx.websocket.Client.init(allocator, io, .{
    .connectMs = 10_000,
    .subprotocols = &.{"chat"},
    .auth = .{ .scheme = .bearer, .token = "secret" },
    .headers = &.{.{ .name = "X-Trace", .value = "abc" }},
});
defer client.deinit();

var session = try client.connect("wss://example.com/ws");
defer session.deinit();

try session.sendText("hello");
if (try session.receiveText()) |reply| {
    defer allocator.free(reply);
    std.log.info("reply: {s}", .{reply});
}
try session.close(1000, "done");
```

The client resolves DNS, connects TCP, performs TLS for `wss://`, validates the
handshake, and owns the socket. `Session.deinit()` releases everything; a
handshake failure returns an error without leaking the connection.

| Field | Default | Meaning |
|---|---|---|
| `headers` | `&.{}` | Extra handshake headers as `{ .name, .value }`. |
| `subprotocols` | `&.{}` | Offered subprotocols, in preference order. |
| `compression` | `false` | Offer permessage-deflate. |
| `connectMs` | `10000` | TCP + TLS + handshake deadline. |
| `maxHead` | `32768` | Response header limit. |
| `verify` | `.caBundle` | TLS verification: `.caBundle`, `.system`, `.none`, `.pinned`. |
| `caPem` | `null` | Custom CA bundle. |
| `auth` | `.{}` | Client credentials for Basic or Bearer. |
| `session` | `.{}` | Frame/message limits and timeouts. |

## Session

| Method | Description |
|---|---|
| `sendText` / `sendBinary` | Send one complete message (fragmented as needed). |
| `receiveText` / `receiveBinary` | Receive one message; `null` after close. |
| `ping` / `pong` | Send a control frame. |
| `close(code, reason)` | Start the RFC 6455 close handshake. |
| `deinit` | Release buffers and (client side) the underlying transport. |

Inbound payloads returned by `receiveText`/`receiveBinary` are caller-owned and
must be freed with the session allocator.

Session limits:

| Field | Default |
|---|---|
| `maxMsgBytes` | 16 MiB |
| `maxFrame` | 16 MiB |
| `readBuf` | 8 KiB |
| `readMs` | 30000 |
| `writeMs` | 30000 |
| `closeMs` | 5000 |
| `autoPong` | `true` |
| `maxInflate` | 16 MiB |

## Connection takeover

HTTPX routes every accepted connection through one transport. A WebSocket
upgrade reuses that connection: buffered bytes read past the request head are
preserved, the HTTP layer skips its response writer, and only one component
owns the final close. This is the mechanism behind GitHub Discussion #68.

```
TCP accept -> HTTP parse -> router -> websocket.accept -> Session
                                                 |
                                    same socket, no second connect
```

## Low-level primitives

`httpx.websocket.protocol` remains available for custom transports:

```zig
var accept: [28]u8 = undefined;
httpx.websocket.computeAccept(clientKey, &accept);

var hdr: [10]u8 = undefined;
const n = httpx.websocket.protocol.Frame.buildFrameHeader(
    &hdr, true, .text, payload.len, null,
);
```

Client-to-server frames must be masked; server-to-client frames must not be.

## Examples

* [WebSocket Server](/examples/websocket-server)
* [WebSocket Client](/examples/websocket-client)
* [API: WebSocket](/api/websocket)

## References

* RFC 6455 — The WebSocket Protocol
* RFC 7692 — Compression Extensions for WebSocket
