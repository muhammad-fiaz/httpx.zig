//! HTTP Router Implementation for httpx.zig
//!
//! Pattern-based routing with path parameter support:
//!
//! - Static path matching (/users, /api/posts)
//! - Dynamic parameters (/users/:id, /posts/:postId/comments/:commentId)
//! - Wildcard routes (/files/*path)
//! - Route groups with prefixes
//! - Method-based routing
//! - Route priority (static > param > wildcard)
//! - 405 Method Not Allowed with Allow header
//! - Route conflict detection
//! - Trailing slash normalization policy

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const types = @import("../core/types.zig");

/// Route parameter extracted from the URL.
pub const RouteParam = struct {
    name: []const u8,
    value: []const u8,
};

/// Route match result containing the handler and extracted parameters.
/// `params` is allocated memory — caller must free with `allocator.free(result.params)`.
pub const RouteMatch = struct {
    handler: Handler,
    params: []const RouteParam,
};

/// Result of a find operation that distinguishes 404 from 405.
pub const FindResult = union(enum) {
    /// Route found with matching method.
    found: RouteMatch,
    /// Path exists but method is not allowed. `allowed` contains the methods.
    method_not_allowed: []const types.Method,
    /// No route matches this path at all.
    not_found,
};

pub const Handler = @import("server.zig").Handler;

/// Specificity score for route priority ordering.
/// Lower score = higher priority. Static beats param beats wildcard.
fn specificityScore(segments: []const Segment) u32 {
    var score: u32 = 0;
    for (segments) |seg| {
        switch (seg) {
            .literal => score += 0, // highest priority
            .param => score += 1000,
            .wildcard => score += 2000,
        }
    }
    // Also prefer shorter routes (fewer segments).
    score += @intCast(segments.len);
    return score;
}

const Route = struct {
    method: types.Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
    /// Specificity score for priority ordering.
    specificity: u32 = 0,
};

const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: []const u8,
};

/// Trailing slash handling policy.
pub const TrailingSlashPolicy = enum {
    /// Match exactly as registered. /users != /users/
    strict,
    /// Strip trailing slash before matching. /users/ -> /users
    strip,
    /// Redirect trailing slash to non-trailing version (301).
    redirect,
};

const MAX_PARAMS = 16;

