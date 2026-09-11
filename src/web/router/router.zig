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
    /// Route-level middleware selected by the match (runs after router
    /// middleware, before the handler). Borrowed from the matched entry.
    routeMiddleware: []const MiddlewareFn = &.{},
    routeMiddlewareIndex: usize = 0,
    /// Remote peer network address (e.g. "127.0.0.1" or "[::1]").
    peerAddress: []const u8 = "",
    /// True if connection was established over direct TLS / HTTPS.
    isTls: bool = false,
    /// Whether reverse proxy forwarded headers (X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host) are trusted.
    trustForwarded: bool = false,

    /// Invokes the next middleware in the pipeline, or the route handler if at the end.
    /// Order is deterministic: router middleware → route middleware → handler.
    pub fn next(self: *Context) anyerror!Response {
        const r: *Router = @ptrCast(@alignCast(self.activeRouter orelse return error.NoRouter));
        if (self.middlewareIndex < r.middlewares.items.len) {
            const mw = r.middlewares.items[self.middlewareIndex];
            self.middlewareIndex += 1;
            return mw(self, contextNext);
        }
        if (self.routeMiddlewareIndex < self.routeMiddleware.len) {
            const mw = self.routeMiddleware[self.routeMiddlewareIndex];
            self.routeMiddlewareIndex += 1;
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

    /// Typed path-parameter accessors. Return null when the parameter is
    /// absent or fails conversion.
    pub fn paramInt(self: *const Context, name: []const u8) ?i64 {
        const v = self.param(name) orelse return null;
        return std.fmt.parseInt(i64, v, 10) catch null;
    }

    pub fn paramUint(self: *const Context, name: []const u8) ?u64 {
        const v = self.param(name) orelse return null;
        return std.fmt.parseInt(u64, v, 10) catch null;
    }

    pub fn paramFloat(self: *const Context, name: []const u8) ?f64 {
        const v = self.param(name) orelse return null;
        return std.fmt.parseFloat(f64, v) catch null;
    }

    pub fn paramBool(self: *const Context, name: []const u8) ?bool {
        const v = self.param(name) orelse return null;
        if (std.mem.eql(u8, v, "true")) return true;
        if (std.mem.eql(u8, v, "false")) return false;
        return null;
    }

    /// Fills a user struct from matched path parameters (optional Level 2
    /// type safety; plain `param()` stays allocation-free and simple).
    /// Field names must match parameter names. Supported field types: ints,
    /// uints, floats, bools, `[]const u8` (borrowed), and optionals of
    /// those (missing → null). Anything else is a compile error.
    pub fn bindParams(self: *const Context, comptime T: type) ParamError!T {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("bindParams requires a struct type");
        var out: T = undefined;
        inline for (info.@"struct".fields) |field| {
            const FT = field.type;
            const fti = @typeInfo(FT);
            const is_optional = fti == .optional;
            const inner = if (is_optional) @typeInfo(fti.optional.child) else fti;
            const raw = self.param(field.name);
            if (raw == null and is_optional) {
                @field(out, field.name) = null;
            } else if (raw == null and field.default_value_ptr != null) {
                const dv_ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr.?));
                @field(out, field.name) = dv_ptr.*;
            } else if (raw == null) {
                return ParamError.MissingParam;
            } else {
                const v = raw.?;
                switch (inner) {
                    .int => {
                        const ChildT = if (is_optional) fti.optional.child else FT;
                        const parsed = std.fmt.parseInt(ChildT, v, 10) catch return ParamError.InvalidParamValue;
                        @field(out, field.name) = parsed;
                    },
                    .float => {
                        const ChildT = if (is_optional) fti.optional.child else FT;
                        const parsed = std.fmt.parseFloat(ChildT, v) catch return ParamError.InvalidParamValue;
                        @field(out, field.name) = parsed;
                    },
                    .bool => {
                        const b = if (std.mem.eql(u8, v, "true"))
                            true
                        else if (std.mem.eql(u8, v, "false"))
                            false
                        else
                            return ParamError.InvalidParamValue;
                        @field(out, field.name) = b;
                    },
                    .pointer => |ptr| {
                        if (ptr.size == .slice and ptr.child == u8) {
                            @field(out, field.name) = v;
                        } else return ParamError.UnsupportedField;
                    },
                    .optional => return ParamError.UnsupportedField, // nested optionals unsupported
                    else => @compileError("bindParams: unsupported field type for '" ++ field.name ++ "'"),
                }
            }
        }
        return out;
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
        const decodedLen = decoder.calcSizeForSlice(b64) catch return null;
        const buf = self.allocator.alloc(u8, decodedLen) catch return null;
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
    DuplicateName,
    InvalidPattern,
    UnknownRoute,
    MissingParam,
    UnknownParam,
    InvalidParamValue,
    OutOfMemory,
};

