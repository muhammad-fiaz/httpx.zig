//! HTTP/2 transport (RFC 9113): cleartext h2c prior knowledge plus TLS.
//!
//! Thin glue driving the Session engine over plain TCP or a native TLS
//! session for BOTH roles. The Session itself is transport-agnostic
//! (outbound buffer + feed()); this layer only moves bytes.
//!
//! The server side is fully multiplexed: every concurrent stream keeps
//! its own request state, responses are emitted per stream, and a body
//! larger than the flow-control window is drained as WINDOW_UPDATE
//! frames arrive. The client keeps a per-stream response registry, so
//! several requests can be in flight on one connection.
//!
//! References:
//!   - RFC 9113 Section 3.4 — HTTP/2 Connection Preface (h2c)
//!   - RFC 9113 Section 3.3 — Starting HTTP/2 for Prior Knowledge
//!   - RFC 9113 Section 8.1 — Field Requirements (lowercase names)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../../sockets/tcp.zig");
const clock = @import("../../common/clock.zig");
const sessionMod = @import("connection.zig");
const Session = sessionMod.Session;
const hpack = @import("hpack.zig");
const tlsClientMod = @import("../tls/tlsClient.zig");
const tlsServerMod = @import("../tls/tlsServer.zig");
const tlsSessionMod = @import("../tls/tlsSession.zig");
pub const Error = error{
    ProtocolViolation,
    HandshakeFailed,
    WriteFailed,
    ReadFailed,
    StreamClosed,
    WindowExhausted,
    ResponseTooLarge,
    RequestTooLarge,
    OutOfMemory,
} || sessionMod.Error;

pub const maxResponseBodySize: usize = 64 * 1024 * 1024;
pub const MAX_REQUEST_BODY_SIZE: usize = 16 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8 };

/// Byte mover used by the server loop. Keeping it abstract lets the
/// high-level server reuse the same multiplexing logic over its own
/// socket wrapper (which adds read/write timeouts).
pub const ByteStream = struct {
    ctx: ?*anyopaque = null,
    readFn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    writeAllFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,

    pub fn read(self: ByteStream, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, buf);
    }

    pub fn writeAll(self: ByteStream, bytes: []const u8) anyerror!void {
        return self.writeAllFn(self.ctx, bytes);
    }
};

/// Transport stream: plain TCP or an established native TLS session.
/// Both expose read/writeAll/close with identical ownership (the Client
/// or serve loop owns the underlying socket through the stream).
pub const Stream = union(enum) {
    tcp: tcp.Socket,
    /// Client side of a native TLS session (h2 negotiated via ALPN).
    tls: *tlsClientMod.Client.Connection,
    /// Server side of a native TLS session.
    tlsServer: *tlsServerMod.Server.Connection,

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
            // Client connections fully tear down (socket included).
            .tls => |t| t.deinit(),
            .tlsServer => |t| {
                t.deinit();
                t.socket.close();
            },
        }
    }

    fn byteStream(self: *Stream) ByteStream {
        return .{ .ctx = self, .readFn = streamRead, .writeAllFn = streamWriteAll };
    }
};

fn streamRead(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
    const s: *Stream = @ptrCast(@alignCast(ctx.?));
    return s.read(buf);
}

fn streamWriteAll(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
    const s: *Stream = @ptrCast(@alignCast(ctx.?));
    return s.writeAll(bytes);
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

/// Per-stream response accumulator. The session callbacks dispatch by
/// stream id, so several requests may be in flight at once.
/// Duplicates a header field into `list`, freeing the copies if either
/// allocation or the append fails. The caller owns the appended field.
fn appendCopiedHeader(a: Allocator, list: *std.ArrayList(Header), name: []const u8, value: []const u8) !void {
    const ownedName = try a.dupe(u8, name);
    errdefer a.free(ownedName);
    const ownedValue = try a.dupe(u8, value);
    errdefer a.free(ownedValue);
    try list.append(a, .{ .name = ownedName, .value = ownedValue });
}

const RequestState = struct {
    sid: u31,
    allocator: Allocator,
    status: u16 = 500,
    headers: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// The final response header block was consumed; later blocks are
    /// trailers and must not be merged into response headers.
    headersSeen: bool = false,
    /// Response fully received (END_STREAM seen).
    done: bool = false,
    /// Body exceeded the configured limit.
    tooLarge: bool = false,
    /// The peer reset the stream.
    reset: bool = false,
    resetCode: u32 = 0,
    maxBytes: usize,

    fn deinit(self: *RequestState) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn onHeaders(self: *RequestState, flds: []hpack.HeaderField, endStream: bool) !void {
        var status: u16 = 0;
        for (flds) |f| {
            if (std.mem.eql(u8, f.name, ":status")) {
                status = std.fmt.parseInt(u16, f.value, 10) catch 0;
            }
        }
        // Informational blocks precede the final response; later blocks
        // are trailers. Neither may overwrite response headers, in
        // particular Content-Encoding (RFC 9110 Section 6.5). Trailers
        // still carry END_STREAM, so they complete the response.
        if (self.headersSeen) {
            if (endStream) self.done = true;
            return;
        }
        if (status < 200) return;
        self.status = status;
        self.headersSeen = true;
        for (flds) |f| {
            if (f.name.len > 0 and f.name[0] == ':') continue;
            try appendCopiedHeader(self.allocator, &self.headers, f.name, f.value);
        }
        if (endStream) self.done = true;
    }

    fn onData(self: *RequestState, data: []const u8) !void {
        if (data.len > self.maxBytes -| self.body.items.len) {
            self.tooLarge = true;
            return;
        }
        try self.body.appendSlice(self.allocator, data);
    }
};

fn parseContentLength(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidContentLength;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
    }
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidContentLength;
}

