//! HTTP router with static, parameter, wildcard, and catch-all routes.
//!
//! Route precedence (deterministic):
//!   1. Exact/static match
//!   2. Parameter match
//!   3. Wildcard/catch-all match
//!
//! Duplicate method+path detection at registration time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = @import("../../common/method.zig").Method;
const pattern_mod = @import("pattern.zig");
const Pattern = pattern_mod.Pattern;
const SegmentKind = pattern_mod.SegmentKind;

pub const HandlerFn = *const fn (*Context) anyerror!Response;
pub const NextFn = *const fn (*Context) anyerror!Response;
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!Response;

pub fn contextNext(ctx: *Context) anyerror!Response {
    return ctx.next();
}

/// A single extra response header (name excludes the trailing colon).
pub const Header = struct { name: []const u8, value: []const u8 };

pub const Context = struct {
    /// Per-request scratch allocator. Dynamic response content (bodies,
    /// header arrays) MUST come from here; the transport resets it after the
    /// response is written. Slices placed in Response are borrowed.
    allocator: Allocator,
    /// Raw request headers as provided by the transport (may be empty).
    headers: []const Header = &.{},
    params: [16]struct { name: []const u8, value: []const u8 } = undefined,
    paramCount: usize = 0,
    path: []const u8 = "",
    /// Raw query string (without leading '?' and without fragment), populated
    /// by the server transports. Direct `match()` calls also fill it when the
    /// input path contains '?'. `queryParam()` reads this first.
    query: []const u8 = "",
    method: Method = .GET,
    /// IO context for handlers that need filesystem/network access.
    io: std.Io = undefined,
    /// Raw request body (Content-Length framed; empty otherwise).
    body: []const u8 = "",
    /// User-supplied state pointer attached to the route, enabling zero-global-state handlers.
    userData: ?*anyopaque = null,
    middlewareIndex: usize = 0,
    activeRouter: ?*anyopaque = null,
    activeHandler: ?HandlerFn = null,
    /// Remote peer network address (e.g. "127.0.0.1" or "[::1]").
    peerAddress: []const u8 = "",
    /// True if connection was established over direct TLS / HTTPS.
    isTls: bool = false,
    /// Whether reverse proxy forwarded headers (X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host) are trusted.
    trustForwarded: bool = false,

    /// Invokes the next middleware in the pipeline, or the route handler if at the end.
    pub fn next(self: *Context) anyerror!Response {
        const r: *Router = @ptrCast(@alignCast(self.activeRouter orelse return error.NoRouter));
        if (self.middlewareIndex < r.middlewares.items.len) {
            const mw = r.middlewares.items[self.middlewareIndex];
            self.middlewareIndex += 1;
            return mw(self, contextNext);
        }
        if (self.activeHandler) |h| {
            return h(self);
        }
        if (r.notFoundHandler) |nf| {
            return nf(self) catch Response{ .status = 404, .body = "Not Found", .contentType = "text/plain; charset=utf-8" };
        } else if (r.statusHandlers.get(404)) |sh| {
            return sh(self) catch Response{ .status = 404, .body = "Not Found", .contentType = "text/plain; charset=utf-8" };
        } else {
            return Response{ .status = 404, .body = "Not Found", .contentType = "text/plain; charset=utf-8" };
        }
    }

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.params[0..self.paramCount]) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// Case-insensitive single-header lookup; returns the first match.
    pub fn header(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Extracts Bearer token from Authorization header if present.
    pub fn bearerToken(self: *const Context) ?[]const u8 {
        const hv = self.header("Authorization") orelse return null;
        const prefix = "Bearer ";
        if (!std.ascii.startsWithIgnoreCase(hv, prefix)) return null;
        const tok = std.mem.trim(u8, hv[prefix.len..], " ");
        if (tok.len == 0) return null;
        return tok;
    }

    /// Extracts and parses Basic Auth credentials from Authorization header if present.
    pub fn basicAuth(self: *const Context) ?struct { username: []const u8, password: []const u8 } {
        const hv = self.header("Authorization") orelse return null;
        const prefix = "Basic ";
        if (!std.ascii.startsWithIgnoreCase(hv, prefix)) return null;
        const b64 = std.mem.trim(u8, hv[prefix.len..], " ");
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(b64) catch return null;
        const buf = self.allocator.alloc(u8, decoded_len) catch return null;
        decoder.decode(buf, b64) catch return null;
        const colon = std.mem.indexOfScalar(u8, buf, ':') orelse return null;
        return .{
            .username = buf[0..colon],
            .password = buf[colon + 1 ..],
        };
    }

    /// Deserializes JSON request body into type `T`.
    pub fn json(self: *const Context, comptime T: type) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, self.body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value;
    }

    /// Renders an HTML response.
    pub fn html(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.html(content);
    }

    /// Renders an HTML response with custom status code.
    pub fn htmlStatus(self: *const Context, code: u16, content: []const u8) Response {
        _ = self;
        return .{
            .status = code,
            .body = content,
            .contentType = "text/html; charset=utf-8",
        };
    }

    /// Renders a native server-side template by name using the configured template engine (200 OK).
    pub fn render(self: *const Context, templateName: []const u8, data: anytype) anyerror!Response {
        return self.renderStatus(200, templateName, data);
    }

    /// Renders a native server-side template with a custom HTTP status code.
    pub fn renderStatus(self: *const Context, code: u16, templateName: []const u8, data: anytype) anyerror!Response {
        const templates_mod = @import("../templates/templates.zig");
        var engine: ?*templates_mod.Engine = null;
        if (self.activeRouter) |r_ptr| {
            const r: *Router = @ptrCast(@alignCast(r_ptr));
            if (r.templateEngine) |te| {
                engine = @ptrCast(@alignCast(te));
            }
        }
        if (engine) |eng| {
            const body_str = try eng.renderToString(self.allocator, templateName, data);
            return self.htmlStatus(code, body_str);
        }
        return error.TemplateEngineNotConfigured;
    }

    /// Renders a JSON response from a serialized string or struct (200 OK).
    pub fn renderJson(self: *const Context, value: anytype) !Response {
        return self.renderJsonStatus(200, value);
    }

    /// Renders a JSON response with a custom status code.
    pub fn renderJsonStatus(self: *const Context, code: u16, value: anytype) !Response {
        const T = @TypeOf(value);
        if (T == []const u8 or T == []u8) {
            return Response{
                .status = code,
                .body = value,
                .contentType = "application/json",
            };
        }
        const str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        return Response{
            .status = code,
            .body = str,
            .contentType = "application/json",
        };
    }

    /// Formatted JSON response from a format string and arguments.
    pub fn jsonFmt(self: *const Context, comptime fmt: []const u8, args: anytype) !Response {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        return Response{
            .status = 200,
            .body = str,
            .contentType = "application/json",
        };
    }

    /// Renders a plain text response.
    pub fn text(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.text(content);
    }

    /// Renders a plain text response with custom status code.
    pub fn textStatus(self: *const Context, code: u16, content: []const u8) Response {
        _ = self;
        return .{
            .status = code,
            .body = content,
            .contentType = "text/plain; charset=utf-8",
        };
    }

    /// Renders an XML response (application/xml; charset=utf-8).
    pub fn xml(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.xml(content);
    }

    /// Renders an XML response with custom status code.
    pub fn xmlStatus(self: *const Context, code: u16, content: []const u8) Response {
        _ = self;
        return .{
            .status = code,
            .body = content,
            .contentType = "application/xml; charset=utf-8",
        };
    }

    /// Renders an RSS 2.0 XML feed response (application/rss+xml; charset=utf-8).
    pub fn rss(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.rss(content);
    }

    /// Renders an Atom XML feed response (application/atom+xml; charset=utf-8).
    pub fn atom(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.atom(content);
    }

    /// Renders a robots.txt response (text/plain; charset=utf-8).
    pub fn robots(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.robots(content);
    }

    /// Renders a sitemap.xml response (application/xml; charset=utf-8).
    pub fn sitemap(self: *const Context, content: []const u8) Response {
        _ = self;
        return Response.sitemap(content);
    }

    /// Renders a binary octet stream or custom binary payload response.
    pub fn binary(self: *const Context, bytes: []const u8, contentType: ?[]const u8) Response {
        _ = self;
        return Response.binary(bytes, contentType);
    }

    /// Renders an arbitrary custom response.
    pub fn custom(self: *const Context, statusCode: u16, contentType: ?[]const u8, content: []const u8) Response {
        _ = self;
        return Response.custom(statusCode, contentType, content);
    }

    /// HTTP Redirect response (default 302 Found or 301/307/308).
    pub fn redirect(self: *const Context, location: []const u8, code: ?u16) !Response {
        const headers_slice = try self.allocator.alloc(Header, 1);
        headers_slice[0] = .{ .name = "Location", .value = location };
        return Response{
            .status = code orelse 302,
            .body = "",
            .headers = headers_slice,
        };
    }

    /// Extract a query parameter by name from the URL.
    /// Reads the transport-populated `query` field first, then falls back to
    /// parsing `path` directly (for hand-built contexts in tests).
    pub fn queryParam(self: *const Context, name: []const u8) ?[]const u8 {
        if (self.query.len > 0) {
            if (lookupQuery(self.query, name)) |v| return v;
        }
        const path = self.path;
        if (std.mem.indexOfScalar(u8, path, '?')) |qstart| {
            var q = path[qstart + 1 ..];
            if (std.mem.indexOfScalar(u8, q, '#')) |hend| q = q[0..hend];
            if (lookupQuery(q, name)) |v| return v;
        }
        return null;
    }

    /// Extract a cookie value by name from the Cookie header.
    pub fn cookie(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Cookie")) {
                var iter = std.mem.splitScalar(u8, h.value, ';');
                while (iter.next()) |pair| {
                    const trimmed = std.mem.trim(u8, pair, " \t");
                    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                        const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                        if (std.mem.eql(u8, k, name)) {
                            return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Returns the effective scheme ("https" or "http").
    /// Honors X-Forwarded-Proto only when trustForwarded is true.
    pub fn scheme(self: *const Context) []const u8 {
        if (self.trustForwarded) {
            if (self.header("X-Forwarded-Proto")) |p| {
                const trimmed = std.mem.trim(u8, p, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "https")) return "https";
                if (std.ascii.eqlIgnoreCase(trimmed, "http")) return "http";
            }
        }
        return if (self.isTls) "https" else "http";
    }

    /// Returns the client's IP address.
    /// If trustForwarded is true and X-Forwarded-For / X-Real-IP is present, it returns the forwarded client IP.
    /// Otherwise returns peerAddress if available, or fallback header if no peer address was set.
    pub fn remoteAddress(self: *const Context) ?[]const u8 {
        if (self.trustForwarded) {
            if (self.header("X-Forwarded-For")) |xff| {
                if (std.mem.indexOfScalar(u8, xff, ',')) |comma| {
                    return std.mem.trim(u8, xff[0..comma], " \t");
                }
                const trimmed = std.mem.trim(u8, xff, " \t");
                if (trimmed.len > 0) return trimmed;
            }
            if (self.header("X-Real-IP")) |xri| {
                const trimmed = std.mem.trim(u8, xri, " \t");
                if (trimmed.len > 0) return trimmed;
            }
        }
        if (self.peerAddress.len > 0) return self.peerAddress;
        // Fallback for standalone/mock tests
        if (self.header("X-Forwarded-For")) |xff| {
            if (std.mem.indexOfScalar(u8, xff, ',')) |comma| {
                return std.mem.trim(u8, xff[0..comma], " \t");
            }
            return xff;
        }
        return null;
    }

    /// Returns the authoritative host header.
    /// When trustForwarded is true, respects X-Forwarded-Host if provided.
    pub fn host(self: *const Context) ?[]const u8 {
        if (self.trustForwarded) {
            if (self.header("X-Forwarded-Host")) |h| {
                const trimmed = std.mem.trim(u8, h, " \t");
                if (trimmed.len > 0) return trimmed;
            }
        }
        return self.header("Host");
    }
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
    /// When set, transports should emit this as Content-Type.
    contentType: ?[]const u8 = null,
    /// Additional headers; borrowed from ctx-scratch or static data.
    headers: []const Header = &.{},

    pub fn html(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "text/html; charset=utf-8",
        };
    }

    pub fn text(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "text/plain; charset=utf-8",
        };
    }

    pub fn jsonRaw(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "application/json",
        };
    }

    pub fn xml(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "application/xml; charset=utf-8",
        };
    }

    pub fn rss(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "application/rss+xml; charset=utf-8",
        };
    }

    pub fn atom(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "application/atom+xml; charset=utf-8",
        };
    }

    pub fn robots(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "text/plain; charset=utf-8",
        };
    }

    pub fn sitemap(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .contentType = "application/xml; charset=utf-8",
        };
    }

    pub fn binary(bytes: []const u8, contentType: ?[]const u8) Response {
        return .{
            .status = 200,
            .body = bytes,
            .contentType = contentType orelse "application/octet-stream",
        };
    }

    pub fn custom(statusCode: u16, contentType: ?[]const u8, content: []const u8) Response {
        return .{
            .status = statusCode,
            .body = content,
            .contentType = contentType,
        };
    }

    pub fn empty(statusCode: u16) Response {
        return .{
            .status = statusCode,
            .body = "",
        };
    }
};

