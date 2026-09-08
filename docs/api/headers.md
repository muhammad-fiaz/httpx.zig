# API: Headers

The `httpx.headers` module provides the canonical, case-insensitive HTTP header collection used throughout HTTPX client requests, client responses, and server context.

## Overview

HTTP header names are case-insensitive per RFC 9110. `httpx.Headers` normalizes header lookups while preserving efficient in-place storage.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hdrs = httpx.Headers.init(allocator);
    defer hdrs.deinit();

    try hdrs.set("Content-Type", "application/json");
    try hdrs.add("Accept", "text/html");
    try hdrs.add("Accept", "application/json");

    // Case-insensitive lookup
    if (hdrs.get("content-type")) |ct| {
        std.debug.print("Content-Type: {s}\n", .{ct});
    }

    var it = hdrs.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: {s}\n", .{ entry.name, entry.value });
    }
}
```

## Structure

```zig
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    allocator: Allocator,
    items: std.ArrayList(Header),

    pub fn init(allocator: Allocator) Headers;
    pub fn deinit(self: *Headers) void;
    pub fn add(self: *Headers, name: []const u8, value: []const u8) !void;
    pub fn set(self: *Headers, name: []const u8, value: []const u8) !void;
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8;
    pub fn delete(self: *Headers, name: []const u8) bool;
    pub fn has(self: *const Headers, name: []const u8) bool;
    pub fn clear(self: *Headers) void;
    pub fn clone(self: *const Headers) !Headers;
    pub fn iterator(self: *const Headers) Iterator;
};
```

## Standard Header Constants

`httpx.headers` exposes canonical compile-time constants for standard HTTP headers:

* `httpx.headers.CONTENT_TYPE`: `"content-type"`
* `httpx.headers.CONTENT_LENGTH`: `"content-length"`
* `httpx.headers.AUTHORIZATION`: `"authorization"`
* `httpx.headers.ACCEPT`: `"accept"`
* `httpx.headers.ACCEPT_ENCODING`: `"accept-encoding"`
* `httpx.headers.CACHE_CONTROL`: `"cache-control"`
* `httpx.headers.COOKIE`: `"cookie"`
* `httpx.headers.SET_COOKIE`: `"set-cookie"`
* `httpx.headers.HOST`: `"host"`
* `httpx.headers.LOCATION`: `"location"`

## Methods

### `Headers.init(allocator)`
Initializes an empty header container using the provided memory allocator.

### `headers.set(name, value) !void`
Replaces any existing header matching `name` (case-insensitively) with `value`, or appends it if absent.

### `headers.add(name, value) !void`
Appends a new header entry without removing existing matching names, enabling multi-valued headers such as `Set-Cookie` and `Accept`.

### `headers.get(name) ?[]const u8`
Finds the first value matching `name` case-insensitively. Returns `null` if not found.

### `headers.delete(name) bool`
Removes all header entries matching `name`. Returns `true` if any entries were removed.

### `headers.has(name) bool`
Returns `true` if one or more entries with the given name exist.

### `headers.deinit() void`
Frees all duplicated header names, values, and the underlying list.

## Related

* [API: Request](/api/request)
* [API: Response](/api/response)
* [Security: Headers](/security/headers)
