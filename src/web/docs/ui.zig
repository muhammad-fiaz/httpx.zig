//! Built-in API documentation UIs: Swagger UI, ReDoc, Scalar, GraphiQL.
//!
//! All vendor assets are embedded (see the isolated `*Assets.zig` modules) and
//! served locally — never from a CDN. Mounting registers:
//!
//!   GET {openapiRoute}              -> OpenAPI 3.1 JSON of current routes
//!   GET {swaggerRoute}              -> Swagger UI page
//!   GET {swaggerRoute}/<asset>      -> Swagger UI bundle files
//!   GET {redocRoute}                -> ReDoc page
//!   GET {redocRoute}/<asset>        -> ReDoc bundle
//!   GET {scalarRoute}               -> Scalar page
//!   GET {scalarRoute}/standalone.js -> Scalar bundle
//!   GET {graphiqlRoute}             -> GraphiQL page
//!   GET {graphiqlRoute}/<asset>     -> GraphiQL bundle, workers, and font
//!
//! Route conflicts are surfaced as Router errors, never silently overwritten.
//!
//! Handlers are capture-less fn pointers, so mounted state is carried in
//! `Context.userData`. Each server mount owns its own state; `unmount`
//! releases one mount and `unmountAll` releases every remaining mount.

const std = @import("std");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Router = routerMod.Router;
const Response = routerMod.Response;
const Context = routerMod.Context;
const Method = @import("../../common/method.zig").Method;
const mediaTypeMod = @import("../../common/mediaType.zig");
const openapi = @import("../openApi/spec.zig");
const assetFile = @import("assetFile.zig");
const testAssets = @import("assets.zig");
const metaMod = @import("../router/routeMetadata.zig");
const versionInfo = @import("../../common/version.zig");
const z = @import("zigantic");
const headersMod = @import("../../common/headers.zig");

// Route teardown needs only stable file names, never asset payloads.
const swaggerAssetNames = [_][]const u8{
    "swagger-ui-bundle.js", "swagger-ui-standalone-preset.js", "swagger-ui.css",
    "oauth2-redirect.html", "oauth2-redirect.js",              "favicon-16x16.png",
    "favicon-32x32.png",
};
const redocAssetNames = [_][]const u8{"redoc.standalone.js"};
const scalarAssetNames = [_][]const u8{"standalone.js"};
const graphiqlAssetNames = [_][]const u8{
    "graphiql.js", "graphiql.css", "editor.worker.js", "json.worker.js", "codicon-mxdk0fnd.ttf",
};

/// Operation expansion for Swagger UI: `list`, `full`, or `none`.
pub const DocExpansion = enum { list, full, none };
pub const DefaultModelRendering = enum { example, model };
pub const SubmitMethod = enum { get, put, post, delete, options, head, patch, trace };

pub const HeaderSchema = headersMod.HeaderSchema;
pub const Header = headersMod.Header;

/// GraphiQL request headers. Common headers use flat fields so the simple case
/// stays a single `.{ ... }` literal; `custom` is used only for extra headers.
pub const GraphiQLHeadersSchema = z.objectOf(.{
    .authorization = z.withDefault(z.string(.{}), ""),
    .cookie = z.withDefault(z.string(.{}), ""),
    .accept = z.withDefault(z.string(.{}), ""),
    .custom = z.withDefault(z.array(HeaderSchema, .{}), &.{}),
}, .{});
pub const GraphiQLHeaders = GraphiQLHeadersSchema.Value;