pub const Client = struct {
    allocator: Allocator,
    stream: Stream,
    session: *Session,
    /// In-flight requests keyed by stream id (multiplexing support).
    pending: std.AutoHashMap(u31, *RequestState),

    /// Handshakes (magic + SETTINGS) and flushes over plain TCP.
    pub fn connect(allocator: Allocator, sock: tcp.Socket) !*Client {
        return connectStream(allocator, .{ .tcp = sock });
    }

    /// Handshakes (magic + SETTINGS) and flushes over an established
    /// native TLS session (h2 negotiated via ALPN).
    pub fn connectTls(allocator: Allocator, tlsConn: *tlsClientMod.Client.Connection) !*Client {
        return connectStream(allocator, .{ .tls = tlsConn });
    }

    fn connectStream(allocator: Allocator, stream: Stream) !*Client {
        const c = try allocator.create(Client);
        errdefer allocator.destroy(c);

        const sess = try allocator.create(Session);
        errdefer {
            sess.deinit();
            allocator.destroy(sess);
        }

        c.* = .{
            .allocator = allocator,
            .stream = stream,
            .session = sess,
            .pending = std.AutoHashMap(u31, *RequestState).init(allocator),
        };
        sess.* = try Session.init(allocator, .client, .{});
        sess.cbs = .{
            .ctx = c,
            .onHeaders = clientOnHeaders,
            .onData = clientOnData,
            .onStreamEnd = clientOnStreamEnd,
            .onReset = clientOnReset,
        };
        try sess.startHandshake();
        try c.flush();
        return c;
    }

    pub fn deinit(self: *Client) void {
        var it = self.pending.valueIterator();
        while (it.next()) |sp| sp.*.deinit();
        self.pending.deinit();
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.stream.close();
        self.allocator.destroy(self);
    }

    fn clientOnHeaders(ctx: ?*anyopaque, sid: u31, flds: []hpack.HeaderField, endStream: bool) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const st = self.pending.get(sid) orelse return;
        try st.onHeaders(flds, endStream);
    }

    fn clientOnData(ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const st = self.pending.get(sid) orelse return;
        try st.onData(data);
    }

    fn clientOnStreamEnd(ctx: ?*anyopaque, sid: u31) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const st = self.pending.get(sid) orelse return;
        st.done = true;
    }

    fn clientOnReset(ctx: ?*anyopaque, sid: u31, code: u32) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const st = self.pending.get(sid) orelse return;
        st.reset = true;
        st.resetCode = code;
        st.done = true;
    }

    /// Reads one chunk from the transport and feeds it to the session.
    /// Public so callers can drive a connection whose flow-control window
    /// is exhausted without consuming a response.
    pub fn pump(self: *Client) Error!void {
        var buf: [16 * 1024]u8 = undefined;
        const n = self.stream.read(&buf) catch return error.ReadFailed;
        if (n == 0) return error.StreamClosed;
        self.session.feed(buf[0..n]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // A protocol violation queues a GOAWAY: flush it so the
                // peer learns why the connection ended.
                self.flush() catch {};
                return error.ProtocolViolation;
            },
        };
        try self.flush();
    }

    fn flush(self: *Client) Error!void {
        if (self.session.outbound.items.len > 0) {
            self.stream.writeAll(self.session.outbound.items) catch return error.WriteFailed;
            self.session.outbound.clearRetainingCapacity();
        }
    }

    /// Starts a request on a fresh stream without waiting for the
    /// response. Several requests may be in flight at the same time.
    pub fn beginRequest(
        self: *Client,
        method: []const u8,
        path: []const u8,
        extra: []const Header,
        scheme: []const u8,
        authority: []const u8,
        reqBody: ?[]const u8,
        maxBytes: usize,
    ) !u31 {
        const a = self.allocator;
        const sid = try self.session.nextClientStreamId();

        const rstate = try a.create(RequestState);
        errdefer rstate.deinit();
        rstate.* = .{
            .sid = sid,
            .allocator = a,
            .maxBytes = @min(maxBytes, maxResponseBodySize),
        };
        try self.pending.put(sid, rstate);
        errdefer _ = self.pending.remove(sid);

        const isConnect = std.mem.eql(u8, method, "CONNECT");
        const bodyLen: ?u64 = if (reqBody) |body| body.len else null;
        var clBuf: [20]u8 = undefined;
        var clValue: ?[]const u8 = null;
        if (bodyLen) |n| {
            clValue = clBuf[0..std.fmt.printInt(&clBuf, n, 10, .lower, .{})];
        }
        var explicitZeroLength = false;

        var fields = std.ArrayList(hpack.HeaderField).empty;
        defer fields.deinit(a);
        try fields.append(a, .{ .name = ":method", .value = method });
        if (!isConnect) {
            try fields.append(a, .{ .name = ":path", .value = path });
            try fields.append(a, .{ .name = ":scheme", .value = scheme });
        }
        try fields.append(a, .{ .name = ":authority", .value = authority });
        for (extra) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
                const declared = parseContentLength(h.value) catch return error.ProtocolViolation;
                if (bodyLen) |actual| {
                    if (declared != actual) return error.ProtocolViolation;
                } else if (declared == 0) {
                    // A body-less request may explicitly declare zero length,
                    // but a non-zero declaration would frame a missing body.
                    explicitZeroLength = true;
                } else {
                    return error.ProtocolViolation;
                }
                // The transport emits the authoritative value below.
                continue;
            }
            try fields.append(a, .{ .name = h.name, .value = h.value });
        }
        if (clValue) |cl| {
            try fields.append(a, .{ .name = "content-length", .value = cl });
        } else if (explicitZeroLength) {
            try fields.append(a, .{ .name = "content-length", .value = "0" });
        }

        const hasReqBody = bodyLen != null and bodyLen.? > 0;

        try self.session.sendHeaders(sid, fields.items, !hasReqBody);
        try self.flush();
        return sid;
    }
    /// Sends the remaining request body of a stream started with
    /// `beginRequest`. Returns true when the body is fully written.
    pub fn sendRequestBody(self: *Client, sid: u31, body: []const u8, sent: *usize) Error!bool {
        while (sent.* < body.len) {
            const n = try self.session.sendData(sid, body[sent.*..], true);
            sent.* += n;
            try self.flush();
            if (n == 0) return false; // flow-control blocked
            if (self.state(sid)) |st| {
                if (st.done) return true; // peer answered early
            }
        }
        return true;
    }

    fn state(self: *Client, sid: u31) ?*RequestState {
        return self.pending.get(sid);
    }

    /// Waits until the response for `sid` completes and returns it.
    pub fn awaitResponse(self: *Client, sid: u31) !Response {
        const a = self.allocator;
        while (true) {
            const st = self.pending.get(sid) orelse return error.StreamClosed;
            if (st.done) break;
            if (st.tooLarge) {
                self.cancelStream(sid);
                self.dropStream(sid);
                return error.ResponseTooLarge;
            }
            if (self.session.closed) {
                self.dropStream(sid);
                return error.StreamClosed;
            }
            if (self.session.goawayReceived) {
                // The peer will not process streams above its last id.
                if (self.session.goawayLastStream) |last| {
                    if (sid > last) {
                        self.dropStream(sid);
                        return error.StreamClosed;
                    }
                }
            }
            try self.pump();
        }

        const st = self.pending.get(sid) orelse return error.StreamClosed;
        if (st.tooLarge) {
            self.cancelStream(sid);
            self.dropStream(sid);
            return error.ResponseTooLarge;
        }
        if (st.reset) {
            self.dropStream(sid);
            return error.StreamClosed;
        }
        const status = st.status;
        const headers = try st.headers.toOwnedSlice(a);
        errdefer a.free(headers);
        const body = try st.body.toOwnedSlice(a);
        st.headers = .empty;
        st.body = .empty;
        self.dropStream(sid);
        return .{
            .status = status,
            .headers = headers,
            .body = body,
            .allocator = a,
        };
    }

    fn dropStream(self: *Client, sid: u31) void {
        if (self.pending.fetchRemove(sid)) |kv| kv.value.deinit();
    }

    fn cancelStream(self: *Client, sid: u31) void {
        self.session.sendRstStream(sid, .cancel) catch return;
        self.flush() catch {};
    }

    /// One full request/response exchange on a fresh stream.
    /// `scheme`/`authority` are caller-supplied (:scheme https and the
    /// real host for TLS; http/localhost for cleartext loopback tests).
    /// `body`: optional request payload. If non-empty, transmitted via DATA frames.
    pub fn request(
        self: *Client,
        method: []const u8,
        path: []const u8,
        extra: []const Header,
        scheme: []const u8,
        authority: []const u8,
        reqBody: ?[]const u8,
        maxBytes: usize,
    ) !Response {
        const sid = try self.beginRequest(method, path, extra, scheme, authority, reqBody, maxBytes);
        return self.exchange(sid, reqBody) catch |e| {
            // Every error path abandons this exchange; release the
            // per-stream buffers even if the failure predates awaitResponse.
            self.dropStream(sid);
            return e;
        };
    }

    fn exchange(self: *Client, sid: u31, reqBody: ?[]const u8) !Response {
        var bodyComplete = true;
        if (reqBody) |body| {
            if (body.len > 0) {
                var sent: usize = 0;
                while (true) {
                    const complete = try self.sendRequestBody(sid, body, &sent);
                    if (complete) {
                        bodyComplete = sent == body.len;
                        break;
                    }
                    // Flow control blocked: read until the peer opens the
                    // window (or answers early).
                    const st = self.state(sid);
                    if (st != null and st.?.done) {
                        bodyComplete = false;
                        break;
                    }
                    try self.pump();
                }
            }
        }
        const resp = try self.awaitResponse(sid);
        if (!bodyComplete) {
            // The peer answered before consuming the upload. Cancel the
            // half-closed request side so the stream can be reaped instead
            // of staying open for the connection lifetime.
            self.cancelStream(sid);
        }
        return resp;
    }
};

