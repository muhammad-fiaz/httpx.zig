//! GraphQL HTTP Server Handler and Endpoint Integration.
//!
//! Provides first-class GraphQL routing and execution:
//! - POST /graphql: GraphQL JSON body parser (query, variables, operationName)
//! - GET /graphql: GraphQL query string support
//! - Request validation & security limits (maxBody, depth, complexity)
//! - CORS, custom headers, and auth context forwarding
//! - Integration with `httpx.server.Server` and `httpx.web.router.Router`

const std = @import("std");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const schemaMod = @import("graphQlSchema.zig");
pub const Schema = schemaMod.Schema;
pub const SchemaConfig = schemaMod.SchemaConfig;
pub const ObjectTypeDef = schemaMod.ObjectTypeDef;
pub const FieldDef = schemaMod.FieldDef;
pub const ResolverContext = schemaMod.ResolverContext;
pub const FieldResolver = schemaMod.FieldResolver;

pub const RequestPayload = struct {
    query: []const u8 = "",
    variables: ?std.json.Value = null,
    operationName: ?[]const u8 = null,
};

pub const HandlerConfig = struct {
    endpoint: []const u8 = "/graphql",
    maxBodySize: usize = 2 * 1024 * 1024,
    cors: bool = true,
};

pub const ServerState = struct {
    schema: Schema,
    cfg: HandlerConfig,
};

fn getState(ctx: *Context) !*ServerState {
    return @ptrCast(@alignCast(ctx.userData orelse return error.SchemaNotMounted));
}

/// Mounts a GraphQL schema on a Router at `cfg.endpoint` (default "/graphql").
/// Pre-checks all three methods atomically; on partial failure any routes
/// already added are removed and the allocated state is freed.
/// Caller must call `unmount` before router.deinit to free the state.
pub fn mount(router: *routerMod.Router, schema: Schema, cfg: HandlerConfig) !void {
    if (router.hasConflict(.POST, cfg.endpoint) or
        router.hasConflict(.GET, cfg.endpoint) or
        router.hasConflict(.OPTIONS, cfg.endpoint))
    {
        return error.DuplicateRoute;
    }
    const st = try router.allocator.create(ServerState);
    st.* = .{ .schema = schema, .cfg = cfg };
    errdefer router.allocator.destroy(st);

    router.add(.POST, cfg.endpoint, &handleGraphQLPost, .{ .userData = st }) catch |err| return err;
    errdefer _ = router.remove(.POST, cfg.endpoint);
    router.add(.GET, cfg.endpoint, &handleGraphQLGet, .{ .userData = st }) catch |err| return err;
    errdefer _ = router.remove(.GET, cfg.endpoint);
    try router.add(.OPTIONS, cfg.endpoint, &handleGraphQLOptions, .{ .userData = st });
}

/// Removes the GraphQL routes and frees the associated ServerState.
pub fn unmount(router: *routerMod.Router, cfg: HandlerConfig) void {
    var stateToFree: ?*ServerState = null;
    for (router.routes.items) |entry| {
        if (entry.userData) |ud| {
            if (entry.handler == &handleGraphQLPost or entry.handler == &handleGraphQLGet or entry.handler == &handleGraphQLOptions) {
                stateToFree = @ptrCast(@alignCast(ud));
                break;
            }
        }
    }
    _ = router.remove(.POST, cfg.endpoint);
    _ = router.remove(.GET, cfg.endpoint);
    _ = router.remove(.OPTIONS, cfg.endpoint);
    if (stateToFree) |st| {
        router.allocator.destroy(st);
    }
}

fn handleGraphQLOptions(ctx: *Context) anyerror!Response {
    _ = ctx;
    return .{
        .status = 204,
        .body = "",
        .headers = &.{
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
        },
    };
}

fn handleGraphQLGet(ctx: *Context) anyerror!Response {
    const st = try getState(ctx);
    const s = st.schema;

    // Parse query from query string
    var queryStr: ?[]const u8 = null;
    var varsStr: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, ctx.path, '?')) |qIdx| {
        const queryPart = ctx.path[qIdx + 1 ..];
        var it = std.mem.splitScalar(u8, queryPart, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "query=")) {
                queryStr = pair[6..];
            } else if (std.mem.startsWith(u8, pair, "variables=")) {
                varsStr = pair[10..];
            }
        }
    }

    if (queryStr == null or queryStr.?.len == 0) {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Missing query parameter in GET request\"}]}",
        };
    }

    // Decode URL-encoded query if needed
    const result = try s.execute(ctx.allocator, queryStr.?, varsStr, null);
    return .{
        .status = 200,
        .contentType = "application/json; charset=utf-8",
        .body = result,
        .headers = if (st.cfg.cors) &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} else &.{},
    };
}

fn handleGraphQLPost(ctx: *Context) anyerror!Response {
    const st = try getState(ctx);
    const s = st.schema;

    if (ctx.body.len == 0) {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Empty GraphQL request body\"}]}",
        };
    }

    if (ctx.body.len > st.cfg.maxBodySize) {
        return .{
            .status = 413,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL request body exceeds size limit\"}]}",
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Invalid JSON payload in GraphQL request body\"}]}",
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL JSON payload must be an object\"}]}",
        };
    }

    const queryVal = parsed.value.object.get("query") orelse {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL request object missing 'query' field\"}]}",
        };
    };

    if (queryVal != .string or queryVal.string.len == 0) {
        return .{
            .status = 400,
            .contentType = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"'query' field must be a non-empty string\"}]}",
        };
    }

    var varsBuf: ?[]const u8 = null;
    if (parsed.value.object.get("variables")) |vVal| {
        var outV: std.Io.Writer.Allocating = .init(ctx.allocator);
        try std.json.fmt(vVal, .{}).format(&outV.writer);
        varsBuf = try outV.toOwnedSlice();
    }

    const result = try s.execute(ctx.allocator, queryVal.string, varsBuf, null);

    return .{
        .status = 200,
        .contentType = "application/json; charset=utf-8",
        .body = result,
        .headers = if (st.cfg.cors) &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} else &.{},
    };
}
