//! Built-in API documentation UIs: Swagger UI, ReDoc, Scalar.
//!
//! All vendor assets are embedded (see `assets.zig`) and served locally —
//! never from a CDN. Mounting registers:
//!
//!   GET {openapiRoute}              -> OpenAPI 3.1 JSON of current routes
//!   GET {swaggerRoute}              -> Swagger UI page
//!   GET {swaggerRoute}/<asset>      -> Swagger UI bundle files
//!   GET {redocRoute}                -> ReDoc page
//!   GET {redocRoute}/<asset>        -> ReDoc bundle
//!   GET {scalarRoute}               -> Scalar page
//!   GET {scalarRoute}/standalone.js -> Scalar bundle
//!
//! Route conflicts are surfaced as Router errors, never silently overwritten.
//!
//! Handlers are capture-less fn pointers, so mounted state is carried in
//! `Context.userData`. Each router mount owns its own state; `unmountRouter`
//! releases one mount and `unmount` releases every remaining mount.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configCoerce = @import("../../common/configCoerce.zig");
const routerMod = @import("../router/router.zig");
const Router = routerMod.Router;
const Response = routerMod.Response;
const Context = routerMod.Context;
const Method = @import("../../common/method.zig").Method;
const mediaTypeMod = @import("../../common/mediaType.zig");
const openapi = @import("../openApi/openApiSpec.zig");
const assets = @import("assets.zig");
const metaMod = @import("../router/routeMetadata.zig");
const versionInfo = @import("../../common/version.zig");

/// Operation expansion for Swagger UI: `list`, `full`, or `none`.
pub const DocExpansion = enum { list, full, none };
pub const DefaultModelRendering = enum { example, model };
pub const SubmitMethod = enum { get, put, post, delete, options, head, patch, trace };

/// A single custom HTTP header. Only needed when the built-in header fields on
/// `GraphiQLHeaders` do not cover the request.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// GraphiQL request headers. Common headers use flat fields so the simple case
/// stays a single `.{ ... }` literal; `custom` is used only for extra headers.
pub const GraphiQLHeaders = struct {
    authorization: []const u8 = "",
    cookie: []const u8 = "",
    accept: []const u8 = "",
    custom: []const Header = &.{},
};

/// Swagger UI options. Every field is explicit and typed; omitted fields use
/// the vendor defaults documented next to each option.
pub const SwaggerConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/docs",
    title: []const u8 = "Swagger UI",
    docExpansion: DocExpansion = .list,
    defaultModelRendering: DefaultModelRendering = .example,
    defaultModelsExpandDepth: i32 = 1,
    defaultModelExpandDepth: i32 = 1,
    deepLinking: bool = true,
    displayOperationId: bool = false,
    displayRequestDuration: bool = false,
    filter: bool = false,
    persistAuthorization: bool = false,
    tryItOutEnabled: bool = false,
    showExtensions: bool = false,
    showCommonExtensions: bool = false,
    showMutatedRequest: bool = true,
    withCredentials: bool = false,
    useUnsafeMarkdown: bool = false,
    requestSnippetsEnabled: bool = false,
    /// `null` shows every tag.
    maxDisplayedTags: ?i32 = null,
    /// `null` disables the online validator; empty uses the vendor default.
    validatorUrl: ?[]const u8 = null,
    /// Methods allowed in "Try it out"; empty means every method.
    supportedSubmitMethods: []const SubmitMethod = &.{},
    /// OAuth2 redirect URL; null serves `{route}/oauth2-redirect.html`.
    oauth2RedirectUrl: ?[]const u8 = null,
};

/// ReDoc options. Every field maps to the matching `Redoc.init` option.
pub const RedocConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/redoc",
    title: []const u8 = "ReDoc",
    hideHostname: bool = false,
    hideDownloadButton: bool = false,
    hideFab: bool = false,
    hideLoading: bool = false,
    hideLogo: bool = false,
    hideSecuritySection: bool = false,
    /// Comma-separated status codes expanded by default, e.g. `"200,201"`.
    expandResponses: []const u8 = "",
    pathInMiddlePanel: bool = false,
    requiredPropsFirst: bool = false,
    sortPropsAlphabetically: bool = false,
    sortEnumValuesAlphabetically: bool = false,
    noAutoAuth: bool = false,
    disableSearch: bool = false,
    nativeScrollbars: bool = false,
    onlyRequiredInSamples: bool = false,
    menuToggle: bool = false,
    jsonSampleExpandLevel: i32 = 2,
    generatedPayloadSamplesMaxDepth: i32 = 10,
    /// Offset in pixels applied to the menu when scrolling; null uses the
    /// vendor default.
    scrollYOffset: ?i32 = null,
};

/// Scalar options. Every field is written into the page's
/// `data-configuration` JSON, so no option is silently dropped.
pub const ScalarConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/scalar",
    title: []const u8 = "Scalar API Reference",
    /// `default`, `alternate`, `moon`, `purple`, `solarized`, …
    theme: []const u8 = "default",
    darkMode: bool = false,
    hideModels: bool = false,
    hideDownloadButton: bool = false,
    hideTestRequestButton: bool = false,
    hideClientButton: bool = false,
    isEditable: bool = false,
    showSidebar: bool = true,
    showDeveloperTools: bool = false,
    defaultOpenAllTags: bool = false,
    telemetry: bool = true,
    persistAuth: bool = false,
    withDefaultFonts: bool = true,
    /// Search hotkey, e.g. `"k"`.
    searchHotKey: []const u8 = "k",
    /// Optional proxy URL for "Try it out" requests.
    proxyUrl: []const u8 = "",
    /// Optional custom CSS injected into the page.
    customCss: []const u8 = "",
};

