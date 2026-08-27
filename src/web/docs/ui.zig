//! Built-in API documentation UIs: Swagger UI, ReDoc, Scalar.
//!
//! All vendor assets are embedded (see `assets.zig`) and served locally —
//! never from a CDN. Mounting registers:
//!
//!   GET {openapi_route}              -> OpenAPI 3.1 JSON of current routes
//!   GET {swagger_route}              -> Swagger UI page
//!   GET {swagger_route}/<asset>      -> Swagger UI bundle files
//!   GET {redoc_route}                -> ReDoc page
//!   GET {redoc_route}/<asset>        -> ReDoc bundle
//!   GET {scalar_route}               -> Scalar page
//!   GET {scalar_route}/standalone.js -> Scalar bundle
//!
//! Route conflicts are surfaced as Router errors, never silently overwritten.
//!
//! Handlers are capture-less fn pointers, so mounted state lives in a single
//! module-level instance: one docs mount per process. `unmount()` releases it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");
const Router = router_mod.Router;
const Response = router_mod.Response;
const Context = router_mod.Context;
const Method = @import("../../common/method.zig").Method;
const openapi = @import("../openapi/spec.zig");
const assets = @import("assets.zig");

pub const Config = struct {
    /// Master switch; when false nothing is registered.
    enabled: bool = true,
    /// Where the OpenAPI 3.1 document is served.
    openapi_route: []const u8 = "/openapi.json",
    swagger_route: []const u8 = "/docs",
    redoc_route: []const u8 = "/redoc",
    scalar_route: []const u8 = "/scalar",
    /// Per-UI enablement.
    swagger: bool = true,
    redoc: bool = true,
    scalar: bool = false,
    title: []const u8 = "httpx API",
};

const DocsState = struct {
    allocator: Allocator,
    spec: []u8,
    openapi_route: []u8,
    swagger_route: ?[]u8 = null,
    redoc_route: ?[]u8 = null,
    scalar_route: ?[]u8 = null,
    title: []u8 = &.{},
    /// Pages are rendered once at mount; handlers hand out borrowed slices
    /// so request handling performs zero dynamic allocation.
    swagger_page: ?[]u8 = null,
    redoc_page: ?[]u8 = null,
    scalar_page: ?[]u8 = null,

    fn deinitPages(self: *DocsState) void {
        const a = self.allocator;
        if (self.swagger_page) |p| a.free(p);
        if (self.redoc_page) |p| a.free(p);
        if (self.scalar_page) |p| a.free(p);
    }
};

var g_state: ?*DocsState = null;

