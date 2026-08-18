//! HTTP Response Representation for httpx.zig
//!
//! Provides the Response structure and ResponseBuilder for handling
//! HTTP responses. Features include:
//!
//! - Status code and reason phrase management
//! - Header access with common helpers
//! - Body handling with JSON parsing support
//! - Response building for servers

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const list_writer = @import("../io/list_writer.zig");
const common = @import("../data/common.zig");

const types = @import("types.zig");
const Headers = @import("headers.zig").Headers;
const HeaderName = @import("headers.zig").HeaderName;
const Status = @import("status.zig").Status;
const json_util = @import("../data/json.zig");
/// HTTP response representation.
pub const Response = struct {
    allocator: Allocator,
    version: types.Version = .HTTP_1_1,
    status: Status,
    headers: Headers,
    body: ?[]const u8 = null,
    body_owned: bool = false,
    streaming_done: bool = false,
    trailers: ?Headers = null,

    const Self = @This();

    /// Creates a new response with the given status code.
    pub fn init(allocator: Allocator, status_code: u16) Self {
        return .{
            .allocator = allocator,
            .status = Status.fromCode(status_code),
            .headers = Headers.init(allocator),
        };
    }

    /// Releases all allocated memory.
    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        if (self.body_owned) {
            if (self.body) |b| {
                self.allocator.free(b);
            }
        }
        if (self.trailers) |*t| {
            t.deinit();
        }
    }

    /// Returns true if the response indicates success (2xx).
    pub fn ok(self: *const Self) bool {
        return self.status.isSuccess();
    }

    /// Returns true if the response is a redirect (3xx).
    pub fn isRedirect(self: *const Self) bool {
        return self.status.isRedirect();
    }

    /// Returns true if the response is an error (4xx or 5xx).
    pub fn isError(self: *const Self) bool {
        return self.status.isError();
    }

    /// Returns the response body as text.
    pub fn text(self: *const Self) ?[]const u8 {
        return self.body;
    }

    /// Parses the response body as JSON into the given type.
    /// The caller must call `deinit()` on the returned `std.json.Parsed(T)`.
    pub fn json(self: *const Self, comptime T: type, options: std.json.ParseOptions) !std.json.Parsed(T) {
        const body = self.body orelse return error.NoBody;
        const result = std.json.parseFromSlice(T, self.allocator, body, options);
        return result;
    }

    /// Zero-copy parse: returns T with strings pointing into the response body.
    /// The response must outlive the returned value.
    pub fn jsonBorrowed(self: *const Self, comptime T: type, options: std.json.ParseOptions) !T {
        const body = self.body orelse return error.NoBody;
        return std.json.parseFromSliceLeaky(T, self.allocator, body, options);
    }

    /// Alias for `jsonBorrowed` — parses JSON with strings borrowing from the response body.
    pub const jsonLeaky = jsonBorrowed;

    /// Parses the response body as a dynamic JSON value.
    /// The caller must call `deinit()` on the returned `ParsedJson`.
    pub fn jsonValue(self: *const Self) !json_util.ParsedJson {
        const body = self.body orelse return error.NoBody;
        return json_util.Json.parseValue(self.allocator, body);
    }

    /// Returns true if the Content-Type header indicates JSON.
    pub fn isJson(self: *const Self) bool {
        const ct = self.contentType() orelse return false;
        return json_util.isJsonContentType(ct);
    }

    /// Returns the Location header value for redirects.
    pub fn location(self: *const Self) ?[]const u8 {
        return self.headers.get(HeaderName.LOCATION);
    }

    /// Returns the Content-Type header value.
    pub fn contentType(self: *const Self) ?[]const u8 {
        return self.headers.get(HeaderName.CONTENT_TYPE);
    }

    /// Returns the Content-Length header value.
    pub fn contentLength(self: *const Self) ?u64 {
        return self.headers.getContentLength();
    }

    /// Returns true if the response uses chunked transfer encoding.
    pub fn isChunked(self: *const Self) bool {
        return self.headers.isChunked();
    }

    /// Returns a specific header value.
    pub fn header(self: *const Self, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Sets the trailers for this response (used by HTTP/2).
    pub fn setTrailers(self: *Self, trailers: Headers) void {
        if (self.trailers) |*t| {
            t.deinit();
        }
        self.trailers = trailers;
    }

    /// Creates a redirect response and sets the `Location` header.
    pub fn redirect(allocator: Allocator, status_code: u16, redirect_to: []const u8) !Self {
        var resp = Self.init(allocator, status_code);
        try resp.headers.set(HeaderName.LOCATION, redirect_to);
        return resp;
    }

    /// Creates a plain-text response with Content-Type and Content-Length set.
    pub fn fromText(allocator: Allocator, status_code: u16, text_body: []const u8) !Self {
        var resp = Self.init(allocator, status_code);
        try resp.headers.set(HeaderName.CONTENT_TYPE, "text/plain; charset=utf-8");
        resp.body = try allocator.dupe(u8, text_body);
        resp.body_owned = true;

        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{text_body.len}) catch unreachable;
        try resp.headers.set(HeaderName.CONTENT_LENGTH, len_str);
        return resp;
    }

    /// Creates a JSON response from a serializable value.
    pub fn fromJson(allocator: Allocator, status_code: u16, value: anytype) !Self {
        var resp = Self.init(allocator, status_code);
        try resp.headers.set(HeaderName.CONTENT_TYPE, "application/json");
        resp.body = try json_util.Json.stringify(allocator, value);
        resp.body_owned = true;

        if (resp.body) |b| {
            var len_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{b.len}) catch unreachable;
            try resp.headers.set(HeaderName.CONTENT_LENGTH, len_str);
        }
        return resp;
    }

    /// Serializes the response to HTTP/1.1 wire format.
    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.print("{s} {d} {s}\r\n", .{
            self.version.toString(),
            self.status.code,
            self.status.phrase,
        });

        try self.headers.serialize(writer);
        try writer.writeAll("\r\n");

        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }

    /// Serializes to an allocated buffer.
    pub fn toSlice(self: *const Self, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        const writer = list_writer.init(allocator, &buffer);
        try self.serialize(writer);
        return buffer.toOwnedSlice(allocator);
    }

    pub fn setCookie(self: *Self, name: []const u8, value: []const u8, options: common.CookieOptions) !void {
        const header_value = try common.buildSetCookieHeader(self.allocator, name, value, options);
        try self.headers.append(HeaderName.SET_COOKIE, header_value);
    }

    pub fn getCookies(self: *const Self, allocator: Allocator) ![][]const u8 {
        return self.headers.getAll(HeaderName.SET_COOKIE, allocator);
    }

    pub fn getCookie(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.name, HeaderName.SET_COOKIE)) continue;
            const eq_idx = std.mem.indexOfScalar(u8, entry.value, '=') orelse continue;
            if (std.ascii.eqlIgnoreCase(entry.value[0..eq_idx], name)) {
                return entry.value;
            }
        }
        return null;
    }
};

