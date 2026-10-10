# Filesystem Watcher & Live Reload

HTTPX features a cross-platform runtime filesystem watcher subsystem (`httpx.Watcher`) designed for development hot-reloading, template cache invalidation, and dynamic file-based routing.

## Architecture

The watcher decouples event production (delegated to native OS mechanisms or a polling scanner) from event consumption and dispatch:

- **Windows**: `ReadDirectoryChangesW` with overlapped I/O, event notification objects, and `CancelIoEx`-driven clean shutdown.
- **Linux**: `inotify` with non-blocking file descriptors, queue overflow handling, and recursive subdirectory watch adoption.
- **macOS & BSD**: `kqueue` (`EVFILT_VNODE`) directory monitoring with targeted stat reconciliation.
- **Polling Fallback**: Recursive stat-walk with directory creation/deletion tracking, metadata diffing, and size + timestamp rename pairing.

```
   +-----------------------------------------------------------+
   |                       httpx.Watcher                       |
   +-----------------------------------------------------------+
          |                      |                       |
          v                      v                       v
 [ReadDirectoryChangesW]     [inotify]           [kqueue / BSD]
      (Windows)               (Linux)             (macOS/BSD)
          |                      |                       |
          +----------------------+-----------------------+
                                 | (on error or mode = .polling)
                                 v
                     [Reliable Polling Fallback]
```

## Backend Selection & Capabilities

Backend mode is configurable via `WatcherConfig.mode`:

```zig
pub const BackendMode = enum {
    auto,    // Prefer native backend; fall back to polling if unavailable
    native,  // Require native OS backend; fail with error if unsupported
    polling, // Explicit polling scanner fallback
};
```

### Querying Capabilities

You can inspect the active backend and its capabilities at runtime:

```zig
var watcher = try httpx.Watcher.init(allocator, io, .{
    .dirPath = "./src",
    .mode = .auto,
});
defer watcher.deinit();

const kind = watcher.getBackendKind(); // .windows, .linux, .macos, .bsd, .polling
const caps = watcher.getCapabilities();

std.debug.print("Native: {}\n", .{caps.native});
std.debug.print("Precise Events: {}\n", .{caps.preciseEvents});
std.debug.print("Rename Detection: {}\n", .{caps.renameDetection});
std.debug.print("Subtree Monitoring: {}\n", .{caps.subtrees});
std.debug.print("Overflow Detection: {}\n", .{caps.overflowDetection});
```

## Status & Lifecycle Callbacks

The watcher reports lifecycle transitions and recovery actions via `onStatus`:

```zig
fn handleStatus(status: httpx.WatcherStatus, detail: ?[]const u8, _: ?*anyopaque) void {
    switch (status) {
        .initialized => std.debug.print("Watcher initialized\n", .{}),
        .nativeActive => std.debug.print("Native OS backend active\n", .{}),
        .pollingActive => std.debug.print("Polling fallback active\n", .{}),
        .fallbackActivated => std.debug.print("Fallback activated: {?s}\n", .{detail}),
        .overflowDetected => std.debug.print("Event overflow detected: {?s}\n", .{detail}),
        .reconciled => std.debug.print("State reconciled: {?s}\n", .{detail}),
        .stopped => std.debug.print("Watcher stopped\n", .{}),
    }
}

var watcher = try httpx.Watcher.init(allocator, io, .{
    .dirPath = "./templates",
    .onStatus = handleStatus,
});
```

## Event Normalization & Rename Pairing

Regardless of the active backend, filesystem mutations are normalized into `WatchEvent`:

```zig
pub const WatchEventKind = enum {
    created,
    modified,
    deleted,
    renamed,
    directoryCreated,
    directoryDeleted,
};
```

- When an atomic rename occurs (e.g. editor temporary swap file replacing an existing file), native event cookies and polling size/timestamp pairing infer the source `oldPath` and destination `path`.
- In polling mode, directory creation and deletion are tracked independently of files, emitting `.directoryCreated` and `.directoryDeleted`.

## Event Queue Overflow & Reconciliation

If a burst of filesystem activity overflows the OS event queue or internal buffer (e.g., rapid Git branch switches or batch builds):

1. The backend detects the overflow flag (`IN_Q_OVERFLOW` on Linux, buffer overflow on Windows, `EV_ERROR` on macOS).
2. The watcher enters a `dirty` state and triggers `onStatus(.overflowDetected)`.
3. On the next drain pass, a complete reconciliation stat-scan is executed against the watched root to synchronize the tracked file index without dropping state.
4. An `onStatus(.reconciled)` notification is emitted once synchronization completes.

## Switching Backends

Applications can explicitly transition an active watcher to polling mode at runtime:

```zig
try watcher.switchToPolling();
// Native OS handles are released and an atomic reconciliation scan is executed.
```