/// Registers documentation routes on `router` and captures the generated
/// OpenAPI document. The spec reflects routes registered BEFORE this call.
pub fn mount(
    allocator: Allocator,
    router: *Router,
    cfg: Config,
    info: openapi.Info,
) !void {
    if (!cfg.enabled) return;
    if (g_state != null) return error.AlreadyMounted;

    // Pre-flight: every route we intend to register must be free. This keeps
    // failure atomic — either all docs routes are registered, or none are, so
    // handlers can never observe missing state.
    const planned = [_][]const u8{ cfg.openapi_route, cfg.swagger_route, cfg.redoc_route, cfg.scalar_route };
    for (planned) |route| {
        if (router.hasConflict(.GET, route)) return error.DuplicateRoute;
    }
    if (cfg.swagger) {
        for (assets.swagger_files) |f| {
            const full = try joinRoute(allocator, cfg.swagger_route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (cfg.redoc) {
        for (assets.redoc_files) |f| {
            const full = try joinRoute(allocator, cfg.redoc_route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (cfg.scalar) {
        const full = try joinRoute(allocator, cfg.scalar_route, "standalone.js");
        defer allocator.free(full);
        if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
    }

    const st = try allocator.create(DocsState);
    errdefer allocator.destroy(st);
    st.* = .{
        .allocator = allocator,
        .spec = &.{},
        .openapi_route = &.{},
    };
    errdefer {
        allocator.free(st.spec);
        allocator.free(st.openapi_route);
        if (st.swagger_route) |p| allocator.free(p);
        if (st.redoc_route) |p| allocator.free(p);
        if (st.scalar_route) |p| allocator.free(p);
        allocator.free(st.title);
        st.deinitPages();
    }

    // Spec is generated first: docs' own routes stay out of the document.
    st.spec = try openapi.generate(allocator, router, info);
    st.openapi_route = try normalizeRoute(allocator, cfg.openapi_route);
    st.title = try allocator.dupe(u8, cfg.title);
    if (cfg.swagger and cfg.swagger_route.len > 0)
        st.swagger_route = try normalizeRoute(allocator, cfg.swagger_route);
    if (cfg.redoc and cfg.redoc_route.len > 0)
        st.redoc_route = try normalizeRoute(allocator, cfg.redoc_route);
    if (cfg.scalar and cfg.scalar_route.len > 0)
        st.scalar_route = try normalizeRoute(allocator, cfg.scalar_route);

    // Pre-render enabled UI pages once; handlers only borrow.
    if (st.swagger_route != null) {
        st.swagger_page = try renderSwaggerPage(allocator, st.title, st.openapi_route);
    }
    if (st.redoc_route) |route| {
        const script = try joinRoute(allocator, route, "redoc.standalone.js");
        st.redoc_page = try renderRedocPage(allocator, st.title, st.openapi_route, script);
    }
    if (st.scalar_route) |route| {
        const script = try joinRoute(allocator, route, "standalone.js");
        st.scalar_page = try renderScalarPage(allocator, st.title, st.openapi_route, script);
    }

    try router.get(st.openapi_route, openApiHandler);
    if (st.swagger_route) |route| {
        try router.get(route, swaggerPageHandler);
        for (assets.swagger_files) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.get(full, swaggerAssetHandler);
        }
    }
    if (st.redoc_route) |route| {
        try router.get(route, redocPageHandler);
        for (assets.redoc_files) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.get(full, redocAssetHandler);
        }
    }
    if (st.scalar_route) |route| {
        try router.get(route, scalarPageHandler);
        const full = try joinRoute(allocator, route, "standalone.js");
        defer allocator.free(full);
        try router.get(full, scalarAssetHandler);
    }

    g_state = st;
}

/// Frees mounted docs state. Safe to call when nothing is mounted.
pub fn unmount() void {
    if (g_state) |st| {
        const a = st.allocator;
        a.free(st.spec);
        a.free(st.openapi_route);
        if (st.swagger_route) |p| a.free(p);
        if (st.redoc_route) |p| a.free(p);
        if (st.scalar_route) |p| a.free(p);
        a.free(st.title);
        st.deinitPages();
        a.destroy(st);
        g_state = null;
    }
}

fn normalizeRoute(allocator: Allocator, route: []const u8) Allocator.Error![]u8 {
    var trimmed = route;
    while (trimmed.len > 1 and trimmed[0] == '/' and trimmed[1] == '/') trimmed = trimmed[1..];
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return allocator.dupe(u8, trimmed);
}

fn joinRoute(allocator: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (base.len > 0 and base[base.len - 1] == '/')
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, name }) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name }) catch return error.OutOfMemory;
}

fn requireState() *DocsState {
    return g_state orelse unreachable; // handlers only reachable after mount()
}

// --- handlers ---------------------------------------------------------------

fn openApiHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    return .{ .status = 200, .content_type = "application/json; charset=utf-8", .body = st.spec };
}

fn swaggerPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = st.swagger_page.? };
}

fn redocPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = st.redoc_page.? };
}

fn scalarPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = st.scalar_page.? };
}

fn swaggerAssetHandler(ctx: *Context) anyerror!Response {
    return serveAsset(ctx, .swagger_ui, ctx.path);
}

fn redocAssetHandler(ctx: *Context) anyerror!Response {
    return serveAsset(ctx, .redoc, ctx.path);
}

fn scalarAssetHandler(ctx: *Context) anyerror!Response {
    return serveAsset(ctx, .scalar, ctx.path);
}

/// Extracts the filename after the mount prefix and serves the embedded file.
fn serveAsset(ctx: *Context, kind: assets.Kind, path: []const u8) anyerror!Response {
    const name = blk: {
        const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse break :blk path;
        break :blk path[idx + 1 ..];
    };
    const f = assets.find(kind, name) orelse
        return .{ .status = 404, .content_type = "text/plain; charset=utf-8", .body = "not found" };
    _ = ctx;
    return .{ .status = 200, .content_type = f.content_type, .body = f.data };
}

// --- page rendering ---------------------------------------------------------

