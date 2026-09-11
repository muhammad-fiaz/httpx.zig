//! HTTP/2 transport (RFC 9113): cleartext h2c prior knowledge plus TLS.
//!
//! Thin glue driving the Session engine over plain TCP or a native TLS
//! session for BOTH roles. The Session itself is transport-agnostic
//! (outbound buffer + feed()); this layer only moves bytes.
//!
//! References:
//!   - RFC 9113 Section 3.4 — HTTP/2 Connection Preface (h2c)
//!   - RFC 9113 Section 3.3 — Starting HTTP/2 for Prior Knowledge
//!   - RFC 9113 Section 8.1 — Field Requirements (lowercase names)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const clock = @import("../../common/clock.zig");
const session_mod = @import("connection.zig");
const Session = session_mod.Session;
const hpack = @import("hpack.zig");
const tlsClientMod = @import("../tls/tcpClient.zig");
const tlsServerMod = @import("../tls/tcpTls.zig");
const tlsSessionMod = @import("../tls/session.zig");
pub const Error = error{
    ProtocolViolation,
    HandshakeFailed,
    WriteFailed,
    ReadFailed,
    StreamClosed,
    WindowExhausted,
    ResponseTooLarge,
    OutOfMemory,
};

pub const maxResponseBodySize: usize = 64 * 1024 * 1024;
pub const MAX_REQUEST_BODY_SIZE: usize = 16 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8 };

