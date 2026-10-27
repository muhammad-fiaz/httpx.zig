# FTP Client

Connect to an FTP server with PASV/EPSV, directory listing, upload, and download.

## Demo Program

```zig
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
```

The full `examples/ftpClient.zig` file also contains an always-runs explicit-FTPS loopback demo (`ftpsLoopbackDemo`) with inlined loopback certificate helpers.

## Expected Output

```text
=== HTTPX Native FTP Client ===
1. FTP client configuration: test.rebex.net:21
3. Connected to FTP server successfully!
4. Login successful
5. File listing:
-rw-r--r-- 1 user user 1024 Jan 01 00:00 file1.txt
FTP client demonstration completed.
=== HTTPX Native FTPS Client (loopback) ===
1. FTPS login over AUTH TLS + PROT P
2. FTPS LIST: secure.txt present
FTPS DEMO VERIFICATION PASSED
```

Hostnames, ports, listing contents, and timings vary; when the remote server is unreachable the program instead prints `3. FTP connection failed: ...` and exits early. Only the line format above is stable.

## Run

```bash
zig build run-ftp-client
```

## What to Verify

- FTP client configuration is printed cleanly.
- Connection is established using passive data channel negotiations.
- Directory listing (`LIST /`) displays remote directory contents.