/// Fluent builder for constructing responses (server-side).
pub const ResponseBuilder = struct {
    allocator: Allocator,
    status_code: u16 = 200,
    headers: Headers,
    body_data: ?[]const u8 = null,
    body_owned: bool = false,

    const Self = @This();

    /// Creates a new response builder.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .headers = Headers.init(allocator),
        };
    }

    /// Releases builder resources.
    pub fn deinit(self: *Self) void {
        self.clearOwnedBody();
        self.headers.deinit();
    }

    fn clearOwnedBody(self: *Self) void {
        if (self.body_owned) {
            if (self.body_data) |b| {
                self.allocator.free(b);
            }
        }
        self.body_data = null;
        self.body_owned = false;
    }

    /// Sets the status code.
    pub fn status(self: *Self, code: u16) *Self {
        self.status_code = code;
        return self;
    }

    /// Adds a response header.
    pub fn header(self: *Self, name: []const u8, value: []const u8) !*Self {
        try self.headers.append(name, value);
        return self;
    }

    /// Sets the response body.
    pub fn body(self: *Self, data: []const u8) *Self {
        self.clearOwnedBody();
        self.body_data = data;
        return self;
    }

    /// Sets a JSON body with appropriate Content-Type.
    pub fn json(self: *Self, value: anytype) !*Self {
        _ = try self.header(HeaderName.CONTENT_TYPE, "application/json");
        self.clearOwnedBody();
        const serialized = try json_util.Json.stringify(self.allocator, value);
        self.body_data = serialized;
        self.body_owned = true;
        return self;
    }

    /// Sets an HTML body with appropriate Content-Type.
    pub fn html(self: *Self, content: []const u8) !*Self {
        _ = try self.header(HeaderName.CONTENT_TYPE, "text/html; charset=utf-8");
        self.clearOwnedBody();
        self.body_data = content;
        return self;
    }

    /// Sets a plain text body with appropriate Content-Type.
    pub fn text(self: *Self, content: []const u8) !*Self {
        _ = try self.header(HeaderName.CONTENT_TYPE, "text/plain; charset=utf-8");
        self.clearOwnedBody();
        self.body_data = content;
        return self;
    }

    pub fn setCookie(self: *Self, name: []const u8, value: []const u8, options: common.CookieOptions) !*Self {
        const header_value = try common.buildSetCookieHeader(self.allocator, name, value, options);
        try self.headers.append(HeaderName.SET_COOKIE, header_value);
        return self;
    }

    /// Builds the final response.
    pub fn build(self: *Self) !Response {
        var response = Response.init(self.allocator, self.status_code);
        errdefer response.deinit();

        for (self.headers.entries.items) |h| {
            try response.headers.append(h.name, h.value);
        }

        if (self.body_data) |b| {
            if (self.body_owned) {
                // Transfer ownership for allocated JSON payloads.
                response.body = b;
                response.body_owned = true;
                self.body_data = null;
                self.body_owned = false;
            } else {
                response.body = try self.allocator.dupe(u8, b);
                response.body_owned = true;
            }

            if (!response.headers.isChunked()) {
                var len_buf: [32]u8 = undefined;
                const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{b.len}) catch unreachable;
                try response.headers.set(HeaderName.CONTENT_LENGTH, len_str);
            }
        }

        return response;
    }
};