pub const RouteError = error{
    DuplicateRoute,
    InvalidPattern,
    OutOfMemory,
};

const meta_mod = @import("metadata.zig");

const RouteEntry = struct {
    method: Method,
    /// Owned copy of the registered path. Pattern segments point into this
    /// allocation, so callers may pass temporary strings.
    path: []u8,
    pattern: Pattern,
    handler: *const fn (*Context) anyerror!Response,
    priority: u32,
    /// OpenAPI documentation source; empty default keeps plain routes free.
    meta: meta_mod.Metadata = .{},
    userData: ?*anyopaque = null,
    deinitData: ?*const fn (?*anyopaque) void = null,
};

pub const ErrorHandlerFn = *const fn (*Context, anyerror) anyerror!Response;

pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayList(RouteEntry) = .empty,
    middlewares: std.ArrayList(MiddlewareFn) = .empty,
    notFoundHandler: ?HandlerFn = null,
    errorHandler: ?ErrorHandlerFn = null,
    statusHandlers: std.AutoHashMap(u16, HandlerFn),
    templateEngine: ?*anyopaque = null,

    pub fn init(allocator: Allocator) Router {
        return .{
            .allocator = allocator,
            .statusHandlers = std.AutoHashMap(u16, HandlerFn).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var freed_ptrs = std.AutoHashMap(?*anyopaque, void).init(self.allocator);
        defer freed_ptrs.deinit();

        for (self.routes.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.userData != null and entry.deinitData != null) {
                if (!freed_ptrs.contains(entry.userData)) {
                    entry.deinitData.?(entry.userData);
                    freed_ptrs.put(entry.userData, {}) catch {};
                }
            }
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
        self.statusHandlers.deinit();
    }

    /// Registers a middleware that runs on all routed requests.
    pub fn use(self: *Router, mw: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    /// Sets a custom 404 Not Found handler (HTML, JSON, custom template, etc.)
    pub fn setNotFoundHandler(self: *Router, handler: HandlerFn) void {
        self.notFoundHandler = handler;
    }

    /// Sets a custom 500 / Exception handler (HTML, JSON error envelope, etc.)
    pub fn setErrorHandler(self: *Router, handler: ErrorHandlerFn) void {
        self.errorHandler = handler;
    }

    /// Sets a custom error page / response handler for a specific HTTP status code (e.g. 403, 404, 500, 502, 503).
    pub fn setStatusHandler(self: *Router, statusCode: u16, handler: HandlerFn) !void {
        try self.statusHandlers.put(statusCode, handler);
    }

    pub fn add(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        return self.addMeta(method, path, handler, .{});
    }

    /// Register with OpenAPI metadata — the "define once" path: handler and
    /// documentation come from this single call.
    pub fn addMeta(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, meta: meta_mod.Metadata) RouteError!void {
        // Registration paths must be clean patterns; query/fragment belong
        // to requests, never to route definitions.
        if (std.mem.indexOfAny(u8, path, "?#") != null) return RouteError.InvalidPattern;
        // Parse from an owned copy so pattern segments outlive the call.
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        const pat = pattern_mod.parsePattern(owned) catch return RouteError.InvalidPattern;

        // Check duplicates
        var buf1: [512]u8 = undefined;
        const new_shape = pat.shape(&buf1) catch return RouteError.InvalidPattern;

        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            var buf2: [512]u8 = undefined;
            const existing_shape = existing.pattern.shape(&buf2) catch continue;
            if (std.mem.eql(u8, new_shape, existing_shape)) {
                return RouteError.DuplicateRoute;
            }
        }

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = owned,
            .pattern = pat,
            .handler = handler,
            .priority = pattern_mod.priorityScore(&pat),
            .meta = meta,
        });
    }

    /// All registered entries (for docs generators). Read-only view.
    pub fn entries(self: *const Router) []const RouteEntry {
        return self.routes.items;
    }

    pub fn get(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.GET, path, handler);
    }

    /// True when a GET route with the same normalized shape already exists.
    /// Query strings and fragments are ignored for conflict checks.
    pub fn hasConflict(self: *Router, method: Method, path: []const u8) bool {
        const clean = cleanRequestPath(path);
        const pat = pattern_mod.parsePattern(clean) catch return false;
        var buf1: [512]u8 = undefined;
        const new_shape = pat.shape(&buf1) catch return false;
        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            var buf2: [512]u8 = undefined;
            const existing_shape = existing.pattern.shape(&buf2) catch continue;
            if (std.mem.eql(u8, new_shape, existing_shape)) return true;
        }
        return false;
    }

    /// Removes the first route matching method+shape. Returns true when a
    /// route was removed (its owned path is freed). Query/fragment ignored.
    pub fn remove(self: *Router, method: Method, path: []const u8) bool {
        const clean = cleanRequestPath(path);
        const pat = pattern_mod.parsePattern(clean) catch return false;
        var buf1: [512]u8 = undefined;
        const target = pat.shape(&buf1) catch return false;
        for (self.routes.items, 0..) |existing, i| {
            if (existing.method != method) continue;
            var buf2: [512]u8 = undefined;
            const existing_shape = existing.pattern.shape(&buf2) catch continue;
            if (std.mem.eql(u8, target, existing_shape)) {
                const entry = self.routes.orderedRemove(i);
                self.allocator.free(entry.path);
                return true;
            }
        }
        return false;
    }
    pub fn post(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.POST, path, handler);
    }
    pub fn put(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.PUT, path, handler);
    }
    pub fn patch(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.PATCH, path, handler);
    }
    pub fn delete(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.DELETE, path, handler);
    }
    pub fn head(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.HEAD, path, handler);
    }
    pub fn options(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        try self.add(.OPTIONS, path, handler);
    }
    pub fn getMeta(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, m: meta_mod.Metadata) RouteError!void {
        try self.addMeta(.GET, path, handler, m);
    }
    pub fn postMeta(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, m: meta_mod.Metadata) RouteError!void {
        try self.addMeta(.POST, path, handler, m);
    }
    pub fn putMeta(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, m: meta_mod.Metadata) RouteError!void {
        try self.addMeta(.PUT, path, handler, m);
    }
    pub fn patchMeta(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, m: meta_mod.Metadata) RouteError!void {
        try self.addMeta(.PATCH, path, handler, m);
    }
    pub fn deleteMeta(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, m: meta_mod.Metadata) RouteError!void {
        try self.addMeta(.DELETE, path, handler, m);
    }

    pub fn addMetaWithData(
        self: *Router,
        method: Method,
        path: []const u8,
        handler: *const fn (*Context) anyerror!Response,
        meta: meta_mod.Metadata,
        userData: ?*anyopaque,
    ) RouteError!void {
        return self.addMetaWithDataDeinit(method, path, handler, meta, userData, null);
    }

    pub fn addMetaWithDataDeinit(
        self: *Router,
        method: Method,
        path: []const u8,
        handler: *const fn (*Context) anyerror!Response,
        meta: meta_mod.Metadata,
        userData: ?*anyopaque,
        deinitData: ?*const fn (?*anyopaque) void,
    ) RouteError!void {
        if (std.mem.indexOfAny(u8, path, "?#") != null) return RouteError.InvalidPattern;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        const pat = pattern_mod.parsePattern(owned) catch return RouteError.InvalidPattern;

        var buf1: [512]u8 = undefined;
        const new_shape = pat.shape(&buf1) catch return RouteError.InvalidPattern;

        for (self.routes.items) |existing| {
            if (existing.method != method) continue;
            var buf2: [512]u8 = undefined;
            const existing_shape = existing.pattern.shape(&buf2) catch continue;
            if (std.mem.eql(u8, new_shape, existing_shape)) {
                return RouteError.DuplicateRoute;
            }
        }

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = owned,
            .pattern = pat,
            .handler = handler,
            .priority = pattern_mod.priorityScore(&pat),
            .meta = meta,
            .userData = userData,
            .deinitData = deinitData,
        });
    }

    pub fn addWithData(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, userData: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(method, path, handler, .{}, userData);
    }

    pub fn getWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, userData: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.GET, path, handler, .{}, userData);
    }

    pub fn getWithDataDeinit(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, userData: ?*anyopaque, deinitData: ?*const fn (?*anyopaque) void) RouteError!void {
        return self.addMetaWithDataDeinit(.GET, path, handler, .{}, userData, deinitData);
    }

    pub fn postWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, userData: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.POST, path, handler, .{}, userData);
    }

    pub fn optionsWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, userData: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.OPTIONS, path, handler, .{}, userData);
    }

    /// Matches a request and fills in path parameters.
    /// Returns the handler or null if no match.
    /// Query strings and fragments are stripped for matching; the extracted
    /// query is stored on the context so `queryParam()` keeps working.
    /// Request-scoped fields (headers, body, peer, TLS, trust) are preserved
    /// across the match. HEAD falls back to GET when no explicit HEAD route
    /// exists (body stripped by the transport).
    pub fn match(self: *Router, method: Method, path: []const u8, ctx: *Context) ?*const fn (*Context) anyerror!Response {
        const orig = ctx.method;
        if (self.matchMethod(method, path, ctx)) |h| return h;
        if (method == .HEAD) {
            if (self.matchMethod(.GET, path, ctx)) |h| {
                ctx.method = orig;
                return h;
            }
        }
        return null;
    }

    fn matchMethod(self: *Router, method: Method, path: []const u8, ctx: *Context) ?*const fn (*Context) anyerror!Response {
        const clean = cleanRequestPath(path);
        // Preserve a transport-populated query when the match input is
        // already stripped (server path); otherwise extract from the input.
        const from_path = queryStringOf(path);
        const query = if (from_path.len > 0) from_path else ctx.query;
        var best: ?*const RouteEntry = null;
        var best_score: i64 = -1;

        // Sort-like approach: find highest-priority match
        for (self.routes.items) |*entry| {
            if (entry.method != method) continue;

            // Trial context for parameter extraction; carries the caller's
            // request-scoped fields so a successful match preserves them.
            var ctx_params = Context{
                .allocator = ctx.allocator,
                .headers = ctx.headers,
                .body = ctx.body,
                .path = clean,
                .query = query,
                .method = method,
                .io = ctx.io,
                .userData = entry.userData,
                .peerAddress = ctx.peerAddress,
                .isTls = ctx.isTls,
                .trustForwarded = ctx.trustForwarded,
                .activeRouter = ctx.activeRouter,
            };

            if (matchPattern(&entry.pattern, clean, &ctx_params)) {
                const score: i64 = @intCast(entry.priority);
                if (score > best_score) {
                    best_score = score;
                    best = entry;
                    const saved_router = ctx.activeRouter;
                    const saved_handler = ctx.activeHandler;
                    const saved_mw = ctx.middlewareIndex;
                    ctx.* = ctx_params;
                    // match() must not clobber dispatch bookkeeping; dispatch
                    // sets activeHandler/middlewareIndex itself.
                    ctx.activeRouter = saved_router;
                    ctx.activeHandler = saved_handler;
                    ctx.middlewareIndex = saved_mw;
                }
            }
        }

        return if (best) |b| b.handler else null;
    }

    /// Matches and dispatches the request through registered middlewares and route handler.
    pub fn dispatch(self: *Router, ctx: *Context) Response {
        const maybe_handler = self.match(ctx.method, ctx.path, ctx);
        ctx.activeRouter = self;
        ctx.activeHandler = maybe_handler;
        ctx.middlewareIndex = 0;
        return ctx.next() catch |err| self.handleError(ctx, err);
    }

    fn handleError(self: *Router, ctx: *Context, err: anyerror) Response {
        if (self.errorHandler) |eh| {
            return eh(ctx, err) catch Response{ .status = 500, .body = "Internal Server Error", .contentType = "text/plain; charset=utf-8" };
        } else if (self.statusHandlers.get(500)) |sh| {
            return sh(ctx) catch Response{ .status = 500, .body = "Internal Server Error", .contentType = "text/plain; charset=utf-8" };
        } else {
            return Response{ .status = 500, .body = "Internal Server Error", .contentType = "text/plain; charset=utf-8" };
        }
    }
};