/// Heap box for a TLS-backed H2 session. The TLS connection borrows
/// its socket, and pooled connections outlive any stack frame, so both
/// live together on the heap with a stable address.
pub const TlsBox = struct {
    sock: tcp.Socket,
    conn: tlsClientMod.Client.Connection,
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
        self.* = .{ .allocator = allocator, .tlsBox = null, .client = hc, .createdAtMs = clock.monotonicMillis() };
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
            allocator.destroy(box);
            return err;
        };
        self.* = .{ .allocator = allocator, .tlsBox = box, .client = hc, .createdAtMs = clock.monotonicMillis() };
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
        reqBody: ?[]const u8,
        maxBytes: usize,
    ) !Response {
        return self.client.request(method, path, extra, scheme, authority, reqBody, maxBytes);
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

/// Optional response transformation applied after the handler returns
/// (content coding, HEAD handling, ...).
///
/// The hook may:
///   * append header fields to `extra` (the strings must stay valid
///     until the response is written, e.g. connection-lifetime arena),
///   * return a replacement body allocated with `allocator`; the
///     transport takes ownership and releases it.
pub const ResponseHook = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    resp: *HandlerResponse,
    method: []const u8,
    reqHeaders: []const Header,
    extra: *std.ArrayList(Header),
) anyerror!?[]u8;

