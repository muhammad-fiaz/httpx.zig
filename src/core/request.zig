//! HTTP Request Representation for httpx.zig
//!
//! Provides the Request structure and RequestBuilder for constructing
//! HTTP requests with a fluent API. Features include:
//!
//! - Support for all HTTP methods and versions
//! - Header management with automatic Content-Length
//! - Body handling for JSON, form data, and binary
//! - Request serialization for wire format

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("types.zig");
const Headers = @import("headers.zig").Headers;
const HeaderName = @import("headers.zig").HeaderName;
const Uri = @import("uri.zig").Uri;
const PercentEncoding = @import("../util/encoding.zig").PercentEncoding;

/// HTTP request representation.
pub const Request = struct {
    allocator: Allocator,
    method: types.Method,
    uri: Uri,
    version: types.Version = .HTTP_1_1,
    headers: Headers,
    body: ?[]const u8 = null,
    body_owned: bool = false,
    custom_method: ?[]const u8 = null,
    query_owned: bool = false,
    context: ?*anyopaque = null,

    const Self = @This();

    /// Creates a new request with the given method and URL.
    pub fn init(allocator: Allocator, method: types.Method, url: []const u8) !Self {
        const uri = try Uri.parse(url);
        var headers = Headers.init(allocator);

        if (uri.host) |host| {
            try headers.set(HeaderName.HOST, host);
        }

        return .{
            .allocator = allocator,
            .method = method,
            .uri = uri,
            .headers = headers,
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
        if (self.query_owned) {
            if (self.uri.query) |q| {
                self.allocator.free(q);
            }
        }
    }

    /// Sets the request body with ownership.
    pub fn setBody(self: *Self, body: []const u8) !void {
        if (self.body_owned) {
            if (self.body) |b| {
                self.allocator.free(b);
            }
        }
        self.body = try self.allocator.dupe(u8, body);
        self.body_owned = true;

        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
        try self.headers.set(HeaderName.CONTENT_LENGTH, len_str);
    }

    /// Sets the request body as JSON with appropriate headers.
    pub fn setJson(self: *Self, body: []const u8) !void {
        try self.headers.set(HeaderName.CONTENT_TYPE, "application/json");
        try self.setBody(body);
    }

    /// Sets a request header.
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.set(name, value);
    }

    /// Appends a URL query parameter to the request URI.
    ///
    /// The key and value are percent-encoded before being added.
    pub fn addQueryParam(self: *Self, key: []const u8, value: []const u8) !void {
        const enc_key = try PercentEncoding.encode(self.allocator, key);
        defer self.allocator.free(enc_key);
        const enc_value = try PercentEncoding.encode(self.allocator, value);
        defer self.allocator.free(enc_value);

        const previous = self.uri.query;
        const next_query = if (previous) |q|
            try std.fmt.allocPrint(self.allocator, "{s}&{s}={s}", .{ q, enc_key, enc_value })
        else
            try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ enc_key, enc_value });

        if (self.query_owned) {
            if (previous) |q| {
                self.allocator.free(q);
            }
        }

        self.uri.query = next_query;
        self.query_owned = true;
    }

    /// Returns the host from the URI.
    pub fn getHost(self: *const Self) ?[]const u8 {
        return self.uri.host;
    }

    /// Returns the effective port.
    pub fn getPort(self: *const Self) u16 {
        return self.uri.effectivePort();
    }

    /// Returns true if the request uses TLS.
    pub fn isTls(self: *const Self) bool {
        return self.uri.isTls();
    }

    /// Serializes the request to HTTP/1.1 wire format.
    pub fn serialize(self: *const Self, writer: anytype) !void {
        const method_str = if (self.method == .CUSTOM)
            self.custom_method orelse "CUSTOM"
        else
            self.method.toString();

        const path = self.uri.path;
        const version_str = self.version.toString();

        try writer.print("{s} {s}", .{ method_str, path });
        if (self.uri.query) |q| {
            try writer.print("?{s}", .{q});
        }
        try writer.print(" {s}\r\n", .{version_str});

        try self.headers.serialize(writer);
        try writer.writeAll("\r\n");

        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }

    /// Serializes to an allocated buffer.
    pub fn toSlice(self: *const Self, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayListUnmanaged(u8){};
        const writer = buffer.writer(allocator);
        try self.serialize(writer);
        return buffer.toOwnedSlice(allocator);
    }
};