fn matchPattern(pat: *const Pattern, path: []const u8, ctx: *Context) bool {
    const clean = cleanRequestPath(path);
    var path_it = std.mem.splitScalar(u8, clean, '/');
    var seg_idx: usize = 0;

    while (path_it.next()) |path_seg| {
        if (path_seg.len == 0) continue;

        if (seg_idx >= pat.count) return false;
        const seg = pat.segments[seg_idx];

        switch (seg.kind) {
            .literal => {
                if (!std.mem.eql(u8, seg.text, path_seg)) return false;
            },
            .parameter => {
                if (ctx.paramCount < 16) {
                    ctx.params[ctx.paramCount] = .{ .name = seg.text, .value = path_seg };
                    ctx.paramCount += 1;
                }
            },
            .wildcard => {
                // Wildcard matches everything remaining in the path from this segment on
                // (nested slugs preserved, query already stripped via clean).
                if (ctx.paramCount < 16) {
                    const seg_start = @intFromPtr(path_seg.ptr) - @intFromPtr(clean.ptr);
                    const remainder = clean[seg_start..];
                    ctx.params[ctx.paramCount] = .{ .name = seg.text, .value = remainder };
                    ctx.paramCount += 1;
                }
                return true;
            },
        }
        seg_idx += 1;
    }

    // All path segments consumed — check all pattern segments consumed
    return seg_idx == pat.count;
}

