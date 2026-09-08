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
    param_count: usize = 0,
    path: []const u8 = "",
    method: Method = .GET,
    /// IO context for handlers that need filesystem/network access.
    io: std.Io = undefined,
    /// Raw request body (Content-Length framed; empty otherwise).
    body: []const u8 = "",
    /// User-supplied state pointer attached to the route, enabling zero-global-state handlers.
    user_data: ?*anyopaque = null,
    middleware_index: usize = 0,
    active_router: ?*anyopaque = null,
    active_handler: ?HandlerFn = null,
    /// Remote peer network address (e.g. "127.0.0.1" or "[::1]").
    peer_address: []const u8 = "",
    /// True if connection was established over direct TLS / HTTPS.
    is_tls: bool = false,
    /// Whether reverse proxy forwarded headers (X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host) are trusted.
    trust_forwarded: bool = false,

    /// Invokes the next middleware in the pipeline, or the route handler if at the end.
    pub fn next(self: *Context) anyerror!Response {
        const r: *Router = @ptrCast(@alignCast(self.active_router orelse return error.NoRouter));
        if (self.middleware_index < r.middlewares.items.len) {
            const mw = r.middlewares.items[self.middleware_index];
            self.middleware_index += 1;
            return mw(self, contextNext);
        }
        if (self.active_handler) |h| {
            return h(self);
        }
        if (r.not_found_handler) |nf| {
            return nf(self) catch Response{ .status = 404, .body = "Not Found", .content_type = "text/plain; charset=utf-8" };
        } else if (r.status_handlers.get(404)) |sh| {
            return sh(self) catch Response{ .status = 404, .body = "Not Found", .content_type = "text/plain; charset=utf-8" };
        } else {
            return Response{ .status = 404, .body = "Not Found", .content_type = "text/plain; charset=utf-8" };
        }
    }

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.params[0..self.param_count]) |p| {
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
            .content_type = "text/html; charset=utf-8",
        };
    }

    /// Renders a native server-side template by name using the configured template engine (200 OK).
    pub fn render(self: *const Context, template_name: []const u8, data: anytype) anyerror!Response {
        return self.renderStatus(200, template_name, data);
    }

    /// Renders a native server-side template with a custom HTTP status code.
    pub fn renderStatus(self: *const Context, code: u16, template_name: []const u8, data: anytype) anyerror!Response {
        const templates_mod = @import("../templates/templates.zig");
        var engine: ?*templates_mod.Engine = null;
        if (self.active_router) |r_ptr| {
            const r: *Router = @ptrCast(@alignCast(r_ptr));
            if (r.template_engine) |te| {
                engine = @ptrCast(@alignCast(te));
            }
        }
        if (engine) |eng| {
            const body_str = try eng.renderToString(self.allocator, template_name, data);
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
                .content_type = "application/json",
            };
        }
        const str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        return Response{
            .status = code,
            .body = str,
            .content_type = "application/json",
        };
    }

    /// Formatted JSON response from a format string and arguments.
    pub fn jsonFmt(self: *const Context, comptime fmt: []const u8, args: anytype) !Response {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        return Response{
            .status = 200,
            .body = str,
            .content_type = "application/json",
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
            .content_type = "text/plain; charset=utf-8",
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
            .content_type = "application/xml; charset=utf-8",
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
    pub fn binary(self: *const Context, bytes: []const u8, content_type: ?[]const u8) Response {
        _ = self;
        return Response.binary(bytes, content_type);
    }

    /// Renders an arbitrary custom response.
    pub fn custom(self: *const Context, status_code: u16, content_type: ?[]const u8, content: []const u8) Response {
        _ = self;
        return Response.custom(status_code, content_type, content);
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

    /// Extract a query parameter by name from the URL path.
    pub fn queryParam(self: *const Context, name: []const u8) ?[]const u8 {
        const path = self.path;
        if (std.mem.indexOfScalar(u8, path, '?')) |qstart| {
            var iter = std.mem.splitScalar(u8, path[qstart + 1 ..], '&');
            while (iter.next()) |pair| {
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                    const k = pair[0..eq];
                    if (std.mem.eql(u8, k, name)) {
                        return pair[eq + 1 ..];
                    }
                }
            }
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
    /// Honors X-Forwarded-Proto only when trust_forwarded is true.
    pub fn scheme(self: *const Context) []const u8 {
        if (self.trust_forwarded) {
            if (self.header("X-Forwarded-Proto")) |p| {
                const trimmed = std.mem.trim(u8, p, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "https")) return "https";
                if (std.ascii.eqlIgnoreCase(trimmed, "http")) return "http";
            }
        }
        return if (self.is_tls) "https" else "http";
    }

    /// Returns the client's IP address.
    /// If trust_forwarded is true and X-Forwarded-For / X-Real-IP is present, it returns the forwarded client IP.
    /// Otherwise returns peer_address if available, or fallback header if no peer address was set.
    pub fn remoteAddress(self: *const Context) ?[]const u8 {
        if (self.trust_forwarded) {
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
        if (self.peer_address.len > 0) return self.peer_address;
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
    /// When trust_forwarded is true, respects X-Forwarded-Host if provided.
    pub fn host(self: *const Context) ?[]const u8 {
        if (self.trust_forwarded) {
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
    content_type: ?[]const u8 = null,
    /// Additional headers; borrowed from ctx-scratch or static data.
    headers: []const Header = &.{},

    pub fn html(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "text/html; charset=utf-8",
        };
    }

    pub fn text(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "text/plain; charset=utf-8",
        };
    }

    pub fn jsonRaw(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "application/json",
        };
    }

    pub fn xml(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "application/xml; charset=utf-8",
        };
    }

    pub fn rss(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "application/rss+xml; charset=utf-8",
        };
    }

    pub fn atom(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "application/atom+xml; charset=utf-8",
        };
    }

    pub fn robots(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "text/plain; charset=utf-8",
        };
    }

    pub fn sitemap(content: []const u8) Response {
        return .{
            .status = 200,
            .body = content,
            .content_type = "application/xml; charset=utf-8",
        };
    }

    pub fn binary(bytes: []const u8, content_type: ?[]const u8) Response {
        return .{
            .status = 200,
            .body = bytes,
            .content_type = content_type orelse "application/octet-stream",
        };
    }

    pub fn custom(status_code: u16, content_type: ?[]const u8, content: []const u8) Response {
        return .{
            .status = status_code,
            .body = content,
            .content_type = content_type,
        };
    }

    pub fn empty(status_code: u16) Response {
        return .{
            .status = status_code,
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
    user_data: ?*anyopaque = null,
    deinit_data: ?*const fn (?*anyopaque) void = null,
};

pub const ErrorHandlerFn = *const fn (*Context, anyerror) anyerror!Response;

pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayList(RouteEntry) = .empty,
    middlewares: std.ArrayList(MiddlewareFn) = .empty,
    not_found_handler: ?HandlerFn = null,
    error_handler: ?ErrorHandlerFn = null,
    status_handlers: std.AutoHashMap(u16, HandlerFn),
    template_engine: ?*anyopaque = null,

    pub fn init(allocator: Allocator) Router {
        return .{
            .allocator = allocator,
            .status_handlers = std.AutoHashMap(u16, HandlerFn).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var freed_ptrs = std.AutoHashMap(?*anyopaque, void).init(self.allocator);
        defer freed_ptrs.deinit();

        for (self.routes.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.user_data != null and entry.deinit_data != null) {
                if (!freed_ptrs.contains(entry.user_data)) {
                    entry.deinit_data.?(entry.user_data);
                    freed_ptrs.put(entry.user_data, {}) catch {};
                }
            }
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
        self.status_handlers.deinit();
    }

    /// Registers a middleware that runs on all routed requests.
    pub fn use(self: *Router, mw: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    /// Sets a custom 404 Not Found handler (HTML, JSON, custom template, etc.)
    pub fn setNotFoundHandler(self: *Router, handler: HandlerFn) void {
        self.not_found_handler = handler;
    }

    /// Sets a custom 500 / Exception handler (HTML, JSON error envelope, etc.)
    pub fn setErrorHandler(self: *Router, handler: ErrorHandlerFn) void {
        self.error_handler = handler;
    }

    /// Sets a custom error page / response handler for a specific HTTP status code (e.g. 403, 404, 500, 502, 503).
    pub fn setStatusHandler(self: *Router, status_code: u16, handler: HandlerFn) !void {
        try self.status_handlers.put(status_code, handler);
    }

    pub fn add(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response) RouteError!void {
        return self.addMeta(method, path, handler, .{});
    }

    /// Register with OpenAPI metadata — the "define once" path: handler and
    /// documentation come from this single call.
    pub fn addMeta(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, meta: meta_mod.Metadata) RouteError!void {
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
    pub fn hasConflict(self: *Router, method: Method, path: []const u8) bool {
        const pat = pattern_mod.parsePattern(path) catch return false;
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
    /// route was removed (its owned path is freed).
    pub fn remove(self: *Router, method: Method, path: []const u8) bool {
        const pat = pattern_mod.parsePattern(path) catch return false;
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
        user_data: ?*anyopaque,
    ) RouteError!void {
        return self.addMetaWithDataDeinit(method, path, handler, meta, user_data, null);
    }

    pub fn addMetaWithDataDeinit(
        self: *Router,
        method: Method,
        path: []const u8,
        handler: *const fn (*Context) anyerror!Response,
        meta: meta_mod.Metadata,
        user_data: ?*anyopaque,
        deinit_data: ?*const fn (?*anyopaque) void,
    ) RouteError!void {
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
            .user_data = user_data,
            .deinit_data = deinit_data,
        });
    }

    pub fn addWithData(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, user_data: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(method, path, handler, .{}, user_data);
    }

    pub fn getWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, user_data: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.GET, path, handler, .{}, user_data);
    }

    pub fn getWithDataDeinit(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, user_data: ?*anyopaque, deinit_data: ?*const fn (?*anyopaque) void) RouteError!void {
        return self.addMetaWithDataDeinit(.GET, path, handler, .{}, user_data, deinit_data);
    }

    pub fn postWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, user_data: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.POST, path, handler, .{}, user_data);
    }

    pub fn optionsWithData(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, user_data: ?*anyopaque) RouteError!void {
        return self.addMetaWithData(.OPTIONS, path, handler, .{}, user_data);
    }

    /// Matches a request and fills in path parameters.
    /// Returns the handler or null if no match.
    pub fn match(self: *Router, method: Method, path: []const u8, ctx: *Context) ?*const fn (*Context) anyerror!Response {
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
                .path = path,
                .method = method,
                .io = ctx.io,
                .user_data = entry.user_data,
            };

            if (matchPattern(&entry.pattern, path, &ctx_params)) {
                const score: i64 = @intCast(entry.priority);
                if (score > best_score) {
                    best_score = score;
                    best = entry;
                    ctx.* = ctx_params;
                }
            }
        }

        return if (best) |b| b.handler else null;
    }

    /// Matches and dispatches the request through registered middlewares and route handler.
    pub fn dispatch(self: *Router, ctx: *Context) Response {
        const maybe_handler = self.match(ctx.method, ctx.path, ctx);
        ctx.active_router = self;
        ctx.active_handler = maybe_handler;
        ctx.middleware_index = 0;
        return ctx.next() catch |err| self.handleError(ctx, err);
    }

    fn handleError(self: *Router, ctx: *Context, err: anyerror) Response {
        if (self.error_handler) |eh| {
            return eh(ctx, err) catch Response{ .status = 500, .body = "Internal Server Error", .content_type = "text/plain; charset=utf-8" };
        } else if (self.status_handlers.get(500)) |sh| {
            return sh(ctx) catch Response{ .status = 500, .body = "Internal Server Error", .content_type = "text/plain; charset=utf-8" };
        } else {
            return Response{ .status = 500, .body = "Internal Server Error", .content_type = "text/plain; charset=utf-8" };
        }
    }
};

