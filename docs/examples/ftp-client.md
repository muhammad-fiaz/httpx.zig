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

    const config = httpx.FtpConfig{
        .allocator = allocator,
        .host = "127.0.0.1",
        .port = 21,
        .connection_mode = .passive,
        .transfer_mode = .binary,
    };

    std.debug.print("FTP Config: {s}:{d}\n", .{ config.host, config.port });
    std.debug.print("Mode: {s}\n", .{if (config.connection_mode == .passive) "passive" else "active"});
    std.debug.print("Transfer: {s}\n", .{config.transfer_mode.toString()});

    const addr = httpx.ftp.parsePasvAddress("227 Entering Passive Mode (192,168,1,1,4,1)");
    if (addr) |a| {
        std.debug.print("Parsed PASV: port={d}\n", .{a.getPort()});
    }
}
```

## Run

```bash
zig build run-all-ftp_example
```

## What to Verify

- FTP config fields are printed correctly.
- Connection mode defaults to passive.
- Transfer mode defaults to binary.
- PASV address parsing extracts the correct port.
