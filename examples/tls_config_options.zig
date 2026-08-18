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

    {
        const config = tls.TlsConfig.init(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n\n", .{config.alpn_protocols.len});
    }

    {
        const config = tls.TlsConfig.insecure(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n\n", .{config.alpn_protocols.len});
    }

    {
        const config = tls.TlsConfig.insecureWithH2(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        for (config.alpn_protocols) |proto| {
            std.debug.print("    - {s}\n", .{proto});
        }
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHTTP2()});
    }

    {
        const config = tls.TlsConfig.insecureWithH3(allocator);
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        for (config.alpn_protocols) |proto| {
            std.debug.print("    - {s}\n", .{proto});
        }
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHTTP2()});
    }

    {
        const alpn = [_][]const u8{"h2"};
        const config = tls.TlsConfig{
            .allocator = allocator,
            .alpn_protocols = &alpn,
            .verify_server = false,
        };
        std.debug.print("  verify_server: {}\n", .{config.verify_server});
        std.debug.print("  ALPN:          {d} protocols\n", .{config.alpn_protocols.len});
        std.debug.print("  wantsHttp2:    {}\n\n", .{config.wantsHTTP2()});
    }
}
