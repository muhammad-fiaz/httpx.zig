//! Typed REST endpoints with explicit metadata, JSON media-type handling, and
//! OpenAPI derivation.
//!
//! Every route is registered with an explicit `Method`, an explicit path, an
//! explicit handler, and explicit metadata. Nothing is inferred from a string
//! verb, and nothing is silently defaulted on the caller's behalf.
//!
//! Handlers return a typed result built from [`Schema`]:
//!
//! ```zig
//! const CreateUser = struct { name: []const u8, email: []const u8 };
//! const User = struct { id: u64, name: []const u8, email: []const u8 };
//!
//! fn createUser(ctx: *httpx.Context, req: CreateUser) !httpx.Schema(User) {
//!     _ = ctx;
//!     return httpx.Schema(User).result(.{
//!         .status = .created,
//!         .body = .{ .id = 1, .name = req.name, .email = req.email },
//!     });
//! }
//!
//! try app.post("/users", .{
//!     .handler = createUser,
//!     .summary = "Create a new user",
//!     .tags = &.{"users"},
//! });
//! ```
//!
//! ## JSON on the wire
//!
//! * JSON document types are accepted on input: `application/json`, `text/json`,
//!   `application/x-json`, and every
//!   `+json` structured-syntax type (`problem+json`, `merge-patch+json`,
//!   `json-patch+json`, `vnd.api+json`, `hal+json`, `ld+json`, `geo+json`, etc.
//!   JSON5, NDJSON, and JSON text sequences are classified separately and are
//!   not accepted by this single-document typed-body parser.
//!   A non-JSON `Content-Type` is rejected with `415`.
//! * Responses are emitted with the endpoint's `mediaType` (JSON by default).
//! * A malformed body is `400` with a JSON error envelope, never a panic.
//!
//! ## Keys that are not Zig identifiers
//!
//! JSON keys are arbitrary strings. Pass a rename map and both the decoder and
//! the OpenAPI document use the wire names:
//!
//! ```zig
//! const names = .{ .user_name = "user-name", .context = "@context" };
//!
//! try app.post("/users", .{
//!     .handler = createUser,
//!     .names = names,
//! });
//! ```
//!
//! Untyped JSON stays available too: use `std.json.Value` (or
//! `httpx.json.Object`) as the request/response type when the shape is not
//! known ahead of time.

const std = @import("std");
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const Router = routerMod.Router;
const Method = @import("../../common/method.zig").Method;
const Status = @import("../../common/status.zig").Status;
const jsonMod = @import("../../common/json.zig");
const metaMod = @import("../router/routeMetadata.zig");

const MetaSchema = metaMod.Schema;
const Param = metaMod.Param;
const Location = metaMod.Location;

/// OpenAPI schema node type, re-exported for custom `responses` declarations.
pub const JsonSchema = metaMod.Schema;

/// Field type of the `body` slot: `void` for bodiless results, `?T` otherwise.
fn BodyField(comptime T: type) type {
    return if (T == void) void else ?T;
}

/// Typed REST result for a response payload of type `T`.
///
/// ```zig
/// return httpx.Schema(User).result(.{ .status = .ok, .body = user });
/// return httpx.Schema(User).created(user);
/// return httpx.Schema(void).noContent();
/// ```
pub fn Schema(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The payload type this schema carries; `void` for empty responses.
        pub const ResponseBody = T;

        /// Response status. `.ok` is the explicit default for a result that
        /// does not state one.
        status: Status = .ok,
        /// Optional payload. `null` means "no body".
        body: BodyField(T) = if (T == void) {} else null,
        /// Extra response headers, borrowed for the duration of the request.
        headers: []const routerMod.Header = &.{},
        /// Response media type override; `null` keeps the endpoint default.
        mediaType: ?[]const u8 = null,

        /// Builds a result from a struct literal. Every field is optional:
        ///
        /// ```zig
        /// .result(.{ .status = .created, .body = user })
        /// .result(.{ .status = Status.fromCode(422), .body = problem })
        /// ```
        pub fn result(spec: anytype) Self {
            var out: Self = .{};
            if (@typeInfo(@TypeOf(spec)) == .@"struct") {
                inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |fname| {
                    if (!@hasField(Self, fname)) continue;
                    const value = @field(spec, fname);
                    if (comptime std.mem.eql(u8, fname, "status")) {
                        out.status = statusValue(value);
                    } else {
                        @field(out, fname) = coerceTo(@FieldType(Self, fname), value);
                    }
                }
            }
            return out;
        }

        pub fn ok(body: T) Self {
            return .{ .status = .ok, .body = body };
        }

        pub fn created(body: T) Self {
            return .{ .status = .created, .body = body };
        }

        pub fn accepted(body: T) Self {
            return .{ .status = .accepted, .body = body };
        }

        /// `204 No Content` — the payload is omitted even when `T` is not `void`.
        pub fn noContent() Self {
            return .{ .status = .noContent };
        }

        /// Explicit status with an optional payload.
        pub fn of(status: Status, body: ?T) Self {
            return .{ .status = status, .body = body };
        }
    };
}