/// Strips query string and fragment for route matching.
/// "/users/42?foo=bar#sec" -> "/users/42", "/" stays "/".
fn cleanRequestPath(path: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, path, "?#")) |idx| return path[0..idx];
    return path;
}

/// Returns the raw query string without '?' and without fragment.
fn queryStringOf(path: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return "";
    var rest = path[q + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |hend| rest = rest[0..hend];
    return rest;
}

fn lookupQuery(query: []const u8, name: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        } else if (std.mem.eql(u8, pair, name)) {
            return "";
        }
    }
    return null;
}

// Tests

fn dummyHandler(ctx: *Context) anyerror!Response {
    _ = ctx;
    return Response{};
}

test "matches exact route" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/hello", dummyHandler);
    var ctx = Context{ .allocator = a };
    const handler = router.match(.GET, "/hello", &ctx);
    try std.testing.expect(handler != null);
}

test "rejects duplicate GET route" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users", dummyHandler);
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/users", dummyHandler));
}

test "allows same path different methods" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users", dummyHandler);
    try router.post("/users", dummyHandler);
}

test "static beats parameter precedence" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/me", dummyHandler);
    try router.get("/users/{id}", dummyHandler);

    var ctx = Context{ .allocator = a };
    const handler = router.match(.GET, "/users/me", &ctx);
    try std.testing.expect(handler != null);
    // The /users/me route should have won (higher priority)
    try std.testing.expectEqual(@as(usize, 0), ctx.paramCount);
}

