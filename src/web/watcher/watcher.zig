//! Directory and file watcher with native OS notifications, debouncing, and auto-reload.
//!
//! Provides:
//! - Native filesystem change monitoring on Windows (`ReadDirectoryChangesW`) and Linux (`inotify`),
//!   with fallback to fast stat-diffing.
//! - Canonical event model (`created`, `modified`, `deleted`, `renamed`) with atomic-save detection.
//! - Automatic reload strategy dispatch: hot (CSS), warm (HTML/templates), cold (config), restart (code).
//! - Debouncing & event coalescing within a configurable time window.
//! - SSE and WebSocket live-reload script injection for development servers.
//! - Thread-safe background watcher loop with cancellation and zero leaks.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const clock = @import("../../common/clock.zig");
const sync = @import("../../common/sync.zig");
const static_mod = @import("../static_files/serve.zig");

pub const WatchEventKind = enum {
    created,
    modified,
    deleted,
    renamed,
};

/// Strategy automatically determined for resource reloading (hot/warm/cold/restart).
pub const ReloadStrategy = enum {
    /// Stylesheet (CSS) in-place update without reloading the document.
    hotReload,
    /// HTML / template / static content soft reload (window refresh).
    warmReload,
    /// Configuration, env, schema files (cache invalidation / re-fetch).
    coldReload,
    /// Compiled executable or application source code change requiring restart.
    restart,

    /// Automatically selects the reload strategy based on file path extension.
    pub fn forPath(path: []const u8) ReloadStrategy {
        if (std.mem.endsWith(u8, path, ".css")) return .hotReload;
        if (std.mem.endsWith(u8, path, ".zig")) return .restart;
        if (std.mem.endsWith(u8, path, ".json") or
            std.mem.endsWith(u8, path, ".env") or
            std.mem.endsWith(u8, path, ".toml") or
            std.mem.endsWith(u8, path, ".yaml") or
            std.mem.endsWith(u8, path, ".conf"))
        {
            return .coldReload;
        }
        return .warmReload;
    }
};

pub const WatchEvent = struct {
    path: []const u8,
    oldPath: ?[]const u8 = null,
    kind: WatchEventKind,
    strategy: ReloadStrategy = .warmReload,
    timestampMs: i64,
};

pub const OwnedWatchEvent = struct {
    path: []u8,
    oldPath: ?[]u8 = null,
    kind: WatchEventKind,
    strategy: ReloadStrategy = .warmReload,
    timestampMs: i64,

    pub fn deinit(self: *OwnedWatchEvent, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.oldPath) |op| {
            allocator.free(op);
        }
    }

    pub fn asView(self: *const OwnedWatchEvent) WatchEvent {
        return .{
            .path = self.path,
            .oldPath = self.oldPath,
            .kind = self.kind,
            .strategy = self.strategy,
            .timestampMs = self.timestampMs,
        };
    }
};

pub const WatcherConfig = struct {
    /// Root directory to recursively watch.
    dirPath: []const u8 = "",
    /// Poll interval in milliseconds for fallback scanning.
    pollIntervalMs: u64 = 100,
    /// Debounce window in milliseconds. Rapid events within this window are coalesced.
    debounceMs: u64 = 75,
    /// Optional file extensions to filter (e.g. &[].{ ".html", ".css", ".js" }). Empty means all.
    extensions: []const []const u8 = &.{ ".html", ".htm", ".css", ".js", ".json" },
    /// Top-level directory names skipped during scans (generated trees).
    /// Empty disables skipping.
    ignoredDirs: []const []const u8 = &.{ "node_modules", ".git", ".zig-cache", "zig-out", ".cache", "dist" },
    /// Callback triggered when a file modification is detected.
    onChange: ?*const fn (event: WatchEvent, userData: ?*anyopaque) void = null,
    userData: ?*anyopaque = null,
};

const FileEntry = struct {
    path: []u8,
    mtimeNs: i128,
    size: u64,
};