pub const ParamError = error{
    MissingParam,
    InvalidParamValue,
    UnsupportedField,
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
    /// Route name for URL reversing (borrowed, typically a literal).
    name: ?[]const u8 = null,
    /// Route-level middleware, run after router middleware. Owned iff
    /// `ownsMiddleware`; empty for plain routes.
    middleware: []const MiddlewareFn = &.{},
    ownsMiddleware: bool = false,
    userData: ?*anyopaque = null,
    deinitData: ?*const fn (?*anyopaque) void = null,
};

/// Per-route options. Everything configurable about one registration lives
/// here; `path` + `handler` stay positional as the fundamental inputs.
pub const RouteOptions = struct {
    /// OpenAPI documentation source.
    meta: meta_mod.Metadata = .{},
    /// Route name for `url()` reversing. Must be unique per router.
    name: ?[]const u8 = null,
    /// Route-level middleware (router middleware runs first).
    middleware: []const MiddlewareFn = &.{},
    /// Handler-private state pointer (borrowed; see `deinitData`).
    userData: ?*anyopaque = null,
    /// Optional destructor for `userData`, run once at router deinit.
    deinitData: ?*const fn (?*anyopaque) void = null,
};

pub const ErrorHandlerFn = *const fn (*Context, anyerror) anyerror!Response;

/// Options shared by every route in a group.
pub const GroupOptions = struct {
    /// Middleware prepended (outer groups first) to each route's own list.
    middleware: []const MiddlewareFn = &.{},
};

/// Options for `mount()`.
pub const MountOptions = struct {
    /// Middleware prepended to every mounted route's own list.
    middleware: []const MiddlewareFn = &.{},
};

