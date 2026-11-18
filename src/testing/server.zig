//! Full-featured local testing server built on the production HTTP server.
//!
//! `httpx.testing.Server` is not a mock: it owns a real `httpx.Server`, binds a
//! real loopback socket during `init`, and serves through the same parser,
//! router, middleware, compression, and response writer as production routes.
//! Testing adds ephemeral-port defaults, concise route registration, URL
//! construction, request capture, and thread-safe lifecycle helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const handlerMod = @import("handler.zig");
const requestMod = @import("request.zig");
const responseMod = @import("response.zig");
const routeMod = @import("route.zig");
const assertions = @import("assertions.zig");
const fixtures = @import("fixtures.zig");

const Config = common.httpServer.TestingConfig;
pub const CaptureConfig = requestMod.CaptureConfig;
pub const CapturedRequest = requestMod.CapturedRequest;
pub const RouteOptions = responseMod.RouteOptions;
pub const Method = common.Method;
pub const Header = common.Header;

const routerMod = common.router;
const httpServer = common.httpServer;

pub const Server = struct {
    state: *State,

    /// Stable heap state shared with the transport observer and the run
    /// thread. Keeping it out of the returned value makes those pointers
    /// independent of where the caller stores the `Server`.
    const State = struct {
        allocator: Allocator,
        io: std.Io,
        inner: httpServer.Server,
        capture: requestMod.Capture,
        routes: std.ArrayList(*routeMod.Route) = .empty,
        thread: ?std.Thread = null,
        started: bool = false,
        stopped: bool = false,
    };

    /// Creates a testing server bound to `127.0.0.1` on an OS-assigned port by
    /// default. Every production configuration field is accepted; omitted
    /// fields keep the shared schema defaults.
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .io = io,
            .inner = undefined,
            .capture = try requestMod.Capture.init(allocator, io, .{}),
        };
        state.inner = try httpServer.Server.init(allocator, io, httpServer.fromTestingConfig(cfg));
        state.inner.setRequestObserver(observe, state);
        return .{ .state = state };
    }

    fn observe(userData: ?*anyopaque, ctx: *const common.Context) void {
        const state: *State = @ptrCast(@alignCast(userData orelse return));
        state.capture.record(ctx);
    }

    /// Starts the background serving thread. Readiness is deterministic: the
    /// listener is already bound by `init`, so accepted connections queue as
    /// soon as this returns; no sleep or polling is involved.
    pub fn start(self: *Server) !void {
        const state = self.state;
        if (state.started) return error.AlreadyStarted;
        if (state.stopped) return error.ServerStopped;
        state.thread = try state.inner.start();
        state.started = true;
    }

    /// Stops accepting, interrupts active connections, and joins the serving
    /// thread. Safe to call repeatedly and safe after `init` without `start`.
    pub fn stop(self: *Server) void {
        const state = self.state;
        state.inner.stop();
        if (state.thread) |thread| {
            thread.join();
            state.thread = null;
        }
        state.started = false;
        state.stopped = true;
    }

    /// Stops the server if needed, releases every route/capture allocation,
    /// and destroys the production server. Call once.
    pub fn deinit(self: *Server) void {
        const state = self.state;
        self.stop();
        state.inner.setRequestObserver(null, null);
        state.capture.deinit();
        for (state.routes.items) |r| {
            r.deinit();
            state.allocator.destroy(r);
        }
        state.routes.deinit(state.allocator);
        state.inner.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }

    /// Registers a testing route. Static strings are copied. Registering the
    /// same method+path twice returns `error.DuplicateRoute` and leaves the
    /// server unchanged.
    pub fn route(self: *Server, path: []const u8, opts: RouteOptions) !void {
        const state = self.state;
        if (path.len == 0 or path[0] != '/') return routerMod.RouteError.InvalidPattern;
        if (std.mem.indexOfAny(u8, path, "?#") != null) return routerMod.RouteError.InvalidPattern;
        if (opts.status < 100 or opts.status > 599) return error.InvalidStatus;
        _ = try responseMod.validate(opts);

        const registered = try createRoute(state.allocator, path, opts);
        errdefer {
            registered.deinit();
            state.allocator.destroy(registered);
        }

        try state.routes.append(state.allocator, registered);
        errdefer _ = state.routes.pop();

        const methods = if (opts.methods.len > 0) opts.methods else &[_]Method{opts.method};
        var added: usize = 0;
        errdefer {
            for (methods[0..added]) |method| _ = state.inner.router.remove(method, path);
        }
        for (methods) |method| {
            try state.inner.router.add(method, path, routeMod.Route.serve, .{ .userData = registered });
            added += 1;
        }
    }

    fn createRoute(allocator: Allocator, path: []const u8, opts: RouteOptions) !*routeMod.Route {
        const entry = try allocator.create(routeMod.Route);
        errdefer allocator.destroy(entry);

        const ownedPath = try allocator.dupe(u8, path);
        errdefer allocator.free(ownedPath);

        // A handler produces status/body/headers itself, so static response
        // storage is neither copied nor consulted for dynamic routes.
        const isDynamic = opts.handler != null;
        const ownedBody: []u8 = if (isDynamic)
            &.{}
        else
            try allocator.dupe(u8, opts.body);
        errdefer allocator.free(ownedBody);

        const ownedContentType = if (isDynamic)
            null
        else if (opts.contentType) |ct|
            try allocator.dupe(u8, ct)
        else
            null;
        errdefer if (ownedContentType) |ct| allocator.free(ct);

        var headerList = std.ArrayList(common.Header).empty;
        errdefer {
            for (headerList.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            headerList.deinit(allocator);
        }
        if (!isDynamic) {
            for (opts.headers) |h| {
                const name = try allocator.dupe(u8, h.name);
                errdefer allocator.free(name);
                const value = try allocator.dupe(u8, h.value);
                errdefer allocator.free(value);
                try headerList.append(allocator, .{ .name = name, .value = value });
            }
            if (opts.closeConnection and common.headerValue(headerList.items, "connection") == null) {
                const name = try allocator.dupe(u8, "connection");
                errdefer allocator.free(name);
                const value = try allocator.dupe(u8, "close");
                errdefer allocator.free(value);
                try headerList.append(allocator, .{ .name = name, .value = value });
            }
        }
        const headers = try headerList.toOwnedSlice(allocator);

        entry.* = .{
            .allocator = allocator,
            .path = ownedPath,
            .status = opts.status,
            .body = ownedBody,
            .contentType = ownedContentType,
            .headers = headers,
            .handler = opts.handler,
            .delayMs = opts.delayMs,
        };
        return entry;
    }

    /// Builds an absolute `http://127.0.0.1:<port>...` URL for this server.
    /// Caller owns the returned string and frees it with the server allocator.
    pub fn url(self: *Server, path: []const u8) ![]u8 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        const state = self.state;
        const host = connectHost(state.inner.cfg.host);
        const scheme: []const u8 = if (state.inner.isTls()) "https" else "http";
        if (std.mem.indexOfScalar(u8, host, ':') != null) {
            return std.fmt.allocPrint(state.allocator, "{s}://[{s}]:{d}{s}", .{
                scheme, host, state.inner.localPort(), path,
            });
        }
        return std.fmt.allocPrint(state.allocator, "{s}://{s}:{d}{s}", .{
            scheme, host, state.inner.localPort(), path,
        });
    }

    fn connectHost(configured: []const u8) []const u8 {
        if (std.mem.eql(u8, configured, "0.0.0.0")) return "127.0.0.1";
        if (std.mem.eql(u8, configured, "::")) return "::1";
        return configured;
    }

    /// Reconfigures request capture after validating the limits. Retained
    /// requests are dropped; the total counter is preserved.
    pub fn capture(self: *Server, cfg: CaptureConfig) !void {
        try self.state.capture.reconfigure(cfg);
    }

    /// Total requests observed, including 404s and requests evicted from
    /// retention.
    pub fn requestCount(self: *const Server) usize {
        return self.state.capture.totalCount();
    }

    /// Number of requests currently retained for inspection.
    pub fn capturedCount(self: *Server) usize {
        return self.state.capture.retainedCount();
    }

    /// Owned, oldest-first snapshot of retained requests.
    pub fn requests(self: *Server, allocator: Allocator) ![]CapturedRequest {
        return self.state.capture.snapshot(allocator);
    }

    /// Owned copy of the most recent retained request.
    pub fn lastRequest(self: *Server, allocator: Allocator) !?CapturedRequest {
        return self.state.capture.last(allocator);
    }

    /// Drops retained requests and resets the total counter.
    pub fn resetRequests(self: *Server) void {
        self.state.capture.reset();
    }

    /// Counts requests served by testing routes registered at `path`
    /// (all methods). Production routes registered through forwarded verbs
    /// are still captured globally but are not included here.
    pub fn routeRequestCount(self: *const Server, path: []const u8) usize {
        var total: usize = 0;
        for (self.state.routes.items) |r| {
            if (std.mem.eql(u8, r.path, path)) total += r.requestCount();
        }
        return total;
    }

    // ---------------------------------------------------------------------
    // Production server API parity. Every method forwards to the one
    // canonical `httpx.Server`; behavior and validation are identical.

    pub fn get(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.get(path, arg);
    }

    pub fn post(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.post(path, arg);
    }

    pub fn put(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.put(path, arg);
    }

    pub fn patch(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.patch(path, arg);
    }

    pub fn delete(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.delete(path, arg);
    }

    pub fn head(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.head(path, arg);
    }

    pub fn options(self: *Server, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.options(path, arg);
    }

    pub fn add(self: *Server, comptime method: Method, path: []const u8, comptime arg: anytype) !void {
        try self.state.inner.add(method, path, arg);
    }

    pub fn group(self: *Server, prefix: []const u8, opts: routerMod.GroupOptions) routerMod.Group {
        return self.state.inner.group(prefix, opts);
    }

    pub fn mount(self: *Server, prefix: []const u8, other: *routerMod.Router, opts: routerMod.MountOptions) routerMod.RouteError!void {
        try self.state.inner.mount(prefix, other, opts);
    }

    pub fn register(self: *Server, routes: []const routerMod.RouteDecl) routerMod.RouteError!void {
        try self.state.inner.register(routes);
    }

    pub fn use(self: *Server, middleware: routerMod.MiddlewareFn) !void {
        try self.state.inner.use(middleware);
    }

    pub fn static(self: *Server, cfg: @import("../web/staticFiles/static.zig").Config) !void {
        try self.state.inner.static(cfg);
    }

    pub fn spa(self: *Server, cfg: @import("../web/spa/server.zig").Config) !void {
        try self.state.inner.spa(cfg);
    }

    pub fn metrics(self: *Server, path: []const u8) routerMod.RouteError!void {
        try self.state.inner.metrics(path);
    }

    pub fn metricsSnapshot(self: *const Server) @import("../web/metrics/metricsRegistry.zig").MetricsSnapshot {
        return self.state.inner.metricsSnapshot();
    }

    pub fn snapshot(self: *const Server) @import("../web/metrics/metricsRegistry.zig").ServerSnapshot {
        return self.state.inner.snapshot();
    }

    pub fn setNotFoundHandler(self: *Server, handler: *const fn (*common.Context) anyerror!common.Response) void {
        self.state.inner.setNotFoundHandler(handler);
    }

    pub fn setErrorHandler(self: *Server, handler: *const fn (*common.Context, anyerror) anyerror!common.Response) void {
        self.state.inner.setErrorHandler(handler);
    }

    pub fn setStatusHandler(self: *Server, statusCode: u16, handler: *const fn (*common.Context) anyerror!common.Response) !void {
        try self.state.inner.setStatusHandler(statusCode, handler);
    }

    pub fn rest(self: *Server) @import("../web/rest/api.zig").Rest {
        return self.state.inner.rest();
    }

    /// Mounts GraphQL request handling on the production router. See
    /// `httpx.Server.graphql` for configuration.
    pub fn graphql(self: *Server, cfg: @import("../web/graphql/graphQlServer.zig").MountConfig) !void {
        try self.state.inner.graphql(cfg);
    }

    pub fn isTls(self: *const Server) bool {
        return self.state.inner.isTls();
    }

    pub fn isHttp3Ready(self: *const Server) bool {
        return self.state.inner.isHttp3Ready();
    }

    pub fn setTls(self: *Server, certPemOrPath: []const u8, keyPemOrPath: []const u8) !void {
        try self.state.inner.setTls(certPemOrPath, keyPemOrPath);
    }

    pub fn templates(self: *Server) ?*@import("../web/templates/templates.zig").Engine {
        return self.state.inner.templates();
    }

    /// Actual bound TCP port, including OS-assigned port 0.
    pub fn localPort(self: *const Server) u16 {
        return self.state.inner.localPort();
    }

    /// HTTP/3 endpoint information, identical to `httpx.Server.http3`.
    pub fn http3(self: *const Server) httpServer.Server.Http3 {
        return self.state.inner.http3;
    }

    pub fn localAddress(self: *const Server) std.Io.net.IpAddress {
        return self.state.inner.localAddress();
    }

    pub fn requestShutdown(self: *Server) void {
        self.state.inner.requestShutdown();
    }

    pub fn pause(self: *Server) void {
        self.state.inner.pause();
    }

    pub fn resumeAccepting(self: *Server) void {
        self.state.inner.resumeAccepting();
    }

    /// Blocking serve loop, forwarded for parity. Tests normally use
    /// `start`/`stop`; this call returns when the server shuts down.
    pub fn serve(self: *Server) void {
        self.state.inner.serve();
    }

    /// Blocking run loop, forwarded for parity.
    pub fn run(self: *Server) void {
        self.state.inner.run();
    }

    /// Access to the production router for advanced route/middleware work and
    /// integrations such as `httpx.docs.init(allocator, io, server.router())`.
    pub fn router(self: *Server) *routerMod.Router {
        return &self.state.inner.router;
    }

    /// Effective production configuration after validation/defaults.
    pub fn config(self: *const Server) httpServer.Config {
        return self.state.inner.cfg;
    }

    /// Underlying production server, for APIs that take `*httpx.Server`.
    /// Its lifetime is owned by this testing server.
    pub fn production(self: *Server) *httpServer.Server {
        return &self.state.inner;
    }
};

