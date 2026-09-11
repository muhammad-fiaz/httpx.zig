//! Mutual TLS end to end over loopback using the high-level API: the
//! server requires client certificates (`.clientAuth = .required`) and
//! serves HTTP only to clients that present a trusted certificate.
//! `httpx.Client.get(url, .{ .tls = .{ .clientCertPem, .clientKeyPem } })`
//! drives the native TLS 1.3 client under the hood; a second request
//! without a certificate is rejected during the handshake.

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

fn handler(_: httpx.tls.Request) anyerror!httpx.tls.Response {
    return .{ .status = 200, .body = "mutual-hello" };
}

fn runServer(listener: *httpx.tls.Listener) void {
    listener.run(handler) catch |err| std.debug.print("server error: {s}\n", .{@errorName(err)});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var listener = try httpx.tls.Listener.init(allocator, io, .{
        .port = 0,
        .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
        .clientAuth = .required,
        .clientCaPem = cert_pem,
    });
    defer listener.deinit();
    const port = listener.localPort();
    const th = try std.Thread.spawn(.{}, runServer, .{&listener});
    defer th.join();
    defer listener.stop();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{port});

    // 1. Client WITH a trusted certificate: full HTTPS over mTLS.
    {
        var res = try client.get(url, .{
            .tls = .{
                .verify = .caBundle,
                .caPem = cert_pem,
                .clientCertPem = cert_pem,
                .clientKeyPem = key_pem,
            },
            .timeoutMs = 15_000,
        });
        defer res.deinit();
        if (res.status != 200) return error.UnexpectedStatus;
        if (std.mem.indexOf(u8, res.body, "mutual-hello") == null) return error.UnexpectedBody;
        std.debug.print("mTLS HTTPS: status={d} mutual-hello present\n", .{res.status});
    }

    // 2. Client WITHOUT a certificate: rejected during the handshake.
    {
        if (client.get(url, .{
            .tls = .{ .verify = .caBundle, .caPem = cert_pem },
            .timeoutMs = 15_000,
        })) |res| {
            var r = res;
            r.deinit();
            std.debug.print("UNEXPECTED: empty-cert request served\n", .{});
            return error.UnexpectedSuccess;
        } else |_| {
            std.debug.print("mTLS enforcement: empty-cert client rejected\n", .{});
        }
    }

    std.debug.print("MTLS DEMO VERIFICATION PASSED\n", .{});
}