pub const SwaggerConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .route = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/docs"),
    .title = z.withDefault(z.string(.{}), "Swagger UI"),
    .docExpansion = z.withDefault(z.enumType(DocExpansion, .{}), .list),
    .defaultModelRendering = z.withDefault(z.enumType(DefaultModelRendering, .{}), .example),
    .defaultModelsExpandDepth = z.withDefault(z.integer(i32, .{}), 1),
    .defaultModelExpandDepth = z.withDefault(z.integer(i32, .{}), 1),
    .deepLinking = z.withDefault(z.boolean(.{}), true),
    .displayOperationId = z.withDefault(z.boolean(.{}), false),
    .displayRequestDuration = z.withDefault(z.boolean(.{}), false),
    .filter = z.withDefault(z.boolean(.{}), false),
    .persistAuthorization = z.withDefault(z.boolean(.{}), false),
    .tryItOutEnabled = z.withDefault(z.boolean(.{}), false),
    .showExtensions = z.withDefault(z.boolean(.{}), false),
    .showCommonExtensions = z.withDefault(z.boolean(.{}), false),
    .showMutatedRequest = z.withDefault(z.boolean(.{}), true),
    .withCredentials = z.withDefault(z.boolean(.{}), false),
    .useUnsafeMarkdown = z.withDefault(z.boolean(.{}), false),
    .requestSnippetsEnabled = z.withDefault(z.boolean(.{}), false),
    .maxDisplayedTags = z.optional(z.integer(i32, .{})),
    .validatorUrl = z.optional(z.string(.{})),
    .supportedSubmitMethods = z.withDefault(z.array(z.enumType(SubmitMethod, .{}), .{}), &.{}),
    .oauth2RedirectUrl = z.optional(z.string(.{})),
}, .{});
pub const SwaggerConfig = SwaggerConfigSchema.Value;

pub const RedocConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .route = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/redoc"),
    .title = z.withDefault(z.string(.{}), "ReDoc"),
    .hideHostname = z.withDefault(z.boolean(.{}), false),
    .hideDownloadButton = z.withDefault(z.boolean(.{}), false),
    .hideFab = z.withDefault(z.boolean(.{}), false),
    .hideLoading = z.withDefault(z.boolean(.{}), false),
    .hideLogo = z.withDefault(z.boolean(.{}), false),
    .hideSecuritySection = z.withDefault(z.boolean(.{}), false),
    .expandResponses = z.withDefault(z.string(.{}), ""),
    .pathInMiddlePanel = z.withDefault(z.boolean(.{}), false),
    .requiredPropsFirst = z.withDefault(z.boolean(.{}), false),
    .sortPropsAlphabetically = z.withDefault(z.boolean(.{}), false),
    .sortEnumValuesAlphabetically = z.withDefault(z.boolean(.{}), false),
    .noAutoAuth = z.withDefault(z.boolean(.{}), false),
    .disableSearch = z.withDefault(z.boolean(.{}), false),
    .nativeScrollbars = z.withDefault(z.boolean(.{}), false),
    .onlyRequiredInSamples = z.withDefault(z.boolean(.{}), false),
    .menuToggle = z.withDefault(z.boolean(.{}), false),
    .jsonSampleExpandLevel = z.withDefault(z.integer(i32, .{}), 2),
    .generatedPayloadSamplesMaxDepth = z.withDefault(z.integer(i32, .{}), 10),
    .scrollYOffset = z.optional(z.integer(i32, .{})),
}, .{});
pub const RedocConfig = RedocConfigSchema.Value;

pub const ScalarConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .route = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/scalar"),
    .title = z.withDefault(z.string(.{}), "Scalar API Reference"),
    .theme = z.withDefault(z.string(.{}), "default"),
    .darkMode = z.withDefault(z.boolean(.{}), false),
    .hideModels = z.withDefault(z.boolean(.{}), false),
    .hideDownloadButton = z.withDefault(z.boolean(.{}), false),
    .hideTestRequestButton = z.withDefault(z.boolean(.{}), false),
    .hideClientButton = z.withDefault(z.boolean(.{}), false),
    .isEditable = z.withDefault(z.boolean(.{}), false),
    .showSidebar = z.withDefault(z.boolean(.{}), true),
    .showDeveloperTools = z.withDefault(z.boolean(.{}), false),
    .defaultOpenAllTags = z.withDefault(z.boolean(.{}), false),
    .telemetry = z.withDefault(z.boolean(.{}), true),
    .persistAuth = z.withDefault(z.boolean(.{}), false),
    .withDefaultFonts = z.withDefault(z.boolean(.{}), true),
    .searchHotKey = z.withDefault(z.string(.{}), "k"),
    .proxyUrl = z.withDefault(z.string(.{}), ""),
    .customCss = z.withDefault(z.string(.{}), ""),
}, .{});
pub const ScalarConfig = ScalarConfigSchema.Value;

