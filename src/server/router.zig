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
const dbg = @import("../util/debug.zig");

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

pub const Handler = @import("server.zig").Handler;

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
    routes: std.ArrayList(Route) = .empty,
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
            self.allocator.free(route.pattern);
        }
        self.routes.deinit(self.allocator);
    }

    /// Adds a route to the router.
    pub fn add(self: *Self, method: types.Method, pattern: []const u8, handler: Handler) !void {
        dbg.log("ROUTER", "register {s} {s}", .{ method.toString(), pattern });
        const dup_pattern = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(dup_pattern);

        const segments = try self.parsePattern(dup_pattern);
        errdefer self.allocator.free(segments);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = dup_pattern,
            .segments = segments,
            .handler = handler,
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
                dbg.log("ROUTER", "matched {s} {s}", .{ method.toString(), path });
                return .{
                    .handler = route.handler,
                    .params = params_buf[0..param_count],
                };
            }
        }

        dbg.log("ROUTER", "no match for {s} {s}", .{ method.toString(), path });
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

    try std.testing.expect(router.find(.GET, "/get") != null);
    try std.testing.expect(router.find(.POST, "/post") != null);
    try std.testing.expect(router.find(.PUT, "/put") != null);
    try std.testing.expect(router.find(.DELETE, "/del") != null);
    try std.testing.expect(router.find(.PATCH, "/patch") != null);
    try std.testing.expect(router.find(.HEAD, "/head") != null);
    try std.testing.expect(router.find(.OPTIONS, "/options") != null);
    try std.testing.expect(router.find(.TRACE, "/trace") != null);
    try std.testing.expect(router.find(.CONNECT, "/connect") != null);

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

    try std.testing.expect(router.find(.GET, "/api/users") != null);
    try std.testing.expect(router.find(.POST, "/api/users") != null);
    try std.testing.expect(router.find(.PUT, "/api/users/1") != null);
    try std.testing.expect(router.find(.DELETE, "/api/users/1") != null);
    try std.testing.expect(router.find(.PATCH, "/api/users/1") != null);
    try std.testing.expect(router.find(.HEAD, "/api/users/1") != null);
    try std.testing.expect(router.find(.OPTIONS, "/api/users/1") != null);
    try std.testing.expect(router.find(.TRACE, "/api/diag") != null);
    try std.testing.expect(router.find(.CONNECT, "/api/tunnel") != null);
}