/// A prefixed view over a router. Groups compose (`group.group(...)`)
/// without allocating: prefixes and middleware chain-borrow caller memory
/// and are merged per registration into router-owned storage.
pub const Group = struct {
    router: *Router,
    parent: ?*const Group = null,
    prefix: []const u8 = "",
    middleware: []const MiddlewareFn = &.{},

    fn appendPrefix(self: *const Group, out: *std.ArrayList(u8), allocator: Allocator) !void {
        if (self.parent) |p| try p.appendPrefix(out, allocator);
        if (self.prefix.len == 0) return;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
        var seg = self.prefix;
        while (seg.len > 0 and seg[0] == '/') seg = seg[1..];
        while (seg.len > 0 and seg[seg.len - 1] == '/') seg = seg[0 .. seg.len - 1];
        if (seg.len > 0) try out.appendSlice(allocator, seg);
    }

    fn appendMiddleware(self: *const Group, out: *std.ArrayList(MiddlewareFn), allocator: Allocator) !void {
        if (self.parent) |p| try p.appendMiddleware(out, allocator);
        try out.appendSlice(allocator, self.middleware);
    }

    fn register(self: *const Group, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        const a = self.router.allocator;
        var full = std.ArrayList(u8).empty;
        defer full.deinit(a);
        try full.append(a, '/');
        try self.appendPrefix(&full, a);
        var sub = path;
        while (sub.len > 0 and sub[0] == '/') sub = sub[1..];
        if (sub.len > 0) {
            if (full.items.len > 0 and full.items[full.items.len - 1] != '/') try full.append(a, '/');
            try full.appendSlice(a, sub);
        }
        var mw = std.ArrayList(MiddlewareFn).empty;
        defer mw.deinit(a);
        try self.appendMiddleware(&mw, a);
        try mw.appendSlice(a, opts.middleware);
        var o = opts;
        o.middleware = mw.items;
        try self.router.add(method, full.items, handler, o);
    }

    pub fn get(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.GET, path, handler, opts);
    }
    pub fn post(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.POST, path, handler, opts);
    }
    pub fn put(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.PUT, path, handler, opts);
    }
    pub fn patch(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.PATCH, path, handler, opts);
    }
    pub fn delete(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.DELETE, path, handler, opts);
    }
    pub fn head(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.HEAD, path, handler, opts);
    }
    pub fn options(self: *const Group, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.register(.OPTIONS, path, handler, opts);
    }

    /// Nested group: prefixes compose (`/api` + `/users` → `/api/users`),
    /// middleware accumulates outer-first. Borrow rules match `group()`.
    pub fn group(self: *const Group, prefix: []const u8, opts: GroupOptions) Group {
        return .{ .router = self.router, .parent = self, .prefix = prefix, .middleware = opts.middleware };
    }

    /// Mounts another router's entries under this group's prefix.
    pub fn mount(self: *const Group, prefix: []const u8, other: *Router, opts: MountOptions) RouteError!void {
        const sub = self.group(prefix, .{});
        try sub.mountRouter(other, opts);
    }

    fn mountRouter(self: *const Group, other: *Router, opts: MountOptions) RouteError!void {
        for (other.routes.items) |*entry| {
            const a = self.router.allocator;
            var full = std.ArrayList(u8).empty;
            defer full.deinit(a);
            try full.append(a, '/');
            try self.appendPrefix(&full, a);
            var sub = entry.path;
            while (sub.len > 0 and sub[0] == '/') sub = sub[1..];
            if (sub.len > 0) {
                if (full.items.len > 0 and full.items[full.items.len - 1] != '/') try full.append(a, '/');
                try full.appendSlice(a, sub);
            }
            var mw = std.ArrayList(MiddlewareFn).empty;
            defer mw.deinit(a);
            try self.appendMiddleware(&mw, a);
            try mw.appendSlice(a, opts.middleware);
            try mw.appendSlice(a, entry.middleware);
            try self.router.add(entry.method, full.items, entry.handler, .{
                .meta = entry.meta,
                .name = entry.name,
                .middleware = mw.items,
                .userData = entry.userData,
            });
        }
    }
};

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
            if (entry.ownsMiddleware) self.allocator.free(entry.middleware);
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

    pub fn add(self: *Router, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        // Registration paths must be clean patterns; query/fragment belong
        // to requests, never to route definitions.
        if (std.mem.indexOfAny(u8, path, "?#") != null) return RouteError.InvalidPattern;
        // Parse from an owned copy so pattern segments outlive the call.
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        const pat = pattern_mod.parsePattern(owned) catch |err| switch (err) {
            error.EmptyParameterName, error.InvalidWildcardPlacement, error.UnknownConverter, error.DuplicateParameter => return RouteError.InvalidPattern,
            error.TooManySegments => return RouteError.InvalidPattern,
        };

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

        if (opts.name) |n| {
            for (self.routes.items) |existing| {
                if (existing.name) |en| {
                    if (std.mem.eql(u8, en, n)) return RouteError.DuplicateName;
                }
            }
        }

        var owned_mw: []const MiddlewareFn = &.{};
        var owns_mw = false;
        if (opts.middleware.len > 0) {
            const duped = try self.allocator.dupe(MiddlewareFn, opts.middleware);
            owned_mw = duped;
            owns_mw = true;
        }
        errdefer if (owns_mw) self.allocator.free(owned_mw);

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = owned,
            .pattern = pat,
            .handler = handler,
            .priority = pattern_mod.priorityScore(&pat),
            .meta = opts.meta,
            .name = opts.name,
            .middleware = owned_mw,
            .ownsMiddleware = owns_mw,
            .userData = opts.userData,
            .deinitData = opts.deinitData,
        });
    }

    /// All registered entries (for docs generators). Read-only view.
    pub fn entries(self: *const Router) []const RouteEntry {
        return self.routes.items;
    }

    pub fn get(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.GET, path, handler, opts);
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
    pub fn post(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.POST, path, handler, opts);
    }
    pub fn put(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.PUT, path, handler, opts);
    }
    pub fn patch(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.PATCH, path, handler, opts);
    }
    pub fn delete(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.DELETE, path, handler, opts);
    }
    pub fn head(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.HEAD, path, handler, opts);
    }
    pub fn options(self: *Router, path: []const u8, handler: *const fn (*Context) anyerror!Response, opts: RouteOptions) RouteError!void {
        try self.add(.OPTIONS, path, handler, opts);
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
                    ctx.routeMiddleware = entry.middleware;
                    ctx.routeMiddlewareIndex = 0;
                }
            }
        }

        return if (best) |b| b.handler else null;
    }

    /// Rich match: returns the winning route entry (handler + middleware +
    /// metadata) instead of just the handler. Fills `ctx` params like match().
    pub fn matchEntry(self: *Router, method: Method, path: []const u8, ctx: *Context) ?*const RouteEntry {
        if (self.match(method, path, ctx) == null) return null;
        const clean = cleanRequestPath(path);
        var best: ?*const RouteEntry = null;
        var best_score: i64 = -1;
        for (self.routes.items) |*entry| {
            if (entry.method != method) continue;
            var probe = ctx.*;
            probe.paramCount = 0;
            if (matchPattern(&entry.pattern, clean, &probe)) {
                const score: i64 = @intCast(entry.priority);
                if (score > best_score) {
                    best_score = score;
                    best = entry;
                }
            }
        }
        return best;
    }

    /// Methods with a route matching `path` (any method), for 405/OPTIONS.
    /// Writes into `out` (capacity 9 covers every Method) and returns the slice.
    pub fn allowedMethods(self: *Router, path: []const u8, out: *[9]Method) []Method {
        const clean = cleanRequestPath(path);
        var count: usize = 0;
        var seen: [9]Method = undefined;
        var seen_count: usize = 0;
        for (self.routes.items) |*entry| {
            var already = false;
            for (seen[0..seen_count]) |m| {
                if (m == entry.method) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            var probe = Context{
                .allocator = self.allocator,
                .path = clean,
                .method = entry.method,
            };
            if (matchPattern(&entry.pattern, clean, &probe)) {
                if (count < out.len) {
                    out[count] = entry.method;
                    count += 1;
                }
                if (seen_count < seen.len) {
                    seen[seen_count] = entry.method;
                    seen_count += 1;
                }
            }
        }
        return out[0..count];
    }

    /// Creates a prefixed route group. `prefix` and `opts.middleware` are
    /// borrowed for the group's lifetime (typically literals).
    pub fn group(self: *Router, prefix: []const u8, opts: GroupOptions) Group {
        return .{ .router = self, .prefix = prefix, .middleware = opts.middleware };
    }

    /// Mounts all of `other`'s routes under `prefix`, preserving methods,
    /// names, metadata, parameters, and middleware. Mounted `userData`
    /// pointers are borrowed: `other` must outlive this router (same rule
    /// as route names and metadata strings).
    pub fn mount(self: *Router, prefix: []const u8, other: *Router, opts: MountOptions) RouteError!void {
        const g = self.group(prefix, .{});
        try g.mountRouter(other, opts);
    }

    /// Removes the route registered under `name`. Returns true when found.
    pub fn removeByName(self: *Router, name: []const u8) bool {
        for (self.routes.items, 0..) |existing, i| {
            if (existing.name) |n| {
                if (std.mem.eql(u8, n, name)) {
                    const entry = self.routes.orderedRemove(i);
                    self.allocator.free(entry.path);
                    if (entry.ownsMiddleware) self.allocator.free(entry.middleware);
                    return true;
                }
            }
        }
        return false;
    }

    /// Writes one anonymous-struct field into `out` for `url()`.
    /// Integers/floats/bools format; strings borrow; null optionals count
    /// as missing.
    fn writeParamField(out: *std.ArrayList(u8), allocator: Allocator, params: anytype, comptime field_name: []const u8) RouteError!void {
        if (!@hasField(@TypeOf(params), field_name)) return RouteError.MissingParam;
        return writeParamInner(out, allocator, @field(params, field_name));
    }

    fn writeParamInner(out: *std.ArrayList(u8), allocator: Allocator, value: anytype) RouteError!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int, .comptime_int => out.print(allocator, "{d}", .{value}) catch return RouteError.OutOfMemory,
            .float, .comptime_float => out.print(allocator, "{d}", .{value}) catch return RouteError.OutOfMemory,
            .bool => out.appendSlice(allocator, if (value) "true" else "false") catch return RouteError.OutOfMemory,
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    out.appendSlice(allocator, value) catch return RouteError.OutOfMemory;
                } else if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        out.appendSlice(allocator, value[0..]) catch return RouteError.OutOfMemory;
                    } else return RouteError.InvalidParamValue;
                } else return RouteError.InvalidParamValue;
            },
            .array => |arr| {
                if (arr.child == u8) {
                    out.appendSlice(allocator, value[0..]) catch return RouteError.OutOfMemory;
                } else return RouteError.InvalidParamValue;
            },
            .optional => {
                if (value) |inner| {
                    return writeParamInner(out, allocator, inner);
                } else return RouteError.MissingParam;
            },
            else => return RouteError.InvalidParamValue,
        }
    }

    /// Builds a URL from a named route, substituting `{param}` values from
    /// `params` (a struct: ints/floats/bools formatted, strings raw).
    /// Missing, unknown, or invalid values are errors; the result is owned
    /// by the router allocator and must be freed by the caller.
    pub fn url(self: *Router, name: []const u8, params: anytype) RouteError![]u8 {
        const P = @TypeOf(params);
        if (@typeInfo(P) != .@"struct") @compileError("router.url params must be a struct, e.g. .{.id = 42}");
        const entry = for (self.routes.items) |*e| {
            if (e.name) |n| {
                if (std.mem.eql(u8, n, name)) break e;
            }
        } else return RouteError.UnknownRoute;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, '/');
        const fields = @typeInfo(P).@"struct".fields;
        for (entry.pattern.segments[0..entry.pattern.count], 0..) |seg, i| {
            if (i > 0) try out.append(self.allocator, '/');
            switch (seg.kind) {
                .literal => try out.appendSlice(self.allocator, seg.text),
                .wildcard => {
                    var done = false;
                    inline for (fields) |f| {
                        if (!done and std.mem.eql(u8, f.name, seg.text)) {
                            try writeParamField(&out, self.allocator, params, f.name);
                            done = true;
                        }
                    }
                    if (!done) return RouteError.MissingParam;
                },
                .parameter => {
                    const start = out.items.len;
                    var done = false;
                    inline for (fields) |f| {
                        if (!done and std.mem.eql(u8, f.name, seg.text)) {
                            try writeParamField(&out, self.allocator, params, f.name);
                            done = true;
                        }
                    }
                    if (!done) return RouteError.MissingParam;
                    const v = out.items[start..];
                    if (seg.converter != .path and std.mem.indexOfScalar(u8, v, '/') != null) {
                        out.shrinkRetainingCapacity(start);
                        return RouteError.InvalidParamValue;
                    }
                    if (!seg.converter.matches(v)) {
                        out.shrinkRetainingCapacity(start);
                        return RouteError.InvalidParamValue;
                    }
                },
            }
        }
        // Reject unknown params: every supplied field must be consumed.
        inline for (fields) |f| {
            var consumed = false;
            for (entry.pattern.segments[0..entry.pattern.count]) |seg| {
                if ((seg.kind == .parameter or seg.kind == .wildcard) and std.mem.eql(u8, seg.text, f.name)) {
                    consumed = true;
                    break;
                }
            }
            if (!consumed) return RouteError.UnknownParam;
        }
        return out.toOwnedSlice(self.allocator) catch return RouteError.OutOfMemory;
    }

    /// Matches and dispatches the request through registered middlewares and route handler.
    /// Distinguishes 404 (no path match) from 405 (path matches another
    /// method): 405 responses carry an `Allow` header. An OPTIONS request
    /// with no explicit OPTIONS route but other methods on the path gets an
    /// automatic `204 No Content` + `Allow` response.
    pub fn dispatch(self: *Router, ctx: *Context) Response {
        const maybe_handler = self.match(ctx.method, ctx.path, ctx);
        if (maybe_handler == null) {
            var allow_buf: [9]Method = undefined;
            const allowed = self.allowedMethods(ctx.path, &allow_buf);
            if (allowed.len > 0) {
                if (ctx.method == .OPTIONS) {
                    return self.methodNotAllowedResponse(ctx, allowed, 204, "");
                }
                return self.methodNotAllowedResponse(ctx, allowed, 405, "Method Not Allowed");
            }
        }
        ctx.activeRouter = self;
        ctx.activeHandler = maybe_handler;
        ctx.middlewareIndex = 0;
        return ctx.next() catch |err| self.handleError(ctx, err);
    }

    fn methodNotAllowedResponse(self: *Router, ctx: *Context, allowed: []const Method, status: u16, body: []const u8) Response {
        if (self.statusHandlers.get(status)) |sh| {
            return sh(ctx) catch Response{ .status = status, .body = body };
        }
        var buf: [128]u8 = undefined;
        var pos: usize = 0;
        for (allowed, 0..) |m, i| {
            const name = m.toString();
            if (i > 0) {
                if (pos + 2 > buf.len) break;
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            if (pos + name.len > buf.len) break;
            @memcpy(buf[pos..][0..name.len], name);
            pos += name.len;
        }
        const allow_value = ctx.allocator.dupe(u8, buf[0..pos]) catch {
            return Response{ .status = status, .body = body };
        };
        const hs = ctx.allocator.dupe(Header, &.{.{ .name = "Allow", .value = allow_value }}) catch {
            ctx.allocator.free(allow_value);
            return Response{ .status = status, .body = body };
        };
        return Response{ .status = status, .body = body, .headers = hs };
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
                // Typed converters reject non-conforming segments so more
                // specific routes (static, narrower types) win deterministically.
                if (!seg.converter.matches(path_seg)) return false;
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

    try router.get("/hello", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    const handler = router.match(.GET, "/hello", &ctx);
    try std.testing.expect(handler != null);
}

test "rejects duplicate GET route" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users", dummyHandler, .{});
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/users", dummyHandler, .{}));
}

test "allows same path different methods" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users", dummyHandler, .{});
    try router.post("/users", dummyHandler, .{});
}