pub const ServerOptions = struct {
    handler: HandlerFn,
    handlerCtx: ?*anyopaque = null,
    /// Maximum accepted request body size.
    maxBodySize: usize = MAX_REQUEST_BODY_SIZE,
    /// Optional response transformation.
    decorate: ?ResponseHook = null,
};

/// Per-stream server state. One entry per concurrent request.
const ServerStream = struct {
    sid: u31,
    allocator: Allocator,
    method: std.ArrayList(u8) = .empty,
    path: std.ArrayList(u8) = .empty,
    /// `:authority`, exposed to handlers as `host` when no host field
    /// was sent explicitly (RFC 9113 Section 8.3.1).
    authority: std.ArrayList(u8) = .empty,
    hdrs: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// The initial request header block was received.
    headersSeen: bool = false,
    /// The request side ended (END_STREAM).
    requestEnded: bool = false,
    /// The request body exceeded `maxBodySize`.
    tooLarge: bool = false,
    /// A response is queued (headers sent, body pending).
    responsePending: bool = false,
    /// Owned copy of the response body still to be written.
    respBody: ?[]u8 = null,
    respOffset: usize = 0,

    fn deinit(self: *ServerStream) void {
        self.method.deinit(self.allocator);
        self.path.deinit(self.allocator);
        self.authority.deinit(self.allocator);
        for (self.hdrs.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.hdrs.deinit(self.allocator);
        self.body.deinit(self.allocator);
        if (self.respBody) |b| self.allocator.free(b);
        self.allocator.destroy(self);
    }
};

/// Connection-wide server bookkeeping.
const ServerCtx = struct {
    allocator: Allocator,
    session: *Session,
    options: ServerOptions,
    streams: std.AutoHashMap(u31, *ServerStream),
    /// Streams whose request side completed and need a response.
    ready: std.ArrayList(u31) = .empty,

    fn deinit(self: *ServerCtx) void {
        var it = self.streams.valueIterator();
        while (it.next()) |sp| sp.*.deinit();
        self.streams.deinit();
        self.ready.deinit(self.allocator);
    }

    fn getOrCreate(self: *ServerCtx, sid: u31) !*ServerStream {
        if (self.streams.get(sid)) |st| return st;
        const st = try self.allocator.create(ServerStream);
        st.* = .{ .sid = sid, .allocator = self.allocator };
        try self.streams.put(sid, st);
        return st;
    }

    fn remove(self: *ServerCtx, sid: u31) void {
        if (self.streams.fetchRemove(sid)) |kv| kv.value.deinit();
    }
};

fn svrOnHeaders(ctx: ?*anyopaque, sid: u31, flds: []hpack.HeaderField, endStream: bool) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    const st = try s.getOrCreate(sid);
    if (st.headersSeen) {
        // Trailer block: the transport API has no trailer channel, so the
        // fields are validated (by the session) and dropped.
        return;
    }
    st.headersSeen = true;
    for (flds) |f| {
        if (std.mem.eql(u8, f.name, ":method")) {
            try st.method.appendSlice(s.allocator, f.value);
        } else if (std.mem.eql(u8, f.name, ":path")) {
            try st.path.appendSlice(s.allocator, f.value);
        } else if (std.mem.eql(u8, f.name, ":authority")) {
            try st.authority.appendSlice(s.allocator, f.value);
        } else if (f.name.len > 0 and f.name[0] == ':') {
            // :scheme is implied by the transport.
        } else {
            try appendCopiedHeader(s.allocator, &st.hdrs, f.name, f.value);
        }
    }
    // HTTP/2 carries the request target authority in `:authority`, but
    // handlers expect HTTP/1-style `host`. Expose it only when the client
    // did not also send a regular host field.
    if (st.authority.items.len > 0) {
        var hasHost = false;
        for (st.hdrs.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) {
                hasHost = true;
                break;
            }
        }
        if (!hasHost) try appendCopiedHeader(s.allocator, &st.hdrs, "host", st.authority.items);
    }
    if (endStream) try markReady(s, sid);
}

