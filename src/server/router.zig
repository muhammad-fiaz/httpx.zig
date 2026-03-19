//! HTTP Router Implementation for httpx.zig
//!
//! Pattern-based routing with path parameter support:
//!
//! - Static path matching (/users, /api/posts)
//! - Dynamic parameters (/users/:id, /posts/:postId/comments/:commentId)
//! - Wildcard routes (/static/*)
//! - Route groups with prefixes
//! - Method-based routing

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
pub const RouteMatch = struct {
    handler: Handler,
    params: []const RouteParam,
};

/// Handler function type.
pub const Handler = *const fn (*@import("server.zig").Context) anyerror!@import("../core/response.zig").Response;

const Route = struct {
    method: types.Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
};

const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: void,
};

/// HTTP Router with path parameter support.
pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    not_found_handler: ?Handler = null,

    const Self = @This();

    /// Creates a new router.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Releases all allocated resources.
    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
    }

    /// Adds a route to the router.
    pub fn add(self: *Self, method: types.Method, pattern: []const u8, handler: Handler) !void {
        const segments = try self.parsePattern(pattern);
        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
        });
    }

    fn parsePattern(self: *Self, pattern: []const u8) ![]const Segment {
        var segments = std.ArrayListUnmanaged(Segment){};

        var iter = mem.splitScalar(u8, pattern, '/');
        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (part[0] == ':') {
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else if (mem.eql(u8, part, "*")) {
                try segments.append(self.allocator, .wildcard);
            } else {
                try segments.append(self.allocator, .{ .literal = part });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    /// Finds a matching route for the given method and path.
    pub fn find(self: *Self, method: types.Method, path: []const u8) ?struct { handler: Handler, params: []const RouteParam } {
        var params_buf: [16]RouteParam = undefined;

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchRoute(route, path, &params_buf)) |param_count| {
                return .{
                    .handler = route.handler,
                    .params = params_buf[0..param_count],
                };
            }
        }

        return null;
    }

    /// Returns the list of allowed methods for a given path.
    ///
    /// The method list is deduplicated and written into `out_methods`.
    /// The returned value is the number of methods written.
    pub fn allowedMethods(self: *const Self, path: []const u8, out_methods: *[16]types.Method) usize {
        var params_buf: [16]RouteParam = undefined;
        var count: usize = 0;

        for (self.routes.items) |route| {
            if (self.matchRoute(route, path, &params_buf) == null) continue;

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

    fn matchRoute(self: *const Self, route: Route, path: []const u8, params: *[16]RouteParam) ?usize {
        _ = self;
        var path_iter = mem.splitScalar(u8, path, '/');
        var param_idx: usize = 0;
        var seg_idx: usize = 0;

        while (path_iter.next()) |part| {
            if (part.len == 0) continue;

            if (seg_idx >= route.segments.len) return null;

            const segment = route.segments[seg_idx];
            switch (segment) {
                .literal => |lit| {
                    if (!mem.eql(u8, lit, part)) return null;
                },
                .param => |name| {
                    if (param_idx < params.len) {
                        params[param_idx] = .{ .name = name, .value = part };
                        param_idx += 1;
                    }
                },
                .wildcard => {
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
        var full_path = std.ArrayListUnmanaged(u8){};
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

    const result2 = router.find(.GET, "/users/123");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 1), result2.?.params.len);
    try std.testing.expectEqualStrings("id", result2.?.params[0].name);
    try std.testing.expectEqualStrings("123", result2.?.params[0].value);

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
}
