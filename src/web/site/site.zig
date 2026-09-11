//! File-based website serving: one mount for pages, assets and templates.
//!
//! A `Site` discovers page files (filesystem walk or build-generated
//! embedded manifest), builds a deterministic route table with
//! `routes.buildRoutes`, and registers it on the existing `Router`:
//! HTML pages render through the shared template engine, every other
//! asset flows through the existing static/SPA pipeline (which already
//! prefers embedded bytes). Normally mount last, after explicit API
//! routes; exact file routes outscore static wildcards by router priority.
//!
//! ```zig
//! var site = try httpx.site.Site.init(allocator, io, .{ .filesystem = "dist" }, .{});
//! defer site.deinit();
//! try site.mount(&server); // register pages + static layer
//! ```
//!
//! Ownership: `init` receives allocator and IO once. `mount` borrows the
//! server (Site must outlive serving; deinit after `server.stop()`).
//! `urlFor`/`staticUrl` return caller-owned slices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");
const Context = router_mod.Context;
const Response = router_mod.Response;
const uri = @import("../../common/uri.zig");
const assets_mod = @import("../assets.zig");
const templates_mod = @import("../templates/templates.zig");
const static_files = @import("../static_files/serve.zig");
const spa = @import("../spa/serve.zig");
const watcher_mod = @import("../watcher/backend.zig");
const Server = @import("../../server/lifecycle.zig").Server;
const routes_mod = @import("routes.zig");

pub const TrailingSlash = enum { serveBoth, redirectSlash, redirectNoSlash, strict };

/// Re-exported route-table vocabulary so site users import one namespace.
pub const UrlStyle = routes_mod.UrlStyle;
pub const FileRoute = routes_mod.FileRoute;
pub const Collision = routes_mod.Collision;
pub const CustomRoute = routes_mod.CustomRoute;

/// Asset source: a filesystem directory (development) or a build-generated
/// manifest slice (production single-executable).
pub const Source = union(enum) {
    filesystem: []const u8,
    embedded: []const assets_mod.EmbeddedFile,
};

pub const Config = struct {
    base: []const u8 = "/",
    urls: routes_mod.UrlStyle = .both,
    trailing: TrailingSlash = .serveBoth,
    indexBase: []const u8 = "index",
    custom: []const routes_mod.CustomRoute = &.{},
    /// SPA fallback file (e.g. "index.html"); null disables SPA fallback.
    spaFallback: ?[]const u8 = null,
    /// Filesystem mode: drive the server watcher on the site root.
    watch: bool = true,
    /// Filesystem mode: enable live-reload script injection + SSE endpoint.
    reload: bool = true,
    templates: templates_mod.Config = .{},
    /// Subtree reserved for templates: rendered through the engine and
    /// never routed as pages (null disables the reservation).
    templateDir: ?[]const u8 = "templates",
};

pub const NavEntry = struct {
    name: []const u8,
    url: []const u8,
};

const Target = struct {
    site: *Site,
    route: *const routes_mod.FileRoute,
};

