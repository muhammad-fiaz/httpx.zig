# Transfer Download

File downloads with progress and verification. See
`examples/download.zig` and `examples/download_verify.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

const res = try client.download(url, "downloads/", .{
    .progress = .auto,
    .existing = .overwrite,
    .createDirs = true,
});
std.debug.print("Downloaded: {s} ({d} bytes)\n", .{
    res.destinationPath(), res.downloadedBytes,
});
```

## Run

```bash
zig build run-download
```

## What to Verify

- Successful HTTP status code.
- File lands on disk with the expected byte count.