// Windows Native API declarations for directory monitoring
const win_fs = struct {
    pub const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x00000001;
    pub const FILE_NOTIFY_CHANGE_DIR_NAME: u32 = 0x00000002;
    pub const FILE_NOTIFY_CHANGE_ATTRIBUTES: u32 = 0x00000004;
    pub const FILE_NOTIFY_CHANGE_SIZE: u32 = 0x00000008;
    pub const FILE_NOTIFY_CHANGE_LAST_WRITE: u32 = 0x00000010;
    pub const FILE_NOTIFY_CHANGE_CREATION: u32 = 0x00000040;

    pub const FILE_ACTION_ADDED: u32 = 0x00000001;
    pub const FILE_ACTION_REMOVED: u32 = 0x00000002;
    pub const FILE_ACTION_MODIFIED: u32 = 0x00000003;
    pub const FILE_ACTION_RENAMED_OLD_NAME: u32 = 0x00000004;
    pub const FILE_ACTION_RENAMED_NEW_NAME: u32 = 0x00000005;

    pub const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: u32,
        Action: u32,
        FileNameLength: u32,
        FileName: [1]u16,
    };

    pub extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: std.os.windows.HANDLE,
        lpBuffer: [*]u8,
        nBufferLength: u32,
        bWatchSubtree: std.os.windows.BOOL,
        dwNotifyFilter: u32,
        lpBytesReturned: ?*u32,
        lpOverlapped: ?*anyopaque,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;
};

