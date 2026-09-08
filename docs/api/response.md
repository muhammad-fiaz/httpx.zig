# API: Response

The `httpx.Response` struct is the canonical response container representing status code, protocol version, response headers, and body payload.

## Overview

Every HTTP client request returns an allocated `Response`. Callers own the response and must call `defer resp.deinit()` to release body and header allocations.

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

    const resp = try client.get("https://httpbin.org/json", .{});
    defer resp.deinit();

    std.debug.print("Status: {d}\n", .{resp.status});
    std.debug.print("Content-Type: {s}\n", .{resp.header("content-type") orelse "unknown"});

    // Parse JSON into typed struct
    const UserData = struct {
        slideshow: struct {
            title: []const u8,
            author: []const u8,
        },
    };
    const parsed = try resp.json(UserData);
    std.debug.print("Title: {s}\n", .{parsed.slideshow.title});
}
```

## Structure

```zig
pub const Response = struct {
    allocator: Allocator,
    status: u16,
    version: HttpVersion,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Response) void;
    pub fn header(self: *const Response, name: []const u8) ?[]const u8;
    pub fn text(self: *const Response) []const u8;
    pub fn bytes(self: *const Response) []const u8;
    pub fn json(self: *const Response, comptime T: type) !T;
    pub fn jsonAlloc(self: *const Response, comptime T: type, allocator: Allocator) !std.json.Parsed(T);
    pub fn html(self: *const Response) !httpx.parsing.Document;
    pub fn xml(self: *const Response) !httpx.parsing.Document;
    pub fn document(self: *const Response) !httpx.parsing.Document;
    pub fn contentType(self: *const Response) []const u8;
    pub fn writeTo(self: *const Response, writer: anytype) !void;
    pub fn reader(self: *const Response) std.Io.Reader;
    pub fn isInformational(self: *const Response) bool;
    pub fn isSuccess(self: *const Response) bool;
    pub fn isRedirect(self: *const Response) bool;
    pub fn isClientError(self: *const Response) bool;
    pub fn isServerError(self: *const Response) bool;
};
```

## Methods

### `resp.deinit() void`
Frees header allocations and body bytes owned by the response.

### `resp.header(name: []const u8) ?[]const u8`
Performs a case-insensitive lookup across response headers. Returns `null` if the header is absent.

### `resp.text() []const u8`
Returns the body slice as a string. The slice is valid until `resp.deinit()`.

### `resp.json(comptime T: type) !T`
Decodes the response body into the target Zig type `T` using Zig's standard JSON parser.

### `resp.html() !httpx.parsing.Document`
Parses the body into an HTML/DOM document tree using the internal Tree-sitter engine. Caller must call `document.deinit()`.

### `resp.xml() !httpx.parsing.Document`
Parses the body into an XML document tree. Caller must call `document.deinit()`.

### `resp.document() !httpx.parsing.Document`
Parses auto-detected document from body and `content-type` header.

### `resp.bytes() []const u8`
Returns body as bytes.

### `resp.contentType() []const u8`
`content-type` header value or empty string.

### `resp.writeTo(writer) !void`
Streams body bytes to any writer.

### `resp.reader() std.Io.Reader`
Reader over the body for streaming.

### `resp.isSuccess() bool` / `isRedirect()` / `isClientError()` / `isServerError()` / `isInformational()`
Status-range helpers. Use `resp.status` for the raw code.

## Related

* [API: Request](/api/request)
* [API: Client](/api/client)
* [Guide: Responses](/guide/responses)
