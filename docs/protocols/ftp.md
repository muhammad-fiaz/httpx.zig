# FTP (File Transfer Protocol)

RFC 959 defines the File Transfer Protocol, separating command and data channels for efficient remote file storage and retrieval.

## Active vs Passive Mode

* **Passive Mode (`PASV`)** *(Default in HTTPX)*: Client asks server to open a dynamic high-numbered TCP port, client connects to it. Avoids firewall/NAT traversal issues.
* **Active Mode (`PORT`)**: Server connects back to client's IP and port.

## Commands Supported

* `USER`, `PASS`: Authentication credentials.
* `PWD`: Print working directory.
* `CWD`: Change working directory.
* `LIST`: Retrieve directory listing.
* `RETR`: Download file stream.
* `STOR`: Upload file stream.
* `QUIT`: Graceful session termination.

## Example Usage

```zig
var client = try httpx.ftp.Client.init(allocator, io, .{
    .host = "test.rebex.net",
    .port = 21,
    .user = "demo",
    .password = "password",
});
defer client.deinit();

try client.login("demo", "password");

// Operation results are managed internally by Client and retained until next operation or client.deinit()
const dir = try client.pwd();
std.debug.print("Current directory: {s}\n", .{dir});

const listing = try client.list("/");
std.debug.print("Listing:\n{s}\n", .{listing});
```

## Related

* [API: FTP](/api/ftp)
* [Protocol: FTPS](/protocols/ftp-tls)
* [Example: FTP Client](/examples/ftp-client)