test "extracts path parameters" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id}/posts/{post_id}", dummyHandler);

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/users/42/posts/99", &ctx);
    try std.testing.expectEqualStrings("42", ctx.param("id").?);
    try std.testing.expectEqualStrings("99", ctx.param("post_id").?);
}

test "router owns registered path memory" {
    // Regression: pattern segments must not alias caller-owned temporary
    // buffers; registering a heap path and freeing it must leave the router
    // fully functional (matching, shapes, duplicate detection).
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    const temp = try a.dupe(u8, "/tmp/{name}");
    defer a.free(temp);
    try router.get(temp, dummyHandler);

    var ctx = Context{ .allocator = a };
    const handler = router.match(.GET, "/tmp/xyz", &ctx);
    try std.testing.expect(handler != null);
    try std.testing.expectEqualStrings("xyz", ctx.param("name").?);

    // Duplicate detection still works after the temp buffer is freed.
    try std.testing.expect(router.hasConflict(.GET, "/tmp/{other}"));
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/tmp/{name2}", dummyHandler));
}

test "context trusted proxy and scheme detection" {
    const a = std.testing.allocator;
    const hdrs = [_]Header{
        .{ .name = "Host", .value = "internal.local" },
        .{ .name = "X-Forwarded-Host", .value = "example.com" },
        .{ .name = "X-Forwarded-Proto", .value = "https" },
        .{ .name = "X-Forwarded-For", .value = "203.0.113.195, 127.0.0.1" },
    };

    // Case 1: Untrusted proxy (trustForwarded = false)
    {
        var ctx = Context{
            .allocator = a,
            .headers = &hdrs,
            .peerAddress = "127.0.0.1",
            .isTls = false,
            .trustForwarded = false,
        };
        try std.testing.expectEqualStrings("http", ctx.scheme());
        try std.testing.expectEqualStrings("127.0.0.1", ctx.remoteAddress().?);
        try std.testing.expectEqualStrings("internal.local", ctx.host().?);
    }

    // Case 2: Trusted proxy (trustForwarded = true)
    {
        var ctx = Context{
            .allocator = a,
            .headers = &hdrs,
            .peerAddress = "127.0.0.1",
            .isTls = false,
            .trustForwarded = true,
        };
        try std.testing.expectEqualStrings("https", ctx.scheme());
        try std.testing.expectEqualStrings("203.0.113.195", ctx.remoteAddress().?);
        try std.testing.expectEqualStrings("example.com", ctx.host().?);
    }
}

