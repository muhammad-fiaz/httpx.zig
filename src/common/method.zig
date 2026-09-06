//! HTTP request method types shared by client and server.
//!
//! Defines the nine standard HTTP methods from RFC 9110 Section 9.1.
//! Each method carries defined safety, idempotency, and request-body
//! semantics that this library uses to make routing and caching
//! decisions.
//!
//! References:
//!   - RFC 9110 Section 9.1 — Method Definitions
//!   - RFC 9110 Section 9.2.1 — Safe Methods (GET, HEAD, OPTIONS, TRACE)
//!   - RFC 9110 Section 9.2.2 — Idempotent Methods (PUT, DELETE)

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    pub fn toString(self: Method) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Method {
        inline for (@typeInfo(Method).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) {
                return @enumFromInt(f.value);
            }
        }
        return null;
    }

    pub fn isSafe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            else => false,
        };
    }

    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE, .PUT, .DELETE => true,
            else => false,
        };
    }

    pub fn hasBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }
};

test "method roundtrip" {
    try std.testing.expectEqualStrings("GET", Method.GET.toString());
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expectEqual(Method.DELETE, Method.fromString("delete").?);
    try std.testing.expect(Method.fromString("BOGUS") == null);
}

test "method safety" {
    try std.testing.expect(Method.GET.isSafe());
    try std.testing.expect(!Method.POST.isSafe());
    try std.testing.expect(Method.PUT.isIdempotent());
}

test "method body" {
    try std.testing.expect(Method.POST.hasBody());
    try std.testing.expect(!Method.GET.hasBody());
}