test "static beats parameter precedence" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/me", dummyHandler, .{});
    try router.get("/users/{id}", dummyHandler, .{});

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

    try router.get("/users/{id}/posts/{post_id}", dummyHandler, .{});

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
    try router.get(temp, dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    const handler = router.match(.GET, "/tmp/xyz", &ctx);
    try std.testing.expect(handler != null);
    try std.testing.expectEqualStrings("xyz", ctx.param("name").?);

    // Duplicate detection still works after the temp buffer is freed.
    try std.testing.expect(router.hasConflict(.GET, "/tmp/{other}"));
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/tmp/{name2}", dummyHandler, .{}));
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

    try router.get("/users/{id}", dummyHandler, .{});
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

    try router.get("/search", dummyHandler, .{});
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

    try router.get("/asset", dummyHandler, .{});
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

    try std.testing.expectError(RouteError.InvalidPattern, router.get("/users?x=1", dummyHandler, .{}));
    try std.testing.expectError(RouteError.InvalidPattern, router.get("/users#frag", dummyHandler, .{}));
}

test "duplicate detection ignores query strings" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id}", dummyHandler, .{});
    try std.testing.expect(router.hasConflict(.GET, "/users/{other}?x=1"));
    try std.testing.expect(router.remove(.GET, "/users/{other}?x=1"));
    try std.testing.expect(!router.hasConflict(.GET, "/users/{id}"));
}