fn svrOnData(ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    const st = try s.getOrCreate(sid);
    if (st.tooLarge) return;
    if (data.len > s.options.maxBodySize -| st.body.items.len) {
        st.tooLarge = true;
        st.body.clearRetainingCapacity();
        return;
    }
    try st.body.appendSlice(s.allocator, data);
}

fn svrOnStreamEnd(ctx: ?*anyopaque, sid: u31) anyerror!void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    const st = try s.getOrCreate(sid);
    st.requestEnded = true;
    try markReady(s, sid);
}

fn svrOnReset(ctx: ?*anyopaque, sid: u31, _: u32) void {
    const s: *ServerCtx = @ptrCast(@alignCast(ctx.?));
    s.remove(sid);
}

fn markReady(s: *ServerCtx, sid: u31) !void {
    const st = try s.getOrCreate(sid);
    if (!st.requestEnded) return;
    for (s.ready.items) |existing| {
        if (existing == sid) return;
    }
    try s.ready.append(s.allocator, sid);
}

/// Serves h2 requests on an established native TLS session until
/// close/GOAWAY. Same dispatch as serveConnection; only the byte mover
/// differs (TLS records instead of TCP).
pub fn serveTlsConnection(
    allocator: Allocator,
    tlsConn: *tlsServerMod.Server.Connection,
    handler: HandlerFn,
    handlerCtx: ?*anyopaque,
) !void {
    var stream = Stream{ .tlsServer = tlsConn };
    try serveStream(allocator, stream.byteStream(), .{ .handler = handler, .handlerCtx = handlerCtx }, &.{});
}

/// Serves h2c requests on an accepted socket until close/GOAWAY.
pub fn serveConnection(
    allocator: Allocator,
    sock: *tcp.Socket,
    handler: HandlerFn,
    handlerCtx: ?*anyopaque,
) !void {
    var stream = Stream{ .tcp = sock.* };
    try serveStream(allocator, stream.byteStream(), .{ .handler = handler, .handlerCtx = handlerCtx }, &.{});
}

