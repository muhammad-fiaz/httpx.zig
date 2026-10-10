//! Zig-native REST framework with typed endpoint handlers and OpenAPI derivation.
//!
//! Handlers declare typed request/response structs, returning `ApiResult(OutStruct)`.
//! Path/query parameters and request body are automatically parsed, validated,
//! and documented for OpenAPI 3.1.
//!
//! Example:
//! ```zig
//! const CreateUser = struct { name: []const u8, email: []const u8 };
//! const User = struct { id: u64, name: []const u8, email: []const u8 };
//!
//! fn createUser(ctx: *httpx.Context, req: CreateUser) !httpx.ApiResult(User) {
//!     _ = ctx;
//!     return .{ .status = .created, .body = .{ .id = 1, .name = req.name, .email = req.email } };
//! }
//!
//! try app.rest.post("/users", createUser, .{ .summary = "Create user" });
//! ```

const std = @import("std");
const routerMod = @import("router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const Router = routerMod.Router;
const Method = @import("../common/method.zig").Method;
const Status = @import("../common/status.zig").Status;
const metaMod = @import("router/metadata.zig");
const Schema = metaMod.Schema;
const Param = metaMod.Param;
const Location = metaMod.Location;

/// Typed result envelope for REST endpoint handlers.
pub fn ApiResult(comptime T: type) type {
    return struct {
        status: Status = .ok,
        body: ?T = null,
        headers: []const routerMod.Header = &.{},

        pub fn ok(body: T) @This() {
            return .{ .status = .ok, .body = body };
        }

        pub fn created(body: T) @This() {
            return .{ .status = .created, .body = body };
        }

        pub fn noContent() @This() {
            return .{ .status = .noContent, .body = null };
        }
    };
}

/// Generic compile-time schema generator from Zig types.
pub fn typeSchema(comptime T: type) Schema {
    const ti = @typeInfo(T);
    switch (ti) {
        .bool => return .boolean,
        .int => return .integer,
        .float => return .number,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .string;
            } else if (ptr.size == .slice) {
                const childSchema = comptime struct {
                    const s = typeSchema(ptr.child);
                }.s;
                return .{ .array = &childSchema };
            }
            return .string;
        },
        .array => |arr| {
            if (arr.child == u8) {
                return .string;
            } else {
                const childSchema = comptime struct {
                    const s = typeSchema(arr.child);
                }.s;
                return .{ .array = &childSchema };
            }
        },
        .@"enum" => return .string,
        .optional => |opt| {
            return typeSchema(opt.child);
        },
        .@"struct" => |st| {
            // Check for tuple
            if (st.is_tuple) {
                return .string;
            }
            const fields = comptime blk: {
                var flist: [st.field_names.len]Schema.ObjectField = undefined;
                for (st.field_names, st.field_types, 0..) |fname, ftype, i| {
                    const isOpt = @typeInfo(ftype) == .optional;
                    const fieldSchema = struct {
                        const s = typeSchema(ftype);
                    }.s;
                    flist[i] = .{
                        .name = fname,
                        .schema = &fieldSchema,
                        .required = !isOpt,
                        .nullable = isOpt,
                    };
                }
                const res = flist;
                break :blk res;
            };
            const fieldsStatic = struct {
                const f = fields;
            }.f;
            return .{ .object = &fieldsStatic };
        },
        else => return .string,
    }
}

pub const EndpointOptions = struct {
    operationId: ?[]const u8 = null,
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    deprecated: bool = false,
    security: []const metaMod.SecurityReq = &.{},
};

