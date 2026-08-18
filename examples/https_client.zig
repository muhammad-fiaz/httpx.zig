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

    if (!go_online) {
        printOfflineDemo();
        return;
    }

    const tls_config = tls.TlsConfig.insecureWithH2(allocator);

    const host = "httpbun.com";
    const port: u16 = 443;

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

    const request =
        "GET / HTTP/1.1\r\n" ++
        "Host: httpbun.com\r\n" ++
        "Connection: close\r\n" ++
        "Accept: text/html\r\n" ++
        "\r\n";

    session.writeAll(request) catch |err| {
        std.debug.print("  Write failed: {}\n", .{err});
        return;
    };

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

    const response_text = buf[0..@min(total_read, 512)];
    std.debug.print("\nResponse (first {d} bytes):\n", .{response_text.len});
    std.debug.print("{s}\n", .{response_text});

    session.deinit();
}

fn printOfflineDemo() void {}
