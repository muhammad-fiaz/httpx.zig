//! Application facade: one object that owns the server, the router, typed REST
//! registration, and the documentation mounts.
//!
//! The route surface uses lowercase HTTP verbs, a positional path, and one
//! explicit `.{}` options literal. The handler's return type selects the mode
//! at compile time: `!httpx.Schema(T)` is a typed REST endpoint, while
//! `!httpx.Response` is a raw route. There is no separate capitalized API.
//!
//! ```zig
//! var app = try httpx.App.init(allocator, io, .{ .host = "127.0.0.1", .port = 8080 });
//! defer app.deinit();
//!
//! try app.post("/users", .{
//!     .handler = createUser,
//!     .summary = "Create a user",
//!     .tags = &.{"users"},
//! });
//!
//! try app.get("/users/{id:int}", .{
//!     .handler = getUser,
//!     .operationId = "getUser",
//! });
//!
//! // A bare handler is also valid.
//! try app.get("/ping", ping);
//!
//! try app.docs(.{
//!     .title = "Users API",
//!     .version = "1.0.0",
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs" },
//! });
//!
//! try app.listen();
//! ```
//!
//! Typed handlers return `httpx.Schema(T)`:
//!
//! ```zig
//! fn getUser(ctx: *httpx.Context) !httpx.Schema(User) {
//!     const id = ctx.paramUint("id") orelse 1;
//!     return httpx.Schema(User).result(.{ .status = .ok, .body = .{ .id = id } });
//! }
//! ```
//!
//! Raw `HandlerFn` routes use the same lowercase verb:
//!
//! ```zig
//! try app.get("/health", .{ .handler = healthCheck, .summary = "Liveness probe" });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const serverMod = @import("../server/httpServer.zig");
const routerMod = @import("router/router.zig");
const metaMod = @import("router/routeMetadata.zig");
const restMod = @import("rest/api.zig");
const docsMod = @import("docs/docs.zig");
const graphqlMod = @import("graphql/graphql.zig");
const Method = @import("../common/method.zig").Method;

