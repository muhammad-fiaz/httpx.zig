//! Small assertion helpers for responses returned by `httpx.Client`.
//!
//! These are intentionally generic over the response type (anything with
//! `status`, `body`, and `header`) so they also work with handler responses
//! and future client response variants.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn expectStatus(response: anytype, expected: u16) !void {
    try std.testing.expectEqual(expected, response.status);
}

pub fn expectBody(response: anytype, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, response.body);
}

pub fn expectBodyContains(response: anytype, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, response.body, needle) != null);
}

pub fn expectHeader(response: anytype, name: []const u8, expected: []const u8) !void {
    const actual = response.header(name);
    if (actual == null) return error.MissingHeader;
    try std.testing.expectEqualStrings(expected, actual.?);
}

pub fn expectNoHeader(response: anytype, name: []const u8) !void {
    try std.testing.expect(response.header(name) == null);
}

/// Parses the response body as JSON into `T`. The caller owns the returned
/// value and calls `deinit()`.
pub fn expectJsonBody(
    comptime T: type,
    allocator: Allocator,
    response: anytype,
) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
}

test "response assertions report mismatches" {
    const Fake = struct {
        status: u16,
        body: []const u8,
        headers: []const @import("common.zig").Header,

        fn header(self: @This(), name: []const u8) ?[]const u8 {
            for (self.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            }
            return null;
        }
    };
    const response = Fake{
        .status = 201,
        .body = "{\"id\":7}",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
    };
    try expectStatus(response, 201);
    try expectBodyContains(response, "\"id\"");
    try expectHeader(response, "Content-Type", "application/json");
    try expectNoHeader(response, "x-missing");
    var parsed = try expectJsonBody(struct { id: u64 }, std.testing.allocator, response);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.id);
}
