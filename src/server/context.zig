//! Server request context: provides handler access to request data,
//! JSON parsing, cookie extraction, and response building.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../web/router/router.zig");
const Context = router_mod.Context;

/// Parse the request body as JSON into `T`.
pub fn json(comptime T: type, ctx: *Context) !T {
    if (ctx.body.len == 0) return error.EmptyBody;
    return std.json.parseFromSliceLeaky(T, ctx.allocator, ctx.body, .{});
}

/// Extract a cookie value by name from the Cookie header.
pub fn cookie(ctx: *Context, name: []const u8) ?[]const u8 {
    for (ctx.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Cookie")) {
            var iter = std.mem.splitScalar(u8, h.value, ';');
            while (iter.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " \t");
                if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                    const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                    if (std.mem.eql(u8, k, name)) {
                        return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                    }
                }
            }
        }
    }
    return null;
}

/// Extract a query parameter by name from the URL path.
pub fn queryParam(ctx: *Context, name: []const u8) ?[]const u8 {
    const path = ctx.path;
    if (std.mem.indexOfScalar(u8, path, '?')) |qstart| {
        var iter = std.mem.splitScalar(u8, path[qstart + 1 ..], '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const k = pair[0..eq];
                if (std.mem.eql(u8, k, name)) {
                    return pair[eq + 1 ..];
                }
            }
        }
    }
    return null;
}

/// Get the remote address from headers (X-Forwarded-For or peer info).
pub fn remoteAddress(ctx: *Context) ?[]const u8 {
    for (ctx.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Forwarded-For")) {
            if (std.mem.indexOfScalar(u8, h.value, ',')) |comma| {
                return std.mem.trim(u8, h.value[0..comma], " ");
            }
            return h.value;
        }
    }
    return null;
}

/// Write a JSON response.
pub fn jsonResponse(writer: anytype, status: u16, body: []const u8) !void {
    const reason = switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try writer.print("HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len });
    try writer.writeAll(body);
}

/// Write a text response.
pub fn textResponse(writer: anytype, status: u16, body: []const u8) !void {
    const reason = switch (status) {
        200 => "OK",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try writer.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len });
    try writer.writeAll(body);
}

test "cookie extraction" {
    var headers: [2]router_mod.Header = .{
        .{ .name = "Cookie", .value = "session=abc123; theme=dark" },
        .{ .name = "Host", .value = "example.com" },
    };
    var ctx = Context{
        .allocator = std.testing.allocator,
        .io = undefined,
        .headers = &headers,
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    try std.testing.expectEqualStrings("abc123", cookie(&ctx, "session").?);
    try std.testing.expectEqualStrings("dark", cookie(&ctx, "theme").?);
    try std.testing.expect(cookie(&ctx, "missing") == null);
}

test "query param extraction" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .io = undefined,
        .headers = &.{},
        .path = "/search?q=zig&page=2",
        .method = .GET,
        .body = "",
    };
    try std.testing.expectEqualStrings("zig", queryParam(&ctx, "q").?);
    try std.testing.expectEqualStrings("2", queryParam(&ctx, "page").?);
    try std.testing.expect(queryParam(&ctx, "missing") == null);
}
