//! SPA (Single-Page Application) serving.
//!
//! Mounts a static directory and provides an index.html fallback handler
//! for frontend client-side routing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Response = router_mod.Response;
const static_files = @import("../static_files/serve.zig");

pub const Config = struct {
    /// The filesystem path to the SPA directory (e.g. "./dist").
    root: []const u8,
    /// The fallback file for unmatched routes (default: "index.html").
    fallback: []const u8 = "index.html",
    /// URL prefix under which real files are served.
    mount: []const u8 = "/",
};

/// Register the SPA's static assets on the router.
///
/// API routes should be registered BEFORE calling this so they take
/// precedence; register it last so the static mount only claims what
/// remains.
pub fn register(router: *Router, cfg: Config) !void {
    try static_files.register(router, .{
        .root = cfg.root,
        .mount = cfg.mount,
        .index_file = cfg.fallback,
    });
}

test "spa config defaults" {
    const cfg = Config{ .root = "./dist" };
    try std.testing.expectEqualStrings("index.html", cfg.fallback);
    try std.testing.expectEqualStrings("/", cfg.mount);
}
