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

pub const SwaggerConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/docs",
    title: []const u8 = "Swagger UI",
};

pub const RedocConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/redoc",
    title: []const u8 = "ReDoc",
};

pub const ScalarConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/scalar",
    title: []const u8 = "Scalar API Reference",
};

pub const GraphiQLConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/graphiql",
    graphql_endpoint: []const u8 = "/graphql",
    title: []const u8 = "GraphiQL IDE",
};

pub const OpenApiConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/openapi.json",
};

pub const Config = struct {
    /// Master switch; when false nothing is registered.
    enabled: bool = true,
    title: []const u8 = "HTTPX API",
    version: []const u8 = "0.2.0",
    description: []const u8 = "Fast, modern web framework for Zig with automated OpenAPI & GraphQL documentation.",
    openapi: OpenApiConfig = .{},
    swagger: SwaggerConfig = .{},
    redoc: RedocConfig = .{},
    scalar: ScalarConfig = .{},
    graphiql: GraphiQLConfig = .{},
};

const DocsState = struct {
    allocator: Allocator,
    spec: ?[]u8 = null,
    openapi_route: []u8,
    swagger_route: ?[]u8 = null,
    redoc_route: ?[]u8 = null,
    scalar_route: ?[]u8 = null,
    graphiql_route: ?[]u8 = null,
    graphql_endpoint: ?[]u8 = null,
    title: []u8 = &.{},
    router: *const Router,
    info: openapi.Info,
    /// Pages are rendered once at mount; handlers hand out borrowed slices
    /// so request handling performs zero dynamic allocation.
    swagger_page: ?[]u8 = null,
    redoc_page: ?[]u8 = null,
    scalar_page: ?[]u8 = null,
    graphiql_page: ?[]u8 = null,

    fn deinitPages(self: *DocsState) void {
        const a = self.allocator;
        if (self.swagger_page) |p| a.free(p);
        if (self.redoc_page) |p| a.free(p);
        if (self.scalar_page) |p| a.free(p);
        if (self.graphiql_page) |p| a.free(p);
        if (self.spec) |s| a.free(s);
        self.swagger_page = null;
        self.redoc_page = null;
        self.scalar_page = null;
        self.graphiql_page = null;
        self.spec = null;
    }
};

var g_state: ?*DocsState = null;