/// Transport stream: plain TCP or an established native TLS session.
/// Both expose read/writeAll/close with identical ownership (the Client
/// or serve loop owns the underlying socket through the stream).
pub const Stream = union(enum) {
    tcp: tcp.Socket,
    /// Client side of a native TLS session (h2 negotiated via ALPN).
    tls: *tlsClientMod.TlsClientConn,
    /// Server side of a native TLS session.
    tlsServer: *tlsServerMod.TlsServerConn,

    fn read(self: *Stream, buf: []u8) !usize {
        return switch (self.*) {
            .tcp => |*s| try s.read(buf),
            .tls => |t| try t.read(buf),
            .tlsServer => |t| try t.read(buf),
        };
    }

    fn writeAll(self: *Stream, bytes: []const u8) !void {
        switch (self.*) {
            .tcp => |*s| try s.writeAll(bytes),
            .tls => |t| try t.writeAll(bytes),
            .tlsServer => |t| try t.writeAll(bytes),
        }
    }

    fn close(self: *Stream) void {
        switch (self.*) {
            .tcp => |*s| s.close(),
            .tls => |t| {
                t.deinit();
                t.close();
            },
            .tlsServer => |t| {
                t.deinit();
                t.socket.close();
            },
        }
    }
};

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
    stream: Stream,
    session: *Session,

    /// Handshakes (magic + SETTINGS) and flushes over plain TCP.
    pub fn connect(allocator: Allocator, sock: tcp.Socket) !*Client {
        return connectStream(allocator, .{ .tcp = sock });
    }

    /// Handshakes (magic + SETTINGS) and flushes over an established
    /// native TLS session (h2 negotiated via ALPN).
    pub fn connectTls(allocator: Allocator, tlsConn: *tlsClientMod.TlsClientConn) !*Client {
        return connectStream(allocator, .{ .tls = tlsConn });
    }

    fn connectStream(allocator: Allocator, stream: Stream) !*Client {
        const c = try allocator.create(Client);
        errdefer allocator.destroy(c);

        const sess = try allocator.create(Session);
        sess.* = try Session.init(allocator, .client, .{});
        errdefer {
            sess.deinit();
            allocator.destroy(sess);
        }

        try sess.startHandshake();
        c.* = .{ .allocator = allocator, .stream = stream, .session = sess };
        try c.flush();
        return c;
    }

    pub fn deinit(self: *Client) void {
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.stream.close();
        self.allocator.destroy(self);
    }

    fn pump(self: *Client) Error!void {
        var buf: [16 * 1024]u8 = undefined;
        const n = self.stream.read(&buf) catch return error.ReadFailed;
        if (n == 0) return error.StreamClosed;
        self.session.feed(buf[0..n]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProtocolViolation,
        };
        try self.flush();
    }

    fn flush(self: *Client) Error!void {
        if (self.session.outbound.items.len > 0) {
            self.stream.writeAll(self.session.outbound.items) catch return error.WriteFailed;
            self.session.outbound.clearRetainingCapacity();
        }
    }

    /// One full request/response exchange on a fresh stream.
    /// `scheme`/`authority` are caller-supplied (:scheme https and the
    /// real host for TLS; http/localhost for cleartext loopback tests).
    pub fn request(
        self: *Client,
        method: []const u8,
        path: []const u8,
        extra: []const Header,
        scheme: []const u8,
        authority: []const u8,
    ) !Response {
        const a = self.allocator;
        const sid = try self.session.nextClientStreamId();

        var fields = std.ArrayList(hpack.HeaderField).empty;
        defer fields.deinit(a);
        try fields.append(a, .{ .name = ":method", .value = method });
        try fields.append(a, .{ .name = ":path", .value = path });
        try fields.append(a, .{ .name = ":scheme", .value = scheme });
        try fields.append(a, .{ .name = ":authority", .value = authority });
        for (extra) |h| try fields.append(a, .{ .name = h.name, .value = h.value });

        try self.session.sendHeaders(sid, fields.items, true);
        try self.flush();

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

            fn onHeaders(ctx: ?*anyopaque, s: u31, flds: []hpack.HeaderField, endStream: bool) anyerror!void {
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
                if (endStream) self_.done.* = true;
            }
            fn onData(ctx: ?*anyopaque, s: u31, data: []const u8) anyerror!void {
                const self_: *@This() = @ptrCast(@alignCast(ctx.?));
                if (s != self_.sid) return;
                if (self_.body.items.len > maxResponseBodySize -| data.len)
                    return error.ResponseTooLarge;
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

        while (!done and !self.session.closed and !self.session.goawayReceived) {
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

/// Heap box for a TLS-backed H2 session. `TlsClientConn` borrows its
/// socket, and pooled connections outlive any stack frame, so both live
/// together on the heap with a stable address.
pub const TlsBox = struct {
    sock: tcp.Socket,
    conn: tlsClientMod.TlsClientConn,
};

/// A pool-owned H2 connection: heap-stable transport boxes plus the
/// session client. At most one borrower uses it at a time (the pool
/// transfers exclusive ownership on acquire/release), so no per-request
/// locking is needed inside the session. Free with `deinit()`.
pub const PooledConn = struct {
    allocator: Allocator,
    tlsBox: ?*TlsBox,
    client: *Client,
    /// Wall-clock creation time: the pool measures H2 lifetime from
    /// here (connection-lifetime ledger), not from parking.
    createdAtMs: i64,

    /// Wrap a connected cleartext socket (takes ownership).
    pub fn wrapPlain(allocator: Allocator, sock: tcp.Socket) !*PooledConn {
        const self = try allocator.create(PooledConn);
        errdefer allocator.destroy(self);
        const hc = try Client.connect(allocator, sock);
        self.* = .{ .allocator = allocator, .tlsBox = null, .client = hc, .createdAtMs = clock.millisNow() };
        return self;
    }

    /// Wrap a completed TLS box (takes ownership). The box must already
    /// hold a handshaked connection whose socket borrow points at
    /// `box.sock`.
    pub fn wrapTls(allocator: Allocator, box: *TlsBox) !*PooledConn {
        const self = try allocator.create(PooledConn);
        errdefer allocator.destroy(self);
        const hc = Client.connectTls(allocator, &box.conn) catch |err| {
            box.conn.deinit();
            box.sock.close();
            allocator.destroy(box);
            return err;
        };
        self.* = .{ .allocator = allocator, .tlsBox = box, .client = hc, .createdAtMs = clock.millisNow() };
        return self;
    }

    pub fn deinit(self: *PooledConn) void {
        // Client.deinit closes the stream exactly once (plain socket, or
        // TLS session + its borrowed socket); only the boxes remain.
        self.client.deinit();
        if (self.tlsBox) |box| self.allocator.destroy(box);
        self.allocator.destroy(self);
    }

    /// True when another request may run on this session: transport
    /// open, no GOAWAY either way. HPACK tables are connection-scoped
    /// per RFC 9113, so reuse is also compression-correct.
    pub fn isReusable(self: *const PooledConn) bool {
        const s = self.client.session;
        if (s.closed or s.goawayReceived or s.goawaySent) return false;
        return true;
    }

    /// One full request/response exchange on a fresh stream. Exclusive
    /// use is the caller's contract (enforced by pool ownership).
    pub fn request(
        self: *PooledConn,
        method: []const u8,
        path: []const u8,
        extra: []const Header,
        scheme: []const u8,
        authority: []const u8,
    ) !Response {
        return self.client.request(method, path, extra, scheme, authority);
    }

    /// Takes ownership of a captured resumption session from the
    /// underlying TLS connection, if any (null for cleartext or when
    /// capture is disabled). Call before parking to feed the client's
    /// session cache. Caller owns the result.
    pub fn takeSession(self: *PooledConn) ?tlsSessionMod.ClientSession {
        const box = self.tlsBox orelse return null;
        return box.conn.takeCapturedSession();
    }
};

// Server: maps HTTP/2 streams onto a handler over ONE connection (h2c).

/// Handler output for one request.
///
/// Ownership: `headers`/`body` must remain valid until the caller finishes
/// sending the response (the server loop consumes them synchronously before
/// invoking the handler again). Handlers backed by a per-request arena must
/// duplicate response data into a longer-lived allocator.
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

fn svrOnHeaders(ctx: ?*anyopaque, sid: u31, flds: []hpack.HeaderField, endStream: bool) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    s.resetFor(sid);
    for (flds) |f| {
        if (std.mem.eql(u8, f.name, ":method")) {
            try s.method.appendSlice(s.arena, f.value);
        } else if (std.mem.eql(u8, f.name, ":path")) {
            try s.path.appendSlice(s.arena, f.value);
        } else if (!std.mem.startsWith(u8, f.name, ":")) {
            const name = try s.arena.dupe(u8, f.name);
            errdefer s.arena.free(name);
            const value = try s.arena.dupe(u8, f.value);
            s.hdrs.append(s.arena, .{
                .name = name,
                .value = value,
            }) catch return error.OutOfMemory;
        }
    }
    // A request with no body ends at the HEADERS frame itself.
    if (endStream) s.dispatched = true;
}

fn svrOnData(ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    if (sid != s.sid) return;
    if (s.body.items.len > MAX_REQUEST_BODY_SIZE -| data.len)
        return error.RequestTooLarge;
    try s.body.appendSlice(s.arena, data);
}

/// Serves h2 requests on an established native TLS session until
/// close/GOAWAY. Same dispatch as serveConnection; only the byte mover
/// differs (TLS records instead of TCP).
pub fn serveTlsConnection(
    allocator: Allocator,
    tlsConn: *tlsServerMod.TlsServerConn,
    handler: HandlerFn,
    handlerCtx: ?*anyopaque,
) !void {
    var stream = Stream{ .tlsServer = tlsConn };
    try serveStream(allocator, &stream, handler, handlerCtx);
}

/// Serves h2c requests on an accepted socket until close/GOAWAY.
pub fn serveConnection(
    allocator: Allocator,
    sock: *tcp.Socket,
    handler: HandlerFn,
    handlerCtx: ?*anyopaque,
) !void {
    var stream = Stream{ .tcp = sock.* };
    try serveStream(allocator, &stream, handler, handlerCtx);
}

fn serveStream(
    allocator: Allocator,
    stream: *Stream,
    handler: HandlerFn,
    handlerCtx: ?*anyopaque,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var session = try Session.init(allocator, .server, .{});
    defer session.deinit();
    try session.startHandshake();
    stream.writeAll(session.outbound.items) catch return error.WriteFailed;
    session.outbound.clearRetainingCapacity();

    var sc = ServerCtx{ .arena = arena_state.allocator() };
    session.cbs = .{
        .ctx = &sc,
        .onHeaders = svrOnHeaders,
        .onData = svrOnData,
    };

    var buf: [16 * 1024]u8 = undefined;
    while (!session.closed and !session.goawayReceived) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        session.feed(buf[0..n]) catch break;

        if (sc.dispatched and !sc.responded) {
            sc.responded = true;
            const resp = handler(
                handlerCtx,
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
            _ = session.sendData(sc.sid, resp.body, true) catch break;
        }

        if (session.outbound.items.len > 0) {
            stream.writeAll(session.outbound.items) catch break;
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
    const thread = std.Thread.spawn(.{}, Acceptor.run, .{ &l, ctx.io }) catch return;
    defer thread.join();

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);

    var hc = Client.connect(a, sock) catch |err| {
        sock.close();
        return err;
    };
    defer hc.deinit();

    const r = try hc.request("GET", "/h2", &[_]Header{}, "http", "localhost");
    defer r.deinit();

    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("hello-h2", r.body);

    // Second request on the SAME connection proves multiplexing-ready reuse.
    const r404 = try hc.request("GET", "/missing", &[_]Header{}, "http", "localhost");
    defer r404.deinit();
    try std.testing.expectEqual(@as(u16, 404), r404.status);
}

test "http2 over native tls loopback negotiates h2 via alpn" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return; // skip w/o network
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const cert_pem = @embedFile("../tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../tls/testdata/localhost_key.pem");

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/h2s")) {
                return .{ .status = 200, .body = "hello-h2-tls" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var conn = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer conn.close();
            var srv = tlsServerMod.TlsServer.init(.{
                .allocator = std.heap.page_allocator,
                .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
            });
            var tls_conn = srv.handshake(io2, &conn) catch |e| {
                out.* = e;
                return;
            };
            defer tls_conn.deinit();
            if (tls_conn.alpn != .h2) {
                out.* = error.AlpnMismatch;
                return;
            }
            serveTlsConnection(std.heap.page_allocator, &tls_conn, H.handle, null) catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const thread = std.Thread.spawn(.{}, Acceptor.run, .{ &l, ctx.io, &result }) catch return;

    var sock = try tcp.connect(ctx.io, "127.0.0.1", port);
    errdefer sock.close();
    var tls_cli = tlsClientMod.TlsClient.init(.{
        .allocator = a,
        .verify = .caBundle,
        .caPem = cert_pem,
        .alpnProtocols = &.{"h2"},
    });
    var tls_conn = try tls_cli.handshake(ctx.io, &sock, "127.0.0.1");
    {
        // TlsClientConn borrows the socket; the block scope ends the
        // session (and closes the socket) before joining below, so the
        // serve loop observes EOF and exits instead of deadlocking.
        var hc = try Client.connectTls(a, &tls_conn);
        defer hc.deinit();

        const negotiated = tls_conn.alpn orelse return error.AlpnMissing;
        try std.testing.expect(negotiated == .h2);
        const r = try hc.request("GET", "/h2s", &[_]Header{}, "https", "127.0.0.1");
        defer r.deinit();
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("hello-h2-tls", r.body);
    }

    thread.join();
    try std.testing.expect(result == null);
}
