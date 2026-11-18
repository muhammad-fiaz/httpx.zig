const std = @import("std");
const httpx = @import("httpx");

const cert =
    \\-----BEGIN CERTIFICATE-----
    \\MIICPDCCAeKgAwIBAgIUIaIP30+IolyKqY2rJ3BfBKxmjS8wCgYIKoZIzj0EAwIw
    \\XDELMAkGA1UEBhMCVVMxETAPBgNVBAgMCExvb3BiYWNrMREwDwYDVQQHDAhMb29w
    \\YmFjazETMBEGA1UECgwKSFRUUFggRGVtbzESMBAGA1UEAwwJMTI3LjAuMC4xMB4X
    \\DTI2MTExMTE1MzQ0NloXDTM2MTEwODE1MzQ0NlowXDELMAkGA1UEBhMCVVMxETAP
    \\BgNVBAgMCExvb3BiYWNrMREwDwYDVQQHDAhMb29wYmFjazETMBEGA1UECgwKSFRU
    \\UFggRGVtbzESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0D
    \\AQcDQgAEUKzjhE9LkhCVh6okzC/1wyJbSLM3+1PJeV7q+0F7qMM7kcfqbdY2EuAj
    \\kshw68ObUH+RoIkN5S/FIs4cyLsAjaOBgTB/MB0GA1UdDgQWBBSvfg3xo5kQlX1y
    \\GkkonFKZ88JrlTAfBgNVHSMEGDAWgBSvfg3xo5kQlX1yGkkonFKZ88JrlTAPBgNV
    \\HRMBAf8EBTADAQH/MCwGA1UdEQQlMCOCCWxvY2FsaG9zdIcEfwAAAYcQAAAAAAAA
    \\AAAAAAAAAAAAATAKBggqhkjOPQQDAgNIADBFAiBt0pmSlq3mxXRzzyz2NBe6Sc1L
    \\ULxJMml96rS0XSbVoAIhAM8a0xJ+MZ1Tt4T/bVtVPCOHDYkUVNsqHcWBjO8CeroI
    \\-----END CERTIFICATE-----
;

const key =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgI/MhkJ2rgmNOojla
    \\sfGBI3RA2kOPETl53RBm/n5XTc2hRANCAARQrOOET0uSEJWHqiTML/XDIltIszf7
    \\U8l5Xur7QXuowzuRx+pt1jYS4COSyHDrw5tQf5GgiQ3lL8UizhzIuwCN
    \\-----END PRIVATE KEY-----
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .limits = .{ .maxConnections = 2 },
        .tls = .{
            .certificatePem = cert,
            .privateKeyPem = key,
        },
    });
    defer server.deinit();

    try server.get("/", .{ .handler = handler });

    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "https://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{ .tls = .{ .verify = .none, .allowTruncation = true }, .timeoutMs = 15_000 });
    defer res.deinit();
    std.debug.print("GET / -> {d} {s}\n", .{ res.status, res.body });
}

fn handler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "Hello from HTTPS server!",
        .contentType = "text/plain; charset=utf-8",
    };
}