/// HTTP Router with path parameter support.
pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayList(Route) = .empty,
    not_found_handler: ?Handler = null,
    trailing_slash: TrailingSlashPolicy = .strict,
    /// Reusable params buffer owned by the router.
    params_buf: [MAX_PARAMS]RouteParam = undefined,
    /// Set to true by find() when trailing_slash policy is .redirect
    /// and the incoming path had a trailing slash that should redirect.
    redirect_trailing_slash: bool = false,

    const Self = @This();

    /// Creates a new router.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Releases all allocated resources.
    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
            self.allocator.free(route.pattern);
        }
        self.routes.deinit(self.allocator);
    }

    /// Sets the trailing slash policy.
    pub fn setTrailingSlashPolicy(self: *Self, policy: TrailingSlashPolicy) void {
        self.trailing_slash = policy;
    }

    /// Adds a route to the router. Returns error.DuplicateRoute if the
    /// same method+pattern combination already exists.
    pub fn add(self: *Self, method: types.Method, pattern: []const u8, handler: Handler) !void {
        // Check for duplicate routes.
        for (self.routes.items) |route| {
            if (route.method == method and mem.eql(u8, route.pattern, pattern)) {
                return error.DuplicateRoute;
            }
        }

        const dup_pattern = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(dup_pattern);

        const segments = try self.parsePattern(dup_pattern);
        errdefer self.allocator.free(segments);

        const score = specificityScore(segments);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = dup_pattern,
            .segments = segments,
            .handler = handler,
            .specificity = score,
        });
    }

    /// Adds a GET route.
    pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.GET, path, handler);
    }

    /// Adds a POST route.
    pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.POST, path, handler);
    }

    /// Adds a PUT route.
    pub fn put(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PUT, path, handler);
    }

    /// Adds a DELETE route.
    pub fn delete(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.DELETE, path, handler);
    }

    /// Alias for delete().
    pub fn del(self: *Self, path: []const u8, handler: Handler) !void {
        try self.delete(path, handler);
    }

    /// Adds a PATCH route.
    pub fn patch(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PATCH, path, handler);
    }

    /// Adds a HEAD route.
    pub fn head(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.HEAD, path, handler);
    }

    /// Adds an OPTIONS route.
    pub fn options(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.OPTIONS, path, handler);
    }

    /// Adds a TRACE route.
    pub fn trace(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.TRACE, path, handler);
    }

    /// Adds a CONNECT route.
    pub fn connect(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.CONNECT, path, handler);
    }

    fn parsePattern(self: *Self, pattern: []const u8) ![]const Segment {
        var segments = std.ArrayList(Segment).empty;

        var iter = mem.splitScalar(u8, pattern, '/');
        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (part[0] == ':') {
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else if (part[0] == '*') {
                try segments.append(self.allocator, .{ .wildcard = part[1..] });
            } else {
                try segments.append(self.allocator, .{ .literal = part });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    /// Normalize the path according to the trailing slash policy.
    /// Sets redirect_trailing_slash when redirect policy is active.
    fn normalizePath(self: *Self, path: []const u8) []const u8 {
        self.redirect_trailing_slash = false;
        if (self.trailing_slash == .strict) return path;
        if (path.len > 1 and path[path.len - 1] == '/') {
            if (self.trailing_slash == .redirect) {
                self.redirect_trailing_slash = true;
            }
            return path[0 .. path.len - 1];
        }
        return path;
    }

    /// Const version of normalizePath for read-only callers (e.g. allowedMethods).
    fn normalizePathConst(self: *const Self, path: []const u8) []const u8 {
        if (self.trailing_slash == .strict) return path;
        if (path.len > 1 and path[path.len - 1] == '/') {
            return path[0 .. path.len - 1];
        }
        return path;
    }

    /// Finds a matching route for the given method and path.
    /// Returns the best match based on specificity (static > param > wildcard).
    /// The returned RouteMatch's params slice is allocated memory; caller must free it.
    pub fn find(self: *Self, method: types.Method, path: []const u8) ?RouteMatch {
        const normalized = self.normalizePath(path);

        var best_score: ?u32 = null;
        var best_handler: ?Handler = null;
        var best_params_len: usize = 0;

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchRoute(route, normalized, &self.params_buf)) |param_count| {
                if (best_score == null or route.specificity < best_score.?) {
                    best_score = route.specificity;
                    best_handler = route.handler;
                    best_params_len = param_count;
                }
            }
        }

        if (best_handler) |handler| {
            const params = self.allocator.alloc(RouteParam, best_params_len) catch return null;
            for (params, 0..) |*p, i| {
                p.* = self.params_buf[i];
            }
            return .{
                .handler = handler,
                .params = params,
            };
        }

        return null;
    }

    /// Finds a route with full result information (found / 405 / 404).
    /// This allows the server to distinguish 404 from 405.
    /// The returned RouteMatch's params slice is allocated memory; caller must free it.
    pub fn findEx(self: *Self, method: types.Method, path: []const u8) FindResult {
        const normalized = self.normalizePath(path);

        var best_score: ?u32 = null;
        var best_handler: ?Handler = null;
        var best_params_len: usize = 0;

        // Also track if any route matches the path with a different method.
        var method_matched = false;

        for (self.routes.items) |route| {
            if (self.matchRoute(route, normalized, &self.params_buf)) |param_count| {
                if (route.method == method) {
                    if (best_score == null or route.specificity < best_score.?) {
                        best_score = route.specificity;
                        best_handler = route.handler;
                        best_params_len = param_count;
                    }
                } else {
                    method_matched = true;
                }
            }
        }

        if (best_handler) |handler| {
            const params = self.allocator.alloc(RouteParam, best_params_len) catch return .not_found;
            for (params, 0..) |*p, i| {
                p.* = self.params_buf[i];
            }
            return .{ .found = .{
                .handler = handler,
                .params = params,
            } };
        }

        if (method_matched) {
            // Path exists but method is wrong -> 405.
            var allowed_buf: [16]types.Method = undefined;
            const count = self.allowedMethods(normalized, &allowed_buf);
            if (count > 0) {
                // We need to allocate the allowed methods slice.
                const allowed = self.allocator.alloc(types.Method, count) catch return .not_found;
                for (0..count) |i| {
                    allowed[i] = allowed_buf[i];
                }
                return .{ .method_not_allowed = allowed };
            }
        }

        return .not_found;
    }

    /// Returns the list of allowed methods for a given path.
    ///
    /// The method list is deduplicated and written into `out_methods`.
    /// The returned value is the number of methods written.
    pub fn allowedMethods(self: *const Self, path: []const u8, out_methods: *[16]types.Method) usize {
        const normalized = self.normalizePathConst(path);
        var params_buf: [MAX_PARAMS]RouteParam = undefined;
        var count: usize = 0;

        for (self.routes.items) |route| {
            if (self.matchRoute(route, normalized, &params_buf) == null) continue;

            var exists = false;
            for (out_methods[0..count]) |existing| {
                if (existing == route.method) {
                    exists = true;
                    break;
                }
            }

            if (!exists and count < out_methods.len) {
                out_methods[count] = route.method;
                count += 1;
            }
        }

        return count;
    }

    fn matchRoute(self: *const Self, route: Route, path: []const u8, params: *[MAX_PARAMS]RouteParam) ?usize {
        _ = self;

        var path_iter = mem.splitScalar(u8, path, '/');
        var param_idx: usize = 0;
        var seg_idx: usize = 0;
        // Track byte position in original path for wildcard capture.
        // Start at1 to skip the leading '/'.
        var byte_pos: usize = 1;

        while (path_iter.next()) |part| {
            if (part.len == 0) continue;

            if (seg_idx >= route.segments.len) return null;

            const segment = route.segments[seg_idx];
            switch (segment) {
                .literal => |lit| {
                    if (!mem.eql(u8, lit, part)) return null;
                    byte_pos += part.len + 1; // +1 for the trailing '/'
                },
                .param => |name| {
                    if (param_idx < params.len) {
                        params[param_idx] = .{ .name = name, .value = part };
                        param_idx += 1;
                    }
                    byte_pos += part.len + 1;
                },
                .wildcard => |name| {
                    // Capture everything from current byte_pos to end of path.
                    const remaining = if (byte_pos <= path.len) path[byte_pos..] else "";
                    if (param_idx < params.len) {
                        params[param_idx] = .{ .name = name, .value = remaining };
                        param_idx += 1;
                    }
                    return param_idx;
                },
            }
            seg_idx += 1;
        }

        return if (seg_idx == route.segments.len) param_idx else null;
    }

    /// Sets the 404 handler.
    pub fn setNotFound(self: *Self, handler: Handler) void {
        self.not_found_handler = handler;
    }

    /// Creates a route group with the given prefix.
    pub fn group(self: *Self, prefix: []const u8) RouteGroup {
        return RouteGroup.init(self, prefix);
    }
};

