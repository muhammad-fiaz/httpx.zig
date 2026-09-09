# API: Request

The `httpx.Request` struct represents an outgoing HTTP request sent by the client or an incoming request received by the server.

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
    const resp = try client.fetch("https://httpbin.org/post", .{
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

Matches `httpx.RequestOptions` (`src/client/client.zig`). The client
accepts these fields directly (plus duck-typed extras such as `multipart`
handled via `anytype` opts).

```zig
pub const RequestOptions = struct {
    url: []const u8,
    method: ?Method = null,
    headers: []const Header = &.{},
    query: []const Header = &.{},
    body: ?[]const u8 = null,
    json: ?[]const u8 = null,
    form: ?[]const u8 = null,
    text: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    basicAuth: ?[]const u8 = null,
    bearerAuth: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    tls: ?TlsOptions = null,
    timeoutMs: ?u64 = null,
    maxResponseSize: ?usize = null,
    followRedirects: ?bool = null,
    maxRedirects: ?u8 = null,
    allowLfLineEndings: bool = false,
    httpVersion: ?HttpVersion = null,
    http10: ?bool = null,
    http11: ?bool = null,
    http2: ?bool = null,
    http3: ?bool = null,
};
```

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
| `tls` | `?TlsOptions` | Custom TLS configuration for this request |
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

## Related

* [API: Response](/api/response)
* [API: Client](/api/client)
* [Guide: Requests](/guide/requests)
