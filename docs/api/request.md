# API: Request

HTTPX represents outgoing requests in two forms: the high-level methods accept an inline `.{}` options value, while fluent construction uses `httpx.client.requestBuilder` (payload type `httpx.client.requestPayload`). Incoming server requests are exposed through `httpx.router.Context`, not this request type.

## Overview

Requests feature a unified options model. Method convenience functions (`client.get`, `client.post`, etc.) automatically construct and dispatch a canonical request.

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

    // Canonical request via fetch
    var resp = try client.fetch("https://httpbun.com/post", .{
        .method = .POST,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
        .json = .{ .id = 42, .name = "Antigravity" },
        .timeoutMs = 5000,
    });
    defer resp.deinit();
}
```

## Request Options Fields

Pass these fields inline as the final `.{}` argument to request methods. The
client accepts duck-typed extras such as `multipart` through `anytype` opts.
Typed values passed as `.json = value` are serialized by the high-level
wrappers. The fluent payload type is `httpx.client.requestPayload`.

| Field | Type | Description |
|---|---|---|
| `url` | `[]const u8` | Request URL (required) |
| `method` | `?Method` | Explicit method for generic `request`/`fetch` |
| `headers` | `[]const Header` | Slice of request header name/value pairs |
| `query` | `[]const Header` | URL query parameters automatically encoded |
| `body` | `?[]const u8` | Raw payload bytes |
| `json` | `?[]const u8` | JSON string body (sets Content-Type) |
| `form` | `?[]const u8` | Pre-encoded `application/x-www-form-urlencoded` body |
| `text` | `?[]const u8` | Plain-text body |
| `contentType` | `?[]const u8` | Explicit Content-Type override |
| `cookie` | `?[]const u8` | Value for `Cookie` header |
| `basicAuth` | `?[]const u8` | `"user:pass"` for Basic Authorization |
| `bearerAuth` | `?[]const u8` | Token for Bearer Authorization |
| `proxy` | `?[]const u8` | Proxy URL overriding client default |
| `tls` | inline `.{}` | Custom TLS configuration for this request |
| `timeoutMs` | `?u64` | Request deadline in milliseconds |
| `maxResponseSize` | `?usize` | Max response body size for this request |
| `followRedirects` | `?bool` | Whether to automatically follow 3xx redirects |
| `maxRedirects` | `?u8` | Maximum redirect hops before error |
| `allowLfLineEndings` | `bool` | Accept bare LF line endings in the response |
| `httpVersion` | `?HttpVersion` | Protocol version (`.auto`, `.http10`, `.http11`, `.http2`, `.http3`) |
| `http10` | `?bool` | Fast toggle to force HTTP/1.0 |
| `http11` | `?bool` | Fast toggle to force HTTP/1.1 |
| `http2` | `?bool` | Fast toggle to force HTTP/2 |
| `http3` | `?bool` | Fast toggle to force HTTP/3 |
| `earlyData` | inline `.{}` | Per-request 0-RTT settings |
| `bodySource` | `?httpx.BodySource` | Streaming upload source for HTTP/1.1, HTTP/2, and HTTP/3 |

## Related

* [API: Response](/api/response)
* [API: Client](/api/client)
* [Guide: Requests](/guide/requests)
