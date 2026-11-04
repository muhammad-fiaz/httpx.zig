# File downloads

The client download manager writes responses directly to disk, supports
retries and redirects, and can report progress or verify a downloaded file.

## Download to a path

```zig
var result = try client.download(
    "https://example.com/archive.tar",
    .{
        .path = "downloads/archive.tar",
        .createDirs = true,
        .atomic = true,
    },
);

std.debug.print("saved {s} ({d} bytes)\n", .{
    result.destinationPath(),
    result.downloadedBytes,
});
```

Set `path` to a directory to derive the filename from the URL or
`Content-Disposition`. An empty path also enables filename derivation.

## Report progress

```zig
fn progress(info: httpx.client.ProgressInfo, _: ?*anyopaque) void {
    if (info.totalBytes) |total| {
        std.debug.print("{d}/{d} bytes\n", .{ info.downloadedBytes, total });
    }
}

_ = try client.download("https://example.com/archive.tar", .{
    .path = "downloads/archive.tar",
    .progress = .enabled,
    .onProgress = progress,
});
```

## Verify a download

```zig
_ = try client.download("https://example.com/archive.tar", .{
    .path = "downloads/archive.tar",
    .verify = .{
        .sha256 = "expected-sha256-hex",
    },
});
```

Verification failures return a download error and do not replace the target
when atomic replacement is enabled.

## Download several files

```zig
const tasks = [_]httpx.client.DownloadTask{
    .{ .url = "https://example.com/a.tar", .dest = "downloads/a.tar" },
    .{ .url = "https://example.com/b.tar", .dest = "downloads/b.tar" },
};

const results = try client.downloadAll(&tasks, .{});
defer allocator.free(results);
```

## Important options

| Option | Type | Default | Purpose |
|---|---|---:|---|
| `path` | `[]const u8` | `""` | Destination path or directory |
| `existing` | `ExistingFilePolicy` | `.overwrite` | Behavior when the destination exists |
| `progress` | `ProgressMode` | `.auto` | Progress reporting mode |
| `atomic` | `bool` | `true` | Download to a temporary file before replacement |
| `createDirs` | `bool` | `true` | Create missing parent directories |
| `maxRetries` | `u32` | `3` | Retry attempts |
| `timeoutMs` | `?u64` | `null` | Per-download timeout |
| `verify` | `VerifyOptions` | `.{}` | Checksum and size verification |
| `cancelFlag` | `?*const std.atomic.Value(bool)` | `null` | Cooperative cancellation flag |

See the [Downloads API](/api/downloads) and
[transfer examples](/examples/transfer-download) for the complete result and
verification types.