/// Fluent builder for constructing requests.
pub const RequestBuilder = struct {
    allocator: Allocator,
    method: types.Method = .GET,
    url: ?[]const u8 = null,
    version: types.Version = .HTTP_1_1,
    headers: Headers,
    body: ?[]const u8 = null,

    const Self = @This();

    /// Creates a new request builder.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .headers = Headers.init(allocator),
        };
    }

    /// Releases builder resources.
    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }

    /// Sets the HTTP method.
    pub fn setMethod(self: *Self, method: types.Method) *Self {
        self.method = method;
        return self;
    }

    /// Sets the request URL.
    pub fn setUrl(self: *Self, url: []const u8) *Self {
        self.url = url;
        return self;
    }

    /// Sets the HTTP version.
    pub fn setVersion(self: *Self, version: types.Version) *Self {
        self.version = version;
        return self;
    }

    /// Adds a header.
    pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !*Self {
        try self.headers.append(name, value);
        return self;
    }

    /// Sets the request body.
    pub fn setBody(self: *Self, body: []const u8) *Self {
        self.body = body;
        return self;
    }

    /// Sets a JSON body with appropriate Content-Type.
    pub fn setJsonBody(self: *Self, body: []const u8) !*Self {
        _ = try self.addHeader(HeaderName.CONTENT_TYPE, "application/json");
        self.body = body;
        return self;
    }

    /// Builds the final request.
    pub fn build(self: *Self) !Request {
        const url = self.url orelse return error.MissingUrl;
        var request = try Request.init(self.allocator, self.method, url);
        request.version = self.version;

        for (self.headers.entries.items) |h| {
            try request.headers.append(h.name, h.value);
        }

        if (self.body) |b| {
            try request.setBody(b);
        }

        return request;
    }
};

test "Request initialization" {
    const allocator = std.testing.allocator;
    var request = try Request.init(allocator, .GET, "https://example.com/api");
    defer request.deinit();

    try std.testing.expectEqual(types.Method.GET, request.method);
    try std.testing.expectEqualStrings("example.com", request.uri.host.?);
}

test "Request with body" {
    const allocator = std.testing.allocator;
    var request = try Request.init(allocator, .POST, "https://example.com/api");
    defer request.deinit();

    try request.setJson("{\"key\":\"value\"}");
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("application/json", request.headers.get(HeaderName.CONTENT_TYPE).?);
}

test "Request builder" {
    const allocator = std.testing.allocator;
    var builder = RequestBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.setMethod(.POST).setUrl("https://example.com/api");
    _ = try builder.addHeader("X-Custom", "value");
    _ = builder.setBody("test body");

    var request = try builder.build();
    defer request.deinit();

    try std.testing.expectEqual(types.Method.POST, request.method);
}

test "Request serialization" {
    const allocator = std.testing.allocator;
    var request = try Request.init(allocator, .GET, "https://example.com/api");
    defer request.deinit();

    const serialized = try request.toSlice(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(mem.startsWith(u8, serialized, "GET /api HTTP/1.1\r\n"));
}

test "Request addQueryParam" {
    const allocator = std.testing.allocator;
    var request = try Request.init(allocator, .GET, "https://example.com/search");
    defer request.deinit();

    try request.addQueryParam("q", "zig lang");
    try request.addQueryParam("page", "1");

    try std.testing.expectEqualStrings("q=zig%20lang&page=1", request.uri.query.?);

    const serialized = try request.toSlice(allocator);
    defer allocator.free(serialized);
    try std.testing.expect(mem.indexOf(u8, serialized, "GET /search?q=zig%20lang&page=1 HTTP/1.1") != null);
}
