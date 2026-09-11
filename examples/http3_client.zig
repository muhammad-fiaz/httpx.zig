//! HTTP/3 protocol example.
//!
//! Demonstrates HTTP/3 (RFC 9114) and QPACK (RFC 9204) request and response
//! building, SETTINGS frame exchanges, and high-level client initialization.
//! Run with: `zig build run-http3-client`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. High-level Client configured for HTTP/3
    var client = httpx.Client.init(allocator, io, .{
        .httpVersion = .http3,
    });
    defer client.deinit();

    std.debug.print("1. HTTP/3 client configured: protocol={s}\n", .{@tagName(client.config.httpVersion.?)});

    // 2. Client & Server HTTP/3 Connection Engines (RFC 9114)
    var client_conn = httpx.http3.Connection.init(allocator, .client);
    defer client_conn.deinit();

    var server_conn = httpx.http3.Connection.init(allocator, .server);
    defer server_conn.deinit();

    // Exchange control stream SETTINGS
    const client_ctrl = try client_conn.buildControlStream();
    defer allocator.free(client_ctrl);

    const server_ctrl = try server_conn.buildControlStream();
    defer allocator.free(server_ctrl);

    // Server processes client settings (skip 1-byte stream type prefix)
    var off: usize = 1;
    const parsed = try httpx.http3.frame.parseFrame(client_ctrl, &off);
    try server_conn.processControlFrame(parsed.frameType, parsed.payload);

    std.debug.print("2. HTTP/3 control stream SETTINGS exchanged successfully\n", .{});

    // 3. HTTP/3 Request & Response Stream with QPACK encoding
    const bidi_stream_id = client_conn.nextBidiStreamId();
    var req_stream = client_conn.createRequestStream(bidi_stream_id);

    const extra_headers = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx.zig-http3" },
        .{ .name = "accept", .value = "application/json" },
    };

    const req_frame = try req_stream.buildRequestHeaders("GET", "https", "example.com", "/api/v1/resource", &extra_headers);
    defer allocator.free(req_frame);

    std.debug.print("3. Built HTTP/3 request on stream {d} ({d} bytes QPACK payload)\n", .{ bidi_stream_id, req_frame.len });

    // Server response stream
    var resp_stream = server_conn.createRequestStream(bidi_stream_id);

    const resp_headers = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "server", .value = "httpx.zig/0.1.0" },
    };

    const resp_head = try resp_stream.buildResponseHeaders(200, &resp_headers);
    defer allocator.free(resp_head);

    const resp_body = try resp_stream.buildData("{\"status\":\"ok\",\"protocol\":\"HTTP/3\"}");
    defer allocator.free(resp_body);

    std.debug.print("4. Server generated HTTP/3 response: HEADERS ({d} bytes), DATA ({d} bytes)\n", .{ resp_head.len, resp_body.len });
    std.debug.print("HTTP/3 client-server protocol validation complete.\n", .{});

    try liveLoopbackDemo(allocator, io);
}

// Loopback test identity (P-256, SAN 127.0.0.1/localhost). Inlined
// because examples build as separate packages.
const demo_cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBmTCCAT+gAwIBAgIURhx0CMJWTUTFJXV9z2OlmW/cNlcwCgYIKoZIzj0EAwIw
    \\FDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDkwOTE4MTczOFoXDTM2MDkwNjE4
    \\MTczOFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0D
    \\AQcDQgAE71D4pM0SAPK8sdt+xlEESZX/EJoKHUC+4IpPuSlOiQuCXOkN04ozVGKA
    \\mrmUtDqQCdvmdjHbjqGY6TCszXTCnKNvMG0wHQYDVR0OBBYEFFjYJYGodkVKyvXf
    \\4qrn7rvQx+PFMB8GA1UdIwQYMBaAFFjYJYGodkVKyvXf4qrn7rvQx+PFMA8GA1Ud
    \\EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYcEfwAAAYIJbG9jYWxob3N0MAoGCCqGSM49
    \\BAMCA0gAMEUCIQD0sAcuw/jdWdfBrxLXY1ur2cU8F0CAkPCvS2qKn7XK4QIgAP71
    \\95toW+Gsh8/VZlNoHL2s14olRp5zl3cYDPzKM10=
    \\-----END CERTIFICATE-----
;
const demo_key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

