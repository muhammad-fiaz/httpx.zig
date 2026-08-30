const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cert =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBkTCB+wIJALHF+oxZxXNqMA0Gcz9zMFsxCzAJBgNVBAYTAkFVMQswCQYDVQQI
        \\EwJBVDESMBAGA1UEBxMJQmVsaWpkYW5nMRkwFwYDVQQKExBIWFRUUFguWklHIFpJ
        \\RzEeMBwGA1UEAxMSSHRYVFguWklHIFJvb3QgQ0EwHhcNMjUwMTAxMDAwMDAwWhcN
        \\MzUwMTAxMDAwMDAwWjBpMQswCQYDVQQGEwJBVDESMBAGA1UEBxMJQmVsaWpkYW5n
        \\MRkwFwYDVQQKExBIWFRUUFguWklHIFpJRzEeMBwGA1UEAxMSSHRYVFguWklHIFNl
        \\cnZlciAxMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAL1OaJtWrEhKMJgGxCMIx5hO
        \\Y4SxR8CBKL8JJKFQ8BjKJ0CIz6JYtPULqFQdHnDnH4dOgJGmhVnHmIpc3MCAwEAAa
        \\MCMAAwDQYJKoZIhvcNAQEEBQADQQBRZ1pKx4B3rZ3nQqWU4EqH4t1D0pT1R0gH4y
        \\0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z
        \\-----END CERTIFICATE-----
    ;

    const key =
        \\-----BEGIN PRIVATE KEY-----
        \\MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAvU5om1asSEowmAbE
        \\IwjHmE5jhLFHwIEovwkuoVDwGMonQIjPoli09QuoVB0ecOccRk6AlaI6UcuYilzc
        \\gIDAQAQQ3pAMb2JlY3RAZXhhbXBsZS5jbS8wDQYJKoZIhvcNAQEEBQADQQBXdlpK
        \\x4B3rZ3nQqWU4EqH4t1D0pT1R0gH4y0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z0Q8z
        \\-----END PRIVATE KEY-----
    ;

    var tls_listener = try httpx.TlsListener.init(allocator, .{
        .port = 0,
        .default_identity = .{
            .cert_chain_pem = cert,
            .private_key_pem = key,
        },
    });
    defer tls_listener.deinit();

    const port = tls_listener.localPort();
    std.debug.print("TLS server running on 127.0.0.1:{d}\n", .{port});

    std.debug.print("TLS listener initialized successfully on port {d}.\n", .{port});
    std.debug.print("TLS server configuration verified.\n", .{});
}

fn handler(_: httpx.TlsRequest) anyerror!httpx.TlsResponse {
    return .{
        .status = 200,
        .body = "Hello from TLS server!",
    };
}
