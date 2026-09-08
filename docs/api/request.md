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
        .timeout_ms = 5000,
    });
    defer resp.deinit();
}
```

## Request Options Fields

```zig
pub const RequestOptions = struct {
    method: httpx.Method = .GET,
    headers: []const Header = &.{},
    query: []const QueryParam = &.{},
    body: []const u8 = "",
    json: anytype = null,
    form: anytype = null,
    cookie: ?[]const u8 = null,
    basic_auth: ?BasicAuth = null,
    bearer_auth: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    tls: ?TlsOptions = null,
    follow_redirects: bool = true,
    max_redirects: u8 = 5,
    httpVersion: ?HttpVersion = null,
    http10: ?bool = null,
    http11: ?bool = null,
    http2: ?bool = null,
    http3: ?bool = null,
};
```

| Field | Type | Description |
|---|---|---|
| `method` | `Method` | HTTP verb (.GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS) |
| `headers` | `[]const Header` | Slice of request header key-value pairs |
| `query` | `[]const QueryParam` | URL query parameters automatically encoded |
| `body` | `[]const u8` | Raw payload bytes |
| `json` | `anytype` | Zig value serialized to JSON with `application/json` Content-Type |
| `form` | `anytype` | URL-encoded form data |
| `cookie` | `?[]const u8` | Value for `Cookie` header |
| `basic_auth` | `?BasicAuth` | Username and password for Basic Authorization |
| `bearer_auth` | `?[]const u8` | Token for Bearer Authorization |
| `proxy` | `?[]const u8` | Proxy URI overriding client default |
| `tls` | `?TlsOptions` | Custom TLS configuration for this request |
| `timeout_ms` | `?u64` | Request deadline in milliseconds |
| `follow_redirects` | `bool` | Whether to automatically follow 3xx redirects (default: true) |
| `max_redirects` | `u8` | Maximum redirect hops before error (default: 5) |
| `httpVersion` | `?HttpVersion` | Protocol version (.auto, .http10, .http11, .http2, .http3) |
| `http10` | `?bool` | Fast toggle to force HTTP/1.0 |
| `http11` | `?bool` | Fast toggle to force HTTP/1.1 |
| `http2` | `?bool` | Fast toggle to force HTTP/2 |
| `http3` | `?bool` | Fast toggle to force HTTP/3 |

## Related

* [API: Response](/api/response)
* [API: Client](/api/client)
* [Guide: Requests](/guide/requests)
