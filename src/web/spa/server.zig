//! SPA (Single-Page Application) serving.
//!
//! Mounts a static directory and provides an index.html fallback handler
//! for frontend client-side routing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Router = routerMod.Router;
const Context = routerMod.Context;
const Response = routerMod.Response;
const staticFiles = @import("../staticFiles/static.zig");
const z = @import("zigantic");

const ConfigSchema = z.objectOf(.{
    .root = z.withDefault(z.string(.{ .min = 1 }), "dist"),
    .fallback = z.withDefault(z.string(.{ .min = 1 }), "index.html"),
    .mount = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/"),
    .filesystem = z.withDefault(z.boolean(.{}), true),
    .excludePrefixes = z.withDefault(z.array(z.string(.{ .min = 1, .prefix = "/" }), .{}), &.{}),
    .liveReload = z.withDefault(z.boolean(.{}), false),
    .reloadSsePath = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/__httpx_liveReload"),
    .cacheControl = z.withDefault(z.string(.{}), "public, max-age=3600"),
}, .{});
pub const Config = ConfigSchema.Value;

/// Register the SPA's static assets on the router.
///
/// API routes should be registered BEFORE calling this so they take
/// precedence; register it last so the static mount only claims what
/// remains.
pub fn register(router: *Router, cfg: Config) !void {
    var scratch: [4096]u8 = undefined;
    const issue = z.checkFirst(ConfigSchema, cfg, &scratch, .{}) catch
        return error.InvalidMount;
    if (issue != null) return error.InvalidMount;
    try staticFiles.register(router, .{
        .root = cfg.root,
        .mount = cfg.mount,
        .indexFile = cfg.fallback,
        .spaFallback = cfg.fallback,
        .spaExcludePrefixes = cfg.excludePrefixes,
        .filesystem = cfg.filesystem,
        .liveReload = cfg.liveReload,
        .reloadSsePath = cfg.reloadSsePath,
        .cacheControl = cfg.cacheControl,
    });
}

test "spa config defaults" {
    const cfg = Config{ .root = "./dist" };
    try std.testing.expectEqualStrings("index.html", cfg.fallback);
    try std.testing.expectEqualStrings("/", cfg.mount);
    try std.testing.expectEqual(@as(usize, 0), cfg.excludePrefixes.len);
    try std.testing.expect(!cfg.liveReload);
}
