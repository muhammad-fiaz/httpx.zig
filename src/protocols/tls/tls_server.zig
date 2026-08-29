//! TLS server listener with ALPN-based HTTP version dispatch.
//!
//! Accepts TCP connections, performs TLS 1.3 handshake with ALPN
//! negotiation, then dispatches to:
//!   - ALPN "h2" -> HTTP/2 server (transport.serveConnection)
//!   - ALPN "http/1.0" or "http/1.1" -> HTTP/1.x server
//!   - No ALPN -> HTTP/1.1 (default)
//!
//! This is the main entry point for serving HTTPS.
//!
//! References:
//!   - RFC 8446 — TLS 1.3
//!   - RFC 7301 — ALPN (Application-Layer Protocol Negotiation)

const std = @import("std");
const Allocator = std.mem.Allocator;

const tcp = @import("../../sockets/tcp.zig");
const tls_server_mod = @import("tcp_tls.zig");
const alpn_mod = @import("alpn.zig");
const h2_transport = @import("../http2/transport.zig");
const h2_connection_mod = @import("../http2/connection.zig");
const h1_parser = @import("../http1/parser.zig");
const h1_writer = @import("../http1/writer.zig");
const h1_semantics = @import("../http1/semantics.zig");
const compression = @import("../../compression/codec.zig");

const MAX_HTTP2_REQUEST_BODY: usize = 16 * 1024 * 1024;

// Handler callback

pub const Header = struct { name: []const u8, value: []const u8 };

pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const HttpResponse = struct {
    status: u16 = 200,
    reason: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const HandlerFn = *const fn (ctx: ?*anyopaque, req: HttpRequest) anyerror!HttpResponse;

// HTTP/1.x server over TLS

fn serveHttp1OverTls(
    allocator: Allocator,
    tls_conn: *tls_server_mod.TlsServerConn,
    handler: HandlerFn,
    handler_ctx: ?*anyopaque,
) void {
    var buf: [16 * 1024]u8 = undefined;
    var total: usize = 0;

    while (true) {
        const n = tls_conn.read(&buf[total..]) catch break;
        if (n == 0) break;
        total += n;

        // Try to parse the HTTP/1 request head
        const head = h1_parser.parseRequestHead(buf[0..total]) catch {
            if (total >= buf.len) break;
            continue;
        };

        const head_end = head.headers_end;
        if (head_end > total) continue;

        // Parse headers into a flat array
        var fields: [64]h1_parser.Field = undefined;
        const result = h1_parser.parseHeaderBlock(buf[0..total], head_end, &fields) catch break;

        var keep_alive = h1_semantics.shouldKeepAlive(fields[0..result.count]);

        var content_length: usize = 0;
        var transfer_chunked = false;
        var has_expect = false;
        for (fields[0..result.count]) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, field.value, " \t"), 10) catch break;
            }
            if (std.ascii.eqlIgnoreCase(field.name, "transfer-encoding") and
                std.ascii.indexOfIgnoreCase(field.value, "chunked") != null) transfer_chunked = true;
            if (std.ascii.eqlIgnoreCase(field.name, "expect")) {
                has_expect = true;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field.value, " \t"), "100-continue")) {
                    const interim = h1_writer.buildResponse(allocator, 417, "Expectation Failed", null, .{ .minor_version = head.minor_version }, false) catch break;
                    defer allocator.free(interim);
                    tls_conn.writeAll(interim) catch break;
                    return;
                }
            }
        }
        if (content_length > 16 * 1024 * 1024) break;
        if (has_expect and head.minor_version == 1 and (content_length > 0 or transfer_chunked)) {
            const interim = h1_writer.buildInformational(allocator, 100, &.{}) catch break;
            defer allocator.free(interim);
            tls_conn.writeAll(interim) catch break;
        }
        // Body reads use the TLS stream directly. Until pipelined bytes are
        // retained across body consumption, close body-bearing connections
        // to prevent buffered-tail desynchronization.
        if (content_length > 0 or transfer_chunked) keep_alive = false;
        var body_storage = std.ArrayList(u8).empty;
        defer body_storage.deinit(allocator);
        if (transfer_chunked) {
            var decoder = h1_parser.ChunkedDecoder.init();
            var wire = std.ArrayList(u8).empty;
            defer wire.deinit(allocator);
            wire.appendSlice(allocator, buf[head_end..total]) catch break;
            var cursor: usize = 0;
            while (!decoder.isDone()) {
                const tail = decoder.decode(wire.items[cursor..]) catch |err| switch (err) {
                    error.Incomplete => {
                        var chunk: [16 * 1024]u8 = undefined;
                        const body_n = tls_conn.read(&chunk) catch break;
                        if (body_n == 0) break;
                        wire.appendSlice(allocator, chunk[0..body_n]) catch break;
                        continue;
                    },
                    else => break,
                };
                const produced = wire.items.len - cursor - tail;
                body_storage.appendSlice(allocator, wire.items[cursor..][0..produced]) catch break;
                cursor += produced;
            }
        } else {
            body_storage.ensureTotalCapacity(allocator, content_length) catch break;
            if (head_end < total) body_storage.appendSlice(allocator, buf[head_end..][0..@min(content_length, total - head_end)]) catch break;
            while (body_storage.items.len < content_length) {
                const body_n = tls_conn.read(buf[0..]) catch break;
                if (body_n == 0) break;
                const take = @min(body_n, content_length - body_storage.items.len);
                body_storage.appendSlice(allocator, buf[0..take]) catch break;
            }
            if (body_storage.items.len != content_length) break;
        }

        // Build the request
        const req = HttpRequest{
            .method = head.method,
            .path = head.path,
            .version = head.version,
            .headers = blk: {
                var hdrs = std.ArrayList(Header).empty;
                defer hdrs.deinit(allocator);
                for (fields[0..result.count]) |f| {
                    hdrs.append(allocator, .{ .name = f.name, .value = f.value }) catch break;
                }
                break :blk try hdrs.toOwnedSlice(allocator);
            },
            .body = body_storage.items,
        };
        defer allocator.free(req.headers);

        const resp = handler(handler_ctx, req) catch HttpResponse{ .status = 500, .body = "Internal Server Error" };

        var encoded_body: ?[]u8 = null;
        defer if (encoded_body) |bytes| allocator.free(bytes);
        var response_body = resp.body;
        var response_headers: [64]h1_writer.Header = undefined;
        var response_header_count: usize = 0;
        for (resp.headers) |header| {
            if (response_header_count == response_headers.len) break;
            response_headers[response_header_count] = .{ .name = header.name, .value = header.value };
            response_header_count += 1;
        }
        if (resp.body.len > 0 and resp.status != 204 and resp.status != 304) {
            var accept_encoding: ?[]const u8 = null;
            for (req.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Accept-Encoding")) {
                    accept_encoding = header.value;
                    break;
                }
            }
            if (accept_encoding) |accept| {
                const selected = compression.negotiate(accept);
                if (selected != .identity) {
                    encoded_body = compression.compress(allocator, selected, resp.body) catch null;
                    if (encoded_body) |bytes| {
                        response_body = bytes;
                        if (response_header_count + 2 <= response_headers.len) {
                            response_headers[response_header_count] = .{ .name = "Content-Encoding", .value = selected.token() };
                            response_headers[response_header_count + 1] = .{ .name = "Vary", .value = "Accept-Encoding" };
                            response_header_count += 2;
                        }
                    }
                }
            }
        }

        // Build HTTP/1 response
        const resp_bytes = h1_writer.buildResponse(
            allocator,
            resp.status,
            resp.reason,
            if (response_body.len > 0) response_body else null,
            .{ .minor_version = head.minor_version, .headers = response_headers[0..response_header_count] },
            false,
        ) catch break;
        defer allocator.free(resp_bytes);

        tls_conn.writeAll(resp_bytes) catch break;

        if (!keep_alive) break;

        // Move unconsumed data to beginning
        if (head_end < total) {
            const remaining = total - head_end;
            std.mem.copyForwards(u8, buf[0..remaining], buf[head_end..total]);
            total = remaining;
        } else {
            total = 0;
        }
    }
}

// HTTP/2 server over TLS

fn serveHttp2OverTls(
    allocator: Allocator,
    tls_conn: *tls_server_mod.TlsServerConn,
    handler: HandlerFn,
    handler_ctx: ?*anyopaque,
) void {
    var session = h2_connection_mod.Session.init(allocator, .server, .{}) catch return;
    defer session.deinit();
    session.startHandshake() catch return;

    // Flush initial h2 handshake through TLS
    if (session.outbound.items.len > 0) {
        tls_conn.writeAll(session.outbound.items) catch return;
        session.outbound.clearRetainingCapacity();
    }

    var sc = H2ServerCtx{ .allocator = allocator };

    session.cbs = .{
        .ctx = &sc,
        .onHeaders = h2SvrOnHeaders,
        .onData = h2SvrOnData,
    };

    var buf: [16 * 1024]u8 = undefined;
    while (!session.closed and !session.goaway_received) {
        const n = tls_conn.read(&buf) catch break;
        if (n == 0) break;
        session.feed(buf[0..n]) catch break;

        if (sc.dispatched and !sc.responded) {
            sc.responded = true;
            const req = HttpRequest{
                .method = sc.method.items,
                .path = sc.path.items,
                .version = "HTTP/2",
                .headers = sc.hdrs.items,
                .body = sc.body.items,
            };
            const resp = handler(handler_ctx, req) catch HttpResponse{ .status = 500 };

            var out_fields = std.ArrayList(h2_transport.Header).empty;
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
            tls_conn.writeAll(session.outbound.items) catch break;
            session.outbound.clearRetainingCapacity();
        }
    }
}