/// GraphiQL options passed to `window.renderGraphiQL(element, options)`.
pub const GraphiQLConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/graphiql",
    graphqlEndpoint: []const u8 = "/graphql",
    title: []const u8 = "GraphiQL IDE",
    /// Query pre-filled in the editor.
    defaultQuery: []const u8 = "",
    /// Monaco editor theme, e.g. `"vs-dark"`.
    editorTheme: []const u8 = "",
    /// Extra HTTP headers attached to every GraphQL request.
    headers: GraphiQLHeaders = .{},
    shouldPersistHeaders: bool = false,
    inputValueDeprecation: bool = false,
    schemaDescription: bool = false,
    docExplorerOpen: bool = false,
    isHeadersEditorEnabled: bool = true,
};

pub const OpenApiConfig = struct {
    enabled: bool = true,
    route: []const u8 = "/openapi.json",
};

pub const Config = struct {
    /// Master switch; when false nothing is registered.
    enabled: bool = true,
    title: []const u8 = versionInfo.defaultInfo.title,
    version: []const u8 = versionInfo.version,
    description: []const u8 = versionInfo.defaultInfo.description,
    openapi: OpenApiConfig = .{},
    swagger: SwaggerConfig = .{},
    redoc: RedocConfig = .{},
    scalar: ScalarConfig = .{},
    graphiql: GraphiQLConfig = .{},
};

const DocsState = struct {
    allocator: Allocator,
    spec: ?[]u8 = null,
    openapiRoute: []u8,
    swaggerRoute: ?[]u8 = null,
    redocRoute: ?[]u8 = null,
    scalarRoute: ?[]u8 = null,
    graphiqlRoute: ?[]u8 = null,
    graphqlEndpoint: ?[]u8 = null,
    title: []u8 = &.{},
    router: *const Router,
    /// Next mount in the process-wide registry used by `unmount`.
    next: ?*DocsState = null,
    info: openapi.Info,
    /// Pages are rendered once at mount; handlers hand out borrowed slices
    /// so request handling performs zero dynamic allocation.
    swaggerPage: ?[]u8 = null,
    redocPage: ?[]u8 = null,
    scalarPage: ?[]u8 = null,
    graphiqlPage: ?[]u8 = null,

    fn deinitPages(self: *DocsState) void {
        const a = self.allocator;
        if (self.swaggerPage) |p| a.free(p);
        if (self.redocPage) |p| a.free(p);
        if (self.scalarPage) |p| a.free(p);
        if (self.graphiqlPage) |p| a.free(p);
        if (self.spec) |s| a.free(s);
        self.swaggerPage = null;
        self.redocPage = null;
        self.scalarPage = null;
        self.graphiqlPage = null;
        self.spec = null;
    }
};

var gMounts: ?*DocsState = null;

fn removeRoutes(st: *DocsState) void {
    const a = st.allocator;
    const router = @constCast(st.router);
    if (st.openapiRoute.len > 0) _ = router.remove(.GET, st.openapiRoute);
    if (st.swaggerRoute) |route| {
        _ = router.remove(.GET, route);
        for (assets.swaggerFiles) |f| {
            const full = joinRoute(a, route, f.name) catch continue;
            defer a.free(full);
            _ = router.remove(.GET, full);
        }
    }
    if (st.redocRoute) |route| {
        _ = router.remove(.GET, route);
        for (assets.redocFiles) |f| {
            const full = joinRoute(a, route, f.name) catch continue;
            defer a.free(full);
            _ = router.remove(.GET, full);
        }
    }
    if (st.scalarRoute) |route| {
        _ = router.remove(.GET, route);
        const full = joinRoute(a, route, "standalone.js") catch null;
        if (full) |fp| {
            defer a.free(fp);
            _ = router.remove(.GET, fp);
        }
    }
    if (st.graphiqlRoute) |route| {
        _ = router.remove(.GET, route);
        for (assets.graphiqlFiles) |f| {
            const full = joinRoute(a, route, f.name) catch continue;
            defer a.free(full);
            _ = router.remove(.GET, full);
        }
    }
}

fn freeState(st: *DocsState) void {
    removeRoutes(st);
    const a = st.allocator;
    a.free(st.openapiRoute);
    if (st.swaggerRoute) |p| a.free(p);
    if (st.redocRoute) |p| a.free(p);
    if (st.scalarRoute) |p| a.free(p);
    if (st.graphiqlRoute) |p| a.free(p);
    if (st.graphqlEndpoint) |p| a.free(p);
    a.free(st.title);
    st.deinitPages();
    a.destroy(st);
}