test "nested slugs and wildcard remainder" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/a/{x}/c/{y}", dummyHandler, .{});
    try router.get("/files/*path", dummyHandler, .{});

    var ctx1 = Context{ .allocator = a };
    _ = router.match(.GET, "/a/1/c/2", &ctx1);
    try std.testing.expectEqualStrings("1", ctx1.param("x").?);
    try std.testing.expectEqualStrings("2", ctx1.param("y").?);

    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/files/a/b/c?x=1", &ctx2);
    try std.testing.expectEqualStrings("a/b/c", ctx2.param("path").?);

    // Same nested shape with different param names is a duplicate.
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/a/{p}/c/{q}", dummyHandler, .{}));
}

test "match preserves TLS and peer fields" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/secure", dummyHandler, .{});
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

fn idHandler(ctx: *Context) anyerror!Response {
    const id = ctx.paramInt("id") orelse return Response{ .status = 400, .body = "bad id" };
    var buf: [32]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "id={d}", .{id});
    return .{ .status = 200, .body = try ctx.allocator.dupe(u8, body) };
}

test "typed int parameter converts and rejects" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id:int}", idHandler, .{});

    var ctx = Context{ .allocator = a };
    const h = router.match(.GET, "/users/42", &ctx);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(?i64, 42), ctx.paramInt("id"));
    try std.testing.expectEqual(@as(?u64, 42), ctx.paramUint("id"));
    try std.testing.expectEqual(@as(?f64, 42.0), ctx.paramFloat("id"));

    var bad = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/users/abc", &bad) == null);
    try std.testing.expect(router.match(.GET, "/users/4.5", &bad) == null);
    try std.testing.expect(ctx.paramBool("id") == null);
}

