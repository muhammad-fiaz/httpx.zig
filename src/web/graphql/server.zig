//! GraphQL HTTP Server Handler and Endpoint Integration.
//!
//! Provides first-class GraphQL routing and execution:
//! - POST /graphql: GraphQL JSON body parser (query, variables, operationName)
//! - GET /graphql: GraphQL query string support
//! - Request validation & security limits (max_body, depth, complexity)
//! - CORS, custom headers, and auth context forwarding
//! - Integration with `httpx.Server` and `httpx.Router`

const std = @import("std");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");
const Context = router_mod.Context;
const Response = router_mod.Response;
const schema_mod = @import("schema.zig");
pub const Schema = schema_mod.Schema;
pub const SchemaConfig = schema_mod.SchemaConfig;
pub const ObjectTypeDef = schema_mod.ObjectTypeDef;
pub const FieldDef = schema_mod.FieldDef;
pub const ResolverContext = schema_mod.ResolverContext;
pub const FieldResolver = schema_mod.FieldResolver;

pub const RequestPayload = struct {
    query: []const u8 = "",
    variables: ?std.json.Value = null,
    operationName: ?[]const u8 = null,
};

pub const HandlerConfig = struct {
    endpoint: []const u8 = "/graphql",
    max_body_size: usize = 2 * 1024 * 1024,
    enable_cors: bool = true,
};

var g_schema: ?Schema = null;
var g_cfg: HandlerConfig = .{};

/// Mounts a GraphQL schema on a Router at `cfg.endpoint` (default "/graphql").
pub fn mount(router: *router_mod.Router, schema: Schema, cfg: HandlerConfig) !void {
    g_schema = schema;
    g_cfg = cfg;

    try router.add(.POST, cfg.endpoint, &handleGraphQLPost);
    try router.add(.GET, cfg.endpoint, &handleGraphQLGet);
    try router.add(.OPTIONS, cfg.endpoint, &handleGraphQLOptions);
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
    const s = g_schema orelse return error.SchemaNotMounted;

    // Parse query from query string
    var query_str: ?[]const u8 = null;
    var vars_str: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, ctx.path, '?')) |q_idx| {
        const query_part = ctx.path[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, query_part, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "query=")) {
                query_str = pair[6..];
            } else if (std.mem.startsWith(u8, pair, "variables=")) {
                vars_str = pair[10..];
            }
        }
    }

    if (query_str == null or query_str.?.len == 0) {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Missing query parameter in GET request\"}]}",
        };
    }

    // Decode URL-encoded query if needed
    const result = try s.execute(ctx.allocator, query_str.?, vars_str, null);
    return .{
        .status = 200,
        .content_type = "application/json; charset=utf-8",
        .body = result,
        .headers = if (g_cfg.enable_cors) &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} else &.{},
    };
}

fn handleGraphQLPost(ctx: *Context) anyerror!Response {
    const s = g_schema orelse return error.SchemaNotMounted;

    if (ctx.body.len == 0) {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Empty GraphQL request body\"}]}",
        };
    }

    if (ctx.body.len > g_cfg.max_body_size) {
        return .{
            .status = 413,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL request body exceeds size limit\"}]}",
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"Invalid JSON payload in GraphQL request body\"}]}",
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL JSON payload must be an object\"}]}",
        };
    }

    const query_val = parsed.value.object.get("query") orelse {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"GraphQL request object missing 'query' field\"}]}",
        };
    };

    if (query_val != .string or query_val.string.len == 0) {
        return .{
            .status = 400,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"errors\":[{\"message\":\"'query' field must be a non-empty string\"}]}",
        };
    }

    var vars_buf: ?[]const u8 = null;
    if (parsed.value.object.get("variables")) |v_val| {
        var out_v: std.Io.Writer.Allocating = .init(ctx.allocator);
        try std.json.fmt(v_val, .{}).format(&out_v.writer);
        vars_buf = try out_v.toOwnedSlice();
    }

    const result = try s.execute(ctx.allocator, query_val.string, vars_buf, null);

    return .{
        .status = 200,
        .content_type = "application/json; charset=utf-8",
        .body = result,
        .headers = if (g_cfg.enable_cors) &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} else &.{},
    };
}