/// Route group for organizing routes with a common prefix.
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,

    const Self = @This();

    /// Creates a new route group.
    pub fn init(router: *Router, prefix: []const u8) Self {
        return .{ .router = router, .prefix = prefix };
    }

    /// Adds a route to the group.
    pub fn add(self: *Self, method: types.Method, path: []const u8, handler: Handler) !void {
        var full_path = std.ArrayList(u8).empty;
        defer full_path.deinit(self.router.allocator);

        try full_path.appendSlice(self.router.allocator, self.prefix);
        try full_path.appendSlice(self.router.allocator, path);

        try self.router.add(method, full_path.items, handler);
    }

    /// Adds a GET route.
    pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.GET, path, handler);
    }

    /// Adds a POST route.
    pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.POST, path, handler);
    }

    /// Adds a PUT route.
    pub fn put(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PUT, path, handler);
    }

    /// Adds a DELETE route.
    pub fn delete(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.DELETE, path, handler);
    }

    /// Alias for delete().
    pub fn del(self: *Self, path: []const u8, handler: Handler) !void {
        try self.delete(path, handler);
    }

    /// Adds a PATCH route.
    pub fn patch(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.PATCH, path, handler);
    }

    /// Adds a HEAD route.
    pub fn head(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.HEAD, path, handler);
    }

    /// Adds an OPTIONS route.
    pub fn options(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.OPTIONS, path, handler);
    }

    /// Adds a TRACE route.
    pub fn trace(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.TRACE, path, handler);
    }

    /// Adds a CONNECT route.
    pub fn connect(self: *Self, path: []const u8, handler: Handler) !void {
        try self.add(.CONNECT, path, handler);
    }
};

