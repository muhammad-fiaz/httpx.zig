# Unix Domain Sockets Guide

HTTPX does not provide Unix domain socket (AF_UNIX) listeners or dialing.
`Server` binds TCP (`host`/`port`, with `.port = 0` for an ephemeral port)
and the client dials TCP. For same-machine IPC, bind to loopback instead:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
});
defer server.deinit();
const port = server.localPort();
```

See [TCP Local](/examples/tcp-local) for a loopback round trip and
[Simple Server](/examples/simple-server) for the standard lifecycle.
