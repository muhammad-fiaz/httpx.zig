//! GraphQL over HTTP: schema mounting, request parsing, and execution.
//!
//! Transport rules implemented here:
//!
//! - `POST` with a JSON document media type (`application/json`,
//!   `application/graphql-response+json`, `application/graphql+json`,
//!   `application/vnd.api+json`, `problem+json`, etc.) — detected by
//!   `httpx.json.isJsonMediaType`.
//! - `POST` with `application/graphql` (the raw query body, GraphQL-over-HTTP
//!   legacy form).
//! - `POST` with `application/x-www-form-urlencoded` (`query`, `variables`,
//!   `operationName` fields).
//! - `GET` with URL-encoded `query`, `variables`, and `operationName` params.
//! - `OPTIONS` for CORS preflight.
//! - Anything else is `415 Unsupported Media Type`.
//!
//! JSON keys are never restricted to Zig identifiers: the payload is parsed as
//! `std.json.Value`, so `operationName`, `variables`, or any user-supplied key
//! arrives exactly as sent.

const std = @import("std");
const configCoerce = @import("../../common/configCoerce.zig");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const schemaMod = @import("graphQlSchema.zig");
const jsonMod = @import("../../common/json.zig");
const mediaTypeMod = @import("../../common/mediaType.zig");

pub const Schema = schemaMod.Schema;
pub const SchemaConfig = schemaMod.SchemaConfig;
pub const Scalar = schemaMod.Scalar;
pub const Type = schemaMod.Type;
pub const Query = schemaMod.Query;
pub const Mutation = schemaMod.Mutation;

/// GraphQL-over-HTTP request payload. Parsed dynamically from the document so
/// arbitrary JSON keys in `variables` are preserved exactly.
pub const HandlerConfig = struct {
    /// Route the endpoint is mounted on.
    endpoint: []const u8 = "/graphql",
    /// Maximum accepted request body.
    maxBodySize: usize = 2 * 1024 * 1024,
    /// Emit `Access-Control-Allow-Origin: *`.
    cors: bool = true,
    /// Allow queries over GET (`?query=…`).
    allowGet: bool = true,
    /// Response media type. `application/graphql-response+json` is the
    /// GraphQL-over-HTTP registration; the JSON default stays compatible with
    /// clients that only accept `application/json`.
    responseContentType: []const u8 = jsonMod.applicationJsonUtf8,
};

pub const ServerState = struct {
    /// Ownership borrowed from the mounter; `unmount` reuses it to release
    /// the state, so the same allocator that mounted it must still be alive.
    allocator: Allocator,
    io: std.Io,
    schema: Schema,
    cfg: HandlerConfig,
};

const corsHeaders = [_]routerMod.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
};

const preflightHeaders = [_]routerMod.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization, Accept" },
    .{ .name = "Access-Control-Max-Age", .value = "86400" },
};

fn getState(ctx: *Context) !*ServerState {
    return @ptrCast(@alignCast(ctx.userData orelse return error.SchemaNotMounted));
}

/// Mounts `schema` at `cfg.endpoint` (POST, GET, OPTIONS) atomically: if any
/// registration fails, the already-added routes are removed again.
///
/// The allocator and `std.Io` are explicit: they are the owner's, and are
/// carried in the mounted state so concurrent executions reuse exactly the
/// same resources instead of reaching for a process-wide default.
pub fn mount(
    allocator: Allocator,
    io: std.Io,
    router: *routerMod.Router,
    schema: Schema,
    cfg_in: anytype,
) !void {
    const cfg = configCoerce.to(HandlerConfig, cfg_in);
    if (router.hasConflict(.POST, cfg.endpoint) or
        router.hasConflict(.GET, cfg.endpoint) or
        router.hasConflict(.OPTIONS, cfg.endpoint))
    {
        return error.DuplicateRoute;
    }

    const state = try allocator.create(ServerState);
    state.* = .{ .allocator = allocator, .io = io, .schema = schema, .cfg = cfg };
    errdefer allocator.destroy(state);

    try router.add(.POST, cfg.endpoint, &handlePost, .{ .userData = state });
    errdefer _ = router.remove(.POST, cfg.endpoint);
    try router.add(.GET, cfg.endpoint, &handleGet, .{ .userData = state });
    errdefer _ = router.remove(.GET, cfg.endpoint);
    try router.add(.OPTIONS, cfg.endpoint, &handleOptions, .{ .userData = state });
}