/// Registers documentation routes on `router` and captures the generated
/// OpenAPI document. The spec reflects routes registered BEFORE this call.
pub fn mount(
    allocator: Allocator,
    router: *Router,
    cfg_in: anytype,
    info: ?openapi.Info,
) !void {
    const cfg = configCoerce.to(Config, cfg_in);
    if (!cfg.enabled) return;

    const actualInfo = info orelse openapi.Info{
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
        for (assets.swaggerFiles) |f| {
            const full = try joinRoute(allocator, cfg.swagger.route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (cfg.redoc.enabled) {
        for (assets.redocFiles) |f| {
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
        for (assets.graphiqlFiles) |f| {
            const full = try joinRoute(allocator, cfg.graphiql.route, f.name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }

    const st = try allocator.create(DocsState);
    errdefer allocator.destroy(st);
    st.* = .{
        .allocator = allocator,
        .openapiRoute = &.{},
        .router = router,
        .info = actualInfo,
    };
    errdefer {
        allocator.free(st.openapiRoute);
        if (st.swaggerRoute) |p| allocator.free(p);
        if (st.redocRoute) |p| allocator.free(p);
        if (st.scalarRoute) |p| allocator.free(p);
        if (st.graphiqlRoute) |p| allocator.free(p);
        if (st.graphqlEndpoint) |p| allocator.free(p);
        allocator.free(st.title);
        st.deinitPages();
    }

    st.openapiRoute = try normalizeRoute(allocator, cfg.openapi.route);
    st.title = try allocator.dupe(u8, cfg.title);
    if (cfg.swagger.enabled and cfg.swagger.route.len > 0)
        st.swaggerRoute = try normalizeRoute(allocator, cfg.swagger.route);
    if (cfg.redoc.enabled and cfg.redoc.route.len > 0)
        st.redocRoute = try normalizeRoute(allocator, cfg.redoc.route);
    if (cfg.scalar.enabled and cfg.scalar.route.len > 0)
        st.scalarRoute = try normalizeRoute(allocator, cfg.scalar.route);
    if (cfg.graphiql.enabled and cfg.graphiql.route.len > 0) {
        st.graphiqlRoute = try normalizeRoute(allocator, cfg.graphiql.route);
        st.graphqlEndpoint = try normalizeRoute(allocator, cfg.graphiql.graphqlEndpoint);
    }

    st.spec = try openapi.generate(router, actualInfo);

    // Pre-render enabled UI pages once; handlers only borrow.
    if (st.swaggerRoute) |route| {
        st.swaggerPage = try renderSwaggerPage(allocator, cfg.swagger, st.openapiRoute, route);
    }
    if (st.redocRoute) |route| {
        const script = try joinRoute(allocator, route, "redoc.standalone.js");
        st.redocPage = try renderRedocPage(allocator, cfg.redoc, st.openapiRoute, script);
    }
    if (st.scalarRoute) |route| {
        const script = try joinRoute(allocator, route, "standalone.js");
        st.scalarPage = try renderScalarPage(allocator, cfg.scalar, st.openapiRoute, script);
    }
    if (st.graphiqlRoute) |route| {
        st.graphiqlPage = try renderGraphiqlPage(allocator, cfg.graphiql, st.graphqlEndpoint.?, route);
    }

    const internalMeta: metaMod.Metadata = .{ .internal = true };

    // Roll back partial registration on error so a failed mount leaves no
    // stray docs routes behind (pre-checks make this rare, e.g. OOM only).
    errdefer removeRoutes(st);

    if (cfg.openapi.enabled and st.openapiRoute.len > 0) {
        try router.add(.GET, st.openapiRoute, openApiHandler, .{ .meta = internalMeta, .userData = st });
    }
    if (st.swaggerRoute) |route| {
        try router.add(.GET, route, swaggerPageHandler, .{ .meta = internalMeta, .userData = st });
        for (assets.swaggerFiles) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.add(.GET, full, swaggerAssetHandler, .{ .meta = internalMeta });
        }
    }
    if (st.redocRoute) |route| {
        try router.add(.GET, route, redocPageHandler, .{ .meta = internalMeta, .userData = st });
        for (assets.redocFiles) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.add(.GET, full, redocAssetHandler, .{ .meta = internalMeta });
        }
    }
    if (st.scalarRoute) |route| {
        try router.add(.GET, route, scalarPageHandler, .{ .meta = internalMeta, .userData = st });
        const full = try joinRoute(allocator, route, "standalone.js");
        defer allocator.free(full);
        try router.add(.GET, full, scalarAssetHandler, .{ .meta = internalMeta });
    }
    if (st.graphiqlRoute) |route| {
        try router.add(.GET, route, graphiqlPageHandler, .{ .meta = internalMeta, .userData = st });
        for (assets.graphiqlFiles) |f| {
            const full = try joinRoute(allocator, route, f.name);
            defer allocator.free(full);
            try router.add(.GET, full, graphiqlAssetHandler, .{ .meta = internalMeta });
        }
    }
    st.next = gMounts;
    gMounts = st;
}

/// Frees the docs state mounted on `router`. Other mounts are untouched.
pub fn unmountRouter(router: *const Router) void {
    var link = &gMounts;
    while (link.*) |st| {
        if (st.router == router) {
            link.* = st.next;
            freeState(st);
            return;
        }
        link = &st.next;
    }
}

/// Frees every mounted docs state. Safe to call when nothing is mounted.
pub fn unmount() void {
    var current = gMounts;
    gMounts = null;
    while (current) |st| {
        const next = st.next;
        freeState(st);
        current = next;
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

fn requireState(ctx: *Context) *DocsState {
    return @ptrCast(@alignCast(ctx.userData orelse unreachable));
}

fn openApiHandler(ctx: *Context) anyerror!Response {
    const st = requireState(ctx);
    // The document is a snapshot taken at mount time. It is served read-only:
    // regenerating on each request would free the buffer another in-flight
    // request may still be writing.
    return .{ .status = 200, .contentType = mediaTypeMod.applicationJsonUtf8, .body = st.spec.? };
}

fn swaggerPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState(ctx);
    return .{ .status = 200, .contentType = mediaTypeMod.textHtmlUtf8, .body = st.swaggerPage.? };
}

fn redocPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState(ctx);
    return .{ .status = 200, .contentType = mediaTypeMod.textHtmlUtf8, .body = st.redocPage.? };
}

fn scalarPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState(ctx);
    return .{ .status = 200, .contentType = mediaTypeMod.textHtmlUtf8, .body = st.scalarPage.? };
}

fn graphiqlPageHandler(ctx: *Context) anyerror!Response {
    const st = requireState(ctx);
    return .{ .status = 200, .contentType = mediaTypeMod.textHtmlUtf8, .body = st.graphiqlPage.? };
}

fn swaggerAssetHandler(ctx: *Context) anyerror!Response {
    return serveAsset(ctx, .swaggerUi, ctx.path);
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
        return .{ .status = 404, .contentType = mediaTypeMod.textPlainUtf8, .body = "not found" };
    _ = ctx;
    return .{ .status = 200, .contentType = f.contentType, .body = f.data };
}

// page rendering

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

/// Serializes `value` as a JSON literal that is safe inside an inline
/// `<script>`: JSON is valid JavaScript, and `<`, `>`, `&` are escaped so a
/// string can never terminate the script element.
fn writeJsonScript(a: Allocator, w: anytype, value: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    for (bytes) |c| switch (c) {
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        else => try w.writeByte(c),
    };
}

/// Serializes `value` as JSON for an HTML attribute value.
fn writeJsonAttr(a: Allocator, w: anytype, value: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    try escapeInto(w, bytes);
}

fn renderSwaggerPage(a: Allocator, cfg: SwaggerConfig, specUrl: []const u8, swaggerRoute: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const redirect = if (cfg.oauth2RedirectUrl) |url| url else try joinRoute(aa, swaggerRoute, "oauth2-redirect.html");
    var opts = try std.json.ObjectMap.init(aa, &.{}, &.{});
    try opts.put(aa, "url", std.json.Value{ .string = specUrl });
    try opts.put(aa, "dom_id", std.json.Value{ .string = "#swagger-ui" });
    try opts.put(aa, "layout", std.json.Value{ .string = "StandaloneLayout" });
    try opts.put(aa, "docExpansion", std.json.Value{ .string = @tagName(cfg.docExpansion) });
    try opts.put(aa, "defaultModelRendering", std.json.Value{ .string = @tagName(cfg.defaultModelRendering) });
    try opts.put(aa, "defaultModelsExpandDepth", std.json.Value{ .integer = cfg.defaultModelsExpandDepth });
    try opts.put(aa, "defaultModelExpandDepth", std.json.Value{ .integer = cfg.defaultModelExpandDepth });
    try opts.put(aa, "deepLinking", std.json.Value{ .bool = cfg.deepLinking });
    try opts.put(aa, "displayOperationId", std.json.Value{ .bool = cfg.displayOperationId });
    try opts.put(aa, "displayRequestDuration", std.json.Value{ .bool = cfg.displayRequestDuration });
    try opts.put(aa, "filter", std.json.Value{ .bool = cfg.filter });
    try opts.put(aa, "persistAuthorization", std.json.Value{ .bool = cfg.persistAuthorization });
    try opts.put(aa, "tryItOutEnabled", std.json.Value{ .bool = cfg.tryItOutEnabled });
    try opts.put(aa, "showExtensions", std.json.Value{ .bool = cfg.showExtensions });
    try opts.put(aa, "showCommonExtensions", std.json.Value{ .bool = cfg.showCommonExtensions });
    try opts.put(aa, "showMutatedRequest", std.json.Value{ .bool = cfg.showMutatedRequest });
    try opts.put(aa, "withCredentials", std.json.Value{ .bool = cfg.withCredentials });
    try opts.put(aa, "useUnsafeMarkdown", std.json.Value{ .bool = cfg.useUnsafeMarkdown });
    try opts.put(aa, "requestSnippetsEnabled", std.json.Value{ .bool = cfg.requestSnippetsEnabled });
    if (cfg.maxDisplayedTags) |v| try opts.put(aa, "maxDisplayedTags", std.json.Value{ .integer = v });
    if (cfg.validatorUrl) |v| try opts.put(aa, "validatorUrl", std.json.Value{ .string = v });
    if (cfg.supportedSubmitMethods.len > 0) {
        var methods: std.json.Array = .init(aa);
        for (cfg.supportedSubmitMethods) |method| {
            try methods.append(.{ .string = @tagName(method) });
        }
        try opts.put(aa, "supportedSubmitMethods", .{ .array = methods });
    }
    try opts.put(aa, "oauth2RedirectUrl", std.json.Value{ .string = redirect });

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, cfg.title);
    try w.writeAll("</title>\n<link rel=\"stylesheet\" href=\"");
    try escapeInto(w, swaggerRoute);
    try w.writeAll("/swagger-ui.css\">\n<link rel=\"icon\" type=\"image/png\" href=\"");
    try escapeInto(w, swaggerRoute);
    try w.writeAll("/favicon-32x32.png\">\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"");
    try escapeInto(w, swaggerRoute);
    try w.writeAll("/swagger-ui-bundle.js\"></script>\n<script src=\"");
    try escapeInto(w, swaggerRoute);
    try w.writeAll("/swagger-ui-standalone-preset.js\"></script>\n<script>\nwindow.onload = function () {\n  const options = ");
    try writeJsonScript(a, w, std.json.Value{ .object = opts });
    try w.writeAll(";\n  options.presets = [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset];\n  options.plugins = [SwaggerUIBundle.plugins.DownloadUrl];\n  window.ui = SwaggerUIBundle(options);\n};\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderRedocPage(a: Allocator, cfg: RedocConfig, specUrl: []const u8, scriptUrl: []const u8) ![]u8 {
    defer a.free(scriptUrl);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var opts = try std.json.ObjectMap.init(aa, &.{}, &.{});
    try opts.put(aa, "hideHostname", std.json.Value{ .bool = cfg.hideHostname });
    try opts.put(aa, "hideDownloadButton", std.json.Value{ .bool = cfg.hideDownloadButton });
    try opts.put(aa, "hideFab", std.json.Value{ .bool = cfg.hideFab });
    try opts.put(aa, "hideLoading", std.json.Value{ .bool = cfg.hideLoading });
    try opts.put(aa, "hideLogo", std.json.Value{ .bool = cfg.hideLogo });
    try opts.put(aa, "hideSecuritySection", std.json.Value{ .bool = cfg.hideSecuritySection });
    try opts.put(aa, "expandResponses", std.json.Value{ .string = cfg.expandResponses });
    try opts.put(aa, "pathInMiddlePanel", std.json.Value{ .bool = cfg.pathInMiddlePanel });
    try opts.put(aa, "requiredPropsFirst", std.json.Value{ .bool = cfg.requiredPropsFirst });
    try opts.put(aa, "sortPropsAlphabetically", std.json.Value{ .bool = cfg.sortPropsAlphabetically });
    try opts.put(aa, "sortEnumValuesAlphabetically", std.json.Value{ .bool = cfg.sortEnumValuesAlphabetically });
    try opts.put(aa, "noAutoAuth", std.json.Value{ .bool = cfg.noAutoAuth });
    try opts.put(aa, "disableSearch", std.json.Value{ .bool = cfg.disableSearch });
    try opts.put(aa, "nativeScrollbars", std.json.Value{ .bool = cfg.nativeScrollbars });
    try opts.put(aa, "onlyRequiredInSamples", std.json.Value{ .bool = cfg.onlyRequiredInSamples });
    try opts.put(aa, "menuToggle", std.json.Value{ .bool = cfg.menuToggle });
    try opts.put(aa, "jsonSampleExpandLevel", std.json.Value{ .integer = cfg.jsonSampleExpandLevel });
    try opts.put(aa, "generatedPayloadSamplesMaxDepth", std.json.Value{ .integer = cfg.generatedPayloadSamplesMaxDepth });
    if (cfg.scrollYOffset) |v| try opts.put(aa, "scrollYOffset", std.json.Value{ .integer = v });

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, cfg.title);
    try w.writeAll("</title>\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<div id=\"redoc-container\"></div>\n<script type=\"module\">\n  import { init } from \"");
    try escapeInto(w, scriptUrl);
    try w.writeAll("\";\n  init(\"");
    try escapeInto(w, specUrl);
    try w.writeAll("\", ");
    try writeJsonScript(a, w, std.json.Value{ .object = opts });
    try w.writeAll(", document.getElementById('redoc-container'));\n</script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderScalarPage(a: Allocator, cfg: ScalarConfig, specUrl: []const u8, scriptUrl: []const u8) ![]u8 {
    defer a.free(scriptUrl);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var opts = try std.json.ObjectMap.init(aa, &.{}, &.{});
    try opts.put(aa, "theme", std.json.Value{ .string = cfg.theme });
    try opts.put(aa, "darkMode", std.json.Value{ .bool = cfg.darkMode });
    try opts.put(aa, "hideModels", std.json.Value{ .bool = cfg.hideModels });
    try opts.put(aa, "hideDownloadButton", std.json.Value{ .bool = cfg.hideDownloadButton });
    try opts.put(aa, "hideTestRequestButton", std.json.Value{ .bool = cfg.hideTestRequestButton });
    try opts.put(aa, "hideClientButton", std.json.Value{ .bool = cfg.hideClientButton });
    try opts.put(aa, "isEditable", std.json.Value{ .bool = cfg.isEditable });
    try opts.put(aa, "showSidebar", std.json.Value{ .bool = cfg.showSidebar });
    try opts.put(aa, "showDeveloperTools", std.json.Value{ .bool = cfg.showDeveloperTools });
    try opts.put(aa, "defaultOpenAllTags", std.json.Value{ .bool = cfg.defaultOpenAllTags });
    try opts.put(aa, "telemetry", std.json.Value{ .bool = cfg.telemetry });
    try opts.put(aa, "persistAuth", std.json.Value{ .bool = cfg.persistAuth });
    try opts.put(aa, "withDefaultFonts", std.json.Value{ .bool = cfg.withDefaultFonts });
    try opts.put(aa, "searchHotKey", std.json.Value{ .string = cfg.searchHotKey });
    if (cfg.proxyUrl.len > 0) try opts.put(aa, "proxyUrl", std.json.Value{ .string = cfg.proxyUrl });
    if (cfg.customCss.len > 0) try opts.put(aa, "customCss", std.json.Value{ .string = cfg.customCss });

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<title>");
    try escapeInto(w, cfg.title);
    try w.writeAll("</title>\n<style>body { margin: 0; padding: 0; }</style>\n</head>\n<body>\n<script id=\"api-reference\" data-url=\"");
    try escapeInto(w, specUrl);
    try w.writeAll("\" data-configuration=\"");
    try writeJsonAttr(a, w, std.json.Value{ .object = opts });
    try w.writeAll("\"></script>\n<script src=\"");
    try escapeInto(w, scriptUrl);
    try w.writeAll("\"></script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn renderGraphiqlPage(a: Allocator, cfg: GraphiQLConfig, graphqlEndpoint: []const u8, graphiqlRoute: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var opts = try std.json.ObjectMap.init(aa, &.{}, &.{});
    try opts.put(aa, "endpoint", std.json.Value{ .string = graphqlEndpoint });
    if (cfg.defaultQuery.len > 0) try opts.put(aa, "defaultQuery", std.json.Value{ .string = cfg.defaultQuery });
    if (cfg.editorTheme.len > 0) try opts.put(aa, "editorTheme", std.json.Value{ .string = cfg.editorTheme });
    try opts.put(aa, "shouldPersistHeaders", std.json.Value{ .bool = cfg.shouldPersistHeaders });
    try opts.put(aa, "inputValueDeprecation", std.json.Value{ .bool = cfg.inputValueDeprecation });
    try opts.put(aa, "schemaDescription", std.json.Value{ .bool = cfg.schemaDescription });
    try opts.put(aa, "docExplorerOpen", std.json.Value{ .bool = cfg.docExplorerOpen });
    try opts.put(aa, "isHeadersEditorEnabled", std.json.Value{ .bool = cfg.isHeadersEditorEnabled });
    if (cfg.headers.authorization.len > 0 or
        cfg.headers.cookie.len > 0 or
        cfg.headers.accept.len > 0 or
        cfg.headers.custom.len > 0)
    {
        var headers = try std.json.ObjectMap.init(aa, &.{}, &.{});
        if (cfg.headers.authorization.len > 0) try headers.put(aa, "Authorization", .{ .string = cfg.headers.authorization });
        if (cfg.headers.cookie.len > 0) try headers.put(aa, "Cookie", .{ .string = cfg.headers.cookie });
        if (cfg.headers.accept.len > 0) try headers.put(aa, "Accept", .{ .string = cfg.headers.accept });
        for (cfg.headers.custom) |header| {
            try headers.put(aa, header.name, .{ .string = header.value });
        }
        try opts.put(aa, "headers", .{ .object = headers });
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n<base href=\"");
    try escapeInto(w, graphiqlRoute);
    if (graphiqlRoute.len == 0 or graphiqlRoute[graphiqlRoute.len - 1] != '/') try w.writeByte('/');
    try w.writeAll("\">\n<title>");
    try escapeInto(w, cfg.title);
    try w.writeAll("</title>\n<link rel=\"stylesheet\" href=\"");
    try escapeInto(w, graphiqlRoute);
    try w.writeAll("/graphiql.css\">\n<style>\n  html, body, #graphiql {\n    height: 100%;\n    margin: 0;\n    width: 100%;\n    overflow: hidden;\n  }\n</style>\n</head>\n<body>\n<div id=\"graphiql\"></div>\n<script>\n  window.__GRAPHIQL_BASE_PATH__ = '");
    try escapeInto(w, graphiqlRoute);
    try w.writeAll("';\n</script>\n<script src=\"");
    try escapeInto(w, graphiqlRoute);
    try w.writeAll("/graphiql.js\"></script>\n<script>\n  window.onload = function() {\n    if (window.renderGraphiQL) {\n      window.renderGraphiQL(document.getElementById('graphiql'), ");
    try writeJsonScript(a, w, std.json.Value{ .object = opts });
    try w.writeAll(");\n    }\n  };\n</script>\n</body>\n</html>\n");
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
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/hello", helloHandler, .{});

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
    try std.testing.expectEqualStrings("text/html; charset=utf-8", page.contentType.?);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "swagger-ui-bundle.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "cdn") == null);

    // Handlers borrow pre-rendered pages: repeat invocation is stable and
    // allocation-free.
    const again = (try invoke(&router, .GET, "/docs", a)).?;
    try std.testing.expectEqual(page.body.ptr, again.body.ptr);

    // Bundle served from embedded bytes.
    const bundle = (try invoke(&router, .GET, "/docs/swagger-ui-bundle.js", a)).?;
    try std.testing.expect(bundle.body.len == assets.swaggerUiBundleJs.len);
    try std.testing.expect(std.mem.startsWith(u8, bundle.body, "/*!"));

    // Unknown asset name does not fall through to any catch-all route.
    try std.testing.expect((try invoke(&router, .GET, "/docs/nonexistent.js", a)) == null);

    // ReDoc page + bundle. The vendor bundle is an ES module, so the page
    // loads it as one and calls its exported init function.
    const redocPage = (try invoke(&router, .GET, "/redoc", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, redocPage.body, "redoc.standalone.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, redocPage.body, "type=\"module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, redocPage.body, "import { init }") != null);
    try std.testing.expect(std.mem.indexOf(u8, redocPage.body, "fonts.googleapis.com") == null);
    const redocJs = (try invoke(&router, .GET, "/redoc/redoc.standalone.js", a)).?;
    try std.testing.expect(redocJs.body.len == assets.redocStandaloneJs.len);

    // Scalar page + bundle (enabled by default).
    const scalarPage = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, scalarPage.body, "id=\"api-reference\"") != null);
    const scalarJs = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(assets.scalarStandaloneJs.len, scalarJs.body.len);
}

test "scalar opt-in mounts its page and bundle" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/users/{id}", helloHandler, .{});

    try mount(a, &router, .{ .redoc = .{ .enabled = false }, .scalar = .{ .enabled = true } }, null);
    defer unmount();

    const page = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"api-reference\"") != null);
    const js = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(assets.scalarStandaloneJs.len, js.body.len);

    const res = (try invoke(&router, .GET, "/openapi.json", a)).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("paths").?.object.get("/users/{id}") != null);
}

test "disabled config registers nothing" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();

    try mount(a, &router, .{ .enabled = false }, null);
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
}