pub const Site = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    base: []u8,
    embedded: bool,
    /// Site root directory (filesystem mode) or "" (embedded). The template
    /// engine created at mount time serves templates relative to it.
    root: []u8,
    table: routes_mod.BuildResult,
    targets: std.ArrayList(Target),
    nav: std.ArrayList(NavEntry),
    ssePath: []u8,
    mounted: bool = false,

    /// Discovers files from `source`, registers embedded manifests and
    /// builds the route table. The template engine is created at `mount`
    /// time with the server allocator, so the server owns and destroys it.
    pub fn init(allocator: Allocator, io: std.Io, source: Source, config: Config) !Site {
        if (config.base.len == 0 or config.base[0] != '/') return error.InvalidFilePath;
        const embedded = source == .embedded;

        var root: []u8 = undefined;
        switch (source) {
            .filesystem => |r| root = try allocator.dupe(u8, r),
            .embedded => root = try allocator.dupe(u8, ""),
        }
        errdefer allocator.free(root);

        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |f| allocator.free(f);
            files.deinit(allocator);
        }
        switch (source) {
            .filesystem => |r| try discoverFiles(allocator, io, r, &files),
            .embedded => |manifest| {
                try assets_mod.registerEmbeddedDir(allocator, manifest);
                for (manifest) |f| try files.append(allocator, try allocator.dupe(u8, f.path));
            },
        }
        if (config.templateDir) |td| {
            var kept: std.ArrayList([]const u8) = .empty;
            defer kept.deinit(allocator);
            for (files.items) |f| {
                if (isReservedPath(f, td)) {
                    allocator.free(f);
                } else {
                    try kept.append(allocator, f);
                }
            }
            files.clearRetainingCapacity();
            try files.appendSlice(allocator, kept.items);
        }

        var table = try routes_mod.buildRoutes(allocator, files.items, .{
            .base = config.base,
            .urls = config.urls,
            .indexBase = config.indexBase,
            .custom = config.custom,
        });
        errdefer table.deinit(allocator);

        var trimmedEnd = config.base.len;
        while (trimmedEnd > 1 and config.base[trimmedEnd - 1] == '/') trimmedEnd -= 1;

        var self = Site{
            .allocator = allocator,
            .io = io,
            .config = config,
            .base = try allocator.dupe(u8, config.base[0..trimmedEnd]),
            .embedded = embedded,
            .root = root,
            .table = table,
            .targets = .empty,
            .nav = .empty,
            .ssePath = try allocator.dupe(u8, "/__httpx_liveReload"),
        };
        errdefer {
            allocator.free(self.base);
            allocator.free(self.root);
            allocator.free(self.ssePath);
            self.targets.deinit(allocator);
            self.nav.deinit(allocator);
        }
        try self.buildNav();
        return self;
    }

    pub fn deinit(self: *Site) void {
        self.targets.deinit(self.allocator);
        for (self.nav.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.url);
        }
        self.allocator.free(self.ssePath);
        self.allocator.free(self.root);
        self.nav.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.allocator.free(self.base);
    }

    pub fn routes(self: *const Site) []const routes_mod.FileRoute {
        return self.table.routes;
    }

    pub fn collisions(self: *const Site) []const routes_mod.Collision {
        return self.table.collisions;
    }

    /// Registers file routes plus the static/SPA asset layer on `server`.
    /// Call after API routes, before `server.run()`. Creates the template
    /// engine with the server allocator, so the server owns and destroys
    /// it. A preconfigured server engine is adopted when its directory
    /// already equals the site root; otherwise mounting fails loudly
    /// instead of silently rendering from the wrong tree. Duplicate route
    /// shapes also fail loudly.
    pub fn mount(self: *Site, server: *Server) !void {
        // Server.init already wires router.templateEngine when it creates
        // the engine itself; a Site-created engine is unwound below.
        var created: ?*templates_mod.Engine = null;
        errdefer if (created) |e| {
            server.templateEngine = null;
            server.router.templateEngine = null;
            e.deinit();
            server.allocator.destroy(e);
        };
        if (server.templateEngine) |existing| {
            if (!std.mem.eql(u8, existing.config.directory, self.root)) return error.TemplateEngineAlreadyConfigured;
        } else {
            var engine_cfg = self.config.templates;
            engine_cfg.directory = self.root;
            const engine = try server.allocator.create(templates_mod.Engine);
            errdefer server.allocator.destroy(engine);
            // Engine.init either fully succeeds or leaves nothing to deinit.
            engine.* = try templates_mod.Engine.init(server.allocator, server.io, engine_cfg);
            server.templateEngine = engine;
            server.router.templateEngine = engine;
            created = engine;
        }

        // Sync the reload endpoint path before any handler can capture it.
        self.allocator.free(self.ssePath);
        self.ssePath = try self.allocator.dupe(u8, server.cfg.liveReloadPath);

        // Atomicity: pre-check every pattern (file routes plus the asset
        // layer's two patterns) before registering anything.
        const asset_p1 = try staticMountPattern(self.allocator, self.base, false);
        defer self.allocator.free(asset_p1);
        const asset_p2 = try staticMountPattern(self.allocator, self.base, true);
        defer self.allocator.free(asset_p2);
        try self.checkPattern(server, asset_p1);
        try self.checkPattern(server, asset_p2);
        for (self.table.routes) |*r| {
            try self.checkPattern(server, r.route);
            if (r.extRoute) |e| try self.checkPattern(server, e);
            for (r.aliases) |a| try self.checkPattern(server, a);
        }

        var registered: std.ArrayList([]const u8) = .empty;
        defer registered.deinit(self.allocator);
        errdefer {
            // Best-effort unwind so a failed mount leaves no partial routes.
            for (registered.items) |p| _ = server.router.remove(.GET, p);
            self.targets.clearRetainingCapacity();
        }

        const embedded_only = self.embedded;
        // The asset layer always needs a non-empty root string; in embedded
        // mode it is only a lookup prefix since `filesystem = false`.
        // A site root page replaces the asset layer's bare mount route so
        // `/` renders through templates; the wildcard and SPA fallback stay
        // for everything else.
        var has_root = false;
        for (self.table.routes) |r| {
            if (std.mem.eql(u8, r.route, self.base)) {
                has_root = true;
                break;
            }
        }
        const asset_root = if (self.rootDir().len == 0) "." else self.rootDir();
        if (self.config.spaFallback) |fb| {
            try spa.register(&server.router, .{
                .root = asset_root,
                .fallback = fb,
                .mount = self.base,
                .filesystem = !embedded_only,
            });
        } else {
            try static_files.register(&server.router, .{
                .root = asset_root,
                .mount = self.base,
                .liveReload = self.config.reload and !embedded_only,
                .reloadSsePath = self.ssePath,
                .filesystem = !embedded_only,
            });
        }
        try registered.append(self.allocator, asset_p1);
        try registered.append(self.allocator, asset_p2);
        if (has_root) _ = server.router.remove(.GET, self.base);

        for (self.table.routes) |*r| {
            const target = try self.targets.addOne(self.allocator);
            target.* = .{ .site = self, .route = r };
            try server.router.get(r.route, servePage, .{ .userData = target });
            try registered.append(self.allocator, r.route);
            if (r.extRoute) |e| {
                try server.router.get(e, servePage, .{ .userData = target });
                try registered.append(self.allocator, e);
            }
            for (r.aliases) |a| {
                try server.router.get(a, servePage, .{ .userData = target });
                try registered.append(self.allocator, a);
            }
        }

        if (!embedded_only) {
            if (self.config.watch) {
                server.cfg.watch = true;
                server.cfg.watchDir = self.rootDir();
            }
            if (self.config.reload) server.cfg.liveReload = true;
        }
        self.mounted = true;
    }

    /// Mirrors static_files mount pattern construction (`/` + `/*path`).
    fn staticMountPattern(allocator: Allocator, base: []const u8, wildcard: bool) ![]u8 {
        if (std.mem.eql(u8, base, "/")) {
            if (wildcard) return allocator.dupe(u8, "/*path");
            return allocator.dupe(u8, "/");
        }
        if (wildcard) return std.fmt.allocPrint(allocator, "{s}/*path", .{base});
        return allocator.dupe(u8, base);
    }

    fn checkPattern(self: *Site, server: *Server, pattern: []const u8) !void {
        _ = self;
        if (server.router.hasConflict(.GET, pattern)) return error.DuplicateRoute;
    }

    fn rootDir(self: *const Site) []const u8 {
        return self.root;
    }

    fn buildNav(self: *Site) !void {
        for (self.table.routes) |r| {
            const url = try self.canonicalUrl(r.route, r.isIndex);
            errdefer self.allocator.free(url);
            const name = try self.allocator.dupe(u8, r.name);
            errdefer self.allocator.free(name);
            try self.nav.append(self.allocator, .{ .name = name, .url = url });
        }
    }

    fn canonicalUrl(self: *Site, route: []const u8, is_index: bool) ![]u8 {
        _ = is_index;
        if (self.config.trailing == .redirectSlash and !std.mem.eql(u8, route, "/")) {
            return std.fmt.allocPrint(self.allocator, "{s}/", .{route});
        }
        return self.allocator.dupe(u8, route);
    }

    /// Resolves a named route, substituting `{param}`/` *rest` values and
    /// appending an optional query struct. Caller owns the result.
    pub fn urlFor(self: *Site, name: []const u8, params: anytype, query: anytype) ![]u8 {
        const entry = for (self.table.routes) |*r| {
            if (std.mem.eql(u8, r.name, name)) break r;
        } else return error.UnknownRoute;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const pattern = entry.route;
        var i: usize = 0;
        while (i < pattern.len) {
            if (pattern[i] == '{') {
                const end = std.mem.indexOfScalarPos(u8, pattern, i, '}') orelse return error.MissingRouteParam;
                const pname = pattern[i + 1 .. end];
                const value = try paramValue(self.allocator, params, pname);
                defer self.allocator.free(value);
                try out.appendSlice(self.allocator, value);
                i = end + 1;
            } else if (pattern[i] == '*' and (i == 0 or pattern[i - 1] == '/')) {
                const pname = pattern[i + 1 ..];
                const value = try paramValue(self.allocator, params, pname);
                defer self.allocator.free(value);
                try out.appendSlice(self.allocator, value);
                i = pattern.len;
            } else {
                try out.append(self.allocator, pattern[i]);
                i += 1;
            }
        }
        try appendQuery(self.allocator, &out, query);
        return out.toOwnedSlice(self.allocator);
    }

    /// Base-prefixed URL for a static asset path. Caller owns the result.
    pub fn staticUrl(self: *Site, path: []const u8) ![]u8 {
        var p = path;
        while (p.len > 0 and p[0] == '/') p = p[1..];
        if (uri.hasPathTraversal(p)) return error.InvalidFilePath;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        if (!std.mem.eql(u8, self.base, "/")) try out.appendSlice(self.allocator, self.base);
        var it = std.mem.splitScalar(u8, p, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            try out.append(self.allocator, '/');
            var buf: [1024]u8 = undefined;
            if (seg.len * 3 <= buf.len) {
                try out.appendSlice(self.allocator, try uri.percentEncode(&buf, seg));
            } else {
                const big = try self.allocator.alloc(u8, seg.len * 3);
                defer self.allocator.free(big);
                try out.appendSlice(self.allocator, try uri.percentEncode(big, seg));
            }
        }
        if (out.items.len == 0) try out.append(self.allocator, '/');
        return out.toOwnedSlice(self.allocator);
    }
};