pub const GraphiQLConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .route = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/graphiql"),
    .graphqlEndpoint = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/graphql"),
    .title = z.withDefault(z.string(.{}), "GraphiQL IDE"),
    .defaultQuery = z.withDefault(z.string(.{}), ""),
    .editorTheme = z.withDefault(z.string(.{}), ""),
    .headers = z.withDefault(GraphiQLHeadersSchema, .{}),
    .shouldPersistHeaders = z.withDefault(z.boolean(.{}), false),
    .inputValueDeprecation = z.withDefault(z.boolean(.{}), false),
    .schemaDescription = z.withDefault(z.boolean(.{}), false),
    .docExplorerOpen = z.withDefault(z.boolean(.{}), false),
    .isHeadersEditorEnabled = z.withDefault(z.boolean(.{}), true),
}, .{});
pub const GraphiQLConfig = GraphiQLConfigSchema.Value;

pub const OpenApiConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .route = z.withDefault(z.string(.{ .min = 1, .prefix = "/" }), "/openapi.json"),
}, .{});
pub const OpenApiConfig = OpenApiConfigSchema.Value;

pub const ConfigSchema = z.objectOf(.{
    .enabled = z.withDefault(z.boolean(.{}), true),
    .title = z.withDefault(z.string(.{}), versionInfo.defaultInfo.title),
    .version = z.withDefault(z.string(.{}), versionInfo.defaultInfo.version),
    .description = z.withDefault(z.string(.{}), versionInfo.defaultInfo.description),
    .openapi = z.withDefault(OpenApiConfigSchema, .{}),
    .swagger = z.withDefault(SwaggerConfigSchema, .{}),
    .redoc = z.withDefault(RedocConfigSchema, .{}),
    .scalar = z.withDefault(ScalarConfigSchema, .{}),
    .graphiql = z.withDefault(GraphiQLConfigSchema, .{}),
}, .{});
pub const Config = ConfigSchema.Value;

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
        for (swaggerAssetNames) |name| {
            const full = joinRoute(a, route, name) catch continue;
            defer a.free(full);
            _ = router.remove(.GET, full);
        }
    }
    if (st.redocRoute) |route| {
        _ = router.remove(.GET, route);
        for (redocAssetNames) |name| {
            const full = joinRoute(a, route, name) catch continue;
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
        for (graphiqlAssetNames) |name| {
            const full = joinRoute(a, route, name) catch continue;
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

/// Mounts documentation on an initialized server. Its router and allocator
/// are borrowed from the server owner, and `cfg` is compile-time so disabled
/// UI bundles can be eliminated when the compiler can prove them unreachable.
pub fn mount(server: anytype, comptime cfg: Config) !void {
    try mountRouter(server.allocator, &server.router, cfg);
}

/// Removes only the documentation mount belonging to this initialized server.
pub fn unmount(server: anytype) void {
    unmountFromRouter(&server.router);
}

/// Internal router-level implementation shared with the module tests.
fn mountRouter(
    allocator: Allocator,
    router: *Router,
    comptime cfg: Config,
) !void {
    if (comptime (!cfg.enabled or !(cfg.openapi.enabled or cfg.swagger.enabled or cfg.redoc.enabled or cfg.scalar.enabled or cfg.graphiql.enabled))) return;
    {
        var scratch: [4096]u8 = undefined;
        const issue = z.checkFirst(ConfigSchema, cfg, &scratch, .{}) catch
            return error.InvalidConfig;
        if (issue != null) return error.InvalidConfig;
    }

    const actualInfo = openapi.Info{
        .title = cfg.title,
        .version = cfg.version,
        .description = cfg.description,
    };

    if (comptime cfg.openapi.enabled) if (router.hasConflict(.GET, cfg.openapi.route)) return error.DuplicateRoute;
    if (comptime cfg.swagger.enabled) if (router.hasConflict(.GET, cfg.swagger.route)) return error.DuplicateRoute;
    if (comptime cfg.redoc.enabled) if (router.hasConflict(.GET, cfg.redoc.route)) return error.DuplicateRoute;
    if (comptime cfg.scalar.enabled) if (router.hasConflict(.GET, cfg.scalar.route)) return error.DuplicateRoute;
    if (comptime cfg.graphiql.enabled) if (router.hasConflict(.GET, cfg.graphiql.route)) return error.DuplicateRoute;
    if (comptime cfg.swagger.enabled) {
        const swaggerAssets = @import("swaggerAssets.zig");
        for (swaggerAssets.names) |name| {
            const full = try joinRoute(allocator, cfg.swagger.route, name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (comptime cfg.redoc.enabled) {
        const redocAssets = @import("redocAssets.zig");
        for (redocAssets.names) |name| {
            const full = try joinRoute(allocator, cfg.redoc.route, name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (comptime cfg.scalar.enabled) {
        const scalarAssets = @import("scalarAssets.zig");
        for (scalarAssets.names) |name| {
            const full = try joinRoute(allocator, cfg.scalar.route, name);
            defer allocator.free(full);
            if (router.hasConflict(.GET, full)) return error.DuplicateRoute;
        }
    }
    if (comptime cfg.graphiql.enabled) {
        const graphiqlAssets = @import("graphiqlAssets.zig");
        for (graphiqlAssets.names) |name| {
            const full = try joinRoute(allocator, cfg.graphiql.route, name);
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
    if (comptime cfg.swagger.enabled and cfg.swagger.route.len > 0)
        st.swaggerRoute = try normalizeRoute(allocator, cfg.swagger.route);
    if (comptime cfg.redoc.enabled and cfg.redoc.route.len > 0)
        st.redocRoute = try normalizeRoute(allocator, cfg.redoc.route);
    if (comptime cfg.scalar.enabled and cfg.scalar.route.len > 0)
        st.scalarRoute = try normalizeRoute(allocator, cfg.scalar.route);
    if (comptime cfg.graphiql.enabled and cfg.graphiql.route.len > 0) {
        st.graphiqlRoute = try normalizeRoute(allocator, cfg.graphiql.route);
        st.graphqlEndpoint = try normalizeRoute(allocator, cfg.graphiql.graphqlEndpoint);
    }

    if (comptime cfg.openapi.enabled) {
        st.spec = try openapi.generate(router, actualInfo);
    }

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

    if (comptime cfg.openapi.enabled) {
        if (st.openapiRoute.len > 0) {
            try router.add(.GET, st.openapiRoute, openApiHandler, .{ .meta = internalMeta, .userData = st });
        }
    }
    if (comptime cfg.swagger.enabled) {
        if (st.swaggerRoute) |route| {
            const swaggerAssets = @import("swaggerAssets.zig");
            try router.add(.GET, route, swaggerPageHandler, .{ .meta = internalMeta, .userData = st });
            for (swaggerAssets.names) |name| {
                const full = try joinRoute(allocator, route, name);
                defer allocator.free(full);
                try router.add(.GET, full, swaggerAssetHandler, .{ .meta = internalMeta });
            }
        }
    }
    if (comptime cfg.redoc.enabled) {
        if (st.redocRoute) |route| {
            const redocAssets = @import("redocAssets.zig");
            try router.add(.GET, route, redocPageHandler, .{ .meta = internalMeta, .userData = st });
            for (redocAssets.names) |name| {
                const full = try joinRoute(allocator, route, name);
                defer allocator.free(full);
                try router.add(.GET, full, redocAssetHandler, .{ .meta = internalMeta });
            }
        }
    }
    if (comptime cfg.scalar.enabled) {
        if (st.scalarRoute) |route| {
            const scalarAssets = @import("scalarAssets.zig");
            try router.add(.GET, route, scalarPageHandler, .{ .meta = internalMeta, .userData = st });
            for (scalarAssets.names) |name| {
                const full = try joinRoute(allocator, route, name);
                defer allocator.free(full);
                try router.add(.GET, full, scalarAssetHandler, .{ .meta = internalMeta });
            }
        }
    }
    if (comptime cfg.graphiql.enabled) {
        if (st.graphiqlRoute) |route| {
            const graphiqlAssets = @import("graphiqlAssets.zig");
            try router.add(.GET, route, graphiqlPageHandler, .{ .meta = internalMeta, .userData = st });
            for (graphiqlAssets.names) |name| {
                const full = try joinRoute(allocator, route, name);
                defer allocator.free(full);
                try router.add(.GET, full, graphiqlAssetHandler, .{ .meta = internalMeta });
            }
        }
    }
    st.next = gMounts;
    gMounts = st;
}

/// Frees docs state mounted on one router. Other mounts are untouched.
fn unmountFromRouter(router: *const Router) void {
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

/// Frees every mounted docs state. Intended for process/test teardown.
pub fn unmountAll() void {
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
    const vendorAssets = @import("swaggerAssets.zig");
    return serveAsset(ctx, vendorAssets.find(assetName(ctx.path)));
}

fn redocAssetHandler(ctx: *Context) anyerror!Response {
    const vendorAssets = @import("redocAssets.zig");
    return serveAsset(ctx, vendorAssets.find(assetName(ctx.path)));
}

fn scalarAssetHandler(ctx: *Context) anyerror!Response {
    const vendorAssets = @import("scalarAssets.zig");
    return serveAsset(ctx, vendorAssets.find(assetName(ctx.path)));
}

fn graphiqlAssetHandler(ctx: *Context) anyerror!Response {
    const vendorAssets = @import("graphiqlAssets.zig");
    return serveAsset(ctx, vendorAssets.find(assetName(ctx.path)));
}

fn assetName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// Serves a vendor asset found by that vendor's isolated asset module.
fn serveAsset(ctx: *Context, maybeFile: ?*const assetFile.File) anyerror!Response {
    const f = maybeFile orelse
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

    try mountRouter(a, &router, .{});
    defer unmountAll();

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
    try std.testing.expect(bundle.body.len == testAssets.swaggerUiBundleJs.len);
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
    try std.testing.expect(redocJs.body.len == testAssets.redocStandaloneJs.len);

    // Scalar page + bundle (enabled by default).
    const scalarPage = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, scalarPage.body, "id=\"api-reference\"") != null);
    const scalarJs = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(testAssets.scalarStandaloneJs.len, scalarJs.body.len);
}

test "scalar opt-in mounts its page and bundle" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/users/{id}", helloHandler, .{});

    try mountRouter(a, &router, .{ .redoc = .{ .enabled = false }, .scalar = .{ .enabled = true } });
    defer unmountAll();

    const page = (try invoke(&router, .GET, "/scalar", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"api-reference\"") != null);
    const js = (try invoke(&router, .GET, "/scalar/standalone.js", a)).?;
    try std.testing.expectEqual(testAssets.scalarStandaloneJs.len, js.body.len);

    const res = (try invoke(&router, .GET, "/openapi.json", a)).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("paths").?.object.get("/users/{id}") != null);
}

test "disabled config registers nothing" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();

    try mountRouter(a, &router, .{ .enabled = false });
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
}

test "all docs endpoints disabled skips mounting" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();

    try mountRouter(a, &router, .{
        .openapi = .{ .enabled = false },
        .swagger = .{ .enabled = false },
        .redoc = .{ .enabled = false },
        .scalar = .{ .enabled = false },
        .graphiql = .{ .enabled = false },
    });
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/docs", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/redoc", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/scalar", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/graphiql", a)) == null);
}

test "disabled docs releases routes to the application" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();

    try mountRouter(a, &router, .{ .enabled = false });

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

    try mountRouter(a, &router, .{ .openapi = .{ .enabled = false }, .swagger = .{ .enabled = true } });
    defer unmountAll();

    try std.testing.expect(gMounts.?.spec == null);
    try std.testing.expect((try invoke(&router, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&router, .GET, "/docs", a)) != null);
}

test "conflicting user route is reported, not overwritten" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/docs", helloHandler, .{}); // user already owns /docs

    try std.testing.expectError(error.DuplicateRoute, mountRouter(a, &router, .{}));
    unmountAll(); // partial state cleaned up
}

test "graphiql opt-in mounts its page and all worker assets" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/graphql", helloHandler, .{});

    try mountRouter(a, &router, .{ .graphiql = .{ .enabled = true, .graphqlEndpoint = "/graphql" } });
    defer unmountAll();

    const page = (try invoke(&router, .GET, "/graphiql", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, page.body, "id=\"graphiql\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "graphiql.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<base href=\"/graphiql/\">") != null);

    const js = (try invoke(&router, .GET, "/graphiql/graphiql.js", a)).?;
    try std.testing.expectEqual(testAssets.graphiqlJs.len, js.body.len);

    const css = (try invoke(&router, .GET, "/graphiql/graphiql.css", a)).?;
    try std.testing.expectEqual(testAssets.graphiqlCss.len, css.body.len);
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

    try mountRouter(a, &router, .{ .graphiql = .{ .enabled = true, .route = "/internal/ide", .graphqlEndpoint = "/graphql" } });
    defer unmountAll();

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

    try mountRouter(a, &router, .{
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
    });
    defer unmountAll();

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

    try mountRouter(a, &router, .{});
    defer unmountAll();

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

    try mountRouter(a, &router, .{});
    defer unmountAll();

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

    try mountRouter(a, &router, .{ .swagger = .{ .enabled = false }, .redoc = .{ .enabled = false } });
    defer unmountAll();

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

    try mountRouter(a, &first, .{});
    try mountRouter(a, &second, .{});
    defer unmountAll();

    // Both mounts serve independently.
    try std.testing.expect((try invoke(&first, .GET, "/openapi.json", a)) != null);
    const second_spec = (try invoke(&second, .GET, "/openapi.json", a)).?;
    try std.testing.expect(std.mem.indexOf(u8, second_spec.body, "/second") != null);

    // Unmounting one router leaves the other mount usable and removes only
    // the first router's docs routes.
    unmountFromRouter(&first);
    try std.testing.expect((try invoke(&first, .GET, "/openapi.json", a)) == null);
    try std.testing.expect((try invoke(&first, .GET, "/docs", a)) == null);
    try std.testing.expect((try invoke(&second, .GET, "/openapi.json", a)) != null);
    try std.testing.expect((try invoke(&second, .GET, "/docs", a)) != null);
}