test "matches with query string and exposes queryParam" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id}", dummyHandler);
    var ctx = Context{ .allocator = a };
    const h = router.match(.GET, "/users/42?foo=bar&baz=qux", &ctx);
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("42", ctx.param("id").?);
    try std.testing.expectEqualStrings("/users/42", ctx.path);
    try std.testing.expectEqualStrings("bar", ctx.queryParam("foo").?);
    try std.testing.expectEqualStrings("qux", ctx.queryParam("baz").?);
}

test "transport query field survives match on clean path" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/search", dummyHandler);
    var ctx = Context{ .allocator = a, .path = "/search", .query = "q=zig&page=2", .method = .GET };
    const h = router.match(.GET, "/search", &ctx);
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("zig", ctx.queryParam("q").?);
    try std.testing.expectEqualStrings("2", ctx.queryParam("page").?);
}

test "HEAD falls back to GET handler" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/asset", dummyHandler);
    var ctx = Context{ .allocator = a, .method = .HEAD };
    const h = router.match(.HEAD, "/asset", &ctx);
    try std.testing.expect(h != null);
    // Original method preserved for transport body-stripping.
    try std.testing.expectEqual(Method.HEAD, ctx.method);
}

test "registration rejects query and fragment in patterns" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try std.testing.expectError(RouteError.InvalidPattern, router.get("/users?x=1", dummyHandler));
    try std.testing.expectError(RouteError.InvalidPattern, router.get("/users#frag", dummyHandler));
}

