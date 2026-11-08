//! Typed REST endpoints with explicit metadata, JSON media-type handling, and
//! OpenAPI derivation.
//!
//! Every route is registered with an explicit `Method`, an explicit path, an
//! explicit handler, and explicit metadata. Nothing is inferred from a string
//! verb, and nothing is silently defaulted on the caller's behalf.
//!
//! Handlers return a typed `httpx.router.Result(T)`, a struct with `.status`
//! (default `200 OK`), `.body` (default `null`), `.headers`, and
//! `.mediaType`, so a handler is a plain struct literal with no
//! constructor:
//!
//! ```zig
//! const CreateUser = struct { name: []const u8, email: []const u8 };
//! const User = struct { id: u64, name: []const u8, email: []const u8 };
//!
//! fn createUser(ctx: *httpx.router.Context, req: CreateUser) !httpx.router.Result(User) {
//!     _ = ctx;
//!     return .{ .status = .created, .body = .{ .id = 1, .name = req.name, .email = req.email } };
//! }
//!
//! fn deleteUser(_: *httpx.router.Context) !httpx.router.Result(void) {
//!     return .{ .status = .noContent };
//! }
//!
//! try server.post("/users", .{
//!     .handler = createUser,
//!     .summary = "Create a new user",
//!     .tags = &.{"users"},
//! });
//! ```
//!
//! `.status` accepts any `Status` decl (`.ok`, `.created`, `.accepted`,
//! `.noContent`, `.notFound`, ...) or `httpx.Status.fromCode(422)` for
//! arbitrary codes.
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
//! JSON keys are arbitrary strings. Use Zig quoted identifiers so the decoder
//! and the OpenAPI document use the wire names directly:
//!
//! ```zig
//! const CreateUser = struct {
//!     @"user-name": []const u8,
//!     @"@context": []const u8,
//! };
//! const User = struct {
//!     id: u64,
//!     @"user-name": []const u8,
//! };
//!
//! try server.post("/users", .{
//!     .handler = createUser,
//!     .summary = "Create a new user",
//! });
//! ```
//!
//! Untyped JSON stays available too: use `std.json.Value` (or
//! `httpx.json.Object`) as the request/response type when the shape is not
//! known ahead of time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const Router = routerMod.Router;
const Method = @import("../../common/method.zig").Method;
const Status = @import("../../common/status.zig").Status;
const jsonMod = @import("../../common/json.zig");
const metaMod = @import("../router/routeMetadata.zig");

const MetaSchema = metaMod.Schema;
/// Parameter declaration, re-exported so `params` stays explicit and typed.
pub const Param = metaMod.Param;

/// OpenAPI schema node type, re-exported for custom `responses` declarations.
pub const JsonSchema = metaMod.Schema;

/// Response declaration, re-exported so `responses` stays explicit and typed.
pub const ResponseDesc = metaMod.ResponseDesc;
/// Request-body declaration, re-exported for `request` overrides.
pub const RequestBody = metaMod.RequestBody;

/// Addressable compile-time schema for `T`, for `Param.schema` and
/// `ResponseDesc.schema`:
///
/// ```zig
/// .params = &.{.{ .name = "id", .in = .path, .schema = httpx.rest.schemaOf(u64) }},
/// .responses = &.{.{ .status = 200, .description = "User", .schema = httpx.rest.schemaOf(User) }},
/// ```
pub fn schemaOf(comptime T: type) *const MetaSchema {
    return &struct {
        const s = typeSchema(T);
    }.s;
}

/// Field type of the `body` slot: `void` for bodiless results, `?T` otherwise.
fn BodyField(comptime T: type) type {
    return if (T == void) void else ?T;
}

/// Typed REST result for a response payload of type `T`.
///
/// A handler declares the return type and returns a plain struct
/// literal; there are no constructors to call:
///```zig
/// fn getUser(ctx: *httpx.router.Context) !httpx.router.Result(User) {
///     return .{ .body = user };                          // 200 OK
/// }
/// fn createUser(...) !httpx.router.Result(User) {
///     return .{ .status = .created, .body = user };      // 201 Created
/// }
/// fn deleteUser(...) !httpx.router.Result(void) {
///     return .{ .status = .noContent };                  // 204 No Content
/// }
/// fn reject(...) !httpx.router.Result(void) {
///     return .{ .status = httpx.Status.fromCode(422) };
/// }
/// ```
pub fn Result(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The payload type this result carries; `void` for empty responses.
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
    };
}