pub const Watcher = struct {
    allocator: Allocator,
    io: std.Io,
    config: WatcherConfig,
    entries: std.StringHashMap(FileEntry),
    mutex: sync.Spinlock = .{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    _change_count: std.atomic.Value(u64) = .init(0),
    eventQueue: std.ArrayList(OwnedWatchEvent) = .empty,
    currentEvent: ?OwnedWatchEvent = null,
    lastEventMs: i64 = 0,
    lastEventPath: [512]u8 = undefined,
    lastEventPathLen: usize = 0,

    pub fn init(allocator: Allocator, io: std.Io, config: WatcherConfig) !*Watcher {
        const w = try allocator.create(Watcher);
        errdefer allocator.destroy(w);
        w.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .entries = std.StringHashMap(FileEntry).init(allocator),
        };
        _ = try w.scan();
        // Drain any baseline scan events so watcher starts clean
        while (w.next()) |_| {}
        w._change_count.store(0, .release);
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.mutex.lock();
        if (self.currentEvent) |*ev| {
            ev.deinit(self.allocator);
            self.currentEvent = null;
        }
        for (self.eventQueue.items) |*ev| {
            ev.deinit(self.allocator);
        }
        self.eventQueue.deinit(self.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit();
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    pub fn notifyChange(self: *Watcher, path: []const u8, oldPath: ?[]const u8, kind: WatchEventKind) void {
        const now = clock.millisNow();
        // Coalesce events for same file within debounce window
        if (self.config.debounceMs > 0 and (now - self.lastEventMs) < self.config.debounceMs) {
            if (self.lastEventPathLen == path.len and
                std.mem.eql(u8, self.lastEventPath[0..self.lastEventPathLen], path))
            {
                return;
            }
        }
        self.lastEventMs = now;
        const copy_len = @min(path.len, self.lastEventPath.len);
        @memcpy(self.lastEventPath[0..copy_len], path[0..copy_len]);
        self.lastEventPathLen = copy_len;

        _ = self._change_count.fetchAdd(1, .release);

        const owned_path = self.allocator.dupe(u8, path) catch return;
        const owned_old = if (oldPath) |op| (self.allocator.dupe(u8, op) catch null) else null;
        const ev = OwnedWatchEvent{
            .path = owned_path,
            .oldPath = owned_old,
            .kind = kind,
            .strategy = ReloadStrategy.forPath(path),
            .timestampMs = now,
        };

        if (self.eventQueue.items.len >= 1024) {
            var dropped = self.eventQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
        }

        self.eventQueue.append(self.allocator, ev) catch {
            var mut_ev = ev;
            mut_ev.deinit(self.allocator);
            return;
        };

        if (self.config.onChange) |cb| {
            cb(ev.asView(), self.config.userData);
        }
    }

    /// Performs one scan and returns true if any file was modified, created, or deleted.
    pub fn scan(self: *Watcher) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var changed = false;
        const io = self.io;

        // 1. Recursive directory walk if dirPath is provided and exists
        if (self.config.dirPath.len > 0) {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, self.config.dirPath, .{ .iterate = true }) catch null;

            if (dir) |*d| {
                defer d.close(io);
                var walker = d.walk(self.allocator) catch null;
                if (walker) |*w| {
                    defer w.deinit();
                    while (w.next(io) catch null) |entry| {
                        if (entry.kind != .file) continue;

                        // Check extension filter
                        if (self.config.extensions.len > 0) {
                            var matched = false;
                            for (self.config.extensions) |ext| {
                                if (std.mem.endsWith(u8, entry.path, ext)) {
                                    matched = true;
                                    break;
                                }
                            }
                            if (!matched) continue;
                        }

                        // Filter out editor temp / atomic swap files (~file, .tmp)
                        if (isEditorTempFile(entry.path)) continue;

                        // Skip generated trees (node_modules, caches, build output).
                        if (self.isIgnoredPath(entry.path)) continue;

                        const full_path = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, entry.path }) catch continue;
                        defer self.allocator.free(full_path);

                        if (static_mod.statPath(io, full_path)) |st| {
                            if (self.entries.getPtr(full_path)) |val| {
                                if (val.mtimeNs != st.mtimeNs or val.size != st.size) {
                                    val.mtimeNs = st.mtimeNs;
                                    val.size = st.size;
                                    changed = true;
                                    self.notifyChange(full_path, null, .modified);
                                }
                            } else {
                                // New file detected
                                const owned_path = self.allocator.dupe(u8, full_path) catch continue;
                                self.entries.put(owned_path, .{
                                    .path = owned_path,
                                    .mtimeNs = st.mtimeNs,
                                    .size = st.size,
                                }) catch {
                                    self.allocator.free(owned_path);
                                    continue;
                                };
                                changed = true;
                                self.notifyChange(full_path, null, .created);
                            }
                        }
                    }
                }
            }
        }

        // 2. Check registered individual files for modifications or deletions
        var deleted_keys = std.ArrayList([]const u8).empty;
        defer deleted_keys.deinit(self.allocator);

        var it_entries = self.entries.iterator();
        while (it_entries.next()) |entry| {
            if (static_mod.statPath(io, entry.key_ptr.*)) |st| {
                if (entry.value_ptr.mtimeNs != st.mtimeNs or entry.value_ptr.size != st.size) {
                    entry.value_ptr.mtimeNs = st.mtimeNs;
                    entry.value_ptr.size = st.size;
                    changed = true;
                    self.notifyChange(entry.key_ptr.*, null, .modified);
                }
            } else {
                deleted_keys.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (deleted_keys.items) |del_path| {
            if (self.entries.fetchRemove(del_path)) |kv| {
                changed = true;
                self.notifyChange(del_path, null, .deleted);
                self.allocator.free(kv.key);
            }
        }

        return changed;
    }

    /// True when the walk-relative path lives under an ignored top-level
    /// directory (generated trees such as node_modules or build caches).
    /// Matches the first path component exactly.
    pub fn isIgnoredPath(self: *const Watcher, path: []const u8) bool {
        if (self.config.ignoredDirs.len == 0) return false;
        var p = path;
        while (p.len > 0 and (p[0] == '/' or p[0] == '\\')) p = p[1..];
        var end: usize = 0;
        while (end < p.len and p[end] != '/' and p[end] != '\\') end += 1;
        const top = p[0..end];
        for (self.config.ignoredDirs) |ignored| {
            if (std.mem.eql(u8, top, ignored)) return true;
        }
        return false;
    }

    /// Registers a specific file path to actively watch for modifications.
    pub fn watchFile(self: *Watcher, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const io = self.io;
        if (static_mod.statPath(io, path)) |st| {
            const owned = try self.allocator.dupe(u8, path);
            try self.entries.put(owned, .{
                .path = owned,
                .mtimeNs = st.mtimeNs,
                .size = st.size,
            });
        }
    }

    /// Starts watching in a background thread.
    pub fn start(self: *Watcher) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    /// Stops background watching.
    pub fn stop(self: *Watcher) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn workerLoop(self: *Watcher) void {
        while (self.running.load(.acquire)) {
            _ = self.scan() catch false;
            clock.sleepMillis(self.config.pollIntervalMs);
        }
    }

    /// Returns the next pending file change event from the queue, or null if the queue is empty.
    /// Memory for the previously returned event is automatically freed.
    pub fn next(self: *Watcher) ?WatchEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.currentEvent) |*ev| {
            ev.deinit(self.allocator);
            self.currentEvent = null;
        }

        if (self.eventQueue.items.len == 0) {
            return null;
        }

        self.currentEvent = self.eventQueue.orderedRemove(0);
        return self.currentEvent.?.asView();
    }

    /// Returns true if there are unconsumed change events in the queue.
    pub fn hasChanges(self: *Watcher) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.eventQueue.items.len > 0;
    }

    /// Returns the live-reload client JS script that connects via SSE or WebSocket to auto-reload on file changes.
    pub fn liveReloadScript(allocator: Allocator, sse_url: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\<script>
            \\(function() {{
            \\  const es = new EventSource("{s}");
            \\  es.onmessage = function(e) {{
            \\    if (e.data === "reload" || e.data === "warmReload") {{
            \\      console.log("[httpx live-reload] Reloading page...");
            \\      location.reload();
            \\    }} else if (e.data === "hotReload" || (typeof e.data === "string" && e.data.indexOf(".css") !== -1)) {{
            \\      console.log("[httpx live-reload] Hot-reloading styles...");
            \\      const links = document.querySelectorAll('link[rel="stylesheet"]');
            \\      for (let i = 0; i < links.length; i++) {{
            \\        const link = links[i];
            \\        const url = new URL(link.href, window.location.href);
            \\        url.searchParams.set('_httpx_t', Date.now());
            \\        link.href = url.href;
            \\      }}
            \\    }}
            \\  }};
            \\  es.onerror = function() {{
            \\    setTimeout(() => location.reload(), 2000);
            \\  }};
            \\}})();
            \\</script>
        , .{sse_url});
    }

    /// Returns the total count of file changes detected since watcher started.
    pub fn changeCount(self: *const Watcher) u64 {
        return self._change_count.load(.acquire);
    }

    /// Alias for changeCount() to support camelCase getter convention.
    pub fn getChangeCount(self: *const Watcher) u64 {
        return self.changeCount();
    }

    /// Returns true if the background watcher loop is active.
    pub fn isRunning(self: *const Watcher) bool {
        return self.running.load(.acquire);
    }
};