test "disabled docs releases routes to the application" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();

    try mount(a, &router, .{ .enabled = false }, null);

    // The application can now own /docs; requests reach its handler.
    try router.get("/docs", helloHandler, .{});
    const res = (try invoke(&router, .GET, "/docs", a)).?;
    try std.testing.expectEqualStrings("hi", res.body);
}

test "openapi disabled option suppresses /openapi.json only" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/ping", helloHandler, .{});

    try mount(a, &router, .{ .openapi = .{ .enabled = false }, .swagger = .{ .enabled = true } }, null);
    defer unmount();

    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/docs", a)) != null);
}

test "conflicting user route is reported, not overwritten" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/docs", helloHandler, .{}); // user already owns /docs

    try std.testing.expectError(error.DuplicateRoute, mount(a, &router, .{}, null));
    unmount(); // partial state cleaned up
}

test "graphiql opt-in mounts its page and all worker assets" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/graphql", helloHandler, .{});

    try mount(a, &router, .{ .graphiql = .{ .enabled = true, .graphqlEndpoint = "/graphql" } }, null);
    defer unmount();

    const page = (try invoke(&router, .GET, "/graphiql", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"graphiql\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<base href=\"/graphiql/\">") != null);

    const js = (try invoke(&router, .GET, "/graphiql/graphiql.js", a)).?;
    try std.testing.expectEqual(assets.graphiqlJs.len, js.body.len);

    const css = (try invoke(&router, .GET, "/graphiql/graphiql.css", a)).?;
    try std.testing.expectEqual(assets.graphiqlCss.len, css.body.len);
    try std.testing.expect(std.mem.indexOf(u8, css.body, "codicon-mxdk0fnd.ttf") != null);

    const font = (try invoke(&router, .GET, "/graphiql/codicon-mxdk0fnd.ttf", a)).?;
    try std.testing.expectEqualStrings("font/ttf", font.contentType.?);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x00, 0x00 }, font.body[0..4]);
}