/// Convenience alias for handlers that never return a payload.
pub const Empty = Schema(void);

/// Accepts a `Status`, or a status decl literal such as `.created`.
fn statusValue(value: anytype) Status {
    if (@TypeOf(value) == Status) return value;
    return statusByName(comptime @tagName(value));
}

fn statusByName(comptime name: []const u8) Status {
    if (@hasDecl(Status, name)) return @field(Status, name);
    @compileError("unknown status `." ++ name ++ "` in Schema.result");
}

/// Coerces `value` to `Dest`. An anonymous struct literal (`.{ .id = 1 }`) only
/// coerces at its literal site, so the payload is rebuilt field by field here
/// before it is stored in a `Schema(T)` result.
fn coerceTo(comptime Dest: type, value: anytype) Dest {
    const Src = @TypeOf(value);
    if (Src == Dest) return value;
    if (@typeInfo(Src) == .null) return null;
    if (@typeInfo(Dest) == .optional) return coerceTo(@typeInfo(Dest).optional.child, value);
    if (@typeInfo(Src) == .@"struct" and @typeInfo(Dest) == .@"struct") {
        if (@typeInfo(Src).@"struct".is_tuple or @typeInfo(Dest).@"struct".is_tuple) return value;
        var out: Dest = undefined;
        inline for (@typeInfo(Dest).@"struct".field_names) |fname| {
            @field(out, fname) = coerceTo(@FieldType(Dest, fname), @field(value, fname));
        }
        return out;
    }
    return value;
}

/// Compile-time OpenAPI schema for `T` using Zig field names.
pub fn typeSchema(comptime T: type) MetaSchema {
    return typeSchemaNamed(T, .{});
}

/// Compile-time OpenAPI schema for `T`, mapping field names through `names`.
pub fn typeSchemaNamed(comptime T: type, comptime names: anytype) MetaSchema {
    const ti = @typeInfo(T);
    return switch (ti) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float, .comptime_float => .number,
        .@"enum" => .string,
        .optional => |opt| typeSchemaNamed(opt.child, names),
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) break :blk .string;
            if (ptr.child == u8) break :blk .string;
            const childSchema = comptime struct {
                const s = typeSchemaNamed(ptr.child, names);
            }.s;
            break :blk .{ .array = &childSchema };
        },
        .array => |arr| blk: {
            if (arr.child == u8) break :blk .string;
            const childSchema = comptime struct {
                const s = typeSchemaNamed(arr.child, names);
            }.s;
            break :blk .{ .array = &childSchema };
        },
        .@"struct" => |st| blk: {
            if (st.is_tuple) break :blk .string;
            const fields = comptime struct {
                const list = inner: {
                    var out: [st.field_names.len]MetaSchema.ObjectField = undefined;
                    for (st.field_names, st.field_types, 0..) |fname, FType, i| {
                        const optional = @typeInfo(FType) == .optional;
                        const fieldSchema = struct {
                            const s = typeSchemaNamed(FType, names);
                        }.s;
                        out[i] = .{
                            .name = jsonMod.keyFor(names, fname),
                            .schema = &fieldSchema,
                            .required = !optional,
                            .nullable = optional,
                        };
                    }
                    break :inner out;
                };
            }.list;
            break :blk .{ .object = &fields };
        },
        else => .string,
    };
}