test "testing config mirrors the production schema except bind defaults" {
    const productionInfo = @typeInfo(httpServer.Config).@"struct";
    const testingInfo = @typeInfo(Config).@"struct";
    try std.testing.expectEqual(productionInfo.field_names.len, testingInfo.field_names.len);
    inline for (productionInfo.field_names) |name| {
        try std.testing.expect(@hasField(Config, name));
        try std.testing.expectEqual(
            @FieldType(httpServer.Config, name),
            @FieldType(Config, name),
        );
    }

    const productionDefaults = httpServer.Config{};
    try std.testing.expectEqualStrings("0.0.0.0", productionDefaults.host);
    try std.testing.expectEqual(@as(u16, 8080), productionDefaults.port);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), productionDefaults.maxBody);

    const testingDefaults = Config{};
    try std.testing.expectEqualStrings("127.0.0.1", testingDefaults.host);
    try std.testing.expectEqual(@as(u16, 0), testingDefaults.port);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), testingDefaults.maxBody);
}

test "testing server binds loopback on port zero and builds URLs" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{});
    defer server.deinit();

    try std.testing.expect(server.localPort() != 0);
    try std.testing.expectEqualStrings("127.0.0.1", server.config().host);

    const url = try server.url("/get");
    defer allocator.free(url);
    const expected = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/get", .{server.localPort()});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, url);
}