/// Multiplexed HTTP/2 server loop over an abstract byte stream.
/// `initial` carries bytes already read from the transport (for example
/// the connection preface sniffed by the HTTP server).
pub fn serveStream(allocator: Allocator, io: ByteStream, options: ServerOptions, initial: []const u8) !void {
    var session = try Session.init(allocator, .server, .{});
    defer session.deinit();
    try session.startHandshake();
    io.writeAll(session.outbound.items) catch return error.WriteFailed;
    session.outbound.clearRetainingCapacity();

    var ctx = ServerCtx{
        .allocator = allocator,
        .session = &session,
        .options = options,
        .streams = std.AutoHashMap(u31, *ServerStream).init(allocator),
    };
    defer ctx.deinit();
    session.cbs = .{
        .ctx = &ctx,
        .onHeaders = svrOnHeaders,
        .onData = svrOnData,
        .onStreamEnd = svrOnStreamEnd,
        .onReset = svrOnReset,
    };

    if (initial.len > 0) {
        session.feed(initial) catch |err| {
            if (session.outbound.items.len > 0) {
                io.writeAll(session.outbound.items) catch {};
                session.outbound.clearRetainingCapacity();
            }
            return err;
        };
    }

    var buf: [16 * 1024]u8 = undefined;
    while (!session.closed) {
        // 1. Answer every request whose input side is complete.
        try dispatchReady(&ctx);
        // 2. Push out queued response bodies as the windows allow.
        try drainResponses(&ctx);
        // 3. Flush control frames (SETTINGS ACK, WINDOW_UPDATE, RST, ...).
        if (session.outbound.items.len > 0) {
            io.writeAll(session.outbound.items) catch return error.WriteFailed;
            session.outbound.clearRetainingCapacity();
        }
        // 4. Read more input.
        const n = io.read(&buf) catch break;
        if (n == 0) break;
        session.feed(buf[0..n]) catch |err| {
            // A protocol violation queues a GOAWAY: send it before the
            // socket goes away so the peer learns the reason.
            if (session.outbound.items.len > 0) {
                io.writeAll(session.outbound.items) catch {};
                session.outbound.clearRetainingCapacity();
            }
            return err;
        };
    }
}

/// Builds and sends the response for every completed request.
fn dispatchReady(ctx: *ServerCtx) !void {
    while (ctx.ready.items.len > 0) {
        const sid = ctx.ready.orderedRemove(0);
        const st = ctx.streams.get(sid) orelse continue;
        if (st.responsePending) continue;

        var resp: HandlerResponse = undefined;
        if (st.tooLarge) {
            resp = .{ .status = 413 };
        } else {
            resp = ctx.options.handler(
                ctx.options.handlerCtx,
                st.method.items,
                st.path.items,
                st.hdrs.items,
                st.body.items,
            ) catch HandlerResponse{ .status = 500 };
        }

        const isHead = std.ascii.eqlIgnoreCase(st.method.items, "HEAD");

        var fields = std.ArrayList(hpack.HeaderField).empty;
        defer fields.deinit(ctx.allocator);
        var extra = std.ArrayList(Header).empty;
        defer extra.deinit(ctx.allocator);

        if (ctx.options.decorate) |hook| {
            const owned = hook(ctx.options.handlerCtx, ctx.allocator, &resp, st.method.items, st.hdrs.items, &extra) catch null;
            if (owned) |b| {
                // The transport owns the replacement body.
                defer ctx.allocator.free(b);
                resp.body = b;
            }
        }

        // The decorator may change the status, so the body rules are
        // evaluated after it ran. A final response cannot be informational
        // or carry a body for 204/205/304.
        if (resp.status < 200 or resp.status > 599) resp.status = 500;
        const statusAllowsBody = resp.status != 204 and resp.status != 205 and resp.status != 304;

        var stBuf: [8]u8 = undefined;
        const statusStr = std.fmt.bufPrint(&stBuf, "{d}", .{resp.status}) catch "500";
        try fields.append(ctx.allocator, .{ .name = ":status", .value = statusStr });
        if (statusAllowsBody) {
            var clBuf: [20]u8 = undefined;
            const cl = clBuf[0..std.fmt.printInt(&clBuf, resp.body.len, 10, .lower, .{})];
            try fields.append(ctx.allocator, .{ .name = "content-length", .value = cl });
        }
        for (resp.headers) |h| try appendResponseHeader(ctx, &fields, h);
        for (extra.items) |h| try appendResponseHeader(ctx, &fields, h);

        const sendBody = statusAllowsBody and !isHead and resp.body.len > 0;
        if (!sendBody) {
            // HEAD/204/205/304: the headers carry the length, the stream
            // ends immediately and needs no body-drain bookkeeping.
            try ctx.session.sendHeaders(sid, fields.items, true);
            ctx.remove(sid);
            continue;
        }

        try ctx.session.sendHeaders(sid, fields.items, false);
        st.responsePending = true;
        // The handler's buffer may be arena-backed, so the body is copied
        // before the handler returns to its caller.
        const owned = try ctx.allocator.dupe(u8, resp.body);
        st.respBody = owned;
        st.respOffset = 0;
    }
}

