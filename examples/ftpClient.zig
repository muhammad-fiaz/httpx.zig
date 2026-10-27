const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("=== HTTPX Native FTP Client ===\n", .{});

    // 1. Configure FTP options
    const ftpOpts: httpx.protocols.ftp.Options = .{
        .host = "test.rebex.net",
        .port = 21,
        .user = "demo",
        .password = "password",
        .secure = false, // Set to true for explicit FTPS
    };

    std.debug.print("1. FTP client configuration: {s}:{d}\n", .{ ftpOpts.host, ftpOpts.port });

    // 2. Connect via TCP.
    var client = httpx.protocols.ftp.Client.connect(allocator, ftpOpts) catch |err| {
        std.debug.print("3. FTP connection failed: {s}\n", .{@errorName(err)});
        std.debug.print("   Skipping network tests (server may be unreachable).\n", .{});
        return;
    };
    defer client.deinit();

    std.debug.print("3. Connected to FTP server successfully!\n", .{});

    // 4. Login
    client.login("demo", "password") catch |err| {
        std.debug.print("4. Login failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("4. Login successful\n", .{});

    // 5. List files (result lifetime is managed automatically by Client until next operation or client.deinit)
    const files = client.list("/") catch |err| {
        std.debug.print("5. List files failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("5. File listing:\n{s}\n", .{files});

    std.debug.print("FTP client demonstration completed.\n", .{});
    try ftpsLoopbackDemo();
}

// Loopback test identity (P-256, SAN 127.0.0.1/localhost). Inlined
// because examples build as separate packages and cannot embed outside
// their own directory.
const ftpsCertPem =
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
const ftpsKeyPem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

fn ftpsAllow(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
    return true;
}
fn ftpsList(_: ?*anyopaque, _: []const u8) []const u8 {
    return "-rw-r--r-- 1 owner group 12 Jan 01 2025 secure.txt\r\n";
}
fn ftpsRetrieve(_: ?*anyopaque, _: []const u8) []const u8 {
    return "ftps-bytes\n";
}

/// Explicit FTPS end to end over loopback: AUTH TLS + PROT P against an
/// in-process server. Always runs (no internet required).
fn ftpsLoopbackDemo() !void {
    std.debug.print("=== HTTPX Native FTPS Client (loopback) ===\n", .{});
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.protocols.ftp.Server.init(allocator, io, .{
        .port = 0,
        .certChainPem = ftpsCertPem,
        .privateKeyPem = ftpsKeyPem,
        .callbacks = .{
            .authenticate = ftpsAllow,
            .list = ftpsList,
            .retrieve = ftpsRetrieve,
        },
    });
    defer server.deinit();
    const port = server.localPort();
    const Runner = struct {
        fn run(s: *httpx.protocols.ftp.Server) void {
            s.run(1) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, Runner.run, .{&server});
    defer th.join();

    var client = try httpx.protocols.ftp.Client.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = port,
        .secure = true,
        .tlsCaPem = ftpsCertPem,
    });
    defer client.deinit();

    try client.login("demo", "password");
    std.debug.print("1. FTPS login over AUTH TLS + PROT P\n", .{});
    const files = try client.list("");
    if (std.mem.indexOf(u8, files, "secure.txt") == null) return error.UnexpectedListing;
    std.debug.print("2. FTPS LIST: secure.txt present\n", .{});
    client.quit();
    std.debug.print("FTPS DEMO VERIFICATION PASSED\n", .{});
}