/// Converts a comptime array of parameter literals into typed `Param` values
/// stored in an immutable comptime array.
fn paramList(comptime items: anytype) []const metaMod.Param {
    const out = comptime blk: {
        var tmp: [items.len]metaMod.Param = undefined;
        for (items, 0..) |item, i| {
            for (@typeInfo(@TypeOf(item)).@"struct".field_names) |fname| {
                if (!@hasField(metaMod.Param, fname)) {
                    @compileError("unknown parameter option `." ++ fname ++ "`");
                }
            }
            tmp[i] = .{
                .name = item.name,
                .in = item.in,
                .required = if (@hasField(@TypeOf(item), "required")) item.required else false,
                .description = if (@hasField(@TypeOf(item), "description")) item.description else "",
                .schema = if (@hasField(@TypeOf(item), "schema")) item.schema else &metaMod.Param.defaultSchema,
            };
        }
        break :blk tmp;
    };
    return &out;
}

/// Converts a comptime array of response literals into typed `ResponseDesc`
/// values stored in an immutable comptime array.
fn responseList(comptime items: anytype) []const metaMod.ResponseDesc {
    const out = comptime blk: {
        var tmp: [items.len]metaMod.ResponseDesc = undefined;
        for (items, 0..) |item, i| {
            for (@typeInfo(@TypeOf(item)).@"struct".field_names) |fname| {
                if (!@hasField(metaMod.ResponseDesc, fname)) {
                    @compileError("unknown response option `." ++ fname ++ "`");
                }
            }
            tmp[i] = .{
                .status = item.status,
                .description = if (@hasField(@TypeOf(item), "description")) item.description else "",
                .schema = if (@hasField(@TypeOf(item), "schema")) item.schema else null,
            };
        }
        break :blk tmp;
    };
    return &out;
}

/// Coerces a request-body literal onto the typed descriptor.
fn requestDef(comptime value: anytype) metaMod.RequestBody {
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |fname| {
        if (comptime !@hasField(metaMod.RequestBody, fname)) {
            @compileError("unknown request option `." ++ fname ++ "`");
        }
    }
    return .{
        .content = value.content,
        .schema = if (@hasField(@TypeOf(value), "schema")) value.schema else null,
        .required = if (@hasField(@TypeOf(value), "required")) value.required else true,
        .description = if (@hasField(@TypeOf(value), "description")) value.description else "",
    };
}

const anyJsonSchema: MetaSchema = .{ .any = {} };