fn escapeInto(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '\'' => try w.writeAll("&#39;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

fn renderSwaggerPage(a: Allocator, title: []const u8, spec_url: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<link rel=\"stylesheet\" href=\"./swagger-ui.css\">\n<link rel=\"icon\" type=\"image/png\" href=\"./favicon-32x32.png\">\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"./swagger-ui-bundle.js\"></script>\n<script src=\"./swagger-ui-standalone-preset.js\"></script>\n<script>\nwindow.onload = function () {\n  window.ui = SwaggerUIBundle({\n    url: '");
    try escapeInto(w, spec_url);
    try w.writeAll("',\n    dom_id: '#swagger-ui',\n    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],\n    layout: 'StandalonePlugin',\n    oauth2RedirectUrl: './oauth2-redirect.html'\n  });\n};\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderRedocPage(a: Allocator, title: []const u8, spec_url: []const u8, script_url: []const u8) ![]u8 {
    defer a.free(script_url);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<redoc spec-url=\"");
    try escapeInto(w, spec_url);
    try w.writeAll("\"></redoc>\n<script src=\"");
    try escapeInto(w, script_url);
    try w.writeAll("\"></script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderScalarPage(a: Allocator, title: []const u8, spec_url: []const u8, script_url: []const u8) ![]u8 {
    defer a.free(script_url);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n</head>\n<body>\n<script id=\"api-reference\" data-url=\"");
    try escapeInto(w, spec_url);
    try w.writeAll("\" data-configuration=\"{&quot;theme&quot;:&quot;default&quot;}\"></script>\n<script src=\"");
    try escapeInto(w, script_url);
    try w.writeAll("\"></script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn helloHandler(ctx: *Context) anyerror!Response {
    _ = ctx;
    return .{ .status = 200, .body = "hi" };
}

fn invoke(router: *Router, method: Method, path: []const u8, a: Allocator) !?Response {
    var ctx: Context = .{ .allocator = a, .path = path, .method = method };
    const h = router.match(method, path, &ctx) orelse return null;
    return try h(&ctx);
}

test "mount registers spec, pages, and local assets" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/hello", helloHandler);

    try mount(a, &router, .{}, .{ .title = "Demo" });
    defer unmount();

    // Spec excludes docs routes but includes user routes.
    const res = (try invoke(&router, .GET, "/openapi.json", a)).?;
    try std.testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try std.testing.expect(paths.get("/hello") != null);
    try std.testing.expect(paths.get("/docs") == null);

    // Swagger page references only local assets.
    const page = (try invoke(&router, .GET, "/docs", a)).?;
    try std.testing.expectEqualStrings("text/html; charset=utf-8", page.content_type.?);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "./swagger-ui-bundle.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "cdn") == null);

    // Handlers borrow pre-rendered pages: repeat invocation is stable and
    // allocation-free.
    const again = (try invoke(&router, .GET, "/docs", a)).?;
    try std.testing.expectEqual(page.body.ptr, again.body.ptr);

    // Bundle served from embedded bytes.
    const bundle = (try invoke(&router, .GET, "/docs/swagger-ui-bundle.js", a)).?;
    try std.testing.expect(bundle.body.len == assets.swagger_ui_bundle_js.len);
    try std.testing.expect(std.mem.startsWith(u8, bundle.body, "/*!"));

    // Unknown asset name does not fall through to any catch-all route.
    try std.testing.expect((try invoke(&router, .GET, "/docs/nonexistent.js", a)) == null);

    // ReDoc page + bundle.
    const redoc_page = (try invoke(&router, .GET, "/redoc", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, redoc_page.body, "redoc.standalone.js") != null);
    const redoc_js = (try invoke(&router, .GET, "/redoc/redoc.standalone.js", a)).?;
    try std.testing.expect(redoc_js.body.len == assets.redoc_standalone_js.len);

    // Scalar disabled by default.
    try std.testing.expect((try invoke(&router, .GET, "/scalar", a)) == null);
}

test "scalar opt-in mounts its page and bundle" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id}", helloHandler);

    try mount(a, &router, .{ .redoc = false, .scalar = true }, .{});
    defer unmount();

    const page = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"api-reference\"") != null);
    const js = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(assets.scalar_standalone_js.len, js.body.len);

    const res = (try invoke(&router, .GET, "/openapi.json", a)).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("paths").?.object.get("/users/{id}") != null);
}

test "disabled config registers nothing" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try mount(a, &router, .{ .enabled = false }, .{});
    try std.testing.expect(g_state == null);
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
}

test "conflicting user route is reported, not overwritten" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/docs", helloHandler); // user already owns /docs

    try std.testing.expectError(error.DuplicateRoute, mount(a, &router, .{}, .{}));
    unmount(); // partial state cleaned up
    try std.testing.expect(g_state == null);
}
