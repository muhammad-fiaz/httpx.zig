//! HTTP/2 cleartext transport (h2c prior knowledge, RFC 9113 §3.4).
//!
//! Thin glue driving the Session engine over plain TCP for BOTH roles.
//! TLS+ALPN paths use the same Session from their own callers.
//! Thread-safety: one transport per connection, thread-confined.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const session_mod = @import("connection.zig");
const Session = session_mod.Session;
const hpack = @import("hpack.zig");

pub const Error = error{
    ProtocolViolation,
    HandshakeFailed,
    WriteFailed,
    ReadFailed,
    StreamClosed,
    WindowExhausted,
    OutOfMemory,
};

pub const Header = struct { name: []const u8, value: []const u8 };

fn writeAllRaw(sock: *const tcp.Socket, bytes: []const u8) Error!void {
    sock.writeAll(bytes) catch return error.WriteFailed;
}

// Client

/// One complete exchange result.
pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: Response) void {
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }
};

pub const Client = struct {
    allocator: Allocator,
    sock: tcp.Socket,
    session: *Session,

    /// Handshakes (magic + SETTINGS) and flushes.
    pub fn connect(allocator: Allocator, sock: tcp.Socket) !*Client {
        const c = try allocator.create(Client);
        errdefer allocator.destroy(c);

        const sess = try allocator.create(Session);
        sess.* = try Session.init(allocator, .client, .{});
        errdefer {
            sess.deinit();
            allocator.destroy(sess);
        }

        try sess.startHandshake();
        c.* = .{ .allocator = allocator, .sock = sock, .session = sess };
        try writeAllRaw(&c.sock, sess.outbound.items);
        sess.outbound.clearRetainingCapacity();
        return c;
    }

    pub fn deinit(self: *Client) void {
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.sock.close();
        self.allocator.destroy(self);
    }

    fn pump(self: *Client) Error!void {
        var buf: [16 * 1024]u8 = undefined;
        const n = self.sock.read(&buf) catch return error.ReadFailed;
        if (n == 0) return error.StreamClosed;
        self.session.feed(buf[0..n]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProtocolViolation,
        };
        try self.flush();
    }

    fn flush(self: *Client) Error!void {
        if (self.session.outbound.items.len > 0) {
            try writeAllRaw(&self.sock, self.session.outbound.items);
            self.session.outbound.clearRetainingCapacity();
        }
    }

    /// One full request/response exchange on a fresh stream.
    pub fn request(
        self: *Client,
        method: []const u8,
        path: []const u8,
        extra: []const Header,
    ) !Response {
        const a = self.allocator;
        const sid = try self.session.nextClientStreamId();

        var fields = std.ArrayList(hpack.HeaderField).empty;
        defer fields.deinit(a);
        try fields.append(a, .{ .name = ":method", .value = method });
        try fields.append(a, .{ .name = ":path", .value = path });
        try fields.append(a, .{ .name = ":scheme", .value = "http" });
        try fields.append(a, .{ .name = ":authority", .value = "localhost" });
        for (extra) |h| try fields.append(a, .{ .name = h.name, .value = h.value });

        try self.session.sendHeaders(sid, fields.items, true);
        try writeAllRaw(&self.sock, self.session.outbound.items);
        self.session.outbound.clearRetainingCapacity();

        // Collectors wired through session callbacks.
        var status: u16 = 500;
        var headers = std.ArrayList(Header).empty;
        errdefer headers.deinit(a);
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(a);
        var done = false;

        const Collector = struct {
            sid: u31,
            done: *bool,
            status: *u16,
            headers: *std.ArrayList(Header),
            body: *std.ArrayList(u8),
            a: Allocator,

            fn onHeaders(ctx: ?*anyopaque, s: u31, flds: []hpack.HeaderField, end_stream: bool) anyerror!void {
                const self_: *@This() = @ptrCast(@alignCast(ctx.?));
                if (s != self_.sid) return;
                for (flds) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        self_.status.* = std.fmt.parseInt(u16, f.value, 10) catch 500;
                        continue;
                    }
                    try self_.headers.append(self_.a, .{
                        .name = try self_.a.dupe(u8, f.name),
                        .value = try self_.a.dupe(u8, f.value),
                    });
                }
                if (end_stream) self_.done.* = true;
            }
            fn onData(ctx: ?*anyopaque, s: u31, data: []const u8) anyerror!void {
                const self_: *@This() = @ptrCast(@alignCast(ctx.?));
                if (s != self_.sid) return;
                try self_.body.appendSlice(self_.a, data);
            }
            fn onEnd(ctx: ?*anyopaque, s: u31) anyerror!void {
                const self_: *@This() = @ptrCast(@alignCast(ctx.?));
                if (s != self_.sid) return;
                self_.done.* = true;
            }
        };

        var col = Collector{
            .sid = sid,
            .done = &done,
            .status = &status,
            .headers = &headers,
            .body = &body,
            .a = a,
        };
        self.session.cbs = .{
            .ctx = &col,
            .onHeaders = Collector.onHeaders,
            .onData = Collector.onData,
            .onStreamEnd = Collector.onEnd,
        };
        defer self.session.cbs = .{};

        while (!done and !self.session.closed and !self.session.goaway_received) {
            try self.pump();
        }
        if (!done) return error.StreamClosed;

        return .{
            .status = status,
            .headers = try headers.toOwnedSlice(a),
            .body = try body.toOwnedSlice(a),
            .allocator = a,
        };
    }
};

