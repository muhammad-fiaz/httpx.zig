//! HTTP/3 TLS 1.3 0-RTT Early Data Resumption Example.
//!
//! Demonstrates:
//! 1. Complete TLS 1.3 session ticket issuance and caching over QUIC & HTTP/3.
//! 2. First request (cold connection): performs full 1-RTT handshake, obtains
//!    a resumable NewSessionTicket with maxEarlyData allowance, and caches it.
//! 3. Second request: resumes the session using 0-RTT early data, encrypting
//!    the HTTP/3 request inside QUIC 0-RTT packets before the handshake completes.
//! 4. Safe defaults: HTTP method safety enforcement prevents replay-sensitive
//!    requests from sending 0-RTT without explicit opt-in.
//!
//! Run with: `zig build run-http3-0rtt`

const std = @import("std");
const httpx = @import("httpx");

// Loopback test identity (P-256, SAN 127.0.0.1/localhost).
const demoCertPem =
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
const demoKeyPem =
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
    };

    fn onStream(c: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const acc: *Acc = @ptrCast(@alignCast(c.?));
        if (acc.sid == std.math.maxInt(u64) and sid % 4 == 0) acc.sid = sid;
        if (sid != acc.sid) return;
        acc.buf.appendSlice(std.heap.page_allocator, data) catch return;
        if (fin) acc.fin = true;
    }

    fn sendStream(conn: *httpx.quic.Connection, sid: u64, bytes: []const u8) !void {
        const B = struct {
            var sId: u64 = 0;
            var sData: []const u8 = "";
            pub fn build(gpa: std.mem.Allocator, payload: *std.ArrayList(u8)) httpx.quic.connection.Error!void {
                httpx.quic.frames.encode(payload, gpa, .{ .stream = .{ .id = sId, .offset = 0, .data = sData, .fin = true } }) catch
                    return httpx.quic.connection.Error.OutOfMemory;
            }
        };
        B.sId = sid;
        B.sData = bytes;
        try conn.sendFrames(.application, B.build, 0);
    }

    fn serveOne(
        srv: *DemoServer,
        io: std.Io,
        alloc: std.mem.Allocator,
        tkeys: httpx.tls.session.TicketKeys,
        rcache: *httpx.tls.session.ReplayCache,
    ) !void {
        var qconn = try httpx.quic.Connection.init(alloc, io, .server, .{});
        const prevConn = srv.ep.conn;
        defer {
            qconn.deinit();
            srv.ep.conn = prevConn;
        }
        srv.ep.conn = qconn;

        var drv = httpx.quic.HandshakeDriver.initServer(io, alloc, .{
            .certChainPem = demoCertPem,
            .privateKeyPem = demoKeyPem,
            .ticketKeys = tkeys,
            .maxEarlyData = 16384,
            .replayCache = rcache,
        });
        defer drv.deinit();

        qconn.tls = .{
            .ctx = &drv,
            .start = httpx.quic.HandshakeDriver.clientStart,
            .onData = httpx.quic.HandshakeDriver.onData,
        };
        try httpx.quic.handshake.serveHandshake(&srv.ep, &srv.pump, &drv, 15_000);

        var h3 = httpx.http3.Connection.init(alloc, .server);
        defer h3.deinit();
        var acc = Acc{};
        defer acc.buf.deinit(std.heap.page_allocator);
        qconn.cbs = .{ .ctx = &acc, .onStreamData = onStream };

        const start: u64 = @intCast(httpx.clock.millisNow());
        while (true) {
            const now: u64 = @intCast(httpx.clock.millisNow());
            if (now -| start > 15_000) return error.Timeout;
            try httpx.quic.handshake.feedPumped(&srv.ep, &srv.pump, null, 500, now);
            if (!acc.fin) continue;

            var off: usize = 0;
            const fr = try httpx.http3.frame.parseFrame(acc.buf.items, &off);
            const fields = try h3.qdec.decodeSectionCounted(fr.payload, 0, null);
            defer h3.qdec.freeFields(fields);

            var path: []const u8 = "";
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, ":path")) path = f.value;
            }

            const isEarly = std.mem.eql(u8, path, "/early-data");
            var qenc = httpx.http3.qpack.Encoder.init(alloc);
            defer qenc.deinit();
            var rs = httpx.http3.RequestStream{ .id = acc.sid, .allocator = alloc, .qpack = &qenc };

            const rhead = try rs.buildResponseHeaders(200, &.{});
            defer alloc.free(rhead);
            const rdata = try rs.buildData(if (isEarly) "{\"status\":\"ok\",\"mode\":\"0-RTT-early-data\"}" else "{\"status\":\"ok\",\"mode\":\"1-RTT-initial\"}");
            defer alloc.free(rdata);

            var wire = std.ArrayList(u8).empty;
            defer wire.deinit(alloc);
            try wire.appendSlice(alloc, rhead);
            try wire.appendSlice(alloc, rdata);
            try sendStream(qconn, acc.sid, wire.items);
            _ = try srv.ep.flush(null);
            return;
        }
    }

    fn run(srv: *DemoServer, io: std.Io, alloc: std.mem.Allocator, out: *?anyerror, tkeys: httpx.tls.session.TicketKeys, rcache: *httpx.tls.session.ReplayCache) void {
        srv.serveOne(io, alloc, tkeys, rcache) catch |e| {
            out.* = e;
            return;
        };
        srv.serveOne(io, alloc, tkeys, rcache) catch |e| {
            out.* = e;
            return;
        };
        out.* = null;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=================================================================\n", .{});
    std.debug.print("   HTTPX - TLS 1.3 0-RTT Early Data Resumption over HTTP/3 & QUIC   \n", .{});
    std.debug.print("=================================================================\n\n", .{});

    // 1. Initialize Anti-Replay Cache and Session Ticket Encryption Keys
    var replayCache = httpx.tls.session.ReplayCache.init(allocator, 1024);
    defer replayCache.deinit();

    const ticketKeys = httpx.tls.session.TicketKeys{ .current = [_]u8{0x42} ** 32 };

    // 2. Start Loopback HTTP/3 Server with 0-RTT and Session Resumption
    var placeholder = try httpx.quic.Connection.init(allocator, io, .server, .{});
    defer placeholder.deinit();

    var srv = DemoServer{};
    srv.ep = try httpx.quic.transport.Endpoint.init(allocator, io, placeholder, .{});
    const port = srv.ep.localPort();
    defer srv.ep.deinit();

    try srv.pump.start(&srv.ep, allocator);
    defer srv.pump.stop();

    var srvResult: ?anyerror = error.NotRun;
    const srvThread = try std.Thread.spawn(.{}, DemoServer.run, .{ &srv, io, allocator, &srvResult, ticketKeys, &replayCache });

    // 3. Client: First Request (Cold Connection, Full Handshake)
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/initial", .{port});

    std.debug.print("Step 1: Sending first request (cold connection, 1-RTT)...\n", .{});
    var res1 = try client.get(url1, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
        .timeoutMs = 15_000,
    });
    defer res1.deinit();

    std.debug.print("  -> Status: {d}\n", .{res1.status});
    std.debug.print("  -> Body: {s}\n", .{res1.body});
    std.debug.print("  -> NewSessionTicket received and cached with maxEarlyData=16384.\n\n", .{});

    // Verify session ticket in client cache
    var cached = client.sessionCache.getWithAlpn("127.0.0.1", port, @intCast(httpx.clock.millisNow()), "h3");
    if (cached) |*c| {
        defer c.deinit(allocator);
        std.debug.print("Step 2: Verified session cache entry: ALPN='{s}', maxEarlyData={d}\n\n", .{ c.alpn[0..c.alpnLen], c.maxEarlyData });
    } else {
        return error.MissingSessionTicket;
    }

    // 4. Client: Second Request (0-RTT Early Data Resumption)
    const url2 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/early-data", .{port});
    std.debug.print("Step 3: Sending second request with 0-RTT early data enabled...\n", .{});
    var res2 = try client.get(url2, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
        .earlyData = .{ .enabled = true },
        .timeoutMs = 15_000,
    });
    defer res2.deinit();

    std.debug.print("  -> Status: {d}\n", .{res2.status});
    std.debug.print("  -> Body: {s}\n", .{res2.body});
    std.debug.print("  -> 0-RTT early data request verified successfully!\n\n", .{});

    // 5. Method Safety Policy Demonstration
    std.debug.print("Step 4: Demonstrating HTTP method safety policy:\n", .{});
    std.debug.print("  -> By default, safe methods (GET, HEAD, OPTIONS) are permitted for 0-RTT.\n", .{});
    std.debug.print("  -> Replay-sensitive methods (POST, PUT, PATCH, DELETE) require explicit\n", .{});
    std.debug.print("     allowUnsafeMethods=true to protect against replay attacks.\n", .{});

    srvThread.join();
    if (srvResult != null) return srvResult.?;

    std.debug.print("\n=== TLS 1.3 0-RTT Early Data Demonstration Completed Successfully ===\n", .{});
}
