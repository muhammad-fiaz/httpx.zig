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
    try hdrs.append("Accept", "text/html");
    try hdrs.append("Accept", "application/json");

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
    entries: std.ArrayList(Header),

    pub fn init(allocator: Allocator) Headers;
    pub fn deinit(self: *Headers) void;
    pub fn set(self: *Headers, name: []const u8, value: []const u8) !void;
    pub fn append(self: *Headers, name: []const u8, value: []const u8) !void;
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8;
    pub fn getAll(self: *const Headers, allocator: Allocator, name: []const u8) ![]const []const u8;
    pub fn remove(self: *Headers, name: []const u8) bool;
    pub fn contains(self: *const Headers, name: []const u8) bool;
    pub fn count(self: *const Headers) usize;
    pub fn clear(self: *Headers) void;
};
```

## Header Names

There are no predeclared header-name constants; use plain string literals
(`"content-type"`, `"content-length"`, `"authorization"`, `"accept"`,
`"accept-encoding"`, `"cache-control"`, `"cookie"`, `"set-cookie"`,
`"host"`, `"location"`). All lookups are case-insensitive.

## Methods

### `Headers.init(allocator)`
Initializes an empty header container using the provided memory allocator.

### `headers.set(name, value) !void`
Replaces any existing header matching `name` (case-insensitively) with `value`, or appends it if absent.

### `headers.append(name, value) !void`
Appends a new header entry without removing existing matching names, enabling multi-valued headers such as `Set-Cookie` and `Accept`.

### `headers.get(name) ?[]const u8`
Finds the first value matching `name` case-insensitively. Returns `null` if not found.

### `headers.getAll(name, allocator) ![]const []const u8`
Returns all values for a header name (for multi-value headers).

### `headers.remove(name) bool`
Removes all header entries matching `name`. Returns `true` if any entries were removed.

### `headers.contains(name) bool`
Returns `true` if one or more entries with the given name exist.

### `headers.count() usize`
Returns the number of stored header entries.

### `headers.deinit() void`
Frees all duplicated header names, values, and the underlying list.

## Related

* [API: Request](/api/request)
* [API: Response](/api/response)
* [Security: Headers](/security/headers)
