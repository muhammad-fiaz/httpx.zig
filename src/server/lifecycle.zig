//! HTTP/1.1 server: accept loop -> parser -> router dispatch -> writer.
//!
//! One connection per iteration with Connection: close framing; a fresh
//! request arena backs each connection so handlers can allocate freely and
//! everything is released when the response is written.
//!
//! API documentation routes (OpenAPI + Swagger UI + ReDoc) are mounted by
//! default; disable with `Config.docs_enabled = false` or customize through
//! `Config.docs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const compression = @import("../compression/codec.zig");
const parser_mod = @import("../protocols/http1/parser.zig");
const writer_mod = @import("../protocols/http1/writer.zig");
const router_mod = @import("../web/router/router.zig");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Response = router_mod.Response;
const Method = @import("../common/method.zig").Method;
const docs = @import("../web/docs/docs.zig");

pub const max_head_bytes = 32 * 1024;

const logging = @import("../common/logging.zig");
const clock = @import("../common/clock.zig");

/// Built-in logging controls. All opt-in except the master switch; pass
/// `logger` to bridge any external logging library.
pub const LoggingOptions = struct {
    enabled: bool = true,
    level: logging.Level = .info,
    /// Access-log line per request (opt-in).
    requests: bool = false,
    /// Connect/disconnect lines (opt-in).
    connections: bool = false,
    /// Startup/shutdown lines (default on when enabled).
    lifecycle: bool = true,
    /// ANSI colors for the built-in writer sink.
    color: ColorOpt = .never,
    /// Explicit custom logger; overrides built-in writer output entirely.
    logger: ?logging.Logger = null,

    pub const ColorOpt = enum { auto, always, never };
};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// Largest accepted request body.
    max_body: usize = 8 * 1024 * 1024,
    /// Mount /openapi.json, /docs (Swagger UI), /redoc by default.
    docs_enabled: bool = true,
    /// Overrides for docs routes when enabled.
    docs: ?docs.Config = null,
    docs_title: []const u8 = "HTTPX API",
    logging: LoggingOptions = .{},
    /// HTTP/1.1 persistent connections: honor keep-alive, serve multiple
    /// requests per connection (bounded by max_requests_per_conn).
    keep_alive: bool = false,
    max_requests_per_conn: usize = 1000,
};

/// Heap-held state for the built-in stdout sink (self-referential pointers,
/// so Server must not embed it by value).
const LogState = struct {
    file: std.Io.File,
    io: std.Io,
    buf: [4096]u8 align(8) = undefined,
    fw: std.Io.File.Writer = undefined,
    sink: logging.WriterSink = undefined,
};

fn resolveColor(c: LoggingOptions.ColorOpt) bool {
    return c == .always; // .auto resolves plain: TTY detection is host-dependent
}

