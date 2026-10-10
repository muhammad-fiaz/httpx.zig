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
        if (s.len < 3 or s.len > 7) return null;
        switch (s.len) {
            3 => {
                if (s[0] == 'G' and s[1] == 'E' and s[2] == 'T') return .GET;
                if (s[0] == 'P' and s[1] == 'U' and s[2] == 'T') return .PUT;
                if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
                if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
            },
            4 => {
                if (s[0] == 'P' and s[1] == 'O' and s[2] == 'S' and s[3] == 'T') return .POST;
                if (s[0] == 'H' and s[1] == 'E' and s[2] == 'A' and s[3] == 'D') return .HEAD;
                if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
                if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
            },
            5 => {
                if (s[0] == 'P' and s[1] == 'A' and s[2] == 'T' and s[3] == 'C' and s[4] == 'H') return .PATCH;
                if (s[0] == 'T' and s[1] == 'R' and s[2] == 'A' and s[3] == 'C' and s[4] == 'E') return .TRACE;
                if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
                if (std.ascii.eqlIgnoreCase(s, "TRACE")) return .TRACE;
            },
            6 => {
                if (s[0] == 'D' and s[1] == 'E' and s[2] == 'L' and s[3] == 'E' and s[4] == 'T' and s[5] == 'E') return .DELETE;
                if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
            },
            7 => {
                if (s[0] == 'O' and s[1] == 'P' and s[2] == 'T' and s[3] == 'I' and s[4] == 'O' and s[5] == 'N' and s[6] == 'S') return .OPTIONS;
                if (s[0] == 'C' and s[1] == 'O' and s[2] == 'N' and s[3] == 'N' and s[4] == 'E' and s[5] == 'C' and s[6] == 'T') return .CONNECT;
                if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .OPTIONS;
                if (std.ascii.eqlIgnoreCase(s, "CONNECT")) return .CONNECT;
            },
            else => return null,
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