/// Metadata for a single typed endpoint. All fields are optional; only what the
/// caller states is used.
pub const EndpointOptions = struct {
    operationId: ?[]const u8 = null,
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    deprecated: bool = false,
    security: []const metaMod.SecurityReq = &.{},
    /// Response media type. JSON by default; set it for vendor JSON types.
    mediaType: []const u8 = jsonMod.applicationJsonUtf8,
};

/// Typed route controller over a router.
pub const Rest = struct {
    router: *Router,

    pub fn init(router: *Router) Rest {
        return .{ .router = router };
    }

    /// Registers a typed route.
    ///
    /// `arg` is either a bare handler (`rest.get("/x", handler)`) or a struct
    /// literal carrying `.handler` plus any [`EndpointOptions`] field and an
    /// optional `.names` rename map.
    ///
    /// ```zig
    /// try rest.add(.POST, "/users", .{
    ///     .handler = createUser,
    ///     .operationId = "createUser",
    ///     .summary = "Create a user",
    ///     .tags = &.{"users"},
    ///     .names = .{ .user_name = "user-name" },
    /// });
    /// ```
    pub fn add(
        self: *Rest,
        comptime method: Method,
        path: []const u8,
        comptime arg: anytype,
    ) !void {
        const ArgType = @TypeOf(arg);
        const argInfo = @typeInfo(ArgType);
        const isBareFn = argInfo == .@"fn" or (argInfo == .pointer and @typeInfo(argInfo.pointer.child) == .@"fn");
        const isOptions = argInfo == .@"struct" and @hasField(ArgType, "handler");
        if (!isBareFn and !isOptions) {
            @compileError("REST: expected a handler function or a struct literal with a `.handler` field");
        }

        const handlerFn = if (isBareFn) arg else arg.handler;
        const namesGiven = comptime isOptions and @hasField(ArgType, "names");
        const names = comptime if (namesGiven) arg.names else .{};

        const Parsed = struct {
            endpoint: EndpointOptions = .{},
            route: routerMod.RouteOptions = .{},
        };
        const parsedOptions: Parsed = comptime blk: {
            var out: Parsed = .{};
            if (isBareFn) break :blk out;
            for (@typeInfo(ArgType).@"struct".field_names) |fname| {
                if (std.mem.eql(u8, fname, "handler") or std.mem.eql(u8, fname, "names")) continue;
                if (std.mem.eql(u8, fname, "path")) {
                    @compileError("REST: pass the route path as the second argument, not `.path`");
                }
                if (std.mem.eql(u8, fname, "meta")) {
                    @compileError("REST: metadata is derived from the handler; use `.operationId`, `.summary`, `.tags`, … instead of `.meta`");
                }
                if (@hasField(EndpointOptions, fname)) {
                    @field(out.endpoint, fname) = @field(arg, fname);
                } else if (@hasField(routerMod.RouteOptions, fname)) {
                    @field(out.route, fname) = @field(arg, fname);
                } else {
                    @compileError("unknown REST route option `." ++ fname ++ "`");
                }
            }
            break :blk out;
        };
        const endpointOpts = parsedOptions.endpoint;

        const fnInfo = @typeInfo(@TypeOf(handlerFn)).@"fn";
        comptime {
            if (fnInfo.param_types.len < 1 or fnInfo.param_types.len > 2) {
                @compileError("REST handler must accept either (*Context) or (*Context, ReqStruct)");
            }
            const first = fnInfo.param_types[0] orelse @compileError("REST handler params cannot be generic");
            if (first != *Context) {
                @compileError("REST handler's first parameter must be *httpx.Context");
            }
        }

        const HandlerInfo = comptime blk: {
            const returnType = fnInfo.return_type orelse @compileError("REST handler must return a value");
            const retInfo = @typeInfo(returnType);
            if (retInfo != .error_union) {
                @compileError("REST handler must return !httpx.Schema(T)");
            }
            const payload = retInfo.error_union.payload;
            if (@typeInfo(payload) != .@"struct" or !@hasDecl(payload, "ResponseBody") or !@hasField(payload, "body")) {
                @compileError("REST handler must return httpx.Schema(T)");
            }
            break :blk .{ .schema = payload, .body = payload.ResponseBody };
        };
        const OutSchema = HandlerInfo.schema;
        const OutType = HandlerInfo.body;

        const hasReqBody = comptime fnInfo.param_types.len == 2;
        const InType = comptime if (hasReqBody) (fnInfo.param_types[1] orelse void) else void;

        const responses = comptime blk: {
            if (OutType == void) {
                const list = [_]metaMod.ResponseDesc{
                    .{
                        .status = if (method == .DELETE) 204 else 200,
                        .description = if (method == .DELETE) "No Content" else "OK",
                        .schema = null,
                    },
                };
                break :blk list;
            }
            const payloadSchema = struct {
                const s = typeSchemaNamed(OutType, names);
            }.s;
            const list = [_]metaMod.ResponseDesc{
                .{
                    .status = if (method == .POST) 201 else 200,
                    .description = if (method == .POST) "Created" else "OK",
                    .schema = &payloadSchema,
                },
            };
            break :blk list;
        };

        const requestDesc: ?metaMod.RequestBody = comptime blk: {
            if (!hasReqBody or InType == void) break :blk null;
            if (method == .GET or method == .HEAD or method == .DELETE) break :blk null;
            const bodySchema = struct {
                const s = typeSchemaNamed(InType, names);
            }.s;
            break :blk .{
                .content = .json,
                .schema = &bodySchema,
                .required = true,
                .description = "JSON request body",
            };
        };

        const meta: metaMod.Metadata = .{
            .operationId = endpointOpts.operationId,
            .summary = endpointOpts.summary,
            .description = endpointOpts.description,
            .tags = endpointOpts.tags,
            .deprecated = endpointOpts.deprecated,
            .security = endpointOpts.security,
            .request = requestDesc,
            .responses = &responses,
        };

        const Wrapper = struct {
            fn handle(ctx: *Context) anyerror!Response {
                const mediaType = comptime endpointOpts.mediaType;

                const apiRes: OutSchema = if (comptime hasReqBody) blk: {
                    // Only JSON media types carry a typed body. A Content-Type
                    // that is present but not JSON is 415, never a silent miss.
                    if (ctx.header("Content-Type")) |ct| {
                        if (!jsonMod.isJsonMediaType(ct)) {
                            return errorResponse(ctx, 415, "Unsupported Media Type: expected a JSON media type such as application/json or application/*+json");
                        }
                    }

                    if (ctx.body.len == 0) {
                        if (comptime @typeInfo(InType) == .@"struct") {
                            const fromParams = ctx.bindParams(InType) catch {
                                return errorResponse(ctx, 400, "Missing JSON request body");
                            };
                            break :blk try handlerFn(ctx, fromParams);
                        }
                        return errorResponse(ctx, 400, "Missing JSON request body");
                    }

                    const reqValue: InType = if (comptime namesGiven) blkReq: {
                        break :blkReq jsonMod.decodeNamed(InType, ctx.allocator, ctx.body, names) catch |err| {
                            return errorResponse(ctx, 400, @errorName(err));
                        };
                    } else blkReq: {
                        const parsed = std.json.parseFromSlice(InType, ctx.allocator, ctx.body, .{ .ignore_unknown_fields = true }) catch |err| {
                            return errorResponse(ctx, 400, @errorName(err));
                        };
                        break :blkReq parsed.value;
                    };
                    break :blk try handlerFn(ctx, reqValue);
                } else try handlerFn(ctx);

                const statusCode: u16 = apiRes.status.code;
                const responseType = apiRes.mediaType orelse mediaType;

                if (comptime OutType == void) {
                    return .{
                        .status = statusCode,
                        .headers = apiRes.headers,
                        .body = "",
                        .contentType = responseType,
                    };
                }

                if (apiRes.body) |payload| {
                    if (comptime namesGiven) {
                        const encoded = jsonMod.encodeNamed(ctx.allocator, payload, names) catch |err| {
                            return errorResponse(ctx, 500, @errorName(err));
                        };
                        return .{
                            .status = statusCode,
                            .headers = apiRes.headers,
                            .body = encoded,
                            .contentType = responseType,
                        };
                    }
                    var response = try ctx.jsonStatus(statusCode, payload);
                    response.contentType = responseType;
                    if (apiRes.headers.len > 0) response.headers = apiRes.headers;
                    return response;
                }

                return .{
                    .status = statusCode,
                    .headers = apiRes.headers,
                    .body = "",
                    .contentType = responseType,
                };
            }
        };

        var routeOpts = parsedOptions.route;
        routeOpts.meta = meta;
        try self.router.add(method, path, Wrapper.handle, routeOpts);
    }

    /// Typed GET route.
    pub fn get(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.GET, path, arg);
    }

    /// Typed POST route.
    pub fn post(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.POST, path, arg);
    }

    /// Typed PUT route.
    pub fn put(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.PUT, path, arg);
    }

    /// Typed PATCH route.
    pub fn patch(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.PATCH, path, arg);
    }

    /// Typed DELETE route.
    pub fn delete(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.DELETE, path, arg);
    }

    /// Typed HEAD route.
    pub fn head(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.HEAD, path, arg);
    }

    /// Typed OPTIONS route.
    pub fn options(self: *Rest, path: []const u8, comptime arg: anytype) !void {
        try self.add(.OPTIONS, path, arg);
    }
};

