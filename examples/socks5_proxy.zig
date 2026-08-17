//! SOCKS5h Proxy Example
//!
//! Demonstrates routing HTTP client requests through a SOCKS5h proxy.
//! SOCKS5h performs DNS resolution on the proxy side (remote DNS),
//! which is useful for bypassing local DNS restrictions or
//! hiding your real IP from the DNS server.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn mockBackendHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .message = "Hello from backend!",
        .source = "socks5-proxy-example",
    });
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SOCKS5h Proxy Example ===\n\n", .{});

    // 1. Start a mock backend server
    const backend_port = try pickFreeTcpPort();
    var backend_server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = backend_port,
        .keep_alive = false,
    });
    defer backend_server.deinit();
    try backend_server.get("/data", mockBackendHandler);

    const backend_thread = try backend_server.listenInBackground();
    sleepMs(100);

    std.debug.print("Backend server on port {d}\n", .{backend_port});

    // 2. Configure client with SOCKS5h proxy
    //    In production, replace 127.0.0.1:1080 with your SOCKS5 proxy address.
    //    SOCKS5h = SOCKS5 with remote DNS resolution (h = hostname).
    const proxy_port = 1080; // Default SOCKS5 port
    std.debug.print("\nSOCKS5h proxy config:\n", .{});
    std.debug.print("  Proxy: 127.0.0.1:{d}\n", .{proxy_port});
    std.debug.print("  DNS resolution: remote (via proxy)\n", .{});
    std.debug.print("  Protocol: SOCKS5 with username/password auth\n\n", .{});

    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withProxy(.{
        .host = "127.0.0.1",
        .port = proxy_port,
        .kind = .socks5h,
        .username = "proxyuser",
        .password = "proxypass",
    });

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    // 3. Make a request through the SOCKS5h proxy
    const target_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/data", .{backend_port});
    defer allocator.free(target_url);

    std.debug.print("Sending request to {s} via SOCKS5h proxy...\n", .{target_url});

    // Note: This will fail if no SOCKS5 proxy is running on 127.0.0.1:1080.
    // To test, start a SOCKS5 proxy (e.g., dante, microsocks) on port 1080.
    var response = client.get(target_url, .{}) catch |err| {
        std.debug.print("\nRequest failed (expected if no proxy running): {}\n", .{err});
        std.debug.print("\nTo test with a real proxy:\n", .{});
        std.debug.print("  1. Install a SOCKS5 proxy (e.g., microsocks)\n", .{});
        std.debug.print("  2. Start it: microsocks -p 1080 -u proxyuser -P proxypass\n", .{});
        std.debug.print("  3. Run this example again\n\n", .{});

        // Demo the configuration even without a running proxy
        std.debug.print("--- SOCKS5h Proxy Features ---\n", .{});
        std.debug.print("  - Remote DNS resolution (proxy resolves hostnames)\n", .{});
        std.debug.print("  - Username/password authentication (RFC 1929)\n", .{});
        std.debug.print("  - Supports IPv4, IPv6, and domain targets\n", .{});
        std.debug.print("  - Works with HTTP and HTTPS (TLS pass-through)\n", .{});
        return;
    };
    defer response.deinit();

    std.debug.print("Response status: {d}\n", .{response.status.code});
    if (response.text()) |body| {
        std.debug.print("Response body: {s}\n", .{body});
    }

    std.debug.print("\n--- SOCKS5h vs SOCKS5 ---\n", .{});
    std.debug.print("  SOCKS5:  DNS resolved locally (by client)\n", .{});
    std.debug.print("  SOCKS5h: DNS resolved remotely (by proxy)\n", .{});
    std.debug.print("  Use SOCKS5h when you want the proxy to handle DNS.\n", .{});

    backend_server.stop();
    backend_thread.join();
}
