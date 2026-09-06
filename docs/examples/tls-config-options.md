# TLS Configuration Options

Demonstrates all TLS configuration constructors and ALPN protocol options.

## Features Demonstrated

- `TlsConfig.init()` - Default config with server verification
- `TlsConfig.insecure()` - Skip server verification
- `TlsConfig.insecureWithH2()` - HTTP/2 ALPN without verification
- `TlsConfig.insecureWithH3()` - HTTP/3 ALPN without verification
- Custom ALPN protocol lists
- `wantsHttp2()` helper

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");
const tls = httpx.tls;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Default config (verify=true, no ALPN)
    const config1 = tls.TlsConfig.init(allocator);
    std.debug.print("verify_server: {}\n", .{config1.verify_server});

    // Insecure config (verify=false, no ALPN)
    const config2 = tls.TlsConfig.insecure(allocator);
    std.debug.print("verify_server: {}\n", .{config2.verify_server});

    // Insecure with H2 ALPN (verify=false, h2+http/1.1)
    const config3 = tls.TlsConfig.insecureWithH2(allocator);
    std.debug.print("wantsHttp2: {}\n", .{config3.wantsHttp2()});

    // Insecure with H3 ALPN (verify=false, h3+h2+http/1.1)
    const config4 = tls.TlsConfig.insecureWithH3(allocator);
    std.debug.print("ALPN protocols: {d}\n", .{config4.alpn_protocols.len});

    // Custom config
    const alpn = [_][]const u8{ "h2" };
    const config5 = tls.TlsConfig{
        .allocator = allocator,
        .alpn_protocols = &alpn,
        .verify_server = false,
    };
    std.debug.print("custom wantsHttp2: {}\n", .{config5.wantsHttp2()});
}
```

## Run

```bash
zig build run-all-tls_config_options
```
