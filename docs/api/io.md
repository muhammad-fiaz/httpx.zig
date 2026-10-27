# I/O Context API

`httpx` owns one `std.Io.Threaded` per top-level client, server, or pool and shares it across sockets, TLS, and protocol I/O. The helper lives in `src/common/io.zig`.

## IoContext

- `init(allocator)` — allocate and initialize a `std.Io.Threaded`, returning an `IoContext`
- `deinit()` — shut down the threaded backend and release it
- `io` — the `std.Io` value passed to socket, TLS, and timing APIs
- `threaded` — the owned `*std.Io.Threaded`
- `allocator` — the allocator used for the context itself

```zig
var ctx = try httpx.IoContext.init(allocator);
defer ctx.deinit();

const io = ctx.io;
```

Create one context for the lifetime of a `Client`, `Server`, or `Pool`; do not initialize a new `IoContext` per request or per connection. `deinit()` must run only after all operations using `ctx.io` have finished.

Root-level aliases: `httpx.IoContext` and `httpx.ioCtx`.

## Time Helpers

`httpx.clock` wraps the `std.Io` clock:

- `millisNow(io)` — milliseconds since the Unix epoch (`i64`)
- `monotonicMillis(io)` — monotonic milliseconds (`i64`)
- `sleepMillis(io, ms)` — sleep on the supplied `std.Io` (returns `void`)

```zig
httpx.clock.sleepMillis(ctx.io, 10);
```

## URI and Percent Encoding

`httpx.uri` provides RFC 3986 URI parsing and percent-encoding helpers:

- `parse(input)` — parse into a `Uri` whose fields reference `input`
- `Uri.authority(buf)` — format `host[:port]`, with IPv6 brackets
- `Uri.effectivePort()` / `defaultPort(scheme)` — resolve the default service port
- `percentDecode(buf, input)` — decode into a caller buffer; malformed escapes are copied verbatim
- `percentEncode(buf, input)` — encode into a caller buffer, keeping RFC 3986 unreserved bytes
- `percentEncodeAlloc(allocator, input)` — encode into an owned slice
- `hasPathTraversal(decodedPath)` — reject `.`/`..`, NUL, and drive/UNC prefixes

```zig
var buf: [64]u8 = undefined;
const decoded = try httpx.uri.percentDecode(&buf, "hello%20world");

const encoded = try httpx.uri.percentEncodeAlloc(allocator, "hello world");
defer allocator.free(encoded);
```

For Base64 and hexadecimal conversion, use `std.base64` and `std.fmt` directly; `httpx` does not export wrapper types for them.