test "uint/float/bool converters" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/u/{n:uint}", dummyHandler, .{});
    try router.get("/f/{v:float}", dummyHandler, .{});
    try router.get("/b/{v:bool}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/u/7", &ctx);
    try std.testing.expectEqualStrings("7", ctx.param("n").?);
    var neg = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/u/-7", &neg) == null);

    var fl = Context{ .allocator = a };
    _ = router.match(.GET, "/f/2.5", &fl);
    try std.testing.expect(fl.paramFloat("v").? == 2.5);

    var b = Context{ .allocator = a };
    _ = router.match(.GET, "/b/true", &b);
    try std.testing.expectEqual(@as(?bool, true), b.paramBool("v"));
    var b2 = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/b/yes", &b2) == null);
}

test "uuid and slug converters" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/o/{id:uuid}", dummyHandler, .{});
    try router.get("/blog/{slug:slug}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/o/123e4567-e89b-12d3-a456-426614174000", &ctx);
    try std.testing.expect(ctx.param("id") != null);
    var bad = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/o/not-a-uuid", &bad) == null);

    var s = Context{ .allocator = a };
    _ = router.match(.GET, "/blog/hello-world", &s);
    try std.testing.expectEqualStrings("hello-world", s.param("slug").?);
    var s2 = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/blog/Hello-World", &s2) == null);
    var s3 = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/blog/trailing-", &s3) == null);
}

test "catch-all path converter spans segments" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/files/{path:path}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/files/a.txt", &ctx);
    try std.testing.expectEqualStrings("a.txt", ctx.param("path").?);
    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/files/docs/api/v1/index.html", &ctx2);
    try std.testing.expectEqualStrings("docs/api/v1/index.html", ctx2.param("path").?);
}