/// Registers documentation routes on `router` and captures the generated
/// OpenAPI document. The spec reflects routes registered BEFORE this call.
pub fn mount(
    allocator: Allocator,
    router: *Router,
    cfg: Config,
    info: ?openapi.Info,
) !void {
    if (!cfg.enabled) return;
    if (g_state != null) return error.AlreadyMounted;

    const actual_info = info orelse openapi.Info{
        .title = cfg.title,
        .version = cfg.version,
        .description = cfg.description,
    };

    if (cfg.openapi.enabled and router.hasConflict(.GET, cfg.openapi.route)) return error.DuplicateRoute;
    if (cfg.swagger.enabled and router.hasConflict(.GET, cfg.swagger.route)) return error.DuplicateRoute;
    if (cfg.redoc.enabled and router.hasConflict(.GET, cfg.redoc.route)) return error.DuplicateRoute;
    if (cfg.scalar.enabled and router.hasConflict(.GET, cfg.scalar.route)) return error.DuplicateRoute;
    if (cfg.graphiql.enabled and router.hasConflict(.GET, cfg.graphiql.route)) return error.DuplicateRoute;
    if (cfg.swagger.enabled) {
        for (assets.swagger_files) |f| {
            const full = try joinRoute(allocator, cfg.swagger.route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (cfg.redoc.enabled) {
        for (assets.redoc_files) |f| {
            const full = try joinRoute(allocator, cfg.redoc.route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (cfg.scalar.enabled) {
        const full = try joinRoute(allocator, cfg.scalar.route, "standalone.js");
        defer allocator.free(full);
        if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
    }
    if (cfg.graphiql.enabled) {
        for (assets.graphiql_files) |f| {
            const full = try joinRoute(allocator, cfg.graphiql.route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }

    const st = try allocator.create(DocsState);
    errdefer allocator.destroy(st);
    st.* = .{
        .allocator = allocator,
        .openapi_route = &.{},
        .router = router,
        .info = actual_info,
    };
    errdefer {
        allocator.free(st.openapi_route);
        if (st.swagger_route) |p| allocator.free(p);
        if (st.redoc_route) |p| allocator.free(p);
        if (st.scalar_route) |p| allocator.free(p);
        if (st.graphiql_route) |p| allocator.free(p);
        if (st.graphql_endpoint) |p| allocator.free(p);
        allocator.free(st.title);
        st.deinitPages();
    }

    st.openapi_route = try normalizeRoute(allocator, cfg.openapi.route);
    st.title = try allocator.dupe(u8, cfg.title);
    if (cfg.swagger.enabled and cfg.swagger.route.len > 0)
        st.swagger_route = try normalizeRoute(allocator, cfg.swagger.route);
    if (cfg.redoc.enabled and cfg.redoc.route.len > 0)
        st.redoc_route = try normalizeRoute(allocator, cfg.redoc.route);
    if (cfg.scalar.enabled and cfg.scalar.route.len > 0)
        st.scalar_route = try normalizeRoute(allocator, cfg.scalar.route);
    if (cfg.graphiql.enabled and cfg.graphiql.route.len > 0) {
        st.graphiql_route = try normalizeRoute(allocator, cfg.graphiql.route);
        st.graphql_endpoint = try normalizeRoute(allocator, cfg.graphiql.graphql_endpoint);
    }

    st.spec = try openapi.generate(allocator, router, actual_info);

    // Pre-render enabled UI pages once; handlers only borrow.
    if (st.swagger_route) |route| {
        st.swagger_page = try renderSwaggerPage(allocator, cfg.swagger.title, st.openapi_route, route);
    }
    if (st.redoc_route) |route| {
        const script = try joinRoute(allocator, route, "redoc.standalone.js");
        st.redoc_page = try renderRedocPage(allocator, cfg.redoc.title, st.openapi_route, script);
    }
    if (st.scalar_route) |route| {
        const script = try joinRoute(allocator, route, "standalone.js");
        st.scalar_page = try renderScalarPage(allocator, cfg.scalar.title, st.openapi_route, script);
    }
    if (st.graphiql_route) |route| {
        st.graphiql_page = try renderGraphiqlPage(allocator, cfg.graphiql.title, st.graphql_endpoint.?, route);
    }

    if (cfg.openapi.enabled and st.openapi_route.len > 0) {
        try router.get(st.openapi_route, openApiHandler);
    }
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
    if (st.graphiql_route) |route| {
        try router.get(route, graphiqlPageHandler);
        for (assets.graphiql_files) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.get(full, graphiqlAssetHandler);
        }
    }

    g_state = st;
}

/// Frees mounted docs state. Safe to call when nothing is mounted.
pub fn unmount() void {
    if (g_state) |st| {
        const a = st.allocator;
        a.free(st.openapi_route);
        if (st.swagger_route) |p| a.free(p);
        if (st.redoc_route) |p| a.free(p);
        if (st.scalar_route) |p| a.free(p);
        if (st.graphiql_route) |p| a.free(p);
        if (st.graphql_endpoint) |p| a.free(p);
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

fn openApiHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    if (openapi.generate(st.allocator, st.router, st.info)) |fresh_spec| {
        if (st.spec) |old| st.allocator.free(old);
        st.spec = fresh_spec;
    } else |_| {}
    return .{ .status = 200, .content_type = "application/json; charset=utf-8", .body = st.spec.? };
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

fn graphiqlPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState();
    _ = ctx;
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = st.graphiql_page.? };
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

fn graphiqlAssetHandler(ctx: *Context) anyerror!Response {
    return serveAsset(ctx, .graphiql, ctx.path);
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

fn renderSwaggerPage(a: Allocator, title: []const u8, spec_url: []const u8, swagger_route: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<link rel=\"stylesheet\" href=\"");
    try escapeInto(w, swagger_route);
    try w.writeAll("/swagger-ui.css\">\n<link rel=\"icon\" type=\"image/png\" href=\"");
    try escapeInto(w, swagger_route);
    try w.writeAll("/favicon-32x32.png\">\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"");
    try escapeInto(w, swagger_route);
    try w.writeAll("/swagger-ui-bundle.js\"></script>\n<script src=\"");
    try escapeInto(w, swagger_route);
    try w.writeAll("/swagger-ui-standalone-preset.js\"></script>\n<script>\nwindow.onload = function () {\n  const ui = SwaggerUIBundle({\n    url: '");
    try escapeInto(w, spec_url);
    try w.writeAll("',\n    dom_id: '#swagger-ui',\n    deepLinking: true,\n    presets: [\n      SwaggerUIBundle.presets.apis,\n      SwaggerUIStandalonePreset\n    ],\n    plugins: [\n      SwaggerUIBundle.plugins.DownloadUrl\n    ],\n    layout: 'StandaloneLayout',\n    oauth2RedirectUrl: window.location.origin + '");
    try escapeInto(w, swagger_route);
    try w.writeAll("/oauth2-redirect.html'\n  });\n  window.ui = ui;\n};\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderRedocPage(a: Allocator, title: []const u8, spec_url: []const u8, script_url: []const u8) ![]u8 {
    defer a.free(script_url);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<link href=\"https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700\" rel=\"stylesheet\">\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<div id=\"redoc-container\"></div>\n<script src=\"");
    try escapeInto(w, script_url);
    try w.writeAll("\"></script>\n<script>\nwindow.onload = function () {\n  Redoc.init('");
    try escapeInto(w, spec_url);
    try w.writeAll("', {}, document.getElementById('redoc-container'));\n};\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderScalarPage(a: Allocator, title: []const u8, spec_url: []const u8, script_url: []const u8) ![]u8 {
    defer a.free(script_url);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<script id=\"api-reference\" data-url=\"");
    try escapeInto(w, spec_url);
    try w.writeAll("\"></script>\n<script src=\"");
    try escapeInto(w, script_url);
    try w.writeAll("\"></script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderGraphiqlPage(a: Allocator, title: []const u8, graphql_endpoint: []const u8, graphiql_route: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n<title>");
    try escapeInto(w, title);
    try w.writeAll("</title>\n<link rel=\"stylesheet\" href=\"");
    try escapeInto(w, graphiql_route);
    try w.writeAll("/graphiql.css\">\n<style>\n  html, body, #graphiql {\n    height: 100%;\n    margin: 0;\n    width: 100%;\n    overflow: hidden;\n  }\n</style>\n</head>\n<body>\n<div id=\"graphiql\"></div>\n<script>\n  window.__GRAPHIQL_BASE_PATH__ = '");
    try escapeInto(w, graphiql_route);
    try w.writeAll("';\n</script>\n<script src=\"");
    try escapeInto(w, graphiql_route);
    try w.writeAll("/graphiql.js\"></script>\n<script>\n  window.onload = function() {\n    if (window.renderGraphiQL) {\n      window.renderGraphiQL(document.getElementById('graphiql'), {\n        endpoint: '");
    try escapeInto(w, graphql_endpoint);
    try w.writeAll("'\n      });\n    }\n  };\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

// Tests

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
    try std.testing.expect(std.mem.indexOf(u8, page.body, "swagger-ui-bundle.js") != null);
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

    // Scalar page + bundle (enabled by default).
    const scalar_page = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, scalar_page.body, "id=\"api-reference\"") != null);
    const scalar_js = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(assets.scalar_standalone_js.len, scalar_js.body.len);
}

test "scalar opt-in mounts its page and bundle" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id}", helloHandler);

    try mount(a, &router, .{ .redoc = .{ .enabled = false }, .scalar = .{ .enabled = true } }, null);
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

    try mount(a, &router, .{ .enabled = false }, null);
    try std.testing.expect(g_state == null);
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
}

test "openapi disabled option suppresses /openapi.json only" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/ping", helloHandler);

    try mount(a, &router, .{ .openapi = .{ .enabled = false }, .swagger = .{ .enabled = true } }, null);
    defer unmount();

    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/docs", a)) != null);
}

test "conflicting user route is reported, not overwritten" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/docs", helloHandler); // user already owns /docs

    try std.testing.expectError(error.DuplicateRoute, mount(a, &router, .{}, null));
    unmount(); // partial state cleaned up
    try std.testing.expect(g_state == null);
}

test "graphiql opt-in mounts its page and all worker assets" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/graphql", helloHandler);

    try mount(a, &router, .{ .graphiql = .{ .enabled = true, .graphql_endpoint = "/graphql" } }, null);
    defer unmount();

    const page = (try invoke(&router, .GET, "/graphiql", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"graphiql\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.css") != null);

    const js = (try invoke(&router, .GET, "/graphiql/graphiql.js", a)).?;
    try std.testing.expectEqual(assets.graphiql_js.len, js.body.len);

    const css = (try invoke(&router, .GET, "/graphiql/graphiql.css", a)).?;
    try std.testing.expectEqual(assets.graphiql_css.len, css.body.len);

    const worker = (try invoke(&router, .GET, "/graphiql/graphql.worker.js", a)).?;
    try std.testing.expectEqual(assets.graphiql_graphql_worker_js.len, worker.body.len);
}
