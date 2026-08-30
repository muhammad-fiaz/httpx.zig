const std = @import("std");
const httpx = @import("httpx");

const cert =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBkjCB/gIJAMbH0zIKaGmBMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBmNh
    \\LWRldjAeFw0yNTAxMDEwMDAwMDBaFw0zNTAxMDEwMDAwMDBaMBExDzANBgNVBAMM
    \\BmNhLWRldjBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC3ULszTSDoxzgVlMC2Bo1N
    \\5H15fN/5v0y3fUZ/1X0+3f7e9v8q6w2k8r4j1m5n7b3c9x2d0a4h8s6f2g5j7k1l
    \\3p9m0q4w8r5t2y6u1i4o7e3a9x0c5b8n2v6d4f7h1j3k9l5m8p0q2w6r4t7y1u3i
    \\QwIDAQABo1MwUTAdBgNVHQ4EFgQUfCDEH2N3d3FgT7K5p9m8v2b1c0YwHwYDVR0j
    \\BBgwFoAUfCDEH2N3d3FgT7K5p9m8v2b1c0YwDwYDVR0TAQH/BAUwAwEB/zANBgkq
    \\hkiG9w0BAQsFAANBAEL3f8k5x7p2m9q4w1r6t0y8u3i5o7e2a9x4c5b8n2v6d1f3h
    \\7j0k9l5m8p2q4w6r3t1y0u4i8o3e7a9x5c2b6n0v8d4f1h7j3k5l9m6p0q2w8r4t
    \\-----END CERTIFICATE-----
;

const key =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAt1C7M00g6Mc4FZTA
    \\tgaNTer9efzr/4p0v/1Gf9V9Pt3+/vb/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+
    \\I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/
    \\KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+29
    \\3vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+
    \\I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/
    \\KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+293vcvf8r/KusNpPK+I9ZuZ+29
    \\3vcvf8r/KgIDAQAQ
    \\-----END PRIVATE KEY-----
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tls_listener = try httpx.TlsListener.init(allocator, .{
        .port = 8447,
        .default_identity = .{
            .cert_chain_pem = cert,
            .private_key_pem = key,
        },
    });
    defer tls_listener.deinit();

    const server_thread = try std.Thread.spawn(.{}, runServer, .{&tls_listener});
    httpx.clock.sleepMillis(500);

    var client = try httpx.Client.init(allocator, .{
        .timeout_ms = 5_000,
    });
    defer client.deinit();

    var response = client.get(.{
        .url = "https://127.0.0.1:8447/",
        .tls = .{ .verify = .none },
    }) catch |err| {
        std.debug.print("TLS error: {s}\n", .{@errorName(err)});
        tls_listener.requestShutdown();
        server_thread.join();
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});

    tls_listener.requestShutdown();
    server_thread.join();
}

fn runServer(listener: *httpx.TlsListener) void {
    listener.run(handleRequest, null) catch {};
}

fn handleRequest(_: ?*anyopaque, _: httpx.TlsRequest) anyerror!httpx.TlsResponse {
    return .{
        .status = 200,
        .body = "Hello from TLS server!",
    };
}