const H2ServerCtx = struct {
    allocator: Allocator,
    sid: u31 = 0,
    method: std.ArrayList(u8) = .empty,
    path: std.ArrayList(u8) = .empty,
    hdrs: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    dispatched: bool = false,
    responded: bool = false,
};

fn h2SvrOnHeaders(ctx: ?*anyopaque, sid: u31, fields: []const h2_transport.Header, end_stream: bool) anyerror!void {
    const sc: *H2ServerCtx = @ptrCast(@alignCast(ctx orelse return));
    sc.sid = sid;
    sc.method.clearRetainingCapacity();
    sc.path.clearRetainingCapacity();
    sc.hdrs.clearRetainingCapacity();
    sc.body.clearRetainingCapacity();
    sc.dispatched = false;
    sc.responded = false;

    for (fields) |f| {
        if (std.mem.eql(u8, f.name, ":method")) {
            try sc.method.appendSlice(sc.allocator, f.value);
        } else if (std.mem.eql(u8, f.name, ":path")) {
            try sc.path.appendSlice(sc.allocator, f.value);
        } else {
            try sc.hdrs.append(sc.allocator, .{ .name = f.name, .value = f.value });
        }
    }

    if (end_stream) sc.dispatched = true;
}

fn h2SvrOnData(ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void {
    const sc: *H2ServerCtx = @ptrCast(@alignCast(ctx orelse return));
    if (sid == sc.sid) {
        if (sc.body.items.len > MAX_HTTP2_REQUEST_BODY -| data.len)
            return error.RequestTooLarge;
        try sc.body.appendSlice(sc.allocator, data);
    }
}

// TLS server listener

pub const ListenerConfig = struct {
    port: u16 = 8443,
    default_identity: ?tls_server_mod.CertIdentity = null,
    cert_selector: ?tls_server_mod.CertSelector = null,
    alpn_protocols: []const alpn_mod.Protocol = &alpn_mod.DEFAULT_TCP_PREFERENCE,
};

pub const TlsListener = struct {
    listener: tcp.Listener,
    config: ListenerConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, io: std.Io, config: ListenerConfig) !TlsListener {
        const l = try tcp.Listener.bind(io, config.port);
        return .{ .listener = l, .config = config, .allocator = allocator };
    }

    pub fn close(self: *TlsListener, io: std.Io) void {
        self.listener.close(io);
    }

    pub fn localPort(self: *const TlsListener) u16 {
        return self.listener.localPort();
    }

    pub fn acceptAndServe(self: *TlsListener, io: std.Io, handler: HandlerFn, handler_ctx: ?*anyopaque) !void {
        var socket = self.listener.accept(io) catch return error.AcceptFailed;
        defer socket.close();

        const tls_config = tls_server_mod.TlsServerConfig{
            .allocator = self.allocator,
            .default_identity = self.config.default_identity,
            .cert_selector = self.config.cert_selector,
            .alpn_protocols = self.config.alpn_protocols,
        };
        var tls_inst = tls_server_mod.TlsServer.init(tls_config);
        var tls_conn = tls_inst.handshake(&socket) catch return error.TlsHandshakeFailed;
        defer tls_conn.deinit();

        const alpn = tls_conn.alpn orelse .@"http/1.1";
        switch (alpn) {
            .h2 => serveHttp2OverTls(self.allocator, &tls_conn, handler, handler_ctx),
            .@"http/1.0", .@"http/1.1" => serveHttp1OverTls(self.allocator, &tls_conn, handler, handler_ctx),
            .h3 => return error.ProtocolError,
        }
    }
};

// Tests

test "TLS listener config defaults" {
    const cfg = ListenerConfig{
        .port = 8443,
    };
    _ = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 3), cfg.alpn_protocols.len);
    try std.testing.expectEqual(alpn_mod.Protocol.h2, cfg.alpn_protocols[0]);
    try std.testing.expectEqual(alpn_mod.Protocol.@"http/1.1", cfg.alpn_protocols[1]);
}
