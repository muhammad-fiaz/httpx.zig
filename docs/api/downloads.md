# Downloads API

The client download manager supports file transfers, progress reporting,
checksums, resume behavior, and remote file inspection.

## Create a downloader

```zig
var downloader = client.downloader();
```

The downloader uses the client allocator, connection pool, and request
configuration. Release any returned result according to the result type's
documented ownership.

## Public types

| Type | Purpose |
|---|---|
| `httpx.client.Downloader` | Coordinates one or more downloads |
| `httpx.client.DownloadTask` | Describes a requested file transfer |
| `httpx.client.DownloadResult` | Reports the completed transfer |
| `httpx.client.DownloadError` | Download-specific errors |
| `httpx.client.ProgressInfo` | Progress callback data |
| `httpx.client.ProgressState` | Transfer state |
| `httpx.client.ProgressMode` | Progress reporting mode |
| `httpx.client.ChecksumAlgorithm` | Supported checksum selection |
| `httpx.client.VerifyOptions` | Checksum verification settings |
| `httpx.client.ExistingFilePolicy` | Existing destination behavior |
| `httpx.client.RemoteFileInfo` | Remote file metadata |

## Batch downloads

```zig
const tasks = [_]httpx.client.DownloadTask{
    .{ .url = "https://example.com/a.tar", .dest = "a.tar" },
    .{ .url = "https://example.com/b.tar", .dest = "b.tar" },
};

const results = try client.downloadAll(&tasks, .{});
defer allocator.free(results);
```

Check each result before treating the transfer as complete. The exact task
and option fields are defined by `src/client/downloadManager.zig`; use the
[download examples](/examples/download) for complete workflows.

## Related documentation

- [Streaming transfers](/guide/streaming)
- [Download examples](/examples/download)
- [Transfer progress](/examples/transfer-progress)