fn paramValue(allocator: Allocator, params: anytype, name: []const u8) ![]u8 {
    const P = @TypeOf(params);
    if (@typeInfo(P) != .@"struct") return error.MissingRouteParam;
    inline for (@typeInfo(P).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return encodeParamValue(allocator, @field(params, f.name));
        }
    }
    return error.MissingRouteParam;
}

/// Percent-encodes one parameter value (strings, string literals, integers,
/// floats, booleans, enums, and optionals thereof).
fn encodeParamValue(allocator: Allocator, v: anytype) ![]u8 {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    if (p.child != u8) return error.MissingRouteParam;
                    return encodeOwned(allocator, v);
                },
                .one => {
                    const ai = @typeInfo(p.child);
                    if (ai != .array or ai.array.child != u8) return error.MissingRouteParam;
                    return encodeOwned(allocator, v.*[0..]);
                },
                else => return error.MissingRouteParam,
            }
        },
        .array => |a| {
            if (a.child != u8) return error.MissingRouteParam;
            return encodeOwned(allocator, &v);
        },
        .int, .comptime_int => {
            var buf: [32]u8 = undefined;
            return encodeOwned(allocator, try std.fmt.bufPrint(&buf, "{d}", .{v}));
        },
        .float, .comptime_float => {
            var buf: [64]u8 = undefined;
            return encodeOwned(allocator, try std.fmt.bufPrint(&buf, "{d}", .{v}));
        },
        .bool => return encodeOwned(allocator, if (v) "true" else "false"),
        .optional => {
            if (v) |inner| return encodeParamValue(allocator, inner);
            return error.MissingRouteParam;
        },
        .enum_literal => return encodeOwned(allocator, @tagName(v)),
        else => return error.MissingRouteParam,
    }
}