/// Removes the GraphQL routes and frees the mounted state.
pub fn unmount(router: *routerMod.Router, cfg: HandlerConfig) void {
    var state: ?*ServerState = null;
    for (router.entries()) |entry| {
        if (entry.userData) |userData| {
            if (entry.handler == &handlePost or entry.handler == &handleGet or entry.handler == &handleOptions) {
                state = @ptrCast(@alignCast(userData));
                break;
            }
        }
    }
    _ = router.remove(.POST, cfg.endpoint);
    _ = router.remove(.GET, cfg.endpoint);
    _ = router.remove(.OPTIONS, cfg.endpoint);
    if (state) |mounted| mounted.allocator.destroy(mounted);
}

fn handleOptions(ctx: *Context) anyerror!Response {
    const st = try getState(ctx);
    return .{
        .status = 204,
        .body = "",
        .headers = if (st.cfg.cors) &preflightHeaders else &.{},
    };
}

fn handleGet(ctx: *Context) anyerror!Response {
    const st = try getState(ctx);
    if (!st.cfg.allowGet) {
        return .{ .status = 405, .contentType = st.cfg.responseContentType, .body = try errorsBody(ctx.allocator, "GraphQL GET requests are disabled") };
    }

    const queryString = if (ctx.query.len > 0)
        ctx.query
    else if (std.mem.indexOfScalar(u8, ctx.path, '?')) |idx|
        ctx.path[idx + 1 ..]
    else
        "";

    const query = try formValue(ctx.allocator, queryString, "query");
    const variables = try formValue(ctx.allocator, queryString, "variables");
    const operationName = try formValue(ctx.allocator, queryString, "operationName");

    if (query == null or query.?.len == 0) {
        return respondError(st, ctx, 400, "Missing 'query' parameter in GET request");
    }
    return execute(ctx, st, query.?, variables, operationName);
}

fn handlePost(ctx: *Context) anyerror!Response {
    const st = try getState(ctx);
    if (ctx.body.len == 0) return respondError(st, ctx, 400, "Empty GraphQL request body");
    if (ctx.body.len > st.cfg.maxBodySize) {
        return respondError(st, ctx, 413, "GraphQL request body exceeds size limit");
    }

    var typeBuf: [96]u8 = undefined;
    const contentType = ctx.header("Content-Type");
    const mediaType = if (contentType) |value| jsonMod.normalize(&typeBuf, value) else "";

    // An omitted Content-Type is tolerated for existing clients. A supplied
    // but malformed or unsupported value is rejected below with 415.
    if (contentType == null or jsonMod.isJsonMediaType(contentType.?)) {
        return executeJson(ctx, st);
    }
    if (std.mem.eql(u8, mediaType, "application/graphql")) {
        return execute(ctx, st, ctx.body, null, null);
    }
    if (std.mem.eql(u8, mediaType, mediaTypeMod.formUrlEncoded)) {
        const query = try formValue(ctx.allocator, ctx.body, "query");
        const variables = try formValue(ctx.allocator, ctx.body, "variables");
        const operationName = try formValue(ctx.allocator, ctx.body, "operationName");
        if (query == null or query.?.len == 0) {
            return respondError(st, ctx, 400, "Missing 'query' field in form-encoded request");
        }
        return execute(ctx, st, query.?, variables, operationName);
    }

    return respondError(
        st,
        ctx,
        415,
        "Unsupported Media Type: expected a JSON media type, application/graphql, or application/x-www-form-urlencoded",
    );
}

