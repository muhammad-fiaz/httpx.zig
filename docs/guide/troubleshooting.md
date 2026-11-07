# Troubleshooting

## `file exists in modules 'X' and 'X0'`

A dependency is being resolved twice with different options, which makes
Zig treat it as two module instances. Declare shared dependencies once
and resolve them with empty options:

```zig
const httpx_dep = b.dependency("httpx", .{});
```

Avoid re-passing `.target`/`.optimize` through the root dependency
options when the dependency already resolves them. See
[Zig issue #36694](https://codeberg.org/ziglang/zig/issues/36694).

## UDP bind failure (`error.UdpBindFailed` / `ACCESS_DENIED`)

Some hosted Windows environments deny local UDP binds, which makes
HTTP/3 and socket tests fail at bind time even though the code is
correct. Prefer filtered test runs there:

```bash
zig build test -Dtest-filter="GraphQL"
```

## GraphQL definitions inside function bodies return empty results

Declare `Type`, `Query`, and `Mutation` at namespace scope (file
top-level or a namespace struct). A definition created inside a
function body loses static storage in Zig's comptime model and its
fields misbehave at runtime.

## HTTP/3 port not listening

With `.port = 0`, the HTTP/3 endpoint may fall back to its own UDP port
when the TCP-chosen ephemeral port is rejected for UDP. Dial
`server.http3.port()`:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .http3 = true,
    .tls = .{ .certificatePem = certPem, .privateKeyPem = keyPem },
});
const port = server.http3.port() orelse return error.Http3Disabled;
```