fn encodeOwned(allocator: Allocator, s: []const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    if (s.len * 3 <= buf.len) return allocator.dupe(u8, try uri.percentEncode(&buf, s));
    const big = try allocator.alloc(u8, s.len * 3);
    defer allocator.free(big);
    return allocator.dupe(u8, try uri.percentEncode(big, s));
}

fn appendQuery(allocator: Allocator, out: *std.ArrayList(u8), query: anytype) !void {
    const Q = @TypeOf(query);
    if (Q == @TypeOf(null)) return;
    const info = @typeInfo(Q);
    if (info != .@"struct") return error.MissingRouteParam;
    var first = true;
    inline for (info.@"struct".fields) |f| {
        const v = @field(query, f.name);
        if (@TypeOf(v) == @TypeOf(null)) continue;
        const enc_k = try encodeOwned(allocator, f.name);
        defer allocator.free(enc_k);
        const enc_v = try encodeParamValue(allocator, v);
        defer allocator.free(enc_v);
        try out.append(allocator, if (first) '?' else '&');
        first = false;
        try out.appendSlice(allocator, enc_k);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, enc_v);
    }
}

/// Shared file-route handler: trailing-slash policy, then template render
/// with the site navigation model as page data.
fn servePage(ctx: *Context) anyerror!Response {
    const t: *Target = @ptrCast(@alignCast(ctx.userData.?));
    const site = t.site;
    const raw = ctx.path;
    const canonical = t.route.route;

    switch (site.config.trailing) {
        .serveBoth => {},
        .redirectSlash => {
            if (!std.mem.eql(u8, canonical, "/") and !std.mem.endsWith(u8, raw, "/")) {
                const loc = try std.fmt.allocPrint(ctx.allocator, "{s}/", .{raw});
                return ctx.redirect(loc, 301);
            }
        },
        .redirectNoSlash => {
            if (!std.mem.eql(u8, raw, "/") and std.mem.endsWith(u8, raw, "/")) {
                const loc = try allocatorTrimSlash(ctx.allocator, raw);
                return ctx.redirect(loc, 301);
            }
        },
        .strict => {
            if (!std.mem.eql(u8, raw, canonical) and
                !(std.mem.eql(u8, canonical, "/") and std.mem.eql(u8, raw, "/")))
            {
                return .{ .status = 404, .body = @constCast("not found") };
            }
        },
    }

    // Render through the server template engine wired at mount time, so
    // file pages, engine cache, and invalidation stay canonical.
    var resp = try ctx.render(t.route.file, .{
        .site = .{ .pages = site.nav.items },
    });
    if (ctx.method == .HEAD) resp.body = @constCast("");
    if (site.config.reload and ctx.method != .HEAD) {
        const script = try watcher_mod.Watcher.liveReloadScript(ctx.allocator, site.ssePath);
        resp.body = try std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ resp.body, script });
    }
    return resp;
}