/// Compile-time OpenAPI schema for `T` using its exact Zig field names.
pub fn typeSchema(comptime T: type) MetaSchema {
    // Dynamic JSON is always free-form.
    if (comptime T == jsonMod.Value or T == jsonMod.Object) return .{ .any = {} };
    if (comptime T == jsonMod.Array) return .{ .array = &anyJsonSchema };
    const ti = @typeInfo(T);
    return switch (ti) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float, .comptime_float => .number,
        .@"enum" => .string,
        .optional => |opt| typeSchema(opt.child),
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) break :blk .string;
            if (ptr.child == u8) break :blk .string;
            const childSchema = comptime struct {
                const s = typeSchema(ptr.child);
            }.s;
            break :blk .{ .array = &childSchema };
        },
        .array => |arr| blk: {
            if (arr.child == u8) break :blk .string;
            const childSchema = comptime struct {
                const s = typeSchema(arr.child);
            }.s;
            break :blk .{ .array = &childSchema };
        },
        .@"struct" => |st| blk: {
            if (st.is_tuple) break :blk .string;
            const fields = comptime struct {
                const list = inner: {
                    var out: [st.field_names.len]MetaSchema.ObjectField = undefined;
                    for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, FType, fattrs, index| {
                        const optional = @typeInfo(FType) == .optional;
                        const fieldSchema = struct {
                            const s = typeSchema(FType);
                        }.s;
                        out[index] = .{
                            .name = fname,
                            .schema = &fieldSchema,
                            .required = !optional and fattrs.default_value_ptr == null,
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
    /// Declared parameters in every location: `.path`, `.query`, `.header`,
    /// `.cookie`. Use [`schemaOf`] for the schema pointer.
    params: []const metaMod.Param = &.{},
    /// Explicit response list. Empty derives one response from the handler's
    /// return type (`200`/`204`, or `201` for POST).
    responses: []const metaMod.ResponseDesc = &.{},
    /// Request-body descriptor override. Typed handlers decode JSON only, so
    /// `.content` must stay `.json`; `description` and `required` are free.
    request: ?metaMod.RequestBody = null,
    /// Excludes the route from the generated OpenAPI document.
    internal: bool = false,
    /// Response media type. JSON by default; set it for vendor JSON types.
    mediaType: []const u8 = jsonMod.applicationJsonUtf8,
};

/// Typed route controller over a router.
///
/// The controller borrows the allocator and `std.Io` of whoever owns the
/// router (`Server.rest()` passes its own). Eligibility is explicit: no
/// controller, route, or request ever reaches for a hidden process-wide
/// allocator or event loop. Per-request allocation still comes from
/// `ctx.allocator`, which is released with the request by the server.
pub const Rest = struct {
    allocator: Allocator,
    io: std.Io,
    router: *Router,

    pub fn init(allocator: Allocator, io: std.Io, router: *Router) Rest {
        return .{ .allocator = allocator, .io = io, .router = router };
    }

    /// Registers a typed route.
    ///
    /// `arg` is either a bare handler (`rest.get("/x", handler)`) or a struct
    /// literal carrying `.handler` plus any [`EndpointOptions`] field.
    ///
    /// ```zig
    /// try rest.add(.POST, "/users", .{
    ///     .handler = createUser,
    ///     .operationId = "createUser",
    ///     .summary = "Create a user",
    ///     .tags = &.{"users"},
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

        const Parsed = struct {
            endpoint: EndpointOptions = .{},
            route: routerMod.RouteOptions = .{},
        };
        const parsedOptions: Parsed = comptime blk: {
            var out: Parsed = .{};
            if (isBareFn) break :blk out;
            for (@typeInfo(ArgType).@"struct".field_names) |fname| {
                if (std.mem.eql(u8, fname, "handler")) continue;
                if (std.mem.eql(u8, fname, "path")) {
                    @compileError("REST: pass the route path as the second argument, not `.path`");
                }
                if (std.mem.eql(u8, fname, "meta")) {
                    @compileError("REST: metadata is derived from the handler; use `.operationId`, `.summary`, `.tags`, … instead of `.meta`");
                }
                if (std.mem.eql(u8, fname, "params")) {
                    out.endpoint.params = paramList(arg.params);
                } else if (std.mem.eql(u8, fname, "responses")) {
                    out.endpoint.responses = responseList(arg.responses);
                } else if (std.mem.eql(u8, fname, "request")) {
                    out.endpoint.request = requestDef(arg.request);
                } else if (@hasField(EndpointOptions, fname)) {
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
                @compileError("REST handler's first parameter must be *httpx.router.Context");
            }
        }

        const ReturnType = comptime fnInfo.return_type orelse @compileError("REST handler must return a value");
        const isRaw = comptime blk: {
            const retInfo = @typeInfo(ReturnType);
            if (retInfo != .error_union) break :blk false;
            break :blk retInfo.error_union.payload == Response;
        };

        if (comptime isRaw) {
            if (fnInfo.param_types.len != 1) {
                @compileError("REST raw handlers must accept only *httpx.router.Context; parse the body with ctx.jsonValue()");
            }
            const responses: []const metaMod.ResponseDesc = comptime if (endpointOpts.responses.len > 0)
                endpointOpts.responses
            else
                &[_]metaMod.ResponseDesc{.{ .status = 200, .description = "OK", .schema = null }};
            const meta: metaMod.Metadata = .{
                .operationId = endpointOpts.operationId,
                .summary = endpointOpts.summary,
                .description = endpointOpts.description,
                .tags = endpointOpts.tags,
                .deprecated = endpointOpts.deprecated,
                .security = endpointOpts.security,
                .params = endpointOpts.params,
                .request = endpointOpts.request,
                .responses = responses,
                .internal = endpointOpts.internal,
            };
            const Wrapper = struct {
                fn handle(ctx: *Context) anyerror!Response {
                    return handlerFn(ctx);
                }
            };
            var routeOpts = parsedOptions.route;
            routeOpts.meta = meta;
            try self.router.add(method, path, Wrapper.handle, routeOpts);
            return;
        }

        const HandlerInfo = comptime blk: {
            const retInfo = @typeInfo(ReturnType);
            if (retInfo != .error_union) {
                @compileError("REST typed handlers must return !httpx.router.Result(T)");
            }
            const payload = retInfo.error_union.payload;
            if (@typeInfo(payload) != .@"struct" or !@hasDecl(payload, "ResponseBody") or !@hasField(payload, "body")) {
                @compileError("REST handler must return httpx.router.Result(T)");
            }
            break :blk .{ .schema = payload, .body = payload.ResponseBody };
        };
        const OutSchema = HandlerInfo.schema;
        const OutType = HandlerInfo.body;

        const hasReqBody = comptime fnInfo.param_types.len == 2;
        const InType = comptime if (hasReqBody) (fnInfo.param_types[1] orelse void) else void;

        const responses: []const metaMod.ResponseDesc = comptime blk: {
            if (endpointOpts.responses.len > 0) break :blk endpointOpts.responses;
            if (OutType == void) {
                const list = [_]metaMod.ResponseDesc{
                    .{
                        .status = if (method == .DELETE) 204 else 200,
                        .description = if (method == .DELETE) "No Content" else "OK",
                        .schema = null,
                    },
                };
                break :blk &list;
            }
            const payloadSchema = struct {
                const s = typeSchema(OutType);
            }.s;
            const list = [_]metaMod.ResponseDesc{
                .{
                    .status = if (method == .POST) 201 else 200,
                    .description = if (method == .POST) "Created" else "OK",
                    .schema = &payloadSchema,
                },
            };
            break :blk &list;
        };

        const requestDesc: ?metaMod.RequestBody = comptime blk: {
            if (endpointOpts.request) |declared| {
                if (!hasReqBody or InType == void) {
                    @compileError("REST `.request` requires a handler that accepts a request body");
                }
                if (declared.content != .json) {
                    @compileError("REST typed handlers decode JSON only; keep `.request.content = .json`");
                }
                break :blk declared;
            }
            if (!hasReqBody or InType == void) break :blk null;
            if (method == .GET or method == .HEAD or method == .DELETE) break :blk null;
            const bodySchema = struct {
                const s = typeSchema(InType);
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
            .params = endpointOpts.params,
            .request = requestDesc,
            .responses = responses,
            .internal = endpointOpts.internal,
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

                    const reqValue: InType = jsonMod.decode(InType, ctx.allocator, ctx.body) catch |err| {
                        return errorResponse(ctx, 400, @errorName(err));
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

test "typeSchema maps Zig types and uses exact field names" {
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

    // Quoted identifiers are ordinary field names: no mapping layer is needed.
    const Arbitrary = struct { @"user-name": []const u8, @"@context": []const u8 };
    const arbitrary = typeSchema(Arbitrary);
    try testing.expectEqualStrings("user-name", arbitrary.object[0].name);
    try testing.expectEqualStrings("@context", arbitrary.object[1].name);
}

test "endpoint options expose params, custom responses, request overrides, and internal routes" {
    const testing = std.testing;
    const a = testing.allocator;

    var router = Router.init(a, .{});
    defer router.deinit();
    var rest = Rest.init(a, std.Io.Threaded.global_single_threaded.io(), &router);

    const Item = struct { id: u64, name: []const u8 };
    const CreateItem = struct { name: []const u8 };

    const Handlers = struct {
        fn getItem(ctx: *Context) !Result(Item) {
            const id = ctx.paramUint("id") orelse 0;
            return .{ .body = .{ .id = id, .name = "item" } };
        }

        fn createItem(_: *Context, req: CreateItem) !Result(Item) {
            return .{ .status = .created, .body = .{ .id = 1, .name = req.name } };
        }

        fn ping(_: *Context) !Result(void) {
            return .{ .status = .noContent };
        }
    };

    try rest.add(.GET, "/items/{id:int}", .{
        .handler = Handlers.getItem,
        .operationId = "getItem",
        .params = &.{
            .{ .name = "id", .in = .path, .required = true, .schema = schemaOf(u64) },
            .{ .name = "expand", .in = .query, .schema = schemaOf(bool) },
            .{ .name = "X-Trace", .in = .header, .schema = schemaOf([]const u8) },
        },
        .responses = &.{
            .{ .status = 200, .description = "Item", .schema = schemaOf(Item) },
            .{ .status = 404, .description = "Not found" },
        },
    });
    try rest.add(.POST, "/items", .{
        .handler = Handlers.createItem,
        .operationId = "createItem",
        .request = .{ .content = .json, .description = "Item to create", .required = true },
        .responses = &.{
            .{ .status = 201, .description = "Created", .schema = schemaOf(Item) },
            .{ .status = 422, .description = "Invalid item" },
        },
    });
    try rest.add(.GET, "/internal/health", .{
        .handler = Handlers.ping,
        .internal = true,
    });

    const openapi = @import("../openApi/openApiSpec.zig");
    const spec = try openapi.generate(&router, .{ .title = "Options", .version = "1.0.0" });
    defer a.free(spec);

    try testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"path\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"query\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"header\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"404\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "\"422\"") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "Item to create") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "/internal/health") == null);
}

test "typed REST endpoint: JSON body, Result, OpenAPI, quoted identifiers" {
    const testing = std.testing;
    const a = testing.allocator;

    var router = Router.init(a, .{});
    defer router.deinit();
    var rest = Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

    const CreateUserReq = struct { @"full-name": []const u8, email: []const u8 };
    const UserRes = struct { id: u64, @"full-name": []const u8, email: []const u8 };

    const Handlers = struct {
        fn createUser(ctx: *Context, req: CreateUserReq) !Result(UserRes) {
            _ = ctx;
            return .{
                .status = .created,
                .body = .{ .id = 42, .@"full-name" = req.@"full-name", .email = req.email },
            };
        }

        fn getUser(ctx: *Context) !Result(UserRes) {
            _ = ctx;
            return .{ .body = .{ .id = 42, .@"full-name" = "Test User", .email = "test@example.com" } };
        }

        fn deleteUser(ctx: *Context) !Result(void) {
            _ = ctx;
            return .{ .status = .noContent };
        }
    };

    try rest.add(.POST, "/users", .{
        .handler = Handlers.createUser,
        .operationId = "createUser",
        .summary = "Create user record",
        .tags = &.{"users"},
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

    // A vendor JSON media type is accepted; quoted field names are the wire keys.
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
    var router = Router.init(testing.allocator, .{});
    defer router.deinit();
    var rest = Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

    const Handlers = struct {
        fn echo(ctx: *Context, req: std.json.Value) !Result(std.json.Value) {
            _ = ctx;
            // Keys are read exactly as received; no Zig identifier is required.
            _ = req.object.get("user-name") orelse return .{ .body = req };
            return .{ .body = req };
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

test "raw REST handlers return untyped responses" {
    const testing = std.testing;
    var router = Router.init(testing.allocator, .{});
    defer router.deinit();
    var rest = Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

    const Handlers = struct {
        fn echo(ctx: *Context) !Response {
            const value = ctx.jsonValue() catch return ctx.textStatus(400, "bad json");
            return ctx.jsonStatus(200, value);
        }
    };
    try rest.post("/raw", .{ .handler = Handlers.echo, .summary = "Raw echo" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Context{
        .allocator = arena.allocator(),
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"user-name\":\"Fiaz\",\"@context\":\"https://schema.org\"}",
        .path = "/raw",
        .method = .POST,
    };
    const resp = router.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"user-name\":\"Fiaz\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"@context\":\"https://schema.org\"") != null);
}

test "dynamic JSON request and response types derive a free-form OpenAPI schema" {
    const testing = std.testing;
    var router = Router.init(testing.allocator, .{});
    defer router.deinit();
    var rest = Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

    const Handlers = struct {
        fn echo(_: *Context, req: std.json.Value) !Result(std.json.Value) {
            return .{ .body = req };
        }
    };
    try rest.post("/dynamic-openapi", .{ .handler = Handlers.echo });

    try testing.expect(typeSchema(std.json.Value) == .any);
    try testing.expect(typeSchema(jsonMod.Object) == .any);
    try testing.expect(typeSchema(jsonMod.Array) == .array);
    try testing.expect(typeSchema([]const std.json.Value).array.* == .any);

    const openapi = @import("../openApi/openApiSpec.zig");
    const spec = try openapi.generate(&router, .{ .title = "Dynamic", .version = "1.0.0" });
    defer testing.allocator.free(spec);
    // Both the request and response schemas are the empty (any) schema.
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, spec, index, "\"schema\":{}")) |found| : (index = found + 1) count += 1;
    try testing.expect(count >= 2);
}

test "malformed JSON bodies produce a 400 JSON error envelope" {
    const testing = std.testing;
    var router = Router.init(testing.allocator, .{});
    defer router.deinit();
    var rest = Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

    const OkBody = struct { ok: bool };
    const Handlers = struct {
        fn create(ctx: *Context, req: struct { name: []const u8 }) !Result(OkBody) {
            _ = ctx;
            _ = req;
            return .{ .status = .created, .body = .{ .ok = true } };
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