/// JSON error envelope used for every rejected request.
fn errorResponse(ctx: *Context, status: u16, message: []const u8) Response {
    const Envelope = struct { @"error": []const u8, status: u16 };
    const body = std.json.Stringify.valueAlloc(ctx.allocator, Envelope{ .@"error" = message, .status = status }, .{}) catch
        "{\"error\":\"internal error\"}";
    return .{
        .status = status,
        .contentType = jsonMod.applicationJsonUtf8,
        .body = body,
    };
}

test "typeSchema maps Zig types and honours explicit key names" {
    const testing = std.testing;
    const Example = struct {
        id: u64,
        name: []const u8,
        active: bool,
        tags: []const []const u8,
        bio: ?[]const u8,
    };

    const plain = typeSchema(Example);
    try testing.expect(plain == .object);
    try testing.expectEqual(@as(usize, 5), plain.object.len);
    try testing.expectEqualStrings("id", plain.object[0].name);
    try testing.expect(plain.object[0].schema.* == .integer);
    try testing.expect(plain.object[0].required);
    try testing.expectEqualStrings("bio", plain.object[4].name);
    try testing.expect(!plain.object[4].required);

    const renamed = typeSchemaNamed(struct { user_name: []const u8 }, .{ .user_name = "user-name" });
    try testing.expectEqualStrings("user-name", renamed.object[0].name);
}