test "testing server rejects duplicate routes and invalid input" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{});
    defer server.deinit();

    try server.route("/dup", .{ .body = "one" });
    try std.testing.expectError(error.DuplicateRoute, server.route("/dup", .{ .body = "two" }));
    try std.testing.expectError(error.InvalidStatus, server.route("/bad", .{ .status = 42 }));
    try std.testing.expectError(error.InvalidConfig, server.route("/bad-header", .{
        .headers = &.{.{ .name = "", .value = "x" }},
    }));
    const url = server.url("no-slash");
    try std.testing.expectError(error.InvalidPath, url);
}

test "real client exercises methods, bodies, headers, query, redirects, and capture" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const clientMod = @import("../client/httpClient.zig");

    var server = try Server.init(allocator, io, .{ .maxBody = 64 * 1024 });
    defer server.deinit();

    const Handlers = struct {
        fn inspect(ctx: *common.Context) anyerror!common.Response {
            const value = try std.fmt.allocPrint(ctx.allocator, "{s}|{s}|{s}|{s}|{s}", .{
                ctx.method.toString(),
                ctx.path,
                ctx.query,
                ctx.header("x-test") orelse "",
                ctx.header("content-length") orelse "",
            });
            return .{ .status = 200, .body = value, .contentType = "text/plain; charset=utf-8" };
        }
    };

    try server.route("/hello", .{ .body = "hello", .contentType = "text/plain; charset=utf-8" });
    try server.route("/inspect", .{ .handler = Handlers.inspect });
    try server.route("/echo", .{ .method = .POST, .handler = handlerMod.echo });
    try server.route("/multi", .{ .methods = &.{ .PUT, .PATCH, .DELETE }, .body = "multi" });
    try server.route("/redirect", responseMod.redirect("/hello", 302));
    try server.route("/slow", responseMod.delayed(250, .{ .body = "slow" }));
    try server.route("/binary", .{ .body = "\x00\x01\x02", .contentType = "application/octet-stream" });

    try server.start();

    var client = clientMod.Client.init(allocator, io, .{ .timeoutMs = 5_000 });
    defer client.deinit();

    const helloUrl = try server.url("/hello");
    defer allocator.free(helloUrl);
    var hello = try client.get(helloUrl, .{});
    defer hello.deinit();
    try assertions.expectStatus(hello, 200);
    try assertions.expectBody(hello, "hello");

    const inspectUrl = try server.url("/inspect?x=1&y=two");
    defer allocator.free(inspectUrl);
    var inspect = try client.get(inspectUrl, .{
        .headers = &.{.{ .name = "x-test", .value = "seen" }},
    });
    defer inspect.deinit();
    try assertions.expectStatus(inspect, 200);
    try assertions.expectBody(inspect, "GET|/inspect|x=1&y=two|seen|");

    const echoUrl = try server.url("/echo");
    defer allocator.free(echoUrl);
    var echoed = try client.post(echoUrl, .{ .text = "payload", .contentType = "text/plain" });
    defer echoed.deinit();
    try assertions.expectStatus(echoed, 200);
    try assertions.expectBody(echoed, "payload");

    const multiUrl = try server.url("/multi");
    defer allocator.free(multiUrl);
    var putResponse = try client.put(multiUrl, .{});
    defer putResponse.deinit();
    try assertions.expectStatus(putResponse, 200);
    try assertions.expectBody(putResponse, "multi");

    var patchResponse = try client.patch(multiUrl, .{});
    defer patchResponse.deinit();
    try assertions.expectStatus(patchResponse, 200);
    try assertions.expectBody(patchResponse, "multi");

    var deleteResponse = try client.delete(multiUrl, .{});
    defer deleteResponse.deinit();
    try assertions.expectStatus(deleteResponse, 200);
    try assertions.expectBody(deleteResponse, "multi");

    var headResponse = try client.head(helloUrl, .{});
    defer headResponse.deinit();
    try assertions.expectStatus(headResponse, 200);
    try std.testing.expectEqual(@as(usize, 0), headResponse.body.len);

    var optionsResponse = try client.options(helloUrl, .{});
    defer optionsResponse.deinit();
    try assertions.expectStatus(optionsResponse, 204);
    try std.testing.expect(optionsResponse.header("allow") != null);

    const redirectUrl = try server.url("/redirect");
    defer allocator.free(redirectUrl);
    var redirectResponse = try client.get(redirectUrl, .{ .followRedirects = false });
    defer redirectResponse.deinit();
    try assertions.expectStatus(redirectResponse, 302);
    try assertions.expectHeader(redirectResponse, "location", "/hello");

    var followed = try client.get(redirectUrl, .{});
    defer followed.deinit();
    try assertions.expectStatus(followed, 200);
    try assertions.expectBody(followed, "hello");

    const binaryUrl = try server.url("/binary");
    defer allocator.free(binaryUrl);
    var binaryResponse = try client.get(binaryUrl, .{});
    defer binaryResponse.deinit();
    try assertions.expectStatus(binaryResponse, 200);
    try std.testing.expectEqualSlices(u8, "\x00\x01\x02", binaryResponse.body);

    const slowUrl = try server.url("/slow");
    defer allocator.free(slowUrl);
    if (client.get(slowUrl, .{ .timeoutMs = 40 })) |slowResponse| {
        var r = slowResponse;
        r.deinit();
        return error.ExpectedTimeout;
    } else |_| {}

    try std.testing.expect(server.requestCount() >= 11);
    try std.testing.expect(server.routeRequestCount("/hello") >= 2);

    const captured = try server.requests(allocator);
    defer requestMod.freeCaptured(allocator, captured);
    var sawEcho = false;
    var sawQuery = false;
    for (captured) |request| {
        if (request.method == .POST and std.mem.eql(u8, request.path, "/echo")) {
            try std.testing.expectEqualStrings("payload", request.body);
            try std.testing.expectEqualStrings("text/plain", request.header("content-type").?);
            sawEcho = true;
        }
        if (std.mem.eql(u8, request.path, "/inspect")) {
            try std.testing.expectEqualStrings("x=1&y=two", request.query);
            try std.testing.expectEqualStrings("seen", request.header("x-test").?);
            sawQuery = true;
        }
    }
    try std.testing.expect(sawEcho);
    try std.testing.expect(sawQuery);
}