pub const Server = struct {
    io: std.Io,
    allocator: Allocator,
    listener: tcp.Listener,
    router: Router,
    cfg: Config,
    stop: std.atomic.Value(bool) = .init(false),
    /// 0 = unlimited; run() exits after this many connections.
    max_connections: usize = 0,
    logger: logging.Logger,
    /// Heap-allocated built-in sink state (null when a custom logger was
    /// supplied or logging is disabled).
    log_state: ?*LogState = null,
    logged_stop: std.atomic.Value(bool) = .init(false),
    /// Live connections (keep-alive readers) so shutdown can wake them.
    conns_mu: sync.Spinlock = .{},
    active_conns: std.ArrayList(*tcp.Socket) = .empty,
    /// True while the run-thread sits inside accept(); shutdown waits for
    /// this before closing the listener (removes the close/enter race).
    in_accept: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        const address_mod = @import("../net/address.zig");
        // Default: all-interfaces IPv4. Explicit literals (incl. "::") bind
        // their family; anything unparsable falls back to 0.0.0.0.
        var addr: address_mod.Address = blk: {
            if (std.mem.eql(u8, cfg.host, "0.0.0.0")) break :blk address_mod.Address.unspecified4(cfg.port);
            if (std.mem.eql(u8, cfg.host, "::")) break :blk address_mod.Address.unspecified6(cfg.port);
            var tmp: address_mod.Address = undefined;
            break :blk tmp.parseIp(cfg.host) catch address_mod.Address.unspecified4(cfg.port);
        };
        addr.port = cfg.port;

        // Logger: explicit custom sink wins; otherwise the built-in stdout
        // writer when logging is enabled. The state lives on the heap so
        // Server remains safely movable after init.
        var logger: logging.Logger = cfg.logging.logger orelse logging.Logger.disabled();
        var log_state: ?*LogState = null;
        if (cfg.logging.logger == null and cfg.logging.enabled) {
            const st = allocator.create(LogState) catch null;
            if (st) |s| {
                s.* = .{ .file = std.Io.File.stdout(), .io = io };
                s.fw = .init(s.file, io, &s.buf);
                s.sink = logging.WriterSink.init(&s.fw.interface, resolveColor(cfg.logging.color));
                logger = logging.Logger.writer(&s.sink, cfg.logging.level, true);
                log_state = s;
            }
        }

        var srv = Server{
            .io = io,
            .allocator = allocator,
            .listener = try tcp.Listener.bindAddress(io, &addr),
            .router = Router.init(allocator),
            .cfg = cfg,
            .logger = logger,
            .log_state = log_state,
        };
        errdefer srv.router.deinit();

        if (cfg.docs_enabled) {
            const dc = cfg.docs orelse docs.Config{};
            docs.mount(allocator, &srv.router, dc, .{
                .title = cfg.docs_title,
                .version = @import("../common/version.zig").version,
            }) catch {};
        }
        return srv;
    }

    pub fn deinit(self: *Server) void {
        if (self.cfg.docs_enabled) docs.unmount();
        self.router.deinit();
        self.listener.close(self.io);
        if (self.log_state) |s| self.allocator.destroy(s);
        self.active_conns.deinit(self.allocator);
    }

    pub fn localPort(self: *const Server) u16 {
        return self.listener.localPort();
    }

    /// Signals the accept loop to stop and wakes a blocked accept() by
    /// closing the listening socket. Safe to call multiple times.
    pub fn requestShutdown(self: *Server) void {
        if (!self.logged_stop.swap(true, .acq_rel) and self.cfg.logging.enabled and self.cfg.logging.lifecycle) {
            self.logger.log(.info, "server", "shutting down", .{});
        }
        self.stop.store(true, .release);
        // Close immediately. The listener and connection close paths are
        // idempotent, so this also safely handles a worker transitioning
        // between accept and request processing without a shutdown spin loop.
        self.listener.close(self.io);
        // A keep-alive worker may be blocked in recv() and therefore never
        // reach accept(). Wake those readers immediately; Socket.close is
        // idempotent and the worker's deferred drainThenClose will observe
        // the same close flag.
        self.conns_mu.lock();
        for (self.active_conns.items) |conn| conn.close();
        self.conns_mu.unlock();
    }

    /// Blocking accept loop. `requestShutdown()` takes effect between
    /// accepts; `max_connections` (when nonzero) makes run() return after
    /// that many connections, which is how tests join deterministically.
    pub fn run(self: *Server) void {
        if (self.cfg.logging.enabled and self.cfg.logging.lifecycle) {
            self.logger.log(.info, "server", "listening on {s}:{d}", .{ self.cfg.host, self.listener.localPort() });
        }
        var served: usize = 0;
        while (!self.stop.load(.acquire)) {
            if (self.max_connections != 0 and served >= self.max_connections) break;
            self.in_accept.store(true, .release);
            var conn = self.listener.accept(self.io) catch {
                self.in_accept.store(false, .release);
                break;
            };
            self.in_accept.store(false, .release);
            defer conn.drainThenClose();
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            self.serveConnection(&conn, arena.allocator()) catch {};
            served += 1;

            // Stop before blocking on the next accept when asked.
            if (self.stop.load(.acquire)) break;
        }
        if (self.cfg.logging.enabled and self.cfg.logging.lifecycle) {
            self.logger.log(.info, "server", "shutdown complete", .{});
        }
    }

    fn serveConnection(self: *Server, conn: *tcp.Socket, arena_in: Allocator) !void {
        _ = arena_in;
        if (!self.cfg.keep_alive) {
            var arena_one = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_one.deinit();
            _ = try self.serveOneRequest(conn, arena_one.allocator(), 0, true);
            return;
        }
        // Persistent connection: bounded request loop with per-request arena
        // reset so long-lived connections cannot grow memory unbounded.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.conns_mu.lock();
        self.active_conns.append(self.allocator, conn) catch |err| {
            self.conns_mu.unlock();
            return err;
        };
        self.conns_mu.unlock();
        defer {
            self.conns_mu.lock();
            for (self.active_conns.items, 0..) |sc, i| {
                if (sc == conn) {
                    _ = self.active_conns.swapRemove(i);
                    break;
                }
            }
            self.conns_mu.unlock();
        }

        var served_n: usize = 0;
        while (served_n < self.cfg.max_requests_per_conn) : (served_n += 1) {
            _ = arena.reset(.retain_capacity);
            const want_more = self.serveOneRequest(conn, arena.allocator(), served_n, false) catch return;
            if (!want_more) break;
        }
    }

    /// Handles exactly one request. Returns `true` when the connection may
    /// carry another request (keep-alive), `false` to close. In one-shot mode
    /// (`force_close`) the return value is irrelevant.
    fn serveOneRequest(self: *Server, conn: *tcp.Socket, arena: Allocator, _: usize, force_close: bool) !bool {
        const t0 = clock.millisNow();
        var head_buf: [max_head_bytes]u8 = undefined;
        var filled: usize = 0;
        while (filled < head_buf.len) {
            const n = conn.read(head_buf[filled..]) catch return false;
            if (n == 0) return false; // peer closed
            filled += n;
            if (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") != null) break;
        }

        const head = parser_mod.parseRequestHead(head_buf[0..filled]) catch {
            _ = sendSimpleError(conn, 400, "bad request") catch 0;
            return false;
        };

        // Headers -> Context slice.
        var fields: [parser_mod.DEFAULT_MAX_HEADERS]parser_mod.Field = undefined;
        const blk = parser_mod.parseHeaderBlock(head_buf[0..filled], head.head_end, fields[0..]) catch {
            _ = sendSimpleError(conn, 400, "bad headers") catch 0;
            return false;
        };

        const hdrs = arena.alloc(router_mod.Header, blk.count) catch return false;
        for (fields[0..blk.count], 0..) |f, i| hdrs[i] = .{ .name = f.name, .value = f.value };

        // Connection reuse decision (RFC 9112 §7): explicit "close" wins;
        // HTTP/1.0 defaults to close unless it requested keep-alive.
        var client_close = force_close or head.minor_version == 0;
        var client_ka10 = false;
        for (hdrs) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            if (std.ascii.indexOfIgnoreCase(h.value, "close") != null) client_close = true;
            if (std.ascii.indexOfIgnoreCase(h.value, "keep-alive") != null) client_ka10 = true;
        }
        if (head.minor_version == 0 and client_ka10) client_close = false;

        // Body: Content-Length or chunked (both bounded by cfg.max_body).
        var body: []u8 = "";
        const framing = parser_mod.decideFraming(fields[0..blk.count], false, 0, 0) catch {
            _ = sendSimpleError(conn, 400, "invalid message framing") catch 0;
            return false;
        };
        var has_expect = false;
        for (fields[0..blk.count]) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "expect")) {
                has_expect = true;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field.value, " \t"), "100-continue")) {
                    _ = sendSimpleError(conn, 417, "expectation failed") catch 0;
                    return false;
                }
            }
        }
        if (has_expect and head.minor_version == 1 and framing.framing != .none) {
            const interim = writer_mod.buildInformational(arena, 100, &.{}) catch return false;
            defer arena.free(interim);
            conn.writeAll(interim) catch return false;
        }
        {
            const fr = framing;
            switch (fr.framing) {
                .none, .content_length => {
                    if (fr.length > self.cfg.max_body) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = arena.alloc(u8, fr.length) catch return false;
                    // How many body bytes were already pulled in by the header reads.
                    const buffered = if (filled > blk.end) filled - blk.end else 0;
                    if (buffered > fr.length) client_close = true;
                    const take = @min(buffered, fr.length);
                    @memcpy(body[0..take], head_buf[blk.end..][0..take]);
                    var have: usize = take;
                    while (have < fr.length) {
                        // Bounded window keeps behavior uniform across platforms.
                        const want = @min(4096, fr.length - have);
                        const n = conn.read(body[have..][0..want]) catch return false;
                        if (n == 0) return false;
                        have += n;
                    }
                },
                .chunked => {
                    // Persistent decoder + explicit unparsed cursor.
                    var dec: parser_mod.ChunkedDecoder = .{};
                    var acc: std.ArrayList(u8) = .empty;
                    var raw: std.ArrayList(u8) = .empty;
                    raw.appendSlice(arena, head_buf[blk.end..filled]) catch return false;
                    var unparsed: usize = 0;
                    while (true) {
                        const tail = dec.decode(raw.items[unparsed..]) catch |e| switch (e) {
                            error.Incomplete => {
                                const n = conn.read(head_buf[0..]) catch return false;
                                if (n == 0) return false;
                                raw.appendSlice(arena, head_buf[0..n]) catch return false;
                                continue;
                            },
                            else => return false,
                        };
                        const produced = raw.items.len - unparsed - tail;
                        acc.appendSlice(arena, raw.items[unparsed..][0..produced]) catch return false;
                        unparsed += produced;
                        if (dec.state == .done) break;
                        const n = conn.read(head_buf[0..]) catch return false;
                        if (n == 0) return false;
                        raw.appendSlice(arena, head_buf[0..n]) catch return false;
                    }
                    // Any bytes after the terminating chunk are currently not
                    // retained for the next request, so do not reuse this
                    // connection when the read crossed message boundaries.
                    if (unparsed < raw.items.len) client_close = true;
                    if (acc.items.len > self.cfg.max_body) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = acc.items;
                },
                .tunnel => {
                    // CONNECT tunneling is not served by the request router.
                    _ = sendSimpleError(conn, 501, "CONNECT not supported") catch 0;
                    return false;
                },
            }
        }

        const method = Method.fromString(head.method) orelse {
            _ = sendSimpleError(conn, 501, "method not supported") catch 0;
            return false;
        };

        const is_head = method == .HEAD;

        var ctx = Context{
            .allocator = arena,
            .io = self.io,
            .headers = hdrs,
            .path = head.path,
            .method = method,
            .body = body,
        };
        const handler = self.router.match(method, ctx.path, &ctx) orelse {
            _ = sendSimpleError(conn, 404, "not found") catch 0;
            return false;
        };

        const res = handler(&ctx) catch {
            _ = sendSimpleError(conn, 500, "handler error") catch 0;
            return false;
        };

        const bytes_out = try writeResponse(conn, arena, head.minor_version, res, is_head, if (client_close) "close" else "keep-alive", ctx.header("Accept-Encoding"));
        self.emitAccess(head.method, head.path, res.status, body.len, bytes_out, t0);
        return !client_close;
    }

    /// One access-log line for a completed request. No-op unless
    /// `logging.requests` is enabled. Secrets never appear here: only
    /// method/path/status/timing/byte counts are emitted.
    fn emitAccess(self: *Server, method: []const u8, path: []const u8, status: u16, bytes_in: usize, bytes_out: usize, t0: i64) void {
        if (!self.cfg.logging.enabled or !self.cfg.logging.requests or !self.logger.enabled) return;
        const dur = clock.millisNow() -| t0;
        self.logger.logFields(.info, "request", &.{
            .{ .name = "status", .value = statusTag(status) },
        }, "{s} {s} {d}ms in={d} out={d}", .{ method, path, dur, bytes_in, bytes_out });
    }

    fn statusTag(status: u16) []const u8 {
        return switch (status) {
            200 => "200",
            201 => "201",
            204 => "204",
            206 => "206",
            304 => "304",
            400 => "400",
            401 => "401",
            403 => "403",
            404 => "404",
            405 => "405",
            413 => "413",
            416 => "416",
            500 => "500",
            else => "other",
        };
    }

    fn writeResponse(conn: *tcp.Socket, arena: Allocator, minor: u8, res: Response, is_head: bool, conn_hdr: []const u8, accept_encoding: ?[]const u8) !usize {
        // conn_hdr selects the Connection header emitted ("" -> legacy close).
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);

        lines.append(arena, if (conn_hdr.len > 0)
            (std.fmt.allocPrint(arena, "Connection: {s}", .{conn_hdr}) catch return 0)
        else
            "Connection: close") catch return 0;

        if (res.content_type) |ct| {
            const line = std.fmt.allocPrint(arena, "Content-Type: {s}", .{ct}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        for (res.headers) |h| {
            const line = std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }) catch return 0;
            lines.append(arena, line) catch return 0;
        }

        var encoded_body: ?[]u8 = null;
        defer if (encoded_body) |b| arena.free(b);
        var body_out: []const u8 = if (is_head) "" else res.body;
        var content_encoding: ?[]const u8 = null;
        if (!is_head and res.body.len > 0 and res.status != 204 and res.status != 304 and accept_encoding != null) {
            const selected = compression.negotiate(accept_encoding.?);
            if (selected != .identity) {
                encoded_body = compression.compress(arena, selected, res.body) catch null;
                if (encoded_body) |b| {
                    body_out = b;
                    content_encoding = selected.token();
                }
            }
        }
        if (content_encoding) |ce| {
            lines.append(arena, "Vary: Accept-Encoding") catch return 0;
            const line = std.fmt.allocPrint(arena, "Content-Encoding: {s}", .{ce}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        const reason: []const u8 = if (writer_mod.reasonPhrase(res.status).len > 0)
            writer_mod.reasonPhrase(res.status)
        else
            reasonFor(res.status);
        var resp_headers = try arena.alloc(writer_mod.Header, lines.items.len);
        for (lines.items, 0..) |line, i| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
            resp_headers[i] = .{
                .name = std.mem.trim(u8, line[0..colon], " "),
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            };
        }
        const raw = writer_mod.buildResponse(
            arena,
            res.status,
            reason,
            body_out,
            .{ .minor_version = minor, .headers = resp_headers },
            is_head,
        ) catch return 0;
        try conn.writeAll(raw);
        return raw.len;
    }

    fn sendSimpleError(conn: *tcp.Socket, status: u16, text: []const u8) !usize {
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            status,
            reasonFor(status),
            text.len,
            text,
        }) catch return 0;
        try conn.writeAll(out);
        return out.len;
    }
};

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "Status",
    };
}

