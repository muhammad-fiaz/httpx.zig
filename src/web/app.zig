//! Application facade: one object that owns the HTTP client, the HTTP server,
//! the router, typed REST registration, and the documentation mounts.
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
//! // Every UI explicitly enabled: OpenAPI, Swagger UI, ReDoc, Scalar, GraphiQL.
//! try app.docs(.{
//!     .title = "Users API",
//!     .version = "1.0.0",
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
//!     .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
//!     .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar API Reference" },
//!     .graphiql = .{ .enabled = true, .route = "/graphiql", .graphqlEndpoint = "/graphql", .title = "GraphiQL IDE" },
//! });
//!
//! // The same App also owns an HTTP client for outbound calls.
//! const upstream = try app.client.get("https://example.com/health", .{});
//! defer upstream.deinit();
//!
//! try app.listen();
//! ```
//!
//! The client is configured through the optional `.client` field in the same
//! `init` literal; the server reads every other field. Both reuse the single
//! allocator and `std.Io` passed to `init`.
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
const clientMod = @import("../client/httpClient.zig");
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
    /// Outbound HTTP client owned by this application.
    client: clientMod.Client,
    /// Inbound HTTP server owned by this application.
    server: serverMod.Server,
    /// Creates an application with one allocator and one `std.Io`.
    ///
    /// `config` accepts the server fields directly plus an optional nested
    /// `.client` literal. Unknown fields are a compile error, so typos and
    /// unsupported options never pass silently:
    ///
    /// ```zig
    /// var app = try httpx.App.init(allocator, io, .{
    ///     .host = "127.0.0.1",
    ///     .port = 8080,
    ///     .client = .{ .timeoutMs = 10_000 },
    /// });
    /// ```
    pub fn init(allocator: Allocator, io: std.Io, config: anytype) !App {
        const CfgType = @TypeOf(config);
        const srvCfg: serverMod.Config = blk: {
            if (CfgType == serverMod.Config) break :blk config;
            var cfg = serverMod.Config{};
            if (@typeInfo(CfgType) == .@"struct") {
                inline for (@typeInfo(CfgType).@"struct".field_names) |fname| {
                    if (comptime std.mem.eql(u8, fname, "client")) continue;
                    if (comptime !@hasField(serverMod.Config, fname)) {
                        @compileError("unknown App/server config option `." ++ fname ++ "`");
                    }
                    @field(cfg, fname) = coerceConfig(@FieldType(serverMod.Config, fname), @field(config, fname));
                }
            }
            break :blk cfg;
        };
        const cliCfg: clientMod.Config = blk: {
            if (@typeInfo(CfgType) == .@"struct" and @hasField(CfgType, "client")) {
                break :blk coerceConfig(clientMod.Config, config.client);
            }
            break :blk .{};
        };

        var server = try serverMod.Server.init(allocator, io, srvCfg);
        errdefer server.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .client = clientMod.Client.init(allocator, io, cliCfg),
            .server = server,
        };
    }

    /// Releases the owned client and server. The server unmounts its own
    /// documentation and GraphQL routes, so nothing is torn down twice here.
    pub fn deinit(self: *App) void {
        self.client.deinit();
        self.server.deinit();
    }

    /// Typed REST controller bound to this application's router, allocator,
    /// and `std.Io`.
    pub fn rest(self: *App) restMod.Rest {
        return self.server.rest();
    }

    /// Bound TCP port of the owned server (useful with `.port = 0`).
    pub fn localPort(self: *App) u16 {
        return self.server.localPort();
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

    /// Mounts the GraphQL endpoint (POST/GET/OPTIONS) on this application's
    /// server. The server owns the mount and tears it down in its own `deinit`;
    /// GraphiQL IDE is served by the documentation mount (`app.docs`), which
    /// points at `cfg.endpoint`.
    pub fn graphql(self: *App, schema: graphqlMod.Schema, cfg: graphqlMod.HandlerConfig) !void {
        try self.server.graphql(schema, cfg);
    }

    /// Mounts documentation UIs and the OpenAPI document.
    ///
    /// `cfg` is `httpx.docs.Config` or any struct literal with the same field
    /// names, so partial configuration works.
    pub fn docs(self: *App, cfg: anytype) !void {
        if (self.server.docsMounted) return error.DocsAlreadyMounted;
        const docsCfg = coerceConfig(docsMod.Config, cfg);
        try docsMod.mount(self.allocator, &self.server.router, docsCfg, null);
        // Marks the server too, so `listen` never mounts a second copy.
        self.server.docsMounted = true;
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

/// Recursively coerces a struct literal onto an exact config type. This keeps
/// partial nested literals supported without exposing any option struct through
/// the public facade, and rejects unknown field names at compile time.
fn coerceConfig(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    if (V == T) return value;
    if (@typeInfo(T) == .@"struct" and @typeInfo(V) == .@"struct") {
        var out: T = .{};
        inline for (@typeInfo(V).@"struct".field_names) |fname| {
            if (comptime !@hasField(T, fname)) {
                @compileError("unknown config option `." ++ fname ++ "` for " ++ @typeName(T));
            }
            @field(out, fname) = coerceConfig(@FieldType(T, fname), @field(value, fname));
        }
        return out;
    }
    return @as(T, value);
}

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
/// nothing. Typed-only options (`.schema`, `.requestSchema`,
/// `.responseSchema`, `.mediaType`) are rejected here.
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
        if (comptime std.mem.eql(u8, fname, "schema") or
            std.mem.eql(u8, fname, "requestSchema") or
            std.mem.eql(u8, fname, "responseSchema"))
        {
            @compileError("route: JSON schema options are only valid for typed `httpx.Schema(T)` handlers; use ctx.jsonValue()/ctx.jsonSchema() in a raw handler");
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

    var rest = restMod.Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);

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

test "app owns a client and a server from one init" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app = try App.init(testing.allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .client = .{ .maxRedirects = 3, .timeoutMs = 1234 },
    });
    defer app.deinit();

    try testing.expectEqual(@as(u8, 3), app.client.config.maxRedirects);
    try testing.expectEqual(@as(?u64, 1234), app.client.config.timeoutMs);
    try testing.expect(app.server.localPort() > 0);
    try testing.expectEqual(testing.allocator, app.client.allocator);
    try testing.expectEqual(testing.allocator, app.server.allocator);
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

    var rest = restMod.Rest.init(testing.allocator, std.Io.Threaded.global_single_threaded.io(), &router);
    try rest.get("/typed", .{ .handler = Handlers.typed, .summary = "Typed" });
    try router.add(.GET, "/raw", Handlers.raw, rawRouteOptions(.{
        .handler = Handlers.raw,
        .summary = "Raw",
    }));
    try testing.expectEqual(@as(usize, 2), router.entries().len);
}