test "duplicate detection ignores query strings" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id}", dummyHandler);
    try std.testing.expect(router.hasConflict(.GET, "/users/{other}?x=1"));
    try std.testing.expect(router.remove(.GET, "/users/{other}?x=1"));
    try std.testing.expect(!router.hasConflict(.GET, "/users/{id}"));
}

test "nested slugs and wildcard remainder" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/a/{x}/c/{y}", dummyHandler);
    try router.get("/files/*path", dummyHandler);

    var ctx1 = Context{ .allocator = a };
    _ = router.match(.GET, "/a/1/c/2", &ctx1);
    try std.testing.expectEqualStrings("1", ctx1.param("x").?);
    try std.testing.expectEqualStrings("2", ctx1.param("y").?);

    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/files/a/b/c?x=1", &ctx2);
    try std.testing.expectEqualStrings("a/b/c", ctx2.param("path").?);

    // Same nested shape with different param names is a duplicate.
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/a/{p}/c/{q}", dummyHandler));
}

test "match preserves TLS and peer fields" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/secure", dummyHandler);
    var ctx = Context{
        .allocator = a,
        .peerAddress = "10.0.0.1",
        .isTls = true,
        .trustForwarded = true,
    };
    _ = router.match(.GET, "/secure", &ctx);
    try std.testing.expect(ctx.isTls);
    try std.testing.expectEqualStrings("10.0.0.1", ctx.peerAddress);
    try std.testing.expect(ctx.trustForwarded);
}