// Tests

fn helloHandler(ctx: *Context) anyerror!Response {
    if (std.mem.eql(u8, ctx.path, "/hello")) {
        return .{ .body = "hi", .content_type = "text/plain" };
    }
    return .{ .status = 404, .body = "" };
}

test "server handles POST with content-length body" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .docs_enabled = false }) catch return;
    defer srv.deinit();
    try srv.router.post("/echo", echoRawHandler);
    srv.max_connections = 1;

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    const payload = "{\"raw\":true}";
    var req_buf: [256]u8 = undefined;
    const raw = try std.fmt.bufPrint(&req_buf, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    try client.writeAll(raw);

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "}\r\n") != null) break;
    }

    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..total], payload));
}

fn echoRawHandler(ctx: *Context) anyerror!Response {
    if (ctx.body.len == 0) return .{ .status = 400, .body = "empty" };
    return .{ .content_type = "application/json", .body = ctx.body };
}

// Logging verification: custom sink receives access lines; silence when off

const sync = @import("../common/sync.zig");

const CaptureSink = struct {
    mu: sync.Spinlock = .{},
    seen: usize = 0,
    got_request_line: bool = false,
    got_lifecycle: bool = false,

    fn logImpl(ptr: *anyopaque, record: logging.Record) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        self.seen += 1;
        if (std.mem.eql(u8, record.component, "request") and
            std.mem.indexOf(u8, record.message, "/logged") != null and
            std.mem.indexOf(u8, record.message, "GET") != null)
            self.got_request_line = true;
        if (std.mem.eql(u8, record.component, "server")) self.got_lifecycle = true;
    }

    fn sink(self: *CaptureSink) logging.Sink {
        return .{ .ptr = self, .logFn = &logImpl };
    }
};