/// Appends one response header, dropping the fields the server owns
/// (pseudo-headers and content-length are generated above).
fn appendResponseHeader(ctx: *ServerCtx, fields: *std.ArrayList(hpack.HeaderField), h: Header) !void {
    if (h.name.len == 0) return;
    if (h.name[0] == ':') return;
    if (std.ascii.eqlIgnoreCase(h.name, "content-length")) return;
    if (std.ascii.eqlIgnoreCase(h.name, "connection")) return;
    if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) return;
    if (std.ascii.eqlIgnoreCase(h.name, "keep-alive")) return;
    if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) return;
    if (std.ascii.eqlIgnoreCase(h.name, "proxy-connection")) return;
    try fields.append(ctx.allocator, .{ .name = h.name, .value = h.value });
}

/// Writes queued response bodies, respecting the flow-control windows.
fn drainResponses(ctx: *ServerCtx) !void {
    // Removing entries while iterating an AutoHashMap invalidates the
    // iterator, so collect the identifiers first.
    var ids = std.ArrayList(u31).empty;
    defer ids.deinit(ctx.allocator);
    var it = ctx.streams.valueIterator();
    while (it.next()) |sp| {
        if (sp.*.responsePending) {
            try ids.append(ctx.allocator, sp.*.sid);
        }
    }
    for (ids.items) |sid| {
        const st = ctx.streams.get(sid) orelse continue;
        const body = st.respBody orelse continue;
        if (st.respOffset >= body.len) {
            // Everything was written: the last DATA frame carried
            // END_STREAM, so the stream is done.
            ctx.allocator.free(body);
            st.respBody = null;
            ctx.remove(sid);
            continue;
        }
        const n = try ctx.session.sendData(sid, body[st.respOffset..], true);
        st.respOffset += n;
        if (n == 0) continue; // window exhausted; wait for WINDOW_UPDATE
        if (st.respOffset >= body.len) {
            ctx.allocator.free(body);
            st.respBody = null;
            ctx.remove(sid);
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
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, headers: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/h2")) {
                // `:authority` is surfaced as `host` for HTTP/1-style
                // handlers.
                for (headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "host") and std.mem.eql(u8, h.value, "localhost")) {
                        return .{ .status = 200, .body = "hello-h2" };
                    }
                }
                return .{ .status = 400, .body = "missing-host" };
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

    const r = try hc.request("GET", "/h2", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    defer r.deinit();

    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("hello-h2", r.body);

    // A body-less request may explicitly declare content-length 0, but a
    // non-zero declaration without a body is rejected before the wire.
    const cl0 = [_]Header{.{ .name = "content-length", .value = "0" }};
    const rcl = try hc.request("GET", "/h2", cl0[0..], "http", "localhost", null, maxResponseBodySize);
    defer rcl.deinit();
    try std.testing.expectEqual(@as(u16, 200), rcl.status);
    const cl5 = [_]Header{.{ .name = "content-length", .value = "5" }};
    try std.testing.expectError(Error.ProtocolViolation, hc.request("GET", "/h2", cl5[0..], "http", "localhost", null, maxResponseBodySize));

    // Second request on the SAME connection proves multiplexing-ready reuse.
    const r404 = try hc.request("GET", "/missing", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    defer r404.deinit();
    try std.testing.expectEqual(@as(u16, 404), r404.status);
}

test "http2 client and server exchange with request body (POST)" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const Header, reqBody: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/echo")) {
                return .{ .status = 200, .body = reqBody };
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

    const payload = "Hello HTTP/2 request payload body!";
    const r = try hc.request("POST", "/echo", &[_]Header{}, "http", "localhost", payload, maxResponseBodySize);
    defer r.deinit();

    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings(payload, r.body);
}

test "http2 over native tls loopback negotiates h2 via alpn" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return; // skip w/o network
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const certPem = @embedFile("../tls/testdata/localhostCert.pem");
    const keyPem = @embedFile("../tls/testdata/localhostKey.pem");

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
            var srv = tlsServerMod.Server.init(std.heap.page_allocator, io2, .{
                .certificatePem = certPem,
                .privateKeyPem = keyPem,
            }) catch |e| {
                out.* = e;
                return;
            };
            defer srv.deinit();
            var tlsConn = srv.accept(&conn) catch |e| {
                out.* = e;
                return;
            };
            defer tlsConn.deinit();
            if (tlsConn.alpn != .h2) {
                out.* = error.AlpnMismatch;
                return;
            }
            serveTlsConnection(std.heap.page_allocator, &tlsConn, H.handle, null) catch |e| {
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
    var tlsCli = try tlsClientMod.Client.init(a, ctx.io, .{});
    defer tlsCli.deinit();
    var tlsConn = try tlsCli.connect(&sock, "127.0.0.1", .{
        .verify = .caBundle,
        .caPem = certPem,
        .alpn = &.{.h2},
    });
    {
        // The TLS connection borrows the socket; the block scope ends the
        // session (and closes the socket) before joining below, so the
        // serve loop observes EOF and exits instead of deadlocking.
        var hc = try Client.connectTls(a, &tlsConn);
        defer hc.deinit();

        const negotiated = tlsConn.alpn() orelse return error.AlpnMissing;
        try std.testing.expect(negotiated == .h2);
        const r = try hc.request("GET", "/h2s", &[_]Header{}, "https", "127.0.0.1", null, maxResponseBodySize);
        defer r.deinit();
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("hello-h2-tls", r.body);
    }

    thread.join();
    try std.testing.expect(result == null);
}

test "two requests are multiplexed over one connection" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (!std.mem.eql(u8, method, "GET")) return .{ .status = 405 };
            if (std.mem.eql(u8, path, "/slow")) return .{ .status = 200, .body = "slow-response" };
            if (std.mem.eql(u8, path, "/fast")) return .{ .status = 200, .body = "fast-response" };
            return .{ .status = 404 };
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

    // Both requests are in flight before either response is read.
    const slow = try hc.beginRequest("GET", "/slow", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    const fast = try hc.beginRequest("GET", "/fast", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    try std.testing.expect(slow != fast);

    const r1 = try hc.awaitResponse(slow);
    defer r1.deinit();
    const r2 = try hc.awaitResponse(fast);
    defer r2.deinit();

    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("slow-response", r1.body);
    try std.testing.expectEqual(@as(u16, 200), r2.status);
    try std.testing.expectEqualStrings("fast-response", r2.body);
}

test "a response larger than the flow-control window is delivered completely" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const payload_len = 200 * 1024;
    // The response body must stay valid until the transport copied it,
    // so it lives in a static buffer.
    const H = struct {
        var body: [payload_len]u8 = undefined;
        fn handle(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            // A body larger than the 65535-byte window: the server has to
            // wait for WINDOW_UPDATE frames.
            @memset(&body, 'z');
            return .{ .status = 200, .body = &body };
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

    const r = try hc.request("GET", "/big", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(usize, payload_len), r.body.len);
    for (r.body) |c| try std.testing.expectEqual(@as(u8, 'z'), c);
}

test "an empty response body ends the stream" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, _: []const u8, path: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, path, "/empty")) return .{ .status = 204 };
            return .{ .status = 200, .body = "x" };
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

    const r = try hc.request("GET", "/empty", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 204), r.status);
    try std.testing.expectEqual(@as(usize, 0), r.body.len);
}

