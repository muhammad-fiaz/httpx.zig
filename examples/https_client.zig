//! HTTPS Client Example
//!
//! Demonstrates making an HTTPS request using the built-in TLS 1.2/1.3
//! implementation. The TLS handshake negotiates ALPN for HTTP/1.1 or HTTP/2
//! automatically.
//!
//! Set HTTPX_EXAMPLE_ONLINE=1 to run a live request against example.com.
//! By default runs in offline mode to avoid external network dependencies in CI.

const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn shouldUseLiveNetwork(environ: std.process.Environ, allocator: std.mem.Allocator) bool {
    const value = environ.getAlloc(allocator, "HTTPX_EXAMPLE_ONLINE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.InvalidWtf8 => return false,
        else => return false,
    };
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const go_online = shouldUseLiveNetwork(init.minimal.environ, allocator);

    std.debug.print("=== HTTPS Client Example ===\n\n", .{});

    if (!go_online) {
        std.debug.print("Offline mode: set HTTPX_EXAMPLE_ONLINE=1 to run a live request.\n\n", .{});
        printOfflineDemo();
        return;
    }

    // 1. Configure TLS — withH2 enables ALPN for both h2 and http/1.1
    const tls_config = tls.TlsConfig.insecureWithH2(allocator);
    std.debug.print("TLS config: ALPN = h2, http/1.1 (insecure mode for demo)\n", .{});

    // 2. Connect to server
    const host = "example.com";
    const port: u16 = 443;
    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });

    const address = httpx.address.resolve(allocator, host, port) catch |err| {
        std.debug.print("  DNS resolve failed: {} (offline demo)\n", .{err});
        printOfflineDemo();
        return;
    };
    var socket = httpx.Socket.createForAddress(address) catch |err| {
        std.debug.print("  Socket create failed: {} (offline demo)\n", .{err});
        printOfflineDemo();
        return;
    };
    defer socket.close();

    socket.setNoDelay(true) catch {};
    socket.connectWithTimeout(address, 10_000) catch |err| {
        std.debug.print("  Connect failed: {} (offline demo)\n", .{err});
        printOfflineDemo();
        return;
    };

    // 3. Perform TLS handshake
    std.debug.print("Performing TLS handshake...\n", .{});
    var session = tls.TlsSession.init(tls_config);
    defer session.deinit();
    session.attachSocket(&socket);
    session.handshake(host) catch |err| {
        std.debug.print("  TLS handshake failed: {} (custom TLS may not interop with all servers)\n", .{err});
        printOfflineDemo();
        return;
    };

    const negotiated = session.negotiatedProtocol();
    if (negotiated) |proto| {
        std.debug.print("  Negotiated ALPN: {s}\n", .{proto});
    } else {
        std.debug.print("  No ALPN negotiated\n", .{});
    }
    std.debug.print("  TLS version: {}\n", .{session.tls_version orelse .tls_1_2});

    // 4. Send HTTP request over the encrypted channel
    const request =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: close\r\n" ++
        "Accept: text/html\r\n" ++
        "\r\n";

    std.debug.print("Sending HTTP request over TLS...\n", .{});
    session.writeAll(request) catch |err| {
        std.debug.print("  Write failed: {}\n", .{err});
        return;
    };

    // 5. Read the response
    std.debug.print("Reading response...\n", .{});
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const n = session.read(buf[total_read..]) catch |err| {
            std.debug.print("  Read error: {}\n", .{err});
            break;
        };
        if (n == 0) break;
        total_read += n;
    }

    // Print first part of the response
    const response_text = buf[0..@min(total_read, 512)];
    std.debug.print("\nResponse (first {d} bytes):\n", .{response_text.len});
    std.debug.print("--------\n", .{});
    std.debug.print("{s}\n", .{response_text});

    // 6. Send close_notify alert
    session.deinit();
    std.debug.print("\nTLS session closed gracefully.\n", .{});
    std.debug.print("\n=== Example complete ===\n", .{});
}

fn printOfflineDemo() void {
    std.debug.print("\n--- Offline TLS Demo ---\n", .{});
    std.debug.print("The custom TLS implementation supports TLS 1.2 and 1.3 handshakes,\n", .{});
    std.debug.print("ALPN negotiation, and encrypted record I/O. For production use,\n", .{});
    std.debug.print("connect to servers that support the same cipher suites:\n", .{});
    std.debug.print("  TLS 1.3: AES_128_GCM_SHA256, AES_256_GCM_SHA384, CHACHA20_POLY1305_SHA256\n", .{});
    std.debug.print("  TLS 1.2: ECDHE_RSA_WITH_AES_128_GCM_SHA256, ECDHE_RSA_WITH_AES_256_GCM_SHA384\n", .{});
    std.debug.print("\n=== Example complete (offline) ===\n", .{});
}