test "capture retention and body limits are bounded" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const clientMod = @import("../client/httpClient.zig");

    var server = try Server.init(allocator, io, .{});
    defer server.deinit();
    try server.capture(.{ .maxEntries = 2, .maxBody = 4 });
    try server.route("/echo", .{ .method = .POST, .handler = handlerMod.echo });
    try server.start();

    var client = clientMod.Client.init(allocator, io, .{});
    defer client.deinit();

    const url = try server.url("/echo");
    defer allocator.free(url);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var res = try client.post(url, .{ .text = "0123456789" });
        res.deinit();
    }

    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expectEqual(@as(usize, 2), server.capturedCount());
    var last = (try server.lastRequest(allocator)).?;
    defer last.deinit();
    try std.testing.expectEqual(@as(usize, 10), last.bodySize);
    try std.testing.expectEqualStrings("0123", last.body);
    try std.testing.expect(last.bodyTruncated);
}

test "keep-alive, compression, and connection-close reuse the production pipeline" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const clientMod = @import("../client/httpClient.zig");

    var server = try Server.init(allocator, io, .{ .keepAlive = true });
    defer server.deinit();

    const big = try fixtures.repeated(allocator, 'a', 32 * 1024);
    defer allocator.free(big);
    try server.route("/ka", .{ .body = "keep-alive", .contentType = "text/plain" });
    try server.route("/big", .{ .body = big, .contentType = "text/plain" });
    try server.route("/close", .{ .body = "bye", .closeConnection = true });
    try server.start();

    var client = clientMod.Client.init(allocator, io, .{});
    defer client.deinit();

    const kaUrl = try server.url("/ka");
    defer allocator.free(kaUrl);
    var first = try client.get(kaUrl, .{});
    first.deinit();
    var second = try client.get(kaUrl, .{});
    second.deinit();
    const stats = client.pool.statsSnapshot();
    try std.testing.expect(stats.hits >= 1);

    const bigUrl = try server.url("/big");
    defer allocator.free(bigUrl);
    var compressed = try client.get(bigUrl, .{});
    defer compressed.deinit();
    try assertions.expectStatus(compressed, 200);
    try std.testing.expectEqualStrings(big, compressed.body);

    const closeUrl = try server.url("/close");
    defer allocator.free(closeUrl);
    var closing = try client.get(closeUrl, .{});
    defer closing.deinit();
    try assertions.expectStatus(closing, 200);
    try assertions.expectHeader(closing, "connection", "close");
}