test "access log flows through explicit custom logger" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var cap = CaptureSink{};
    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .docs_enabled = false,
        .logging = .{
            .enabled = true,
            .requests = true,
            .lifecycle = true,
            .logger = logging.Logger.custom(cap.sink(), .debug, true),
        },
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk);
    srv.max_connections = 1;

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch {
        srv.requestShutdown();
        t.join();
        return;
    };
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    // Close BEFORE joining: the server's drainThenClose waits for our FIN,
    // so closing here is what lets run() return and the join complete.
    c.close();

    // max_connections=1 => run() returns only AFTER emitAccess ran.
    t.join();
    srv.requestShutdown();
    try std.testing.expect(cap.got_request_line);
    try std.testing.expect(cap.got_lifecycle);
}

test "logging disabled produces zero output" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var cap = CaptureSink{};
    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .docs_enabled = false,
        .logging = .{
            .enabled = false,
            .requests = true,
            .logger = logging.Logger.custom(cap.sink(), .debug, true),
        },
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk);
    srv.max_connections = 1;

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    // Unblock the server's drain before joining (same reason as above).
    c.close();

    t.join();
    srv.requestShutdown();
    try std.testing.expectEqual(@as(usize, 0), cap.seen);
}

fn returnOk(_: *Context) anyerror!Response {
    return .{ .body = "ok", .content_type = "text/plain" };
}

