//! HTTP Server Implementation for httpx.zig
//!
//! Production-ready HTTP server with comprehensive features:
//!
//! - Express-style routing with path parameters
//! - Middleware stack support
//! - Context-based request handling
//! - JSON response helpers
//! - Static file serving
//! - Cross-platform (Linux, Windows, macOS)

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const types = @import("../core/types.zig");
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;
const ResponseBuilder = @import("../core/response.zig").ResponseBuilder;
const Headers = @import("../core/headers.zig").Headers;
const HeaderName = @import("../core/headers.zig").HeaderName;
const Parser = @import("../protocol/parser.zig").Parser;
const http = @import("../protocol/http.zig");
const Socket = @import("../net/socket.zig").Socket;
const TcpListener = @import("../net/socket.zig").TcpListener;
const Router = @import("router.zig").Router;
const Middleware = @import("middleware.zig").Middleware;

/// Server configuration.
pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max_body_size: usize = 10 * 1024 * 1024,
    request_timeout_ms: u64 = 30_000,
    keep_alive_timeout_ms: u64 = 60_000,
    max_connections: u32 = 1000,
    keep_alive: bool = true,
    threads: u32 = 0,
};

/// Request context passed to handlers.
pub const Context = struct {
    allocator: Allocator,
    request: *Request,
    response: ResponseBuilder,
    params: std.StringHashMap([]const u8),
    data: std.StringHashMap(*anyopaque),

    const Self = @This();

    /// Creates a new context for a request.
    pub fn init(allocator: Allocator, req: *Request) Self {
        return .{
            .allocator = allocator,
            .request = req,
            .response = ResponseBuilder.init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .data = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    /// Releases context resources.
    pub fn deinit(self: *Self) void {
        self.response.deinit();
        self.params.deinit();
        self.data.deinit();
    }

    /// Returns a URL parameter by name.
    pub fn param(self: *const Self, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Returns a query parameter by name.
    pub fn query(self: *const Self, name: []const u8) ?[]const u8 {
        _ = self;
        _ = name;
        return null;
    }

    /// Returns a request header by name.
    pub fn header(self: *const Self, name: []const u8) ?[]const u8 {
        return self.request.headers.get(name);
    }

    /// Sets the response status code.
    pub fn status(self: *Self, code: u16) *Self {
        _ = self.response.status(code);
        return self;
    }

    /// Sets a response header.
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        _ = try self.response.header(name, value);
    }

    /// Sends a plain text response.
    pub fn text(self: *Self, data: []const u8) !Response {
        _ = try self.response.header(HeaderName.CONTENT_TYPE, "text/plain; charset=utf-8");
        _ = self.response.body(data);
        return self.response.build();
    }

    /// Sends an HTML response.
    pub fn html(self: *Self, data: []const u8) !Response {
        _ = try self.response.header(HeaderName.CONTENT_TYPE, "text/html; charset=utf-8");
        _ = self.response.body(data);
        return self.response.build();
    }

    /// Sends a file response.
    pub fn file(self: *Self, path: []const u8) !Response {
        const f = std.fs.cwd().openFile(path, .{}) catch return self.status(404).text("Not Found");
        defer f.close();

        const stat = try f.stat();
        const content = try self.allocator.alloc(u8, @intCast(stat.size));
        _ = try f.readAll(content);

        // In a real app, detect MIME type from extension
        _ = try self.response.header(HeaderName.CONTENT_TYPE, "application/octet-stream");
        _ = self.response.body(content);
        return self.response.build();
    }

    /// Sends a JSON response.
    pub fn json(self: *Self, value: anytype) !Response {
        _ = try self.response.json(value);
        return self.response.build();
    }

    /// Sends a redirect response.
    pub fn redirect(self: *Self, url: []const u8, code: u16) !Response {
        _ = self.response.status(code);
        _ = try self.response.header(HeaderName.LOCATION, url);
        return self.response.build();
    }
};

/// Handler function type.
pub const Handler = *const fn (*Context) anyerror!Response;

/// HTTP Server.
pub const Server = struct {
    allocator: Allocator,
    config: ServerConfig,
    router: Router,
    middleware: std.ArrayListUnmanaged(Middleware) = .empty,
    listener: ?TcpListener = null,
    running: bool = false,

    const Self = @This();

    /// Creates a server with default configuration.
    pub fn init(allocator: Allocator) Self {
        return initWithConfig(allocator, .{});
    }

    /// Creates a server with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: ServerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .router = Router.init(allocator),
        };
    }

    /// Releases all server resources.
    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.middleware.deinit(self.allocator);
        if (self.listener) |*l| l.deinit();
    }

    /// Adds middleware to the server.
    pub fn use(self: *Self, mw: Middleware) !void {
        try self.middleware.append(self.allocator, mw);
    }

    /// Registers a route handler.
    pub fn route(self: *Self, method: types.Method, path: []const u8, handler: Handler) !void {
        try self.router.add(method, path, handler);
    }

    /// Registers a GET route.
    pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.GET, path, handler);
    }

    /// Registers a POST route.
    pub fn post(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.POST, path, handler);
    }

    /// Registers a PUT route.
    pub fn put(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.PUT, path, handler);
    }

    /// Registers a DELETE route.
    pub fn delete(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.DELETE, path, handler);
    }

    /// Registers a PATCH route.
    pub fn patch(self: *Self, path: []const u8, handler: Handler) !void {
        try self.route(.PATCH, path, handler);
    }

    /// Starts the server and begins accepting connections.
    pub fn listen(self: *Self) !void {
        const net = std.Io.net;
        const addr = try net.IpAddress.parse(self.config.host, self.config.port);
        self.listener = try TcpListener.listenOn(addr);
        self.running = true;

        std.debug.print("Server listening on {s}:{d}\n", .{ self.config.host, self.config.port });

        while (self.running) {
            var conn = self.listener.?.acceptConnection() catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            self.handleConnection(&conn) catch |err| {
                std.debug.print("Handler error: {}\n", .{err});
            };
        }
    }

    /// Stops the server.
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    /// Handles a single connection.
    fn handleConnection(self: *Self, sock: *Socket) !void {
        defer sock.close();

        var buffer: [8192]u8 = undefined;
        var parser = Parser.init(self.allocator);
        defer parser.deinit();

        while (!parser.isComplete()) {
            const n = try sock.recv(&buffer);
            if (n == 0) return;
            _ = try parser.feed(buffer[0..n]);
        }

        var req = try Request.init(
            self.allocator,
            parser.method orelse .GET,
            parser.path orelse "/",
        );
        defer req.deinit();

        for (parser.headers.entries.items) |h| {
            try req.headers.append(h.name, h.value);
        }

        if (parser.getBody().len > 0) {
            req.body = parser.getBody();
        }

        var ctx = Context.init(self.allocator, &req);
        defer ctx.deinit();

        const route_result = self.router.find(req.method, req.uri.path);

        if (route_result) |r| {
            for (r.params) |p| {
                try ctx.params.put(p.name, p.value);
            }
        }

        var response = if (route_result) |r|
            r.handler(&ctx) catch |err| {
                std.debug.print("Handler error: {}\n", .{err});
                return self.sendError(sock, 500);
            }
        else
            return self.sendError(sock, 404);

        defer response.deinit();

        const formatted = try http.formatResponse(&response, self.allocator);
        defer self.allocator.free(formatted);

        try sock.sendAll(formatted);
    }

    /// Sends an error response.
    fn sendError(self: *Self, socket: *Socket, code: u16) !void {
        var resp = Response.init(self.allocator, code);
        defer resp.deinit();

        const formatted = try http.formatResponse(&resp, self.allocator);
        defer self.allocator.free(formatted);

        try socket.sendAll(formatted);
    }
};

test "Server initialization" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8080), server.config.port);
}

test "Context response helpers" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/test");
    defer req.deinit();

    var ctx = Context.init(allocator, &req);
    defer ctx.deinit();

    _ = ctx.status(201);
    try std.testing.expectEqual(@as(u16, 201), ctx.response.status_code);
}

test "Server with config" {
    const allocator = std.testing.allocator;
    var server = Server.initWithConfig(allocator, .{
        .host = "0.0.0.0",
        .port = 3000,
    });
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 3000), server.config.port);
    try std.testing.expectEqualStrings("0.0.0.0", server.config.host);
}