/// RestController provides fluent typed route registration on a router.
pub const Rest = struct {
    router: *Router,

    pub fn init(router: *Router) Rest {
        return .{ .router = router };
    }

    /// Register a typed REST route.
    /// Handlers can accept:
    /// - `fn (*Context) !ApiResult(Out)` (no request body)
    /// - `fn (*Context, In) !ApiResult(Out)` (typed JSON or param request body)
    pub fn add(
        self: *Rest,
        comptime method: Method,
        path: []const u8,
        comptime handlerFn: anytype,
        opts: EndpointOptions,
    ) !void {
        const FnType = @TypeOf(handlerFn);
        const fnInfo = @typeInfo(FnType).@"fn";

        comptime {
            if (fnInfo.param_types.len < 1 or fnInfo.param_types.len > 2) {
                @compileError("REST handler must accept either (*Context) or (*Context, ReqStruct)");
            }
        }

        const OutType = comptime blk: {
            const retInfo = @typeInfo(fnInfo.return_type orelse @compileError("REST handler must return a result"));
            if (retInfo != .error_union) {
                @compileError("REST handler must return an error union !ApiResult(T)");
            }
            const payload = retInfo.error_union.payload;
            if (@typeInfo(payload) != .@"struct" or !@hasField(payload, "body")) {
                @compileError("REST handler must return ApiResult(T)");
            }
            break :blk @typeInfo(@FieldType(payload, "body")).optional.child;
        };

        const hasReqBody = fnInfo.param_types.len == 2;
        const InType = if (hasReqBody) (fnInfo.param_types[1] orelse void) else void;

        const responses = if (OutType != void) struct {
            const schemaVal = typeSchema(OutType);
            const list = [_]metaMod.ResponseDesc{
                .{
                    .status = if (method == .POST) 201 else 200,
                    .description = if (method == .POST) "Created" else "OK",
                    .schema = &schemaVal,
                },
            };
        }.list else struct {
            const list = [_]metaMod.ResponseDesc{
                .{
                    .status = if (method == .DELETE) 204 else 200,
                    .description = if (method == .DELETE) "No Content" else "OK",
                    .schema = null,
                },
            };
        }.list;

        const requestDesc: ?metaMod.RequestBody = if (hasReqBody and InType != void and method != .GET and method != .HEAD and method != .DELETE)
            .{
                .content = .json,
                .schema = &(struct {
                    const schemaVal = typeSchema(InType);
                }.schemaVal),
                .required = true,
                .description = "Request body",
            }
        else
            null;

        const meta: metaMod.Metadata = .{
            .operationId = opts.operationId,
            .summary = opts.summary,
            .description = opts.description,
            .tags = opts.tags,
            .deprecated = opts.deprecated,
            .security = opts.security,
            .request = requestDesc,
            .responses = &responses,
        };

        const Wrapper = struct {
            fn handle(ctx: *Context) anyerror!Response {
                const apiRes = if (comptime hasReqBody) blk: {
                    const reqVal = if (ctx.body.len > 0)
                        try ctx.json(InType)
                    else if (@typeInfo(InType) == .@"struct")
                        ctx.bindParams(InType) catch try ctx.json(InType)
                    else
                        return error.MissingRequestBody;
                    break :blk try handlerFn(ctx, reqVal);
                } else blk: {
                    break :blk try handlerFn(ctx);
                };

                const statusCode: u16 = apiRes.status.code;

                if (apiRes.body) |b| {
                    var resp = try ctx.renderJsonStatus(statusCode, b);
                    if (apiRes.headers.len > 0) {
                        resp.headers = apiRes.headers;
                    }
                    return resp;
                } else {
                    return Response{
                        .status = statusCode,
                        .headers = apiRes.headers,
                        .body = "",
                    };
                }
            }
        };

        try self.router.add(method, path, Wrapper.handle, .{ .meta = meta });
    }

    pub fn get(self: *Rest, path: []const u8, comptime handlerFn: anytype, opts: EndpointOptions) !void {
        return self.add(.GET, path, handlerFn, opts);
    }

    pub fn post(self: *Rest, path: []const u8, comptime handlerFn: anytype, opts: EndpointOptions) !void {
        return self.add(.POST, path, handlerFn, opts);
    }

    pub fn put(self: *Rest, path: []const u8, comptime handlerFn: anytype, opts: EndpointOptions) !void {
        return self.add(.PUT, path, handlerFn, opts);
    }

    pub fn patch(self: *Rest, path: []const u8, comptime handlerFn: anytype, opts: EndpointOptions) !void {
        return self.add(.PATCH, path, handlerFn, opts);
    }

    pub fn delete(self: *Rest, path: []const u8, comptime handlerFn: anytype, opts: EndpointOptions) !void {
        return self.add(.DELETE, path, handlerFn, opts);
    }
};

test "typeSchema generates valid schema for nested types" {
    const Example = struct {
        id: u64,
        name: []const u8,
        active: bool,
        tags: []const []const u8,
        bio: ?[]const u8,
    };

    const s = typeSchema(Example);
    try std.testing.expect(s == .object);
    try std.testing.expectEqual(@as(usize, 5), s.object.len);
    try std.testing.expectEqualStrings("id", s.object[0].name);
    try std.testing.expect(s.object[0].schema.* == .integer);
    try std.testing.expect(s.object[0].required == true);

    try std.testing.expectEqualStrings("bio", s.object[4].name);
    try std.testing.expect(s.object[4].required == false);
    try std.testing.expect(s.object[4].nullable == true);
}

test "REST endpoint execution and automatic OpenAPI spec derivation" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    var rest = Rest.init(&router);

    const CreateUserReq = struct {
        name: []const u8,
        email: []const u8,
    };

    const UserRes = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };

    const Handlers = struct {
        fn createUser(ctx: *Context, reqVal: CreateUserReq) !ApiResult(UserRes) {
            _ = ctx;
            return ApiResult(UserRes).created(.{
                .id = 42,
                .name = reqVal.name,
                .email = reqVal.email,
            });
        }

        fn getUser(ctx: *Context) !ApiResult(UserRes) {
            _ = ctx;
            return ApiResult(UserRes).ok(.{
                .id = 42,
                .name = "Test User",
                .email = "test@example.com",
            });
        }
    };

    try rest.post("/users", Handlers.createUser, .{
        .operationId = "createUser",
        .summary = "Create user record",
        .tags = &.{"users"},
    });

    try rest.get("/users/{id:int}", Handlers.getUser, .{
        .operationId = "getUser",
        .summary = "Fetch user record",
        .tags = &.{"users"},
    });

    // 1. Verify router entries
    try std.testing.expectEqual(@as(usize, 2), router.entries().len);

    // 2. Verify OpenAPI spec generation reflects the REST endpoints
    const openapi = @import("openapi/spec.zig");
    const specJson = try openapi.generate(&router, .{
        .title = "REST Test API",
        .version = "1.0.0",
    });
    defer a.free(specJson);

    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"operationId\":\"createUser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"operationId\":\"getUser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"201\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, specJson, "\"200\"") != null);

    // 3. Verify dispatch and handler invocation with JSON body
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const reqBody = "{\"name\":\"Muhammad\",\"email\":\"m@example.com\"}";
    var ctx = Context{
        .allocator = arena.allocator(),
        .body = reqBody,
        .path = "/users",
        .method = .POST,
    };

    const resp = router.dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"Muhammad\"") != null);
}

