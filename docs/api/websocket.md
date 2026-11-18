# API: WebSocket

RFC 6455 client and server over the shared HTTPX transport. Options are passed
inline as `.{}`; no option type is exported.

```zig
const httpx = @import("httpx");
```

## Server: `httpx.websocket.accept(ctx, .{})`

Called from a router handler. Validates the handshake, writes a `101` (or an
error response), marks the request as upgraded, and runs the session after the
handler returns.

```zig
fn handler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    try httpx.websocket.accept(ctx, .{
        .subprotocols = &.{"chat"},
        .callbacks = .{ .onMessage = echo },
    });
    return .{};
}
```

| Option | Default | Description |
|---|---|---|
| `subprotocols` | `&.{}` | Supported subprotocols, preference order. |
| `compression` | `false` | Negotiate permessage-deflate. |
| `originCheck` | `null` | `*const fn (*httpx.router.Context) bool`; false -> 403. |
| `auth` | `.{}` | `{ .scheme = .none/.basic/.bearer, .username, .password, .token, .realm }`. |
| `session` | `.{}` | Session limits/timeouts. |
| `callbacks` | `.{}` | `context`, `onOpen`, `onMessage`, `onClose`. |

`Callbacks`:

```zig
pub const Callbacks = struct {
    context: ?*anyopaque = null,
    onOpen: ?*const fn (*Session, ?*anyopaque) anyerror!void = null,
    onMessage: ?*const fn (*Session, *Message, ?*anyopaque) anyerror!void = null,
    onClose: ?*const fn (*Session, CloseInfo, ?*anyopaque) void = null,
};
```

`onMessage` receives a borrowed message. Call `message.deinit()` to keep it.

## Client

### `httpx.websocket.Client.init(allocator, io, .{})`

```zig
var client = try httpx.websocket.Client.init(allocator, io, .{
    .connectMs = 10_000,
    .auth = .{ .scheme = .bearer, .token = "secret" },
});
defer client.deinit();

var session = try client.connect("ws://127.0.0.1:8080/ws");
defer session.deinit();
```

| Option | Default | Description |
|---|---|---|
| `headers` | `&.{}` | Extra handshake headers (`Header{ .name, .value }`). |
| `subprotocols` | `&.{}` | Offered subprotocols. |
| `compression` | `false` | Offer permessage-deflate. |
| `connectMs` | `10000` | TCP + TLS + handshake deadline. |
| `maxHead` | `32768` | Response header limit. |
| `verify` | `.caBundle` | TLS verify mode. |
| `caPem` | `null` | Custom CA bundle. |
| `auth` | `.{}` | Basic/Bearer client credentials. |
| `session` | `.{}` | Session limits/timeouts. |

### `httpx.websocket.connect(allocator, io, url, .{})`

One-shot form of the same operation. Returns an owned `Session`.

## `httpx.websocket.Session`

| Method | Contract |
|---|---|
| `sendText(text)` | Sends one text message; fragments automatically. |
| `sendBinary(bytes)` | Sends one binary message. |
| `receiveText()` | Returns owned `?[]u8`; `null` after close. |
| `receiveBinary()` | Returns owned `?[]u8`; `null` after close. |
| `ping(payload)` / `pong(payload)` | Sends a control frame. |
| `close(code, reason)` | Performs the close handshake. |
| `deinit()` | Releases buffers and the client transport. |

Session options (`session = .{}`):

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

Errors: `NotOpen`, `ConnectionClosed`, `IoError`, `ProtocolError`,
`MessageTooLarge`, `FrameTooLarge`, `InvalidUtf8`, `InvalidCloseCode`,
`OutOfMemory`. Handshake failures surface as `error.HandshakeFailed`.

## `httpx.websocket.protocol`

Low-level codecs for custom transports: `Handshake.buildUpgradeRequest`,
`Handshake.computeAccept`, `Handshake.validateUpgradeResponse`,
`Frame.buildFrameHeader`, `Frame.parseFrameHeader`, `Frame.applyMask`, and
`Frame.Opcode`.

## Related

* [Guide: WebSockets](/guide/websockets)
* [Example: WebSocket Server](/examples/websocket-server)
* [Example: WebSocket Client](/examples/websocket-client)
* [Example: TCP Local](/examples/tcp-local)
