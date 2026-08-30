//! Generate an OpenAPI 3.1 document for a registered router.
//!
//! Run with: `zig build run-openapi`
//!
//! Demonstrates building a router with documented routes and producing
//! the OpenAPI JSON spec to stdout. The same data drives the built-in
//! /openapi.json, /docs (Swagger UI), and /redoc endpoints when
//! `docs_enabled` is left on.

const std = @import("std");
const httpx = @import("httpx");

fn listHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = "[]", .content_type = "application/json" };
}

fn getHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.param("id") orelse "0";
    return .{
        .status = 200,
        .body = id,
        .content_type = "text/plain",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = httpx.Router.init(allocator);
    defer router.deinit();
    try router.addMeta(.GET, "/widgets", listHandler, .{
        .summary = "List all widgets",
        .description = "Returns the full set of widgets.",
    });
    try router.addMeta(.GET, "/widgets/{id}", getHandler, .{
        .summary = "Fetch a single widget",
        .description = "Looks up a widget by its opaque id.",
    });

    const spec = try httpx.openapi.generate(&router, .{
        .title = "Widgets API",
        .version = "1.0.0",
        .description = "Demonstration OpenAPI document generated at build time.",
    });
    defer allocator.free(spec);

    // Examples are stdlib-friendly: dump the generated JSON to the debug
    // stream rather than plumbing an Io through stdout.
    std.debug.print("{s}\n", .{spec});
}
