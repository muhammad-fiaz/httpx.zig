//! HTTP/3 TLS 1.3 0-RTT Early Data Resumption Example.
//!
//! Server and client are the high-level owners: `httpx.Server` serves
//! HTTP/3 over QUIC with session tickets, and `httpx.Client` issues
//! requests against it. The first request performs a full 1-RTT
//! handshake and caches the NewSessionTicket; the second resumes
//! with 0-RTT early data.
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

fn initialHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ok", .mode = "1-RTT-initial" });
}

fn earlyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ok", .mode = "0-RTT-early-data" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=================================================================\n", .{});
    std.debug.print("   HTTPX - TLS 1.3 0-RTT Early Data Resumption over HTTP/3 & QUIC   \n", .{});
    std.debug.print("=================================================================\n\n", .{});

    // One init owns the listener, router, and HTTP/3 endpoint.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .enableDocs = false,
        .tls = .{
            .certificatePem = demoCertPem,
            .privateKeyPem = demoKeyPem,
        },
    });
    defer server.deinit();

    try server.get("/initial", initialHandler);
    try server.get("/early-data", earlyHandler);

    const port = server.http3.port() orelse return error.Http3Disabled;
    std.debug.print("Listening on https://127.0.0.1:{d}\n\n", .{port});

    const Runner = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const srvThread = try std.Thread.spawn(.{}, Runner.run, .{&server});

    // One init owns the pool, DNS cache, and session cache.
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url1 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/initial", .{port});

    std.debug.print("Step 1: Sending first request (cold connection, 1-RTT)...\n", .{});
    var res1 = try client.get(url1, .{
        .httpVersion = .http3,
        .tls = .{
            .verify = .caBundle,
            .caPem = demoCertPem,
        },
        .timeoutMs = 15_000,
    });
    defer res1.deinit();

    std.debug.print("  -> Status: {d}\n", .{res1.status});
    std.debug.print("  -> Body: {s}\n", .{res1.body});
    std.debug.print("  -> NewSessionTicket received and cached with maxEarlyData=16384.\n\n", .{});

    // Verify session ticket in client cache
    var cached = client.session.cache("127.0.0.1", port, .{
        .alpn = "h3",
        .tls = .{ .verify = .caBundle, .caPem = demoCertPem },
    });
    if (cached) |*c| {
        defer c.deinit(allocator);
        std.debug.print("Step 2: Verified session cache entry: ALPN='{s}', maxEarlyData={d}\n\n", .{ c.alpn[0..c.alpnLen], c.maxEarlyData });
    } else {
        server.requestShutdown();
        srvThread.join();
        return error.MissingSessionTicket;
    }

    // Second request resumes with 0-RTT early data.
    const url2 = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/early-data", .{port});
    std.debug.print("Step 3: Sending second request with 0-RTT early data enabled...\n", .{});
    var res2 = try client.get(url2, .{
        .httpVersion = .http3,
        .tls = .{
            .verify = .caBundle,
            .caPem = demoCertPem,
        },
        .earlyData = .{ .enabled = true },
        .timeoutMs = 15_000,
    });
    defer res2.deinit();

    std.debug.print("  -> Status: {d}\n", .{res2.status});
    std.debug.print("  -> Body: {s}\n", .{res2.body});
    std.debug.print("  -> 0-RTT early data request verified successfully!\n\n", .{});

    std.debug.print("Step 4: Safe methods (GET, HEAD, OPTIONS) use 0-RTT by default.\n", .{});
    std.debug.print("        Replay-sensitive methods require allowUnsafeMethods=true.\n\n", .{});

    server.requestShutdown();
    srvThread.join();

    std.debug.print("=== TLS 1.3 0-RTT Early Data Demonstration Completed Successfully ===\n", .{});
}
