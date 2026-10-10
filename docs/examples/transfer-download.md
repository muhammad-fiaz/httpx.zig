# Transfer Download

File downloads with progress and verification. See
`examples/download.zig` and `examples/downloadVerify.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

const res = try client.download(url, .{
    .path = "downloads/",
    .progress = .auto,
    .existing = .overwrite,
    .createDirs = true,
});
std.debug.print("Downloaded: {s} ({d} bytes)\n", .{
    res.destinationPath(), res.downloadedBytes,
});
```

## Expected Output

```text
Downloaded: downloads/90 (90 bytes)
```

The destination path and byte count reflect the requested URL and vary by download; timings vary per run. Requires network access to the download URL. See `examples/download.zig` (`run-download`) and `examples/downloadVerify.zig`.

## Run

```bash
zig build run-download
```

## What to Verify

- Successful HTTP status code.
- File lands on disk with the expected byte count.
