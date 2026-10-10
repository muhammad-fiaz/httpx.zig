//! Modern App facade coordinating Server, Router, Rest, OpenAPI, and Docs integrations.
//!
//! Provides a developer-friendly high-level web application API:
//! ```zig
//! var app = try httpx.App.init(allocator, io, .{ .port = 8080 });
//! defer app.deinit();
//!
//! // Regular routing
//! try app.get("/hello", hello);
//!
//! // Typed REST routing with OpenAPI auto-generation
//! try app.rest.post("/users", createUser, .{ .summary = "Create a user" });
//!
//! // Documentation UIs (Swagger UI, ReDoc, Scalar, GraphiQL)
//! try app.docs(.{
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs" },
//!     .redoc = .{ .enabled = true, .route = "/redoc" },
//!     .scalar = .{ .enabled = true, .route = "/reference" },
//! });
//!
//! try app.listen();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const serverMod = @import("../server/lifecycle.zig");
const routerMod = @import("router/router.zig");
const restMod = @import("rest.zig");
const docsMod = @import("docs/docs.zig");
const Method = @import("../common/method.zig").Method;
const Context = routerMod.Context;
const Response = routerMod.Response;
const Server = serverMod.Server;
const Router = routerMod.Router;

pub const App = struct {
    allocator: Allocator,
    io: std.Io,
    server: Server,

    pub fn init(allocator: Allocator, io: std.Io, config: serverMod.Config) !App {
        const srv = try Server.init(allocator, io, config);
        return App{
            .allocator = allocator,
            .io = io,
            .server = srv,
        };
    }

    pub fn deinit(self: *App) void {
        docsMod.unmount();
        self.server.deinit();
    }

    /// Access typed REST controller.
    pub fn rest(self: *App) restMod.Rest {
        return restMod.Rest.init(&self.server.router);
    }

    /// Access the underlying server instance.
    pub fn getServer(self: *App) *Server {
        return &self.server;
    }

    /// Access the router instance.
    pub fn getRouter(self: *App) *Router {
        return &self.server.router;
    }

    // Direct HTTP route registration
    pub fn get(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.get(path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.post(path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.put(path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.patch(path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.delete(path, handler);
    }

    pub fn head(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.head(path, handler);
    }

    pub fn options(self: *App, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.options(path, handler);
    }

    pub fn add(self: *App, method: Method, path: []const u8, handler: routerMod.HandlerFn) !void {
        try self.server.add(method, path, handler);
    }

    // Typed REST endpoint registration forwarders
    pub fn restGet(self: *App, path: []const u8, comptime handlerFn: anytype, opts: restMod.EndpointOptions) !void {
        var r = self.rest();
        try r.get(path, handlerFn, opts);
    }

    pub fn restPost(self: *App, path: []const u8, comptime handlerFn: anytype, opts: restMod.EndpointOptions) !void {
        var r = self.rest();
        try r.post(path, handlerFn, opts);
    }

    pub fn restPut(self: *App, path: []const u8, comptime handlerFn: anytype, opts: restMod.EndpointOptions) !void {
        var r = self.rest();
        try r.put(path, handlerFn, opts);
    }

    pub fn restPatch(self: *App, path: []const u8, comptime handlerFn: anytype, opts: restMod.EndpointOptions) !void {
        var r = self.rest();
        try r.patch(path, handlerFn, opts);
    }

    pub fn restDelete(self: *App, path: []const u8, comptime handlerFn: anytype, opts: restMod.EndpointOptions) !void {
        var r = self.rest();
        try r.delete(path, handlerFn, opts);
    }

    /// Attach middleware to application pipeline.
    pub fn use(self: *App, mw: routerMod.MiddlewareFn) !void {
        try self.server.use(mw);
    }

    /// Mount static files directory.
    pub fn static(self: *App, mountPath: []const u8, dirPath: []const u8) !void {
        try self.server.static(mountPath, dirPath);
    }

    /// Mount single page application.
    pub fn spa(self: *App, mountPath: []const u8, dirPath: []const u8) !void {
        try self.server.spa(mountPath, dirPath);
    }

    /// Mount Prometheus metrics endpoint.
    pub fn metrics(self: *App, path: []const u8) !void {
        try self.server.metrics(path);
    }

    /// Mount native documentation interfaces (Swagger UI, ReDoc, Scalar, GraphiQL, OpenAPI spec).
    pub fn docs(self: *App, cfg: docsMod.Config) !void {
        try docsMod.mount(self.allocator, &self.server.router, cfg, null);
    }

    /// Run the server listen loop.
    pub fn listen(self: *App) !void {
        try self.server.run();
    }
};

test "App initializes and registers REST endpoints" {
    const a = std.testing.allocator;
    // We test router & REST without binding network port 0
    var router = Router.init(a);
    defer router.deinit();

    var rest = restMod.Rest.init(&router);

    const PingResp = struct { message: []const u8 };
    const pingHandler = struct {
        fn handle(ctx: *Context) !restMod.ApiResult(PingResp) {
            _ = ctx;
            return restMod.ApiResult(PingResp).ok(.{ .message = "pong" });
        }
    }.handle;

    try rest.get("/ping", pingHandler, .{ .summary = "Ping check" });
    try std.testing.expect(router.entries().len == 1);
}
