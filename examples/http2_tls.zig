//! HTTP/2 over TLS end to end over loopback: the server negotiates `h2`
//! via ALPN behind the native TLS engine, and the client verifies the
//! chain + hostname before exchanging an H2 request/response.

const std = @import("std");
const httpx = @import("httpx");

const cert_pem =
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

const key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

fn handle(
    _: ?*anyopaque,
    method: []const u8,
    path: []const u8,
    _: []const httpx.http2.transport.Header,
    _: []const u8,
) anyerror!httpx.http2.transport.HandlerResponse {
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/secure")) {
        return .{ .status = 200, .body = "secure-h2" };
    }
    return .{ .status = 404, .body = "nope" };
}

fn runServer(lst: *httpx.tcp.Listener, io: std.Io) void {
    var conn = lst.accept(io) catch return;
    defer conn.close();
    var srv = httpx.tls.TlsServer.init(.{
        .allocator = std.heap.page_allocator,
        .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
    });
    var tls_conn = srv.handshake(io, &conn) catch return;
    defer tls_conn.deinit();
    httpx.http2.transport.serveTlsConnection(std.heap.page_allocator, &tls_conn, handle, null) catch return;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var ctx = try httpx.tcp.IoContext.init(allocator);
    defer ctx.deinit();
    var listener = try httpx.tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const th = try std.Thread.spawn(.{}, runServer, .{ &listener, ctx.io });
    defer th.join();

    // Two ways to speak H2 over TLS: the high-level client API...
    {
        var client = httpx.Client.init(allocator, io, .{});
        defer client.deinit();
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/secure", .{port});
        var res = try client.get(url, .{
            .httpVersion = .http2,
            .tls = .{ .verify = .caBundle, .caPem = cert_pem },
            .timeoutMs = 15_000,
        });
        defer res.deinit();
        std.debug.print("client.get: status={d} body={s} version={s}\n", .{ res.status, res.body, res.version.wireNameResolved() });
        if (res.status != 200) return error.UnexpectedStatus;
    }

    std.debug.print("H2-TLS DEMO VERIFICATION PASSED\n", .{});
}