fn allocatorTrimSlash(allocator: Allocator, raw: []const u8) ![]u8 {
    var end = raw.len;
    while (end > 1 and raw[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, raw[0..end]);
}

/// True when a logical path lives under the reserved template subtree.
fn isReservedPath(path: []const u8, template_dir: ?[]const u8) bool {
    const td = template_dir orelse return false;
    if (std.mem.eql(u8, path, td)) return true;
    if (path.len > td.len and std.mem.startsWith(u8, path, td) and path[td.len] == '/') return true;
    return false;
}

/// Recursively discovers regular files under `root`, returning sorted
/// `/`-separated paths relative to it. Caller owns every string.
fn discoverFiles(allocator: Allocator, io: std.Io, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    const cwd: std.Io.Dir = .cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return error.FileNotFound;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var p = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(p);
        for (p, 0..) |_, i| {
            if (p[i] == '\\') p[i] = '/';
        }
        try out.append(allocator, p);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

test "site: navigation url building with encoding" {
    // page_allocator: the embedded manifest registers into the process
    // global registry, which outlives any single test on purpose.
    const allocator = std.heap.page_allocator;
    var site = try Site.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .embedded = &.{
            .{ .path = "index.html", .content = "<h1>home</h1>" },
            .{ .path = "users/[id].html", .content = "<h1>user</h1>" },
            .{ .path = "blog/[...path].html", .content = "<h1>post</h1>" },
        },
    }, .{ .base = "/navtest", .urls = .clean });
    defer site.deinit();

    const home = try site.urlFor("home", .{}, null);
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/navtest", home);

    const user = try site.urlFor("users.{id}", .{ .id = "a b/c?" }, null);
    defer allocator.free(user);
    try std.testing.expectEqualStrings("/navtest/users/a%20b%2Fc%3F", user);

    const post = try site.urlFor("blog.*path", .{ .path = "a/b" }, .{ .page = 2, .tag = "a&b" });
    defer allocator.free(post);
    try std.testing.expectEqualStrings("/navtest/blog/a%2Fb?page=2&tag=a%26b", post);

    try std.testing.expectError(error.UnknownRoute, site.urlFor("nope", .{}, null));
    try std.testing.expectError(error.MissingRouteParam, site.urlFor("users.{id}", .{}, null));

    const css = try site.staticUrl("assets/app.css");
    defer allocator.free(css);
    try std.testing.expectEqualStrings("/navtest/assets/app.css", css);
    try std.testing.expectError(error.InvalidFilePath, site.staticUrl("../secret"));
}