fn executeJson(ctx: *Context, st: *ServerState) anyerror!Response {
    const parsed = jsonMod.parse(ctx.allocator, ctx.body) catch {
        return respondError(st, ctx, 400, "Invalid JSON payload in GraphQL request body");
    };
    if (parsed != .object) {
        return respondError(st, ctx, 400, "GraphQL JSON payload must be an object");
    }

    const object = parsed.object;
    const query = jsonMod.getString(&object, "query") orelse
        return respondError(st, ctx, 400, "GraphQL request object is missing the 'query' field");
    if (query.len == 0) {
        return respondError(st, ctx, 400, "'query' must be a non-empty string");
    }

    var variablesJson: ?[]const u8 = null;
    if (object.get("variables")) |variables| {
        if (variables != .null) {
            variablesJson = std.json.Stringify.valueAlloc(ctx.allocator, variables, .{}) catch
                return respondError(st, ctx, 500, "Failed to serialize GraphQL variables");
        }
    }

    const operationName = jsonMod.getString(&object, "operationName");
    if (operationName) |name| {
        if (name.len == 0) {
            return respondError(st, ctx, 400, "'operationName' must be a non-empty string when present");
        }
    }

    return execute(ctx, st, query, variablesJson, operationName);
}

fn execute(
    ctx: *Context,
    st: *ServerState,
    query: []const u8,
    variablesJson: ?[]const u8,
    operationName: ?[]const u8,
) anyerror!Response {
    const result = st.schema.executeRequest(ctx.allocator, query, variablesJson, operationName, null) catch |err| {
        return respondError(st, ctx, 500, @errorName(err));
    };
    return .{
        .status = 200,
        .contentType = st.cfg.responseContentType,
        .body = result,
        .headers = if (st.cfg.cors) &corsHeaders else &.{},
    };
}

fn respondError(st: *ServerState, ctx: *Context, status: u16, message: []const u8) anyerror!Response {
    return .{
        .status = status,
        .contentType = st.cfg.responseContentType,
        .body = try errorsBody(ctx.allocator, message),
        .headers = if (st.cfg.cors) &corsHeaders else &.{},
    };
}

fn errorsBody(allocator: Allocator, message: []const u8) Allocator.Error![]u8 {
    const Error = struct { message: []const u8 };
    return std.json.Stringify.valueAlloc(allocator, .{ .errors = [_]Error{.{ .message = message }} }, .{});
}

/// Reads a `name=value` pair out of a query string or form body and returns
/// the percent-decoded value. JSON keys inside the value are preserved.
fn formValue(allocator: Allocator, encoded: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, encoded, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return try decodePercent(allocator, pair[eq + 1 ..]);
    }
    return null;
}

fn decodePercent(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (i + 2 >= raw.len) return error.InvalidPercentEncoding;
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidPercentEncoding;
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidPercentEncoding;
                try out.append(allocator, hi * 16 + lo);
                i += 2;
            },
            else => |c| try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "form values are percent-decoded and keys preserved" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const encoded = "query=%7B%20me%20%7B%20id%20%7D%20%7D&variables=%7B%22user-name%22%3A%22fiaz%22%7D";
    const query = (try formValue(arena.allocator(), encoded, "query")).?;
    try testing.expectEqualStrings("{ me { id } }", query);
    const variables = (try formValue(arena.allocator(), encoded, "variables")).?;
    try testing.expectEqualStrings("{\"user-name\":\"fiaz\"}", variables);
    try testing.expect(try formValue(arena.allocator(), encoded, "operationName") == null);
}

test "error bodies are valid GraphQL error envelopes" {
    const testing = std.testing;
    const body = try errorsBody(testing.allocator, "boom");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"errors\":[{\"message\":\"boom\"}]}", body);
}
