# FTP Client

Connect to an FTP server with PASV/EPSV, directory listing, upload, and download.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    std.debug.print("=== HTTPX Native FTP Client ===\n", .{});

    // 1. Configure FTP options
    const ftpOpts: httpx.ftp.Options = .{
        .host = "test.rebex.net",
        .port = 21,
        .user = "demo",
        .password = "password",
        .secure = false, // Set to true for explicit FTPS
    };

    std.debug.print("1. FTP client configuration: {s}:{d}\n", .{ ftpOpts.host, ftpOpts.port });

    // 2. Connect via TCP (zero-config, no allocator required)
    var client = httpx.ftp.Client.connect(ftpOpts) catch |err| {
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

    // 5. List files (managed automatically by client)
    const files = client.list("/") catch |err| {
        std.debug.print("5. List files failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("5. File listing:\n{s}\n", .{files});

    std.debug.print("FTP client demonstration completed.\n", .{});
}
```

## Run

```bash
zig build run-ftp-client
```

## What to Verify

- FTP client configuration is printed cleanly.
- Connection is established using passive data channel negotiations.
- Directory listing (`LIST /`) displays remote directory contents.

