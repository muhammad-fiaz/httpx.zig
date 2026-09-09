# API: FTP

The `httpx.ftp` namespace provides a robust File Transfer Protocol client and server supporting standard RFC 959 commands, multiline reply parsing, active/passive data transfers (EPSV preferred, PASV fallback), directory navigation, and file transfers with streaming callbacks or high-level downloads.

## Overview

The FTP client handles command-channel communication over TCP port 21, automatically negotiates extended passive mode (`EPSV`) or passive mode (`PASV`) data ports, and manages streaming file transfers and downloads.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = try httpx.ftp.Client.init(allocator, io, .{
        .host = "test.rebex.net",
        .port = 21,
        .user = "demo",
        .password = "password",
    });
    defer client.deinit();

    try client.login("demo", "password");

    // Results are managed internally by Client and retained until next operation or client.deinit()
    const pwd = try client.pwd();
    std.debug.print("Current directory: {s}\n", .{pwd});

    const listing = try client.list("/");
    std.debug.print("Listing:\n{s}\n", .{listing});
}
```

## High-Level File Download

For one-shot file downloads with automated progress bars, cryptographic hash verification, and atomic file replacement, use `httpx.ftp.download`:

```zig
const res = try httpx.ftp.download(allocator, .{
    .host = "test.rebex.net",
    .port = 21,
    .user = "demo",
    .password = "password",
    .remotePath = "readme.txt",
    .destinationPath = "downloads/readme.txt",
    .progress = .auto,
    .verify = .{
        .minSize = 1,
    },
});
```

## Types and Configuration

### `httpx.ftp.Options`

```zig
pub const Options = struct {
    host: []const u8,
    port: u16 = 21,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    /// Explicit FTPS (AUTH TLS). Rejects plaintext if true when TLS is unavailable.
    secure: bool = false,
};
```

| Field | Type | Default | Description |
|---|---|---|---|
| `host` | `[]const u8` | *(required)* | Remote FTP hostname or IP address |
| `port` | `u16` | `21` | Command channel port (default 21) |
| `user` | `[]const u8` | `"anonymous"` | FTP username |
| `password` | `[]const u8` | `"anonymous@"` | FTP password |
| `secure` | `bool` | `false` | When true, requires TLS encryption |

### `httpx.ftp.Server`

RFC 959 FTP server implementation built on the shared TCP listener:

```zig
var server = try httpx.ftp.Server.init(allocator, io, .{
    .host = "0.0.0.0",
    .port = 2121,
    .user = "demo",
    .password = "password",
    .callbacks = .{
        .authenticate = authFn,
        .list = listFn,
        .retrieve = retrieveFn,
    },
});
defer server.deinit();
```

## Methods

### `Client.init(allocator, io, opts)`
Initializes the client and connects to the FTP server using the provided allocator and I/O engine.

### `Client.connect(opts)`
Zero-config helper to connect to an FTP server with standard page allocator.

### `client.login(user, password) !void`
Sends `USER` and `PASS` commands and sets binary transfer mode (`TYPE I`).

### `client.pwd() ![]const u8`
Queries current working directory (RFC 959 `PWD`). The returned slice is managed internally by the Client and remains valid until the next operation or `client.deinit()`. For an owned allocation, use `client.pwdAlloc()`.

### `client.cwd(path) !void`
Changes remote working directory (`CWD <path>`).

### `client.mkd(path) !void`
Creates a remote directory (`MKD <path>`).

### `client.dele(path) !void`
Deletes a remote file (`DELE <path>`).

### `client.size(path) !u64`
Queries remote file size in bytes via RFC 3659 `SIZE`.

### `client.list(path) ![]const u8`
Retrieves directory listing over passive data channel. The returned slice is managed internally by the Client and remains valid until the next operation or `client.deinit()`. For an owned allocation, use `client.listAlloc(path)`.

### `client.download(remote_path, ctx, sink_fn) !void`
Streams remote file via `RETR` to a chunk callback.

### `client.upload(remote_path, ctx, fill_fn) !void`
Streams local data via `STOR` from a chunk callback.

### `client.deinit() void`
Sends `QUIT`, closes open sockets, and frees client buffers.

## Errors

* `FtpError.ConnectFailed`: Unable to connect to host or data port.
* `FtpError.ProtocolError`: Unexpected FTP response code or command rejection.
* `FtpError.TlsUnavailable`: Explicit FTPS requested but TLS is unconfigured.
* `FtpError.MalformedReply`: Server sent non-conforming reply text.
* `FtpError.MalformedPasv`: Failed to parse passive port negotiation.

## Related

* [Protocols: FTP](/protocols/ftp)
* [Protocols: FTPS (TLS)](/protocols/ftp-tls)
* [Example: FTP Client](/examples/ftp-client)
* [Example: FTP Server](/examples/ftp-server)
* [Example: FTP Download](/examples/ftp-download)