test "multiple typed parameters" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{userId:int}/posts/{postId:int}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/users/42/posts/10", &ctx);
    try std.testing.expectEqual(@as(?i64, 42), ctx.paramInt("userId"));
    try std.testing.expectEqual(@as(?i64, 10), ctx.paramInt("postId"));
}

test "int route does not swallow static sibling" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id:int}", dummyHandler, .{});
    try router.get("/users/me", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/users/me", &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.paramCount);
}

test "int and generic overlap is allowed, typed wins" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/w/{name}", dummyHandler, .{});
    try router.get("/w/{id:int}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/w/42", &ctx);
    try std.testing.expect(ctx.param("id") != null);
    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/w/abc", &ctx2);
    try std.testing.expectEqualStrings("abc", ctx2.param("name").?);
}

test "generic duplicates conflict" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id}", dummyHandler, .{});
    try std.testing.expectError(RouteError.DuplicateRoute, router.get("/users/{name}", dummyHandler, .{}));
    // Same shape different method is fine.
    try router.post("/users/{name}", dummyHandler, .{});
}

test "duplicate names rejected" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/a", dummyHandler, .{ .name = "home" });
    try std.testing.expectError(RouteError.DuplicateName, router.get("/b", dummyHandler, .{ .name = "home" }));
}

test "groups compose prefixes and middleware" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    // Order log lives in the same arena the dispatched request uses, so a
    // single allocator owns it (never freed with a different one).
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var order = std.ArrayList(u8).empty;
    const T = struct {
        var log: *std.ArrayList(u8) = undefined;
        fn mw(ctx: *Context, next: NextFn) anyerror!Response {
            try log.append(ctx.allocator, 'm');
            return next(ctx);
        }
    };
    T.log = &order;
    const api = router.group("/api", .{ .middleware = &.{T.mw} });
    const users = api.group("/users", .{});
    try users.get("/", dummyHandler, .{});
    try users.get("/{id:int}", dummyHandler, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/api/users/42", &ctx);
    try std.testing.expectEqualStrings("42", ctx.param("id").?);
    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/api/users/", &ctx2);
    // Group middleware runs before the handler through dispatch.
    var dctx = Context{ .allocator = aa, .method = .GET, .path = "/api/users/" };
    const res = router.dispatch(&dctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), order.items.len);
}

test "mount preserves routes, params, names" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    var admin = Router.init(a);
    defer admin.deinit();
    try admin.get("/stats", dummyHandler, .{ .name = "stats" });
    try admin.get("/users/{id:int}", dummyHandler, .{});
    try router.mount("/admin", &admin, .{});

    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/admin/users/7", &ctx);
    try std.testing.expectEqualStrings("7", ctx.param("id").?);
    const u = try router.url("stats", .{});
    defer a.free(u);
    try std.testing.expectEqualStrings("/admin/stats", u);
}

test "dispatch distinguishes 404 and 405 with Allow" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users", dummyHandler, .{});
    try router.post("/users", dummyHandler, .{});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctx404 = Context{ .allocator = arena.allocator(), .method = .GET, .path = "/nope" };
    const r404 = router.dispatch(&ctx404);
    try std.testing.expectEqual(@as(u16, 404), r404.status);

    var ctx405 = Context{ .allocator = arena.allocator(), .method = .DELETE, .path = "/users" };
    const r405 = router.dispatch(&ctx405);
    try std.testing.expectEqual(@as(u16, 405), r405.status);
    var allow: ?[]const u8 = null;
    for (r405.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Allow")) allow = h.value;
    }
    try std.testing.expect(allow != null);
    try std.testing.expect(std.mem.indexOf(u8, allow.?, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow.?, "POST") != null);
}

test "dispatch auto-OPTIONS and HEAD fallback" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/asset", dummyHandler, .{});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctxo = Context{ .allocator = arena.allocator(), .method = .OPTIONS, .path = "/asset" };
    const ro = router.dispatch(&ctxo);
    try std.testing.expectEqual(@as(u16, 204), ro.status);

    var ctxh = Context{ .allocator = arena.allocator(), .method = .HEAD, .path = "/asset" };
    const rh = router.dispatch(&ctxh);
    try std.testing.expectEqual(@as(u16, 200), rh.status);
}

