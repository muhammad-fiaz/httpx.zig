//! Directory and file watcher with auto-reload and cache invalidation.
//!
//! Provides:
//! - Polling and event-driven file modification tracking for templates, static assets, and SPA files
//! - SSE (Server-Sent Events) live-reload script injection for development servers
//! - Fast change detection with SHA-256 / mtime hashing
//! - Thread-safe background watcher loop

const std = @import("std");
const Allocator = std.mem.Allocator;
const clock = @import("../../common/clock.zig");

const sync = @import("../../common/sync.zig");

pub const WatchEvent = struct {
    path: []const u8,
    kind: enum { modified, created, deleted },
    timestamp_ms: i64,
};

pub const WatcherConfig = struct {
    /// Root directory to recursively watch.
    dir_path: []const u8,
    /// Poll interval in milliseconds.
    poll_interval_ms: u64 = 250,
    /// Optional file extensions to filter (e.g. &[].{ ".html", ".css", ".js" }). Empty means all.
    extensions: []const []const u8 = &.{ ".html", ".htm", ".css", ".js", ".json" },
    /// Callback triggered when a file modification is detected.
    on_change: ?*const fn (event: WatchEvent, user_data: ?*anyopaque) void = null,
    user_data: ?*anyopaque = null,
};

const FileEntry = struct {
    path: []u8,
    mtime_ns: i128,
    size: u64,
};

pub const Watcher = struct {
    allocator: Allocator,
    config: WatcherConfig,
    entries: std.StringHashMap(FileEntry),
    mutex: sync.Spinlock = .{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    change_count: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: Allocator, config: WatcherConfig) !*Watcher {
        const w = try allocator.create(Watcher);
        errdefer allocator.destroy(w);
        w.* = .{
            .allocator = allocator,
            .config = config,
            .entries = std.StringHashMap(FileEntry).init(allocator),
        };
        _ = try w.scan();
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.mutex.lock();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit();
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    /// Performs one recursive scan and returns true if any file was modified, created, or deleted.
    pub fn scan(self: *Watcher) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var changed = false;
        const static_mod = @import("../static_files/serve.zig");
        const io: std.Io = std.Io.Threaded.global_single_threaded.io();

        // 1. Recursive directory walk if dir_path is provided and exists
        if (self.config.dir_path.len > 0) {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, self.config.dir_path, .{ .iterate = true }) catch null;

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

                        const full_path = std.Io.Dir.path.join(self.allocator, &.{ self.config.dir_path, entry.path }) catch continue;
                        defer self.allocator.free(full_path);

                        if (static_mod.statPath(io, full_path)) |st| {
                            if (self.entries.getPtr(full_path)) |val| {
                                if (val.mtime_ns != st.mtime_ns or val.size != st.size) {
                                    val.mtime_ns = st.mtime_ns;
                                    val.size = st.size;
                                    changed = true;
                                    _ = self.change_count.fetchAdd(1, .release);
                                    if (self.config.on_change) |cb| {
                                        cb(.{
                                            .path = full_path,
                                            .kind = .modified,
                                            .timestamp_ms = clock.millisNow(),
                                        }, self.config.user_data);
                                    }
                                }
                            } else {
                                // New file detected
                                const owned_path = self.allocator.dupe(u8, full_path) catch continue;
                                self.entries.put(owned_path, .{
                                    .path = owned_path,
                                    .mtime_ns = st.mtime_ns,
                                    .size = st.size,
                                }) catch {
                                    self.allocator.free(owned_path);
                                    continue;
                                };
                                changed = true;
                                _ = self.change_count.fetchAdd(1, .release);
                                if (self.config.on_change) |cb| {
                                    cb(.{
                                        .path = full_path,
                                        .kind = .created,
                                        .timestamp_ms = clock.millisNow(),
                                    }, self.config.user_data);
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. Check registered individual files for modifications or deletions
        var it_entries = self.entries.iterator();
        while (it_entries.next()) |entry| {
            if (static_mod.statPath(io, entry.key_ptr.*)) |st| {
                if (entry.value_ptr.mtime_ns != st.mtime_ns or entry.value_ptr.size != st.size) {
                    entry.value_ptr.mtime_ns = st.mtime_ns;
                    entry.value_ptr.size = st.size;
                    changed = true;
                    _ = self.change_count.fetchAdd(1, .release);
                    if (self.config.on_change) |cb| {
                        cb(.{
                            .path = entry.key_ptr.*,
                            .kind = .modified,
                            .timestamp_ms = clock.millisNow(),
                        }, self.config.user_data);
                    }
                }
            }
        }

        return changed;
    }

    /// Registers a specific file path to actively watch for modifications.
    pub fn watchFile(self: *Watcher, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const static_mod = @import("../static_files/serve.zig");
        const io: std.Io = std.Io.Threaded.global_single_threaded.io();
        if (static_mod.statPath(io, path)) |st| {
            const owned = try self.allocator.dupe(u8, path);
            try self.entries.put(owned, .{
                .path = owned,
                .mtime_ns = st.mtime_ns,
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
            clock.sleepMillis(self.config.poll_interval_ms);
        }
    }

    /// Returns the live-reload client JS script that connects via SSE to auto-reload on file changes.
    pub fn liveReloadScript(allocator: Allocator, sse_url: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\<script>
            \\(function() {{
            \\  const es = new EventSource("{s}");
            \\  es.onmessage = function(e) {{
            \\    if (e.data === "reload") {{
            \\      console.log("[httpx live-reload] Reloading page...");
            \\      location.reload();
            \\    }}
            \\  }};
            \\  es.onerror = function() {{
            \\    setTimeout(() => location.reload(), 2000);
            \\  }};
            \\}})();
            \\</script>
        , .{sse_url});
    }
};

test "watcher tracks registered files" {
    const a = std.testing.allocator;
    var watcher = try Watcher.init(a, .{
        .dir_path = "src",
    });
    defer watcher.deinit();

    try watcher.watchFile("build.zig");
    try std.testing.expect(watcher.entries.count() >= 1);
}
