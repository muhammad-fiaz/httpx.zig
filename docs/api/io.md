# I/O API

`httpx` takes `std.Io` explicitly on every `init(allocator, io, .{})` and
reuses it internally. Obtain one threaded context for the program:

```zig
const io = std.Io.Threaded.global_single_threaded.io();
```

Do not create a new context per request or per connection.

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
- `hasPathTraversal(decodedPath)` — reject `.`/`..`, NUL, and drive/UNC prefixes

```zig
var buf: [64]u8 = undefined;
const decoded = try httpx.uri.percentDecode(&buf, "hello%20world");

const encoded = try httpx.uri.percentEncode(&buf, "hello world");
```

For Base64 and hexadecimal conversion, use `std.base64` and `std.fmt` directly; `httpx` does not export wrapper types for them.