test "public docs mount borrows server resources and unmount is owner-scoped" {
    const Owner = struct {
        allocator: Allocator,
        router: Router,
    };
    var owner = Owner{
        .allocator = std.testing.allocator,
        .router = Router.init(std.testing.allocator, .{}),
    };
    defer owner.router.deinit();

    try mount(&owner, .{
        .swagger = .{ .enabled = false },
        .redoc = .{ .enabled = false },
        .scalar = .{ .enabled = false },
        .graphiql = .{ .enabled = false },
    });
    try std.testing.expect(owner.router.hasConflict(.GET, "/openapi.json"));
    unmount(&owner);
    try std.testing.expect(!owner.router.hasConflict(.GET, "/openapi.json"));
}

test "openapi document is a stable mount-time snapshot" {
    const a = std.testing.allocator;
    var router = Router.init(a, .{});
    defer router.deinit();
    try router.get("/before", helloHandler, .{});

    try mountRouter(a, &router, .{});
    defer unmountAll();

    const first = (try invoke(&router, .GET, "/openapi.json", a)).?;
    const first_copy = try a.dupe(u8, first.body);
    defer a.free(first_copy);

    // Routes added after mounting are not reflected by the read-only snapshot.
    try router.get("/after", helloHandler, .{});
    const second = (try invoke(&router, .GET, "/openapi.json", a)).?;
    try std.testing.expectEqualStrings(first_copy, second.body);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "/after") == null);
}