test "url reversing covers params, nesting, errors" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id:int}", dummyHandler, .{ .name = "user" });
    try router.get("/users/{userId:int}/posts/{postId:int}", dummyHandler, .{ .name = "userPost" });
    try router.get("/files/{path:path}", dummyHandler, .{ .name = "file" });

    const user_url = try router.url("user", .{ .id = 42 });
    defer a.free(user_url);
    try std.testing.expectEqualStrings("/users/42", user_url);

    const post_url = try router.url("userPost", .{ .userId = 7, .postId = 9 });
    defer a.free(post_url);
    try std.testing.expectEqualStrings("/users/7/posts/9", post_url);

    const file_url = try router.url("file", .{ .path = "a/b/c.txt" });
    defer a.free(file_url);
    try std.testing.expectEqualStrings("/files/a/b/c.txt", file_url);

    try std.testing.expectError(RouteError.UnknownRoute, router.url("nope", .{}));
    try std.testing.expectError(RouteError.MissingParam, router.url("user", .{}));
    try std.testing.expectError(RouteError.UnknownParam, router.url("user", .{ .id = 1, .extra = 2 }));
    try std.testing.expectError(RouteError.InvalidParamValue, router.url("user", .{ .id = "abc" }));
}

test "trailing slash is lenient" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/users/", &ctx) != null);
    var ctx2 = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "//users//", &ctx2) != null);
}

test "encoded and UTF-8 segments match as raw text" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/f/{name}", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/f/hello%20world", &ctx);
    try std.testing.expectEqualStrings("hello%20world", ctx.param("name").?);
    var ctx2 = Context{ .allocator = a };
    _ = router.match(.GET, "/f/héllo", &ctx2);
    try std.testing.expect(ctx2.param("name") != null);
}

test "query params stay separate from path params" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{id:int}", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/users/42?page=2&limit=20", &ctx);
    try std.testing.expectEqualStrings("42", ctx.param("id").?);
    try std.testing.expectEqualStrings("2", ctx.queryParam("page").?);
    try std.testing.expectEqualStrings("20", ctx.queryParam("limit").?);
}

test "struct binding validates fields and types" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/users/{userId:int}/posts/{postId:int}", dummyHandler, .{});

    const P = struct {
        userId: u64,
        postId: u64,
    };
    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/users/3/posts/4", &ctx);
    const p = try ctx.bindParams(P);
    try std.testing.expectEqual(@as(u64, 3), p.userId);
    try std.testing.expectEqual(@as(u64, 4), p.postId);

    const Q = struct {
        userId: u64,
        missing: u64,
    };
    try std.testing.expectError(ParamError.MissingParam, ctx.bindParams(Q));

    const O = struct {
        userId: u64,
        nick: ?[]const u8 = null,
    };
    const o = try ctx.bindParams(O);
    try std.testing.expectEqual(@as(u64, 3), o.userId);
    try std.testing.expect(o.nick == null);

    const S = struct {
        userId: []const u8,
    };
    const s = try ctx.bindParams(S);
    try std.testing.expectEqualStrings("3", s.userId);
}

test "struct binding rejects bad values" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/n/{v:int}", dummyHandler, .{});
    // Bypass converter by matching the sibling generic route's params.
    try router.get("/g/{v}", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/g/abc", &ctx);
    const P = struct {
        v: i64,
    };
    try std.testing.expectError(ParamError.InvalidParamValue, ctx.bindParams(P));
}

test "route middleware runs global, router, route in order" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var order = std.ArrayList(u8).empty;
    const T = struct {
        var log: *std.ArrayList(u8) = undefined;
        fn g1(ctx: *Context, next: NextFn) anyerror!Response {
            try log.append(ctx.allocator, '1');
            return next(ctx);
        }
        fn g2(ctx: *Context, next: NextFn) anyerror!Response {
            try log.append(ctx.allocator, '2');
            return next(ctx);
        }
        fn h(ctx: *Context) anyerror!Response {
            try log.append(ctx.allocator, 'h');
            return Response{};
        }
    };
    T.log = &order;
    try router.use(T.g1);
    try router.get("/m", T.h, .{ .middleware = &.{T.g2} });
    var ctx = Context{ .allocator = aa, .method = .GET, .path = "/m" };
    const res = router.dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 3), order.items.len);
    try std.testing.expectEqual('1', order.items[0]);
    try std.testing.expectEqual('2', order.items[1]);
    try std.testing.expectEqual('h', order.items[2]);
}

test "removeByName releases the route" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/tmp", dummyHandler, .{ .name = "tmp" });
    try std.testing.expect(router.removeByName("tmp"));
    try std.testing.expect(!router.removeByName("tmp"));
    var ctx = Context{ .allocator = a };
    try std.testing.expect(router.match(.GET, "/tmp", &ctx) == null);
}

test "dynamic websocket-style route matches" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();
    try router.get("/ws/{roomId}", dummyHandler, .{});
    var ctx = Context{ .allocator = a };
    _ = router.match(.GET, "/ws/lobby", &ctx);
    try std.testing.expectEqualStrings("lobby", ctx.param("roomId").?);
}
