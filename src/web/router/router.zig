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
        return .{
            .status = 200,
            .body = content,
            .content_type = "text/html; charset=utf-8",
        };
    }

    /// Renders a JSON response from a serialized string or struct.
    pub fn renderJson(self: *const Context, value: anytype) !Response {
        const T = @TypeOf(value);
        if (T == []const u8 or T == []u8) {
            return Response{
                .status = 200,
                .body = value,
                .content_type = "application/json",
            };
        }
        const str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        return Response{
            .status = 200,
            .body = str,
            .content_type = "application/json",
        };
    }

    /// Renders a plain text response.
    pub fn text(self: *const Context, content: []const u8) Response {
        _ = self;
        return .{
            .status = 200,
            .body = content,
            .content_type = "text/plain; charset=utf-8",
        };
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
};

pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayList(RouteEntry) = .empty,

    pub fn init(allocator: Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |entry| self.allocator.free(entry.path);
        self.routes.deinit(self.allocator);
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
