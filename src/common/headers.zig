//! Case-insensitive HTTP header collection with CRLF injection protection.
//!
//! One authoritative implementation shared by client, server, HTTP/1,
//! HTTP/2, WebSocket, SSE, and authentication layers. Header names are
//! validated per RFC 9110 Section 5.1 (token format) and values per
//! RFC 9110 Section 5.5 (field-content). CRLF injection and null-byte
//! attacks are rejected at the API boundary.
//!
//! References:
//!   - RFC 9110 Section 5 — Request Header Fields, Response Header Fields
//!   - RFC 9110 Section 5.1 — Field Names (token format)
//!   - RFC 9110 Section 5.5 — Field Values (field-content)
//!   - RFC 9112 Section 2.2 — Field Name Case Normalization
//!   - RFC 7230 Section 3.2.6 — Token Definition

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    allocator: Allocator,
    entries: std.ArrayList(Header) = .empty,

    pub fn init(allocator: Allocator) Headers {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Headers) void {
        for (self.entries.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn set(self: *Headers, name: []const u8, value: []const u8) !void {
        try validateName(name);
        try validateValue(value);
        for (self.entries.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                if (h.value.len == value.len) {
                    @memcpy(@constCast(h.value), value);
                    return;
                }
                self.allocator.free(h.value);
                h.value = try self.allocator.dupe(u8, value);
                return;
            }
        }
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    /// Appends a header without replacing duplicates.
    pub fn append(self: *Headers, name: []const u8, value: []const u8) !void {
        try validateName(name);
        try validateValue(value);
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    /// Case-insensitive lookup; returns first match.
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.entries.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Returns all values for a header name (for multi-value headers).
    pub fn getAll(self: *const Headers, allocator: Allocator, name: []const u8) ![]const []const u8 {
        var results = std.ArrayList([]const u8).empty;
        errdefer results.deinit(allocator);
        for (self.entries.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                try results.append(allocator, h.value);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    pub fn remove(self: *Headers, name: []const u8) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.ascii.eqlIgnoreCase(self.entries.items[i].name, name)) {
                const h = self.orderedRemove(i);
                self.allocator.free(h.name);
                self.allocator.free(h.value);
                removed = true;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    fn orderedRemove(self: *Headers, i: usize) Header {
        const old = self.entries.items[i];
        _ = self.entries.orderedRemove(i);
        return old;
    }

    pub fn contains(self: *const Headers, name: []const u8) bool {
        return self.get(name) != null;
    }

    pub fn count(self: *const Headers) usize {
        return self.entries.items.len;
    }

    pub fn clear(self: *Headers) void {
        for (self.entries.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.entries.clearRetainingCapacity();
    }
};

/// Validates that a header name is a valid token (RFC 7230 Section 3.2.6).
fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 256) return error.InvalidHeader;
    for (name) |c| {
        if (c <= 32 or c >= 127) return error.InvalidHeader;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}', ' ', '\t' => return error.InvalidHeader,
            else => {},
        }
    }
}

/// Validates header value (RFC 7230 field-value: no CTL, no CR/LF).
fn validateValue(value: []const u8) !void {
    if (value.len > 8192) return error.InvalidHeader;
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
        if (c < 32 and c != '\t') return error.InvalidHeader;
        if (c == 127) return error.InvalidHeader;
    }
}

// Tests

test "set and get header case-insensitive" {
    const a = std.testing.allocator;
    var h = Headers.init(a);
    defer h.deinit();

    try h.set("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", h.get("content-type").?);
    try std.testing.expectEqualStrings("application/json", h.get("CONTENT-TYPE").?);
}

test "set replaces existing header" {
    const a = std.testing.allocator;
    var h = Headers.init(a);
    defer h.deinit();

    try h.set("X-Custom", "first");
    try h.set("x-custom", "second");
    try std.testing.expectEqualStrings("second", h.get("X-Custom").?);
    try std.testing.expectEqual(@as(usize, 1), h.count());
}

test "rejects CRLF injection in header value" {
    const a = std.testing.allocator;
    var h = Headers.init(a);
    defer h.deinit();

    try std.testing.expectError(error.InvalidHeader, h.set("X-Bad", "value\r\nInjected: true"));
    try std.testing.expectError(error.InvalidHeader, h.set("X-Bad", "value\nInjected"));
    try std.testing.expectError(error.InvalidHeader, h.set("X-Bad", "value\x00null"));
}

test "remove header" {
    const a = std.testing.allocator;
    var h = Headers.init(a);
    defer h.deinit();

    try h.set("X-Remove-Me", "gone");
    try std.testing.expect(h.contains("X-Remove-Me"));
    _ = h.remove("x-remove-me");
    try std.testing.expect(!h.contains("X-Remove-Me"));
}
