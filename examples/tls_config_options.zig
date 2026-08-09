const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== TLS Configuration Options ===\n\n", .{});

    // 1. Default — verify_ssl=true, no ALPN
    {
        std.debug.print("--- 1. TlsConfig.init (verify=true, no ALPN) ---\n", .{});
        const config = tls.TlsConfig.init(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n\n", .{config.alpn_protocols.len});
    }

    // 2. Insecure — verify_ssl=false
    {
        std.debug.print("--- 2. TlsConfig.insecure (verify=false, no ALPN) ---\n", .{});
        const config = tls.TlsConfig.insecure(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n\n", .{config.alpn_protocols.len});
    }

    // 3. Insecure with H2 ALPN
    {
        std.debug.print("--- 3. TlsConfig.insecureWithH2 (verify=false, h2+http/1.1) ---\n", .{});
        const config = tls.TlsConfig.insecureWithH2(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        for (config.alpn_protocols) |proto| {
            std.debug.print("    - {s}\n", .{proto});
        }
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHttp2()});
    }

    // 4. Insecure with H3 ALPN (HTTP/1.1 + HTTP/2 + HTTP/3)
    {
        std.debug.print("--- 4. TlsConfig.insecureWithH3 (verify=false, h3+h2+http/1.1) ---\n", .{});
        const config = tls.TlsConfig.insecureWithH3(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        for (config.alpn_protocols) |proto| {
            std.debug.print("    - {s}\n", .{proto});
        }
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHttp2()});
    }

    // 5. Custom config
    {
        std.debug.print("--- 5. Custom TlsConfig ---\n", .{});
        const alpn = [_][]const u8{"h2"};
        const config = tls.TlsConfig{
            .allocator = allocator,
            .alpn_protocols = &alpn,
            .verify_server = false,
        };
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHttp2()});
    }

    std.debug.print("=== Example complete ===\n", .{});
}