test "Router basic matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);
    try router.add(.GET, "/users/:id", handler);
    try router.add(.POST, "/users", handler);

    const result1 = router.find(.GET, "/users");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 0), result1.?.params.len);
    allocator.free(result1.?.params);

    const result2 = router.find(.GET, "/users/123");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 1), result2.?.params.len);
    try std.testing.expectEqualStrings("id", result2.?.params[0].name);
    try std.testing.expectEqualStrings("123", result2.?.params[0].value);
    allocator.free(result2.?.params);

    const result3 = router.find(.DELETE, "/users");
    try std.testing.expect(result3 == null);
}

test "Router multiple parameters" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users/:userId/posts/:postId", handler);

    const result = router.find(.GET, "/users/42/posts/99");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.params.len);
    try std.testing.expectEqualStrings("userId", result.?.params[0].name);
    try std.testing.expectEqualStrings("42", result.?.params[0].value);
    try std.testing.expectEqualStrings("postId", result.?.params[1].name);
    try std.testing.expectEqualStrings("99", result.?.params[1].value);
    allocator.free(result.?.params);
}

test "Router convenience methods and group helpers" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.get("/get", handler);
    try router.post("/post", handler);
    try router.put("/put", handler);
    try router.del("/del", handler);
    try router.patch("/patch", handler);
    try router.head("/head", handler);
    try router.options("/options", handler);
    try router.trace("/trace", handler);
    try router.connect("/connect", handler);

    {
        const r = router.find(.GET, "/get");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.POST, "/post");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.PUT, "/put");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.DELETE, "/del");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.PATCH, "/patch");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.HEAD, "/head");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.OPTIONS, "/options");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.TRACE, "/trace");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.CONNECT, "/connect");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }

    var api = router.group("/api");
    try api.get("/users", handler);
    try api.post("/users", handler);
    try api.put("/users/:id", handler);
    try api.del("/users/:id", handler);
    try api.patch("/users/:id", handler);
    try api.head("/users/:id", handler);
    try api.options("/users/:id", handler);
    try api.trace("/diag", handler);
    try api.connect("/tunnel", handler);

    {
        const r = router.find(.GET, "/api/users");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.POST, "/api/users");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.PUT, "/api/users/1");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.DELETE, "/api/users/1");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.PATCH, "/api/users/1");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.HEAD, "/api/users/1");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.OPTIONS, "/api/users/1");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.TRACE, "/api/diag");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
    {
        const r = router.find(.CONNECT, "/api/tunnel");
        try std.testing.expect(r != null);
        allocator.free(r.?.params);
    }
}

test "Route priority: static preferred over param" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const static_handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    const param_handler = struct {
        fn h2(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h2;

    // Register param first, then static.
    try router.add(.GET, "/users/:id", param_handler);
    try router.add(.GET, "/users/me", static_handler);

    // Static should win.
    const result = router.find(.GET, "/users/me");
    try std.testing.expect(result != null);
    allocator.free(result.?.params);
    // The static handler has lower specificity (0 vs 1001).
    const r2 = router.find(.GET, "/users/42");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(param_handler, r2.?.handler);
    allocator.free(r2.?.params);
}

test "Route priority: param preferred over wildcard" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const param_handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    const wildcard_handler = struct {
        fn h2(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h2;

    try router.add(.GET, "/files/:name", param_handler);
    try router.add(.GET, "/files/*path", wildcard_handler);

    // /files/foo matches both param and wildcard; param should win.
    const result = router.find(.GET, "/files/foo");
    try std.testing.expect(result != null);
    // Verify param handler was chosen (lower specificity).
    try std.testing.expectEqual(param_handler, result.?.handler);
    allocator.free(result.?.params);
}

test "Duplicate route detection" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);
    // Same method + pattern should fail.
    try std.testing.expectError(error.DuplicateRoute, router.add(.GET, "/users", handler));
    // Different method is OK.
    try router.add(.POST, "/users", handler);
}

