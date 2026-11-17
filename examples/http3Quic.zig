//! HTTP/3 & QUIC example.
//!
//! Demonstrates:
//! 1. QUIC variable-length integer encoding (RFC 9000 Section 16)
//! 2. QUIC frame construction (RFC 9000 Section 12.4)
//! 3. QPACK dynamic-table encoding (RFC 9204)
//! 4. A live HTTP/3 request through `httpx.Client` against `httpx.Server`
//!    (QUIC + TLS 1.3 over UDP)
//!
//! Run with: `zig build run-http3-quic`

const std = @import("std");
const httpx = @import("httpx");

// Loopback test identity (P-256, SAN 127.0.0.1/localhost). Inlined because
// examples build as separate packages.
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=== HTTP/3 & QUIC Protocol Engine ===\n", .{});

    // 1. QUIC Variable-Length Integer Encoding (RFC 9000 Section 16)
    var varintBuf: [16]u8 = undefined;
    const testValues = [_]u62{ 25, 15293, 494878333, 1512888099419124471 };
    std.debug.print("1. QUIC Varint Encoding:\n", .{});
    for (testValues) |val| {
        const n = try httpx.quic.varint.encode(&varintBuf, val);
        var off: usize = 0;
        const decodedVal = try httpx.quic.varint.decode(varintBuf[0..n], &off);
        std.debug.print("   Value {d} -> encoded {d} bytes, decoded {d}\n", .{ val, n, decodedVal });
    }

    // 2. QUIC Frame Construction (RFC 9000 section 12.4)
    var frame = try httpx.quic.encodeFrame(allocator, .{
        .stream = .{
            .id = 4,
            .offset = 0,
            .data = "HTTP/3 over QUIC binary stream",
            .fin = true,
        },
    });
    defer frame.deinit(allocator);
    std.debug.print("2. Encoded QUIC STREAM Frame (Stream 4, FIN=true) -> {d} bytes\n", .{frame.items.len});

    // 3. QPACK Dynamic Table Encoding (RFC 9204)
    var qenc = httpx.http3.qpack.Encoder.init(allocator);
    defer qenc.deinit();

    var fieldSection = std.ArrayList(u8).empty;
    defer fieldSection.deinit(allocator);

    // Required Insert Count & Delta Base prefix
    try fieldSection.appendSlice(allocator, "\x00\x00");
    try qenc.encodeField(&fieldSection, ":method", "GET");
    try qenc.encodeField(&fieldSection, ":path", "/index.html");
    try qenc.encodeField(&fieldSection, ":scheme", "https");
    try qenc.encodeField(&fieldSection, ":authority", "quic.example.org");
    try qenc.encodeField(&fieldSection, "x-quic-version", "v1");

    std.debug.print("3. QPACK encoded 5 HTTP/3 headers into {d} bytes\n", .{fieldSection.items.len});

    // 4. Live HTTP/3 request: server over QUIC/TLS, client through the
    //    public HTTP API.
    try liveHttp3Demo(allocator, io);

    std.debug.print("HTTP/3 & QUIC demonstration completed successfully.\n", .{});
}

fn liveHttp3Demo(allocator: std.mem.Allocator, io: std.Io) !void {
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .protocols = .{ .http3 = true },
        .tls = .{
            .certificatePem = demoCertPem,
            .privateKeyPem = demoKeyPem,
        },
    });
    defer server.deinit();

    const ApiHandler = struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"path\":\"{s}\",\"protocol\":\"HTTP/3\"}}", .{ctx.path});
            return .{ .status = 200, .body = body, .contentType = "application/json" };
        }
    };
    try server.get("/api/v1/resource", ApiHandler.handle);

    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    // HTTP/3 normally shares the TCP port but falls back to its own when the
    // UDP bind fails, so ask the server which port it actually got.
    const port = server.http3.port() orelse return error.NoHttp3Endpoint;

    while (server.h3Pump == null) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

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

    std.debug.print("4. LIVE client.get: status={d} version={s} body={s}\n", .{ res.status, @tagName(res.version), res.body });
    if (res.status != 200) return error.UnexpectedStatus;
    if (res.version != .http3) return error.UnexpectedVersion;
}