test "typed REST endpoint: JSON body, Schema result, OpenAPI, key mapping" {
    const testing = std.testing;
    const a = testing.allocator;

    var router = Router.init(a);
    defer router.deinit();
    var rest = Rest.init(&router);

    const CreateUserReq = struct { name: []const u8, email: []const u8 };
    const UserRes = struct { id: u64, name: []const u8, email: []const u8 };

    const Handlers = struct {
        fn createUser(ctx: *Context, req: CreateUserReq) !Schema(UserRes) {
            _ = ctx;
            return Schema(UserRes).result(.{
                .status = .created,
                .body = .{ .id = 42, .name = req.name, .email = req.email },
            });
        }

        fn getUser(ctx: *Context) !Schema(UserRes) {
            _ = ctx;
            return Schema(UserRes).ok(.{ .id = 42, .name = "Test User", .email = "test@example.com" });
        }

        fn deleteUser(ctx: *Context) !Schema(void) {
            _ = ctx;
            return Schema(void).noContent();
        }
    };

    try rest.add(.POST, "/users", .{
        .handler = Handlers.createUser,
        .operationId = "createUser",
        .summary = "Create user record",
        .tags = &.{"users"},
        .names = .{ .name = "full-name" },
    });
    try rest.add(.GET, "/users/{id:int}", .{
        .handler = Handlers.getUser,
        .operationId = "getUser",
    });
    try rest.add(.DELETE, "/users/{id:int}", .{
        .handler = Handlers.deleteUser,
        .operationId = "deleteUser",
    });

    try testing.expectEqual(@as(usize, 3), router.entries().len);

    // OpenAPI reflects the renamed wire key, not the Zig field name.
    const openapi = @import("../openApi/openApiSpec.zig");
    const spec = try openapi.generate(&router, .{ .title = "REST Test API", .version = "1.0.0" });
    defer a.free(spec);
    try testing.expect(std.mem.indexOf(u8, spec, "\"operationId\":\"createUser\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "full-name") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"201\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"204\"") != null);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Non-JSON content type is refused.
    const badType = "text/plain";
    const headers = [_]routerMod.Header{.{ .name = "Content-Type", .value = badType }};
    var ctxBad = Context{
        .allocator = arena.allocator(),
        .headers = &headers,
        .body = "{\"full-name\":\"x\",\"email\":\"x@example.com\"}",
        .path = "/users",
        .method = .POST,
    };
    const unsupported = router.dispatch(&ctxBad);
    try testing.expectEqual(@as(u16, 415), unsupported.status);

    // A vendor JSON media type is accepted, and the rename map is honoured.
    var ctx = Context{
        .allocator = arena.allocator(),
        .headers = &.{.{ .name = "Content-Type", .value = "application/vnd.api+json; charset=utf-8" }},
        .body = "{\"full-name\":\"Muhammad\",\"email\":\"m@example.com\"}",
        .path = "/users",
        .method = .POST,
    };
    const resp = router.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 201), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":42") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"full-name\":\"Muhammad\"") != null);

    // DELETE returns 204 with an empty body.
    var ctxDelete = Context{
        .allocator = arena.allocator(),
        .path = "/users/7",
        .method = .DELETE,
    };
    const deleted = router.dispatch(&ctxDelete);
    try testing.expectEqual(@as(u16, 204), deleted.status);
}