const DemoServer = struct {
    ep: httpx.quic.Endpoint = undefined,
    pump: httpx.quic.Pump = undefined,

    const Acc = struct {
        sid: u64 = std.math.maxInt(u64),
        buf: std.ArrayList(u8) = .empty,
        fin: bool = false,
        alloc: std.mem.Allocator = undefined,
    };

    fn onStream(c: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const acc: *Acc = @ptrCast(@alignCast(c.?));
        if (acc.sid == std.math.maxInt(u64) and sid % 4 == 0) acc.sid = sid;
        if (sid != acc.sid) return;
        acc.buf.appendSlice(acc.alloc, data) catch return;
        if (fin) acc.fin = true;
    }

    fn run(srv: *DemoServer, io: std.Io, alloc: std.mem.Allocator, out: *?anyerror) void {
        serve(srv, io, alloc) catch |e| {
            out.* = e;
            return;
        };
        out.* = null;
    }

    fn nowMs(io: std.Io) u64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).toNanoseconds(), 1_000_000));
    }

    fn serve(srv: *DemoServer, io: std.Io, alloc: std.mem.Allocator) !void {
        var qconn = try httpx.quic.Connection.init(alloc, .server, .{}, 0x51);
        defer qconn.deinit();
        srv.ep.conn = qconn;
        var drv = httpx.quic.HandshakeDriver.initServer(alloc, .{ .certChainPem = demo_cert_pem, .privateKeyPem = demo_key_pem });
        defer drv.deinit();
        qconn.tls = .{ .ctx = &drv, .start = httpx.quic.HandshakeDriver.clientStart, .onData = httpx.quic.HandshakeDriver.onData };
        try httpx.quic.handshake.serveHandshake(&srv.ep, &srv.pump, &drv, 15_000);

        var h3 = httpx.http3.Connection.init(alloc, .server);
        defer h3.deinit();
        var acc = Acc{ .alloc = alloc };
        defer acc.buf.deinit(alloc);
        qconn.cbs = .{ .ctx = &acc, .onStreamData = onStream };
        const start = nowMs(io);
        while (true) {
            const now = nowMs(io);
            if (now -| start > 15_000) return error.Timeout;
            try httpx.quic.handshake.feedPumped(&srv.ep, &srv.pump, null, 500, now);
            if (!acc.fin) continue;
            var off: usize = 0;
            const fr = try httpx.http3.frame.parseFrame(acc.buf.items, &off);
            const fields = try h3.qdec.decodeSectionWithPrefix(fr.payload);
            defer h3.qdec.freeFields(fields);
            var path: []const u8 = "/";
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, ":path")) path = f.value;
            }
            var rs = httpx.http3.RequestStream{ .id = acc.sid, .allocator = alloc, .qpack = httpx.http3.qpack.Encoder.init(alloc) };
            defer rs.qpack.deinit();
            const rhead = try rs.buildResponseHeaders(200, &.{});
            defer alloc.free(rhead);
            const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"protocol\":\"HTTP/3\"}}", .{path});
            defer alloc.free(body);
            const rdata = try rs.buildData(body);
            defer alloc.free(rdata);
            try sendH3(qconn, acc.sid, rhead, rdata);
            _ = try srv.ep.flush(null);
            return;
        }
    }

    fn sendH3(conn: *httpx.quic.Connection, sid: u64, head: []const u8, data: []const u8) !void {
        const B = struct {
            var s_id: u64 = 0;
            var s_data: []const u8 = "";
            var s_data2: []const u8 = "";
            pub fn build(gpa: std.mem.Allocator, payload: *std.ArrayList(u8)) httpx.quic.connection.Error!void {
                httpx.quic.frames.encode(payload, gpa, .{ .stream = .{ .id = s_id, .offset = 0, .data = s_data, .fin = false } }) catch
                    return httpx.quic.connection.Error.OutOfMemory;
                httpx.quic.frames.encode(payload, gpa, .{ .stream = .{ .id = s_id, .offset = s_data.len, .data = s_data2, .fin = true } }) catch
                    return httpx.quic.connection.Error.OutOfMemory;
            }
        };
        B.s_id = sid;
        B.s_data = head;
        B.s_data2 = data;
        try conn.sendFrames(.application, B.build, 0);
    }
};

/// Live loopback: a real QUIC + TLS 1.3 handshake (ALPN h3, verified
/// chain) over kernel UDP sockets, then an HTTP/3 GET through the
/// high-level client. Always runs (no internet required).
fn liveLoopbackDemo(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== HTTP/3 live loopback (QUIC + TLS 1.3 over UDP) ===\n", .{});

    var placeholder = try httpx.quic.Connection.init(allocator, .server, .{}, 0x50);
    defer placeholder.deinit();
    var srv = DemoServer{};
    srv.ep = try httpx.quic.transport.Endpoint.initPort(allocator, io, placeholder, 0);
    const port = srv.ep.localPort();
    defer srv.ep.deinit();
    try srv.pump.start(&srv.ep, allocator);
    defer srv.pump.stop();

    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, DemoServer.run, .{ &srv, io, allocator, &result });
    defer th.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/api/v1/resource", .{port});
    var res = try client.get(url, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demo_cert_pem },
        .timeoutMs = 15_000,
    });
    defer res.deinit();
    std.debug.print("5. LIVE client.get: status={d} version={s} body={s}\n", .{ res.status, @tagName(res.version), res.body });
    if (res.status != 200) return error.UnexpectedStatus;
    if (res.version != .http3) return error.UnexpectedVersion;
    std.debug.print("H3 LIVE DEMO VERIFICATION PASSED\n", .{});
}
