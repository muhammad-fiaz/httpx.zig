# FTPS (FTP over TLS)

RFC 4217 defines secure FTP extensions via the `AUTH TLS` command, securing authentication credentials and file transfers over encrypted TLS connections.

## Explicit FTPS Handshake

1. Client connects to standard command port (21).
2. Client sends `AUTH TLS`.
3. Server responds `234 Enabling TLS Connection`.
4. Client and server perform TLS 1.3 handshake.
5. All subsequent command traffic (`USER`, `PASS`, etc.) is encrypted.
6. Data channel transfers are secured using `PROT P` (Data Channel Protection Level Private).

## Protection Commands

* `PBSZ 0`: Protection Buffer Size (negotiates buffer for TLS record framing).
* `PROT P`: Enforces full encryption on subsequent data transfer sockets (`PASV`/`PORT`).
* `PROT C`: Transmits data channel in cleartext (insecure; disabled by default).

## Client Usage

```zig
var client = httpx.ftp.Client.init(allocator, io, .{
    .host = "secure.ftp.org",
    .port = 21,
    .user = "user",
    .password = "password",
    .secure = true, // Enables explicit FTPS requirement
}) catch |err| {
    // When TLS is required, plain connections are refused
    std.debug.print("FTP connection: {s}\n", .{@errorName(err)});
    return;
};
defer client.deinit();

try client.login("user", "password");
```

## Related

* [API: FTP](/api/ftp)
* [Protocol: FTP](/protocols/ftp)
* [Example: FTP Client](/examples/ftp-client)