// Server: maps HTTP/2 streams onto a handler over ONE connection (h2c).

/// Handler output for one request.
pub const HandlerResponse = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const HandlerFn = *const fn (
    ctx: ?*anyopaque,
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
) anyerror!HandlerResponse;

/// Per-stream accumulation; the session serializes callbacks on one
/// thread, and responses are emitted from the main loop (never reentrant).
const ServerCtx = struct {
    arena: Allocator,
    sid: u31 = 0,
    method: std.ArrayList(u8) = .empty,
    path: std.ArrayList(u8) = .empty,
    hdrs: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    dispatched: bool = false,
    responded: bool = true, // true until HEADERS open a new request

    fn resetFor(self: *ServerCtx, sid: u31) void {
        self.sid = sid;
        self.method.clearRetainingCapacity();
        self.path.clearRetainingCapacity();
        self.hdrs.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.dispatched = false;
        self.responded = false;
    }
};

fn svrOnHeaders(ctx: ?*anyopaque, sid: u31, flds: []hpack.HeaderField, end_stream: bool) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    s.resetFor(sid);
    for (flds) |f| {
        if (std.mem.eql(u8, f.name, ":method")) {
            s.method.appendSlice(s.arena, f.value) catch {};
        } else if (std.mem.eql(u8, f.name, ":path")) {
            s.path.appendSlice(s.arena, f.value) catch {};
        } else if (!std.mem.startsWith(u8, f.name, ":")) {
            s.hdrs.append(s.arena, .{
                .name = s.arena.dupe(u8, f.name) catch return,
                .value = s.arena.dupe(u8, f.value) catch return,
            }) catch {};
        }
    }
    // A request with no body ends at the HEADERS frame itself.
    if (end_stream) s.dispatched = true;
}

fn svrOnData(ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    if (sid != s.sid) return;
    s.body.appendSlice(s.arena, data) catch {};
}

/// Serves h2c requests on an accepted socket until close/GOAWAY.
pub fn serveConnection(
    allocator: Allocator,
    sock: *tcp.Socket,
    handler: HandlerFn,
    handler_ctx: ?*anyopaque,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var session = try Session.init(allocator, .server, .{});
    defer session.deinit();
    try session.startHandshake();
    sock.writeAll(session.outbound.items) catch return error.WriteFailed;
    session.outbound.clearRetainingCapacity();

    var sc = ServerCtx{ .arena = arena_state.allocator() };
    session.cbs = .{
        .ctx = &sc,
        .onHeaders = svrOnHeaders,
        .onData = svrOnData,
    };

    var buf: [16 * 1024]u8 = undefined;
    while (!session.closed and !session.goaway_received) {
        const n = sock.read(&buf) catch break;
        if (n == 0) break;
        session.feed(buf[0..n]) catch break;

        if (sc.dispatched and !sc.responded) {
            sc.responded = true;
            const resp = handler(
                handler_ctx,
                sc.method.items,
                sc.path.items,
                sc.hdrs.items,
                sc.body.items,
            ) catch HandlerResponse{ .status = 500 };

            var out_fields = std.ArrayList(hpack.HeaderField).empty;
            defer out_fields.deinit(allocator);
            var st_buf: [8]u8 = undefined;
            var cl_buf: [8]u8 = undefined;
            const st = std.fmt.bufPrint(&st_buf, "{d}", .{resp.status}) catch "500";
            const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{resp.body.len}) catch "0";
            out_fields.append(allocator, .{ .name = ":status", .value = st }) catch break;
            out_fields.append(allocator, .{ .name = "content-length", .value = cl }) catch break;
            for (resp.headers) |h| {
                out_fields.append(allocator, .{ .name = h.name, .value = h.value }) catch break;
            }

            session.sendHeaders(sc.sid, out_fields.items, false) catch break;
            _ = session.sendData(sc.sid, resp.body, true) catch {};
        }

        if (session.outbound.items.len > 0) {
            sock.writeAll(session.outbound.items) catch break;
            session.outbound.clearRetainingCapacity();
        }
    }
}

// Tests: real client <-> server over loopback TCP

test "http2 client and server exchange over real tcp (h2c)" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return; // skip w/o network
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/h2")) {
                return .{ .status = 200, .body = "hello-h2" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io: std.Io) void {
            var conn = lst.accept(io) catch return;
            defer conn.close();
            serveConnection(std.heap.page_allocator, &conn, H.handle, null) catch {};
        }
    };
    const t = std.Thread.spawn(.{}, Acceptor.run, .{ &l, ctx.io }) catch return;
    defer t.join();

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);

    var hc = Client.connect(a, sock) catch |err| {
        sock.close();
        return err;
    };
    defer hc.deinit();

    const r = try hc.request("GET", "/h2", &[_]Header{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("hello-h2", r.body);

    // Second request on the SAME connection proves multiplexing-ready reuse.
    const r404 = try hc.request("GET", "/missing", &[_]Header{});
    defer r404.deinit();
    try std.testing.expectEqual(@as(u16, 404), r404.status);
}