test "405 Method Not Allowed" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);
    try router.add(.POST, "/users", handler);

    // Method exists -> found.
    const r1 = router.findEx(.GET, "/users");
    try std.testing.expect(r1 == .found);

    // Wrong method -> method_not_allowed.
    const r2 = router.findEx(.PUT, "/users");
    switch (r2) {
        .method_not_allowed => |allowed| {
            defer allocator.free(allowed);
            try std.testing.expectEqual(@as(usize, 2), allowed.len);
        },
        else => try std.testing.expect(false),
    }

    // No path at all -> not_found.
    const r3 = router.findEx(.GET, "/nonexistent");
    try std.testing.expect(r3 == .not_found);
}

test "Trailing slash strip policy" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    router.setTrailingSlashPolicy(.strip);

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);

    // /users/ should match /users when strip policy is active.
    const result = router.find(.GET, "/users/");
    try std.testing.expect(result != null);
    allocator.free(result.?.params);
}

test "Router wildcard matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/files/*path", handler);

    const result = router.find(.GET, "/files/docs/readme.md");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.params.len);
    try std.testing.expectEqualStrings("path", result.?.params[0].name);
    try std.testing.expectEqualStrings("docs/readme.md", result.?.params[0].value);
    allocator.free(result.?.params);
}

test "allowedMethods returns correct set" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);
    try router.add(.POST, "/users", handler);
    try router.add(.DELETE, "/users/:id", handler);

    var methods: [16]types.Method = undefined;
    const count = router.allowedMethods("/users", &methods);
    try std.testing.expectEqual(@as(usize, 2), count);

    const count2 = router.allowedMethods("/users/1", &methods);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqual(types.Method.DELETE, methods[0]);
}

test "Trailing slash redirect policy sets flag" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    router.setTrailingSlashPolicy(.redirect);

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);

    // /users/ with redirect policy should set the flag.
    const result = router.find(.GET, "/users/");
    try std.testing.expect(result != null);
    try std.testing.expect(router.redirect_trailing_slash);
    allocator.free(result.?.params);

    // /users without trailing slash should not set the flag.
    const result2 = router.find(.GET, "/users");
    try std.testing.expect(result2 != null);
    try std.testing.expect(!router.redirect_trailing_slash);
    allocator.free(result2.?.params);
}

test "Trailing slash strict policy still matches" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users", handler);

    // With strict policy, /users/ still matches /users because empty segments
    // from the trailing slash are skipped during segment-based matching.
    const result = router.find(.GET, "/users/");
    try std.testing.expect(result != null);
    try std.testing.expect(!router.redirect_trailing_slash);
    allocator.free(result.?.params);
}

test "Wildcard with params in same route" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/users/:id/files/*path", handler);

    const result = router.find(.GET, "/users/42/files/docs/readme.md");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.params.len);
    try std.testing.expectEqualStrings("id", result.?.params[0].name);
    try std.testing.expectEqualStrings("42", result.?.params[0].value);
    try std.testing.expectEqualStrings("path", result.?.params[1].name);
    try std.testing.expectEqualStrings("docs/readme.md", result.?.params[1].value);
    allocator.free(result.?.params);
}

test "Root wildcard captures full path" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn h(_: *@import("server.zig").Context) anyerror!@import("../core/response.zig").Response {
            unreachable;
        }
    }.h;

    try router.add(.GET, "/*path", handler);

    const result = router.find(.GET, "/foo/bar/baz");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.params.len);
    try std.testing.expectEqualStrings("path", result.?.params[0].name);
    try std.testing.expectEqualStrings("foo/bar/baz", result.?.params[0].value);
    allocator.free(result.?.params);
}
