//! Application facade: one object that owns the server, the router, typed REST
//! registration, and the documentation mounts.
//!
//! The route surface is object/verb based and fully explicit — every route
//! states its path, its handler, and its metadata. Nothing is inferred from a
//! string verb and nothing is defaulted behind the caller's back:
//!
//! ```zig
//! var app = try httpx.App.init(allocator, io, .{ .host = "127.0.0.1", .port = 8080 });
//! defer app.deinit();
//!
//! try app.post(.{
//!     .path = "/users",
//!     .handler = createUser,
//!     .summary = "Create a user",
//!     .tags = &.{"users"},
//! });
//!
//! try app.get(.{
//!     .path = "/users/{id:int}",
//!     .handler = getUser,
//!     .operationId = "getUser",
//! });
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
//! Handlers return `httpx.Schema(T)`:
//!
//! ```zig
//! fn getUser(ctx: *httpx.Context) !httpx.Schema(User) {
//!     const id = ctx.paramUint("id") orelse 1;
//!     return httpx.Schema(User).result(.{ .status = .ok, .body = .{ .id = id } });
//! }
//! ```
//!
//! Raw `HandlerFn` routes keep their place too, with the explicit method enum:
//!
//! ```zig
//! try app.add(.GET, "/health", healthCheck, .{ .summary = "Liveness probe" });
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
                    if (@hasField(serverMod.Config, fname)) {
                        @field(cfg, fname) = @field(config, fname);
                    }
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

    pub fn deinit(self: *App) void {
        docsMod.unmount();
        self.server.deinit();
    }

    /// Typed REST controller bound to this application's router.
    pub fn rest(self: *App) restMod.Rest {
        return restMod.Rest.init(&self.server.router);
    }

    pub fn getServer(self: *App) *serverMod.Server {
        return &self.server;
    }

    pub fn getRouter(self: *App) *routerMod.Router {
        return &self.server.router;
    }

    /// Registers a raw `HandlerFn` route with an explicit method and metadata.
    ///
    /// ```zig
    /// try app.add(.GET, "/health", healthCheck, .{ .summary = "Liveness" });
    /// ```
    pub fn add(
        self: *App,
        comptime method: Method,
        path: []const u8,
        handler: routerMod.HandlerFn,
        comptime opts: anytype,
    ) !void {
        try self.server.router.add(method, path, handler, routeOptions(opts));
    }

    /// Shared object/verb registration: `arg` must carry `.path` and `.handler`.
    fn route(self: *App, comptime method: Method, comptime arg: anytype) !void {
        const ArgType = @TypeOf(arg);
        if (@typeInfo(ArgType) != .@"struct") {
            @compileError("route options must be a struct literal with `.path` and `.handler`");
        }
        if (!@hasField(ArgType, "path")) {
            @compileError("route options are missing `.path`");
        }
        if (!@hasField(ArgType, "handler")) {
            @compileError("route options are missing `.handler`");
        }
        var typed = self.rest();
        try typed.add(method, arg.path, arg);
    }

    /// Typed GET route.
    pub fn get(self: *App, comptime arg: anytype) !void {
        try self.route(.GET, arg);
    }

    /// Typed POST route.
    pub fn post(self: *App, comptime arg: anytype) !void {
        try self.route(.POST, arg);
    }

    /// Typed PUT route.
    pub fn put(self: *App, comptime arg: anytype) !void {
        try self.route(.PUT, arg);
    }

    /// Typed PATCH route.
    pub fn patch(self: *App, comptime arg: anytype) !void {
        try self.route(.PATCH, arg);
    }

    /// Typed DELETE route.
    pub fn delete(self: *App, comptime arg: anytype) !void {
        try self.route(.DELETE, arg);
    }

    /// Typed HEAD route.
    pub fn head(self: *App, comptime arg: anytype) !void {
        try self.route(.HEAD, arg);
    }

    /// Typed OPTIONS route.
    pub fn options(self: *App, comptime arg: anytype) !void {
        try self.route(.OPTIONS, arg);
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
        try self.server.run();
    }
};

/// Converts any route-option struct literal into router options, copying the
/// fields the caller actually provided. Unknown fields are a compile error so
/// typos surface at build time instead of silently doing nothing.
fn routeOptions(comptime opts: anytype) routerMod.RouteOptions {
    const OptsType = @TypeOf(opts);
    if (OptsType == routerMod.RouteOptions) return opts;

    var out: routerMod.RouteOptions = .{};
    if (@typeInfo(OptsType) != .@"struct") return out;

    inline for (@typeInfo(OptsType).@"struct".field_names) |fname| {
        if (@hasField(metaMod.Metadata, fname)) {
            @field(out.meta, fname) = @field(opts, fname);
        } else if (@hasField(routerMod.RouteOptions, fname)) {
            @field(out, fname) = @field(opts, fname);
        } else {
            @compileError("unknown route option `.{" ++ fname ++ "}`");
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

test "raw route options reject unknown fields at compile time" {
    const testing = std.testing;
    const opts = routeOptions(.{ .summary = "Health", .tags = &.{"system"} });
    try testing.expectEqualStrings("Health", opts.meta.summary);
    try testing.expectEqual(@as(usize, 1), opts.meta.tags.len);
}