test "a HEAD request returns the headers without a body" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, _: []const u8, _: []const Header, _: []const u8) anyerror!HandlerResponse {
            if (std.mem.eql(u8, method, "HEAD")) return .{ .status = 200, .body = "0123456789" };
            return .{ .status = 405 };
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

    const r = try hc.request("HEAD", "/doc", &[_]Header{}, "http", "localhost", null, maxResponseBodySize);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(usize, 0), r.body.len);
    var sawLength = false;
    for (r.headers) |h| {
        if (std.mem.eql(u8, h.name, "content-length")) {
            sawLength = true;
            try std.testing.expectEqualStrings("10", h.value);
        }
    }
    try std.testing.expect(sawLength);
}

test "a request body larger than the flow-control window is sent completely" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var l = tcp.Listener.bind(ctx.io, 0) catch return;
    defer l.close(ctx.io);
    const port = l.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const Header, body: []const u8) anyerror!HandlerResponse {
            return .{ .status = 200, .body = body };
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

    const payload = try a.alloc(u8, 150 * 1024);
    defer a.free(payload);
    @memset(payload, 'q');

    const r = try hc.request("POST", "/echo", &[_]Header{}, "http", "localhost", payload, maxResponseBodySize);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, payload.len), r.body.len);
    for (r.body) |c| try std.testing.expectEqual(@as(u8, 'q'), c);
}

test "response trailers complete the stream without replacing headers" {
    const a = std.testing.allocator;
    const st = try a.create(RequestState);
    st.* = .{ .sid = 1, .allocator = a, .maxBytes = 1024 };
    defer st.deinit();

    var informational = [_]hpack.HeaderField{.{ .name = ":status", .value = "103" }};
    try st.onHeaders(&informational, false);
    try std.testing.expect(!st.headersSeen);

    var final = [_]hpack.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-encoding", .value = "gzip" },
    };
    try st.onHeaders(&final, false);
    try std.testing.expectEqual(@as(u16, 200), st.status);
    try std.testing.expectEqual(@as(usize, 1), st.headers.items.len);

    var trailers = [_]hpack.HeaderField{.{ .name = "x-checksum", .value = "abc" }};
    try st.onHeaders(&trailers, true);
    try std.testing.expect(st.done);
    try std.testing.expectEqual(@as(usize, 1), st.headers.items.len);
    try std.testing.expectEqualStrings("gzip", st.headers.items[0].value);
}