test "typed REST accepts dynamic JSON for arbitrary string keys" {
    const testing = std.testing;
    var router = Router.init(testing.allocator);
    defer router.deinit();
    var rest = Rest.init(&router);

    const Handlers = struct {
        fn echo(ctx: *Context, req: std.json.Value) !Schema(std.json.Value) {
            _ = ctx;
            // Keys are read exactly as received; no Zig identifier is required.
            _ = req.object.get("user-name") orelse return Schema(std.json.Value).ok(req);
            return Schema(std.json.Value).ok(req);
        }
    };
    try rest.post("/dynamic", .{ .handler = Handlers.echo });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Context{
        .allocator = arena.allocator(),
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body =
        \\{"user-name":"Fiaz","user_name":"Fiaz","user.name":"Fiaz","user name":"Fiaz",
        \\ "user@email":"fiaz@example.com","user/id":123,"123user":"Fiaz",
        \\ "@context":"https://schema.org","$schema":"https://example.com/schema",
        \\ "Content-Type":"application/json","X-API-Key":"secret","HTTP/2":true,
        \\ "snake_case":true,"camelCase":true,"PascalCase":true}
        ,
        .path = "/dynamic",
        .method = .POST,
    };
    const resp = router.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"user-name\":\"Fiaz\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"@context\":\"https://schema.org\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"user/id\":123") != null);
}

test "malformed JSON bodies produce a 400 JSON error envelope" {
    const testing = std.testing;
    var router = Router.init(testing.allocator);
    defer router.deinit();
    var rest = Rest.init(&router);

    const OkBody = struct { ok: bool };
    const Handlers = struct {
        fn create(ctx: *Context, req: struct { name: []const u8 }) !Schema(OkBody) {
            _ = ctx;
            _ = req;
            return Schema(OkBody).created(.{ .ok = true });
        }
    };
    try rest.post("/x", .{ .handler = Handlers.create });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Context{
        .allocator = arena.allocator(),
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{not json",
        .path = "/x",
        .method = .POST,
    };
    const resp = router.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\"") != null);
}
