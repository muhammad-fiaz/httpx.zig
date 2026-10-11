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
const staticFiles = @import("../staticFiles/staticFileServer.zig");

pub const Config = struct {
    /// The filesystem path to the SPA directory (e.g. "./dist").
    root: []const u8,
    /// The fallback file for unmatched routes (default: "index.html").
    fallback: []const u8 = "index.html",
    /// URL prefix under which real files are served.
    mount: []const u8 = "/",
    /// Serve from the embedded registry only; never touch the filesystem.
    filesystem: bool = true,
    /// URL prefixes that must NEVER fall back to the SPA entry file (e.g. &[_][]const u8{"/api", "/auth"}).
    excludePrefixes: []const []const u8 = &.{},
    /// Live reload / hot reload for development.
    liveReload: bool = false,
    /// SSE endpoint path for live-reload broadcast (default: "/__httpx_liveReload").
    reloadSsePath: []const u8 = "/__httpx_liveReload",
    /// Cache-Control on success responses.
    cacheControl: []const u8 = "public, max-age=3600",
};

/// Register the SPA's static assets on the router.
///
/// API routes should be registered BEFORE calling this so they take
/// precedence; register it last so the static mount only claims what
/// remains.
pub fn register(router: *Router, cfg: Config) !void {
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