test "Response initialization" {
    const allocator = std.testing.allocator;
    var response = Response.init(allocator, 200);
    defer response.deinit();

    try std.testing.expect(response.ok());
    try std.testing.expectEqual(@as(u16, 200), response.status.code);
}

test "Response status checks" {
    const allocator = std.testing.allocator;

    var ok = Response.init(allocator, 200);
    defer ok.deinit();
    try std.testing.expect(ok.ok());
    try std.testing.expect(!ok.isError());

    var redirect = Response.init(allocator, 301);
    defer redirect.deinit();
    try std.testing.expect(redirect.isRedirect());

    var error_resp = Response.init(allocator, 404);
    defer error_resp.deinit();
    try std.testing.expect(error_resp.isError());
}

test "ResponseBuilder" {
    const allocator = std.testing.allocator;
    var builder = ResponseBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.status(201);
    _ = try builder.header("X-Custom", "value");
    _ = builder.body("test content");

    var response = try builder.build();
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 201), response.status.code);
    try std.testing.expect(response.body != null);
}

test "ResponseBuilder json ownership transfer" {
    const allocator = std.testing.allocator;
    var builder = ResponseBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.json(.{ .ok = true });
    var response = try builder.build();
    defer response.deinit();

    try std.testing.expectEqualStrings("application/json", response.contentType().?);
    try std.testing.expect(response.text() != null);
}

test "Response serialization" {
    const allocator = std.testing.allocator;
    var response = Response.init(allocator, 200);
    defer response.deinit();

    const serialized = try response.toSlice(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(mem.startsWith(u8, serialized, "HTTP/1.1 200 OK\r\n"));
}

test "Response redirect constructor" {
    const allocator = std.testing.allocator;
    var response = try Response.redirect(allocator, 302, "http://httpbun.com/new");
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 302), response.status.code);
    try std.testing.expectEqualStrings("http://httpbun.com/new", response.location().?);
}

test "Response fromText and fromJson constructors" {
    const allocator = std.testing.allocator;

    var text_resp = try Response.fromText(allocator, 200, "hello");
    defer text_resp.deinit();
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", text_resp.contentType().?);
    try std.testing.expectEqualStrings("hello", text_resp.text().?);

    var json_resp = try Response.fromJson(allocator, 201, .{ .ok = true });
    defer json_resp.deinit();
    try std.testing.expectEqualStrings("application/json", json_resp.contentType().?);
    try std.testing.expect(json_resp.text() != null);
}