test "multiple testing servers keep independent ports, routes, capture, and shutdown" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const clientMod = @import("../client/httpClient.zig");

    var first = try Server.init(allocator, io, .{});
    defer first.deinit();
    var second = try Server.init(allocator, io, .{});
    defer second.deinit();

    try std.testing.expect(first.localPort() != second.localPort());
    try first.route("/one", .{ .body = "first" });
    try second.route("/two", .{ .body = "second" });

    try first.start();
    try second.start();

    var client = clientMod.Client.init(allocator, io, .{});
    defer client.deinit();

    const oneUrl = try first.url("/one");
    defer allocator.free(oneUrl);
    const twoUrl = try second.url("/two");
    defer allocator.free(twoUrl);

    var one = try client.get(oneUrl, .{});
    defer one.deinit();
    try assertions.expectBody(one, "first");
    var two = try client.get(twoUrl, .{});
    defer two.deinit();
    try assertions.expectBody(two, "second");

    first.stop();
    var stillTwo = try client.get(twoUrl, .{});
    defer stillTwo.deinit();
    try assertions.expectBody(stillTwo, "second");

    try std.testing.expectEqual(@as(usize, 1), first.requestCount());
    try std.testing.expectEqual(@as(usize, 2), second.requestCount());
}

test "malformed HTTP request is rejected by the same production parser" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tcp = @import("../sockets/tcp.zig");

    var server = try Server.init(allocator, io, .{});
    defer server.deinit();
    try server.route("/", .{ .body = "ok" });
    try server.start();

    var socket = try tcp.connect(io, "127.0.0.1", server.localPort());
    defer socket.close();
    try socket.writeAll("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");

    var buffer: [512]u8 = undefined;
    const n = try socket.read(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..n], "HTTP/1.1 400 Bad Request"));
}