test "graphiql codicon font resolves under a custom mount route" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/graphql", helloHandler, .{});

    try mount(a, &router, .{ .graphiql = .{ .enabled = true, .route = "/internal/ide", .graphqlEndpoint = "/graphql" } }, null);
    defer unmount();

    const css = (try invoke(&router, .GET, "/internal/ide/graphiql.css", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, css.body, "url(\"codicon-mxdk0fnd.ttf\")") != null);
    const font = (try invoke(&router, .GET, "/internal/ide/codicon-mxdk0fnd.ttf", a)).?;
    try std.testing.expectEqualStrings("font/ttf", font.contentType.?);

    // Monaco workers resolve against document.baseURI, so a custom mount must
    // pin <base> to the custom route rather than the default one.
    const page = (try invoke(&router, .GET, "/internal/ide", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<base href=\"/internal/ide/\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "/internal/ide/graphiql.js") != null);
}

test "every ui option reaches the rendered page" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/ping", helloHandler, .{});

    try mount(a, &router, .{
        .swagger = .{
            .route = "/api-docs",
            .docExpansion = .full,
            .deepLinking = false,
            .displayOperationId = true,
            .displayRequestDuration = true,
            .filter = true,
            .persistAuthorization = true,
            .tryItOutEnabled = true,
            .defaultModelsExpandDepth = 2,
            .oauth2RedirectUrl = "https://auth.example.com/callback",
        },
        .redoc = .{
            .route = "/reference",
            .hideHostname = true,
            .hideDownloadButton = true,
            .pathInMiddlePanel = true,
            .expandResponses = "200,201",
        },
        .scalar = .{
            .route = "/scalar-docs",
            .theme = "moon",
            .darkMode = true,
            .hideModels = true,
        },
        .graphiql = .{
            .route = "/ide",
            .graphqlEndpoint = "/graphql",
            .defaultQuery = "{ __typename }",
            .editorTheme = "vs-dark",
            .headers = .{ .authorization = "Bearer demo" },
            .docExplorerOpen = true,
        },
    }, null);
    defer unmount();

    const swagger = (try invoke(&router, .GET, "/api-docs", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"docExpansion\":\"full\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"deepLinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"displayOperationId\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"displayRequestDuration\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"filter\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"persistAuthorization\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"tryItOutEnabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "\"defaultModelsExpandDepth\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, swagger.body, "https://auth.example.com/callback") != null);

    const redoc = (try invoke(&router, .GET, "/reference", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, redoc.body, "\"hideHostname\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, redoc.body, "\"hideDownloadButton\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, redoc.body, "\"pathInMiddlePanel\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, redoc.body, "\"expandResponses\":\"200,201\"") != null);

    const scalar = (try invoke(&router, .GET, "/scalar-docs", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, scalar.body, "data-configuration=") != null);
    try std.testing.expect(std.mem.indexOf(u8, scalar.body, "&quot;theme&quot;:&quot;moon&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, scalar.body, "&quot;darkMode&quot;:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, scalar.body, "&quot;hideModels&quot;:true") != null);

    const ide = (try invoke(&router, .GET, "/ide", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, ide.body, "\"defaultQuery\":\"{ __typename }\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ide.body, "\"editorTheme\":\"vs-dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ide.body, "\"Authorization\":\"Bearer demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ide.body, "\"docExplorerOpen\":true") != null);
}

test "all documentation pages are self-hosted and offline" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/hello", helloHandler, .{});

    try mount(a, &router, .{}, null);
    defer unmount();

    const Pages = struct {
        fn page(r: *Router, path: []const u8, alloc: Allocator) !Response {
            return (try invoke(r, .GET, path, alloc)).?;
        }
    };
    const pages = [_][]const u8{ "/docs", "/redoc", "/scalar" };
    for (pages) |path| {
        const res = try Pages.page(&router, path, a);
        try std.testing.expectEqual(@as(u16, 200), res.status);
        // No CDN or external font/script references: every page works from the
        // embedded bundle routes alone.
        try std.testing.expect(std.mem.indexOf(u8, res.body, "https://") == null);
        try std.testing.expect(std.mem.indexOf(u8, res.body, "http://") == null);
        try std.testing.expect(std.mem.indexOf(u8, res.body, "fonts.googleapis.com") == null);
    }
}

test "all vendored assets serve with correct mime and markers" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/hello", helloHandler, .{});

    try mount(a, &router, .{}, .{ .title = "Demo" });
    defer unmount();

    const Case = struct {
        path: []const u8,
        mime: []const u8,
        marker: ?[]const u8 = null,
    };
    const cases = [_]Case{
        // Swagger UI.
        .{ .path = "/docs/swagger-ui-bundle.js", .mime = "text/javascript; charset=utf-8", .marker = "SwaggerUIBundle" },
        .{ .path = "/docs/swagger-ui-standalone-preset.js", .mime = "text/javascript; charset=utf-8", .marker = "SwaggerUIStandalonePreset" },
        .{ .path = "/docs/swagger-ui.css", .mime = "text/css; charset=utf-8", .marker = ".swagger-ui" },
        .{ .path = "/docs/oauth2-redirect.html", .mime = "text/html; charset=utf-8", .marker = "oauth2-redirect.js" },
        .{ .path = "/docs/oauth2-redirect.js", .mime = "text/javascript; charset=utf-8" },
        .{ .path = "/docs/favicon-16x16.png", .mime = "image/png" },
        .{ .path = "/docs/favicon-32x32.png", .mime = "image/png" },
        // ReDoc.
        .{ .path = "/redoc/redoc.standalone.js", .mime = "text/javascript; charset=utf-8", .marker = "Redoc" },
        // Scalar.
        .{ .path = "/scalar/standalone.js", .mime = "text/javascript; charset=utf-8", .marker = "api-reference" },
        // GraphiQL UI, stylesheet, and Monaco workers.
        .{ .path = "/graphiql/graphiql.js", .mime = "text/javascript; charset=utf-8", .marker = "renderGraphiQL" },
        .{ .path = "/graphiql/graphiql.css", .mime = "text/css; charset=utf-8", .marker = ".monaco-editor" },
        .{ .path = "/graphiql/editor.worker.js", .mime = "text/javascript; charset=utf-8" },
        .{ .path = "/graphiql/json.worker.js", .mime = "text/javascript; charset=utf-8" },
        .{ .path = "/graphiql/codicon-mxdk0fnd.ttf", .mime = "font/ttf" },
    };
    for (cases) |c| {
        const res = (try invoke(&router, .GET, c.path, a)).?;
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqualStrings(c.mime, res.contentType.?);
        try std.testing.expect(res.body.len > 0);
        if (c.marker) |m| try std.testing.expect(std.mem.indexOf(u8, res.body, m) != null);
    }

    // Favicons are real PNG images.
    const fav = (try invoke(&router, .GET, "/docs/favicon-32x32.png", a)).?;
    try std.testing.expect(fav.body.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' }, fav.body[0..8]);

    // Pages reference the served local assets (workers included).
    const swaggerPage = (try invoke(&router, .GET, "/docs", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, swaggerPage.body, "oauth2-redirect.html") != null);
    const graphiqlPage = (try invoke(&router, .GET, "/graphiql", a)).?;
    // Workers are lazy-loaded by the bundle at runtime, not linked in the page.
    for ([_][]const u8{ "editor.worker.js", "json.worker.js" }) |asset| {
        try std.testing.expect(std.mem.indexOf(u8, graphiqlPage.body, asset) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, graphiqlPage.body, "/graphiql/graphiql.js") != null);
}

test "disabling swagger and redoc leaves scalar and spec" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/ping", helloHandler, .{});

    try mount(a, &router, .{ .swagger = .{ .enabled = false }, .redoc = .{ .enabled = false } }, null);
    defer unmount();

    try std.testing.expect((try invoke(&router, .GET, "/docs", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/redoc", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/scalar", a)) != null);
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) != null);
}