pub const App = struct {
    allocator: Allocator,
    io: std.Io,
    server: serverMod.Server,

    /// Creates an application. `config` is any struct whose fields match
    /// `httpx.server.Config`; unmatched fields are ignored, so callers can pass
    /// only what they actually set.
    pub fn init(allocator: Allocator, io: std.Io, config: anytype) !App {
        const CfgType = @TypeOf(config);
        const srvCfg: serverMod.Config = blk: {
            if (CfgType == serverMod.Config) break :blk config;
            var cfg = serverMod.Config{};
            if (@typeInfo(CfgType) == .@"struct") {
                inline for (@typeInfo(CfgType).@"struct".field_names) |fname| {
                    if (comptime !@hasField(serverMod.Config, fname)) {
                        @compileError("unknown App/server config option `." ++ fname ++ "`");
                    }
                    @field(cfg, fname) = @field(config, fname);
                }
            }
            break :blk cfg;
        };
        return .{
            .allocator = allocator,
            .io = io,
            .server = try serverMod.Server.init(allocator, io, srvCfg),
        };
    }

    /// Unmounts documentation and releases the underlying server.
    pub fn deinit(self: *App) void {
        docsMod.unmount();
        self.server.deinit();
    }

    /// Typed REST controller bound to this application's router.
    pub fn rest(self: *App) restMod.Rest {
        return restMod.Rest.init(&self.server.router);
    }

    /// Borrowed pointer to the owned server.
    pub fn getServer(self: *App) *serverMod.Server {
        return &self.server;
    }

    /// Borrowed pointer to the server router.
    pub fn getRouter(self: *App) *routerMod.Router {
        return &self.server.router;
    }

    /// Registers a route for an explicit method.
    ///
    /// Both forms are accepted and type-checked at compile time:
    ///
    /// ```zig
    /// try app.add(.GET, "/health", healthCheck);
    /// try app.add(.GET, "/health", .{ .handler = healthCheck, .summary = "Liveness" });
    /// ```
    ///
    /// A handler returning `!httpx.Schema(T)` becomes a typed REST endpoint
    /// (JSON body handling plus OpenAPI derived from `T`). A handler returning
    /// `!httpx.Response` stays a raw route and uses the same metadata fields.
    pub fn add(
        self: *App,
        comptime method: Method,
        path: []const u8,
        comptime arg: anytype,
    ) !void {
        try self.register(method, path, arg);
    }

    /// Registers a GET route. See [`add`] for the two accepted forms.
    pub fn get(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.GET, path, arg);
    }

    /// Registers a POST route. See [`add`] for the two accepted forms.
    pub fn post(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.POST, path, arg);
    }

    /// Registers a PUT route. See [`add`] for the two accepted forms.
    pub fn put(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.PUT, path, arg);
    }

    /// Registers a PATCH route. See [`add`] for the two accepted forms.
    pub fn patch(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.PATCH, path, arg);
    }

    /// Registers a DELETE route. See [`add`] for the two accepted forms.
    pub fn delete(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.DELETE, path, arg);
    }

    /// Registers a HEAD route. See [`add`] for the two accepted forms.
    pub fn head(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.HEAD, path, arg);
    }

    /// Registers an OPTIONS route. See [`add`] for the two accepted forms.
    pub fn options(self: *App, path: []const u8, comptime arg: anytype) !void {
        try self.register(.OPTIONS, path, arg);
    }

    /// Shared typed/raw dispatch. The handler's return type decides which
    /// registration path is used; there is no separate capitalized API.
    fn register(self: *App, comptime method: Method, path: []const u8, comptime arg: anytype) !void {
        const ArgType = @TypeOf(arg);
        const argInfo = @typeInfo(ArgType);
        const isBareFn = argInfo == .@"fn" or
            (argInfo == .pointer and @typeInfo(argInfo.pointer.child) == .@"fn");
        const isOptions = argInfo == .@"struct" and @hasField(ArgType, "handler");
        if (comptime !isBareFn and !isOptions) {
            @compileError("route registration expects a handler function or a struct literal with `.handler`");
        }

        const handler = comptime if (isBareFn) arg else arg.handler;
        if (comptime isTypedHandler(handler)) {
            var typed = self.rest();
            try typed.add(method, path, arg);
        } else {
            try self.server.router.add(method, path, handler, rawRouteOptions(arg));
        }
    }

    /// Attaches middleware to the pipeline (outermost first).
    pub fn use(self: *App, mw: routerMod.MiddlewareFn) !void {
        try self.server.use(mw);
    }

    /// Opens a prefixed route group. Middleware accumulates outer-first.
    pub fn group(self: *App, prefix: []const u8, opts: routerMod.GroupOptions) routerMod.Group {
        return self.server.router.group(prefix, opts);
    }

    /// Serves a directory of static files under `mountPath`.
    pub fn static(self: *App, mountPath: []const u8, dirPath: []const u8) !void {
        try self.server.static(mountPath, dirPath);
    }

    /// Serves a single-page application directory with history fallback.
    pub fn spa(self: *App, mountPath: []const u8, dirPath: []const u8) !void {
        try self.server.spa(mountPath, dirPath);
    }

    /// Mounts the Prometheus metrics endpoint.
    pub fn metrics(self: *App, path: []const u8) !void {
        try self.server.metrics(path);
    }

    /// Mounts GraphQL (POST/GET/OPTIONS) plus optional GraphiQL.
    pub fn graphql(self: *App, schema: graphqlMod.Schema, cfg: graphqlMod.HandlerConfig) !void {
        try graphqlMod.mount(&self.server.router, schema, cfg);
    }

    /// Mounts documentation UIs and the OpenAPI document.
    ///
    /// `cfg` is `httpx.docs.Config` or any struct literal with the same field
    /// names, so partial configuration works.
    pub fn docs(self: *App, cfg: anytype) !void {
        const CfgType = @TypeOf(cfg);
        const docsCfg: docsMod.Config = blk: {
            if (CfgType == docsMod.Config) break :blk cfg;
            var out = docsMod.Config{};
            if (@typeInfo(CfgType) == .@"struct") {
                inline for (@typeInfo(CfgType).@"struct".field_names) |fname| {
                    if (!@hasField(docsMod.Config, fname)) continue;
                    const value = @field(cfg, fname);
                    const ValueType = @TypeOf(value);
                    if (@typeInfo(ValueType) == .@"struct" and @typeInfo(@FieldType(docsMod.Config, fname)) == .@"struct") {
                        inline for (@typeInfo(ValueType).@"struct".field_names) |subName| {
                            if (@hasField(@FieldType(docsMod.Config, fname), subName)) {
                                @field(@field(out, fname), subName) = @field(value, subName);
                            }
                        }
                    } else {
                        @field(out, fname) = value;
                    }
                }
            }
            break :blk out;
        };
        try docsMod.mount(self.allocator, &self.server.router, docsCfg, null);
    }

    /// Runs the accept loop until shutdown is requested.
    pub fn listen(self: *App) !void {
        self.server.run();
    }

    /// Requests graceful shutdown of the owned server. Safe to call from
    /// signal handlers, route handlers, or another thread.
    pub fn requestShutdown(self: *App) void {
        self.server.requestShutdown();
    }
};