fn matchPattern(pat: *const Pattern, path: []const u8, ctx: *Context) bool {
    var path_it = std.mem.splitScalar(u8, path, '/');
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
                if (ctx.param_count < 16) {
                    ctx.params[ctx.param_count] = .{ .name = seg.text, .value = path_seg };
                    ctx.param_count += 1;
                }
            },
            .wildcard => {
                // Wildcard matches everything remaining in the path from this segment on
                if (ctx.param_count < 16) {
                    const seg_start = @intFromPtr(path_seg.ptr) - @intFromPtr(path.ptr);
                    const remainder = path[seg_start..];
                    ctx.params[ctx.param_count] = .{ .name = seg.text, .value = remainder };
                    ctx.param_count += 1;
                }
                return true;
            },
        }
        seg_idx += 1;
    }

    // All path segments consumed — check all pattern segments consumed
    return seg_idx == pat.count;
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
    try std.testing.expectEqual(@as(usize, 0), ctx.param_count);
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

    // Case 1: Untrusted proxy (trust_forwarded = false)
    {
        var ctx = Context{
            .allocator = a,
            .headers = &hdrs,
            .peer_address = "127.0.0.1",
            .is_tls = false,
            .trust_forwarded = false,
        };
        try std.testing.expectEqualStrings("http", ctx.scheme());
        try std.testing.expectEqualStrings("127.0.0.1", ctx.remoteAddress().?);
        try std.testing.expectEqualStrings("internal.local", ctx.host().?);
    }

    // Case 2: Trusted proxy (trust_forwarded = true)
    {
        var ctx = Context{
            .allocator = a,
            .headers = &hdrs,
            .peer_address = "127.0.0.1",
            .is_tls = false,
            .trust_forwarded = true,
        };
        try std.testing.expectEqualStrings("https", ctx.scheme());
        try std.testing.expectEqualStrings("203.0.113.195", ctx.remoteAddress().?);
        try std.testing.expectEqualStrings("example.com", ctx.host().?);
    }
}