test "docs mounts are isolated per router and unmount removes routes" {
    const a = std.testing.allocator;
    var first = Router.init(a, .{});
    defer first.deinit();
    var second = Router.init(a, .{});
    defer second.deinit();

    try first.get("/first", helloHandler, .{});
    try second.get("/second", helloHandler, .{});

    try mount(a, &first, .{}, null);
    try mount(a, &second, .{}, null);
    defer unmount();

    // Both mounts serve independently.
    try std.testing.expect((try invoke(&first, .GET, "/openapi.json", a)) != null);
    const second_spec = (try invoke(&second, .GET, "/openapi.json", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, second_spec.body, "/second") != null);

    // Unmounting one router leaves the other mount usable and removes only
    // the first router's docs routes.
    unmountRouter(&first);
    try std.testing.expect((try invoke(&first, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&first, .GET, "/docs", a)) == null);
    try std.testing.expect((try invoke(&second, .GET, "/openapi.json", a)) != null);
    try std.testing.expect((try invoke(&second, .GET, "/docs", a)) != null);
}

test "openapi document is a stable mount-time snapshot" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/before", helloHandler, .{});

    try mount(a, &router, .{}, null);
    defer unmount();

    const first = (try invoke(&router, .GET, "/openapi.json", a)).?;
    const first_copy = try a.dupe(u8, first.body);
    defer a.free(first_copy);

    // Routes added after mounting are not reflected by the read-only snapshot.
    try router.get("/after", helloHandler, .{});
    const second = (try invoke(&router, .GET, "/openapi.json", a)).?;
    try std.testing.expectEqualStrings(first_copy, second.body);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "/after") == null);
}