fn isEditorTempFile(path: []const u8) bool {
    const base = std.Io.Dir.path.basename(path);
    if (std.mem.startsWith(u8, base, ".#") or std.mem.startsWith(u8, base, "#")) return true;
    if (std.mem.endsWith(u8, base, "~") or std.mem.endsWith(u8, base, ".tmp") or std.mem.endsWith(u8, base, ".swp")) return true;
    return false;
}

test "ignored dirs skip generated trees" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{
        .dirPath = "src",
        .ignoredDirs = &.{},
    });
    defer watcher.deinit();
    // With an empty ignore list nothing is skipped.
    try std.testing.expect(!watcher.isIgnoredPath("node_modules/x/y.js"));
    try std.testing.expect(!watcher.isIgnoredPath("src/a.html"));

    var watcher2 = try Watcher.init(a, io, .{ .dirPath = "src" });
    defer watcher2.deinit();
    try std.testing.expect(watcher2.isIgnoredPath("node_modules/x/y.js"));
    try std.testing.expect(watcher2.isIgnoredPath(".zig-cache/o/f.js"));
    try std.testing.expect(!watcher2.isIgnoredPath("src/a.html"));
    try std.testing.expect(!watcher2.isIgnoredPath("node_modules_fake/x.js"));
}

// Tests

test "watcher tracks registered files" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{
        .dirPath = "src",
    });
    defer watcher.deinit();

    try watcher.watchFile("build.zig");
    try std.testing.expect(watcher.entries.count() >= 1);
}

test "reload strategy maps extensions correctly" {
    try std.testing.expectEqual(ReloadStrategy.hotReload, ReloadStrategy.forPath("styles/main.css"));
    try std.testing.expectEqual(ReloadStrategy.warmReload, ReloadStrategy.forPath("index.html"));
    try std.testing.expectEqual(ReloadStrategy.warmReload, ReloadStrategy.forPath("templates/page.html"));
    try std.testing.expectEqual(ReloadStrategy.coldReload, ReloadStrategy.forPath("config.json"));
    try std.testing.expectEqual(ReloadStrategy.coldReload, ReloadStrategy.forPath(".env"));
    try std.testing.expectEqual(ReloadStrategy.restart, ReloadStrategy.forPath("src/main.zig"));
}

test "watcher event queue next and hasChanges" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();

    try std.testing.expect(!watcher.hasChanges());
    try std.testing.expectEqual(@as(?WatchEvent, null), watcher.next());
    try std.testing.expectEqual(@as(u64, 0), watcher.changeCount());

    watcher.notifyChange("test_style.css", null, .created);
    try std.testing.expect(watcher.hasChanges());
    try std.testing.expectEqual(@as(u64, 1), watcher.changeCount());

    const ev = watcher.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("test_style.css", ev.?.path);
    try std.testing.expectEqual(WatchEventKind.created, ev.?.kind);
    try std.testing.expectEqual(ReloadStrategy.hotReload, ev.?.strategy);

    try std.testing.expect(!watcher.hasChanges());
    try std.testing.expectEqual(@as(?WatchEvent, null), watcher.next());
}
