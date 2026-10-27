# Unix Domain Socket Example

HTTPX does not provide Unix domain socket (AF_UNIX) listeners or dialing:
`Server` binds TCP (`host`/`port`, `.port = 0` for ephemeral) and the client
dials TCP champions. For same-machine IPC, bind to loopback instead:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
});
defer server.deinit();
const port = server.localPort();
```

## Expected Output

```text
(no output - snippet only binds an ephemeral loopback port)
```

This snippet produces no printed output; the ephemeral loopback port varies per run. Loopback only, no external prerequisites.

See [TCP Local](/examples/tcp-local) for a loopback round trip and
[Simple Server](/examples/simple-server) for the standard lifecycle.