/// True when `handler` returns `!httpx.Schema(T)` (typed REST) rather than a
/// raw `!httpx.Response`.
fn isTypedHandler(comptime handler: anytype) bool {
    const HandlerType = @TypeOf(handler);
    const handlerInfo = @typeInfo(HandlerType);
    if (handlerInfo != .@"fn") return false;
    const returnType = handlerInfo.@"fn".return_type orelse return false;
    const returnInfo = @typeInfo(returnType);
    if (returnInfo != .error_union) return false;
    const payload = returnInfo.error_union.payload;
    if (@typeInfo(payload) != .@"struct") return false;
    return @hasDecl(payload, "ResponseBody") and @hasField(payload, "body");
}

/// Converts a raw-route struct literal into router options. Unknown fields are
/// a compile error so typos surface at build time instead of silently doing
/// nothing. Typed-only fields (`.names`, `.mediaType`) are rejected here.
fn rawRouteOptions(comptime arg: anytype) routerMod.RouteOptions {
    const ArgType = @TypeOf(arg);
    const info = @typeInfo(ArgType);
    if (info != .@"struct") return .{};

    var out: routerMod.RouteOptions = .{};
    inline for (info.@"struct".field_names) |fname| {
        if (comptime std.mem.eql(u8, fname, "handler")) continue;
        if (comptime std.mem.eql(u8, fname, "path")) {
            @compileError("route: pass the path as the second argument, not `.path`");
        }
        if (comptime std.mem.eql(u8, fname, "names")) {
            @compileError("route: `.names` is only valid for typed `httpx.Schema(T)` handlers");
        }
        if (comptime std.mem.eql(u8, fname, "mediaType")) {
            @compileError("route: `.mediaType` is only valid for typed `httpx.Schema(T)` handlers");
        }
        if (@hasField(metaMod.Metadata, fname)) {
            @field(out.meta, fname) = @field(arg, fname);
        } else if (@hasField(routerMod.RouteOptions, fname)) {
            @field(out, fname) = @field(arg, fname);
        } else {
            @compileError("unknown route option `." ++ fname ++ "`");
        }
    }
    return out;
}

test "app facade registers typed REST routes and round-trips JSON" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var router = routerMod.Router.init(testing.allocator);
    defer router.deinit();

    var rest = restMod.Rest.init(&router);

    const Ping = struct { message: []const u8 };
    const handlers = struct {
        fn ping(ctx: *routerMod.Context) !restMod.Schema(Ping) {
            _ = ctx;
            return restMod.Schema(Ping).result(.{ .status = .ok, .body = .{ .message = "pong" } });
        }
    };

    try rest.get("/ping", .{ .handler = handlers.ping, .summary = "Ping" });
    try testing.expectEqual(@as(usize, 1), router.entries().len);

    var ctx = routerMod.Context{
        .allocator = arena.allocator(),
        .path = "/ping",
        .method = .GET,
    };
    const resp = router.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"message\":\"pong\"") != null);
}

test "raw route options map metadata and router fields" {
    const testing = std.testing;
    const opts = rawRouteOptions(.{ .handler = struct {
        fn h(_: *routerMod.Context) anyerror!routerMod.Response {
            return .{};
        }
    }.h, .summary = "Health", .tags = &.{"system"}, .name = "health" });
    try testing.expectEqualStrings("Health", opts.meta.summary);
    try testing.expectEqual(@as(usize, 1), opts.meta.tags.len);
    try testing.expectEqualStrings("health", opts.name.?);
}

test "typed and raw handlers share the lowercase verb surface" {
    const testing = std.testing;

    var router = routerMod.Router.init(testing.allocator);
    defer router.deinit();

    const Ping = struct { message: []const u8 };
    const Handlers = struct {
        fn typed(_: *routerMod.Context) !restMod.Schema(Ping) {
            return restMod.Schema(Ping).ok(.{ .message = "pong" });
        }
        fn raw(_: *routerMod.Context) anyerror!routerMod.Response {
            return .{ .status = 200, .body = "ok", .contentType = "text/plain" };
        }
    };

    var rest = restMod.Rest.init(&router);
    try rest.get("/typed", .{ .handler = Handlers.typed, .summary = "Typed" });
    try router.add(.GET, "/raw", Handlers.raw, rawRouteOptions(.{
        .handler = Handlers.raw,
        .summary = "Raw",
    }));
    try testing.expectEqual(@as(usize, 2), router.entries().len);
}
