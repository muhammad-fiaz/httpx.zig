//! Dynamic handler types and small built-in handlers for the testing server.
//!
//! Handlers use the production router context and response types, so they
//! have exactly the same access to method, path, query, headers, body,
//! protocol metadata, and per-request allocation as production routes.

const std = @import("std");
const common = @import("common.zig");

pub const Handler = common.Handler;
pub const Context = common.Context;
pub const Response = common.Response;

/// Calls a configured handler. Kept as a named function so the route layer
/// has one place to enforce the "static response when no handler" rule.
pub fn invoke(handler: Handler, ctx: *Context) !Response {
    return handler(ctx);
}

/// Built-in handler that echoes the request body. Returns `text/plain`, or
/// `application/json` when the request carried a JSON content type.
pub fn echo(ctx: *Context) anyerror!Response {
    const isJson = if (ctx.header("Content-Type")) |ct|
        std.ascii.startsWithIgnoreCase(ct, "application/json") or
            std.mem.indexOf(u8, ct, "+json") != null
    else
        false;
    return .{
        .status = 200,
        .body = ctx.body,
        .contentType = if (isJson) "application/json" else "text/plain; charset=utf-8",
    };
}

test "echo handler mirrors the body and content type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const headers = [_]common.Header{.{ .name = "content-type", .value = "application/json" }};
    var ctx = Context{
        .allocator = arena.allocator(),
        .headers = &headers,
        .body = "{\"ok\":true}",
    };
    const res = try invoke(echo, &ctx);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.body);
    try std.testing.expectEqualStrings("application/json", res.contentType.?);
}
