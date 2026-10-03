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
    var clientConn = httpx.http3.Connection.init(allocator, .client);
    defer clientConn.deinit();

    var serverConn = httpx.http3.Connection.init(allocator, .server);
    defer serverConn.deinit();

    // Exchange control stream SETTINGS
    const clientCtrl = try clientConn.buildControlStream();
    defer allocator.free(clientCtrl);

    const serverCtrl = try serverConn.buildControlStream();
    defer allocator.free(serverCtrl);

    // Server processes client settings (skip 1-byte stream type prefix)
    var off: usize = 1;
    const parsed = try httpx.http3.frame.parseFrame(clientCtrl, &off);
    try serverConn.processControlFrame(parsed.frameType, parsed.payload);

    std.debug.print("2. HTTP/3 control stream SETTINGS exchanged successfully\n", .{});

    // 3. HTTP/3 Request & Response Stream with QPACK encoding
    const bidiStreamId = clientConn.nextBidiStreamId();
    var reqStream = clientConn.createRequestStream(bidiStreamId);

    const extraHeaders = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "user-agent", .value = "httpx.zig-http3" },
        .{ .name = "accept", .value = "application/json" },
    };

    const reqFrame = try reqStream.buildRequestHeaders("GET", "https", "example.com", "/api/v1/resource", &extraHeaders);
    defer allocator.free(reqFrame);

    std.debug.print("3. Built HTTP/3 request on stream {d} ({d} bytes QPACK payload)\n", .{ bidiStreamId, reqFrame.len });

    // Server response stream
    var respStream = serverConn.createRequestStream(bidiStreamId);

    const respHeaders = [_]httpx.http3.qpack.FieldLine{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "server", .value = "httpx.zig/0.1.0" },
    };

    const respHead = try respStream.buildResponseHeaders(200, &respHeaders);
    defer allocator.free(respHead);

    const respBody = try respStream.buildData("{\"status\":\"ok\",\"protocol\":\"HTTP/3\"}");
    defer allocator.free(respBody);

    std.debug.print("4. Server generated HTTP/3 response: HEADERS ({d} bytes), DATA ({d} bytes)\n", .{ respHead.len, respBody.len });
    std.debug.print("HTTP/3 client-server protocol validation complete.\n", .{});

    try liveLoopbackDemo(allocator, io);
}

// Loopback test identity (P-256, SAN 127.0.0.1/localhost). Inlined
// because examples build as separate packages.
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

/// Live loopback: a real QUIC + TLS 1.3 handshake (ALPN h3, verified
/// chain) over kernel UDP sockets, then an HTTP/3 GET through the
/// high-level client against high-level httpx.Server. Always runs (no internet required).
fn liveLoopbackDemo(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== HTTP/3 live loopback (QUIC + TLS 1.3 over UDP) ===\n", .{});

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .tls = .{
            .certificatePem = demoCertPem,
            .privateKeyPem = demoKeyPem,
        },
        .enableDocs = false,
    });
    defer server.deinit();

    const ApiHandler = struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"path\":\"{s}\",\"protocol\":\"HTTP/3\"}}", .{ctx.path});
            return .{
                .status = 200,
                .body = body,
                .contentType = "application/json",
            };
        }
    };
    try server.get("/api/v1/resource", ApiHandler.handle);

    const srvThread = try server.start();
    defer {
        server.requestShutdown();
        srvThread.join();
    }

    // HTTP/3 normally shares the TCP port, but falls back to its own if
    // that UDP bind fails, so ask the server which port it actually got.
    const port = server.http3.port() orelse return error.NoHttp3Endpoint;

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/api/v1/resource", .{port});
    var res = try client.get(url, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
        .timeoutMs = 15_000,
    });
    defer res.deinit();
    std.debug.print("5. LIVE client.get: status={d} version={s} body={s}\n", .{ res.status, @tagName(res.version), res.body });
    if (res.status != 200) return error.UnexpectedStatus;
    if (res.version != .http3) return error.UnexpectedVersion;
    std.debug.print("H3 LIVE DEMO VERIFICATION PASSED\n", .{});
}