test "server serves routed GET end to end" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0 }) catch return;
    defer srv.deinit();
    try srv.router.get("/hello", helloHandler);
    srv.max_connections = 1;

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /hello HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=1, zstd;q=0, br;q=0\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null and
            std.mem.indexOf(u8, buf[0..total], "\r\n\x1f\x8b") != null) break;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Vary: Accept-Encoding") != null);
    try std.testing.expect(total > 20);

    srv.requestShutdown();
}

test "raw socket 200KB content-length body roundtrip" {
    const a = std.testing.allocator;
    var ctx0 = tcp.IoContext.init(a) catch return;
    defer ctx0.deinit();
    var srv = Server.init(a, ctx0.io, .{ .port = 0, .docs_enabled = false }) catch return;
    defer srv.deinit();
    const LenH = struct {
        fn h(ctx: *Context) anyerror!Response {
            const t = std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.body.len}) catch return error.OutOfMemory;
            return .{ .body = t };
        }
    };
    try srv.router.post("/len", LenH.h);
    srv.max_connections = 1;
    const R = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const th = std.Thread.spawn(.{}, R.run, .{&srv}) catch return;
    defer th.join();
    var c = tcp.connect(ctx0.io, "127.0.0.1", srv.localPort()) catch return;
    defer c.drainThenClose();
    const total = 200 * 1024;
    var hb: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{total});
    try c.writeAll(head);
    var blk: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < total) : (sent += blk.len) try c.writeAll(&blk);
    var rb: [256]u8 = undefined;
    var gotn: usize = 0;
    while (gotn < rb.len) {
        const n = c.read(rb[gotn..]) catch break;
        if (n == 0) break;
        gotn += n;
        if (std.mem.indexOf(u8, rb[0..gotn], "204800") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, rb[0..gotn], "204800") != null);
}
test "reason phrases cover common statuses" {
    try std.testing.expectEqualStrings("OK", reasonFor(200));
    try std.testing.expectEqualStrings("Not Found", reasonFor(404));
}
