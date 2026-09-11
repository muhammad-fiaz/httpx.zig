//! Native filesystem watcher facade.
//!
//! Owns the watch lifecycle, file index, event queue, and debouncing, and
//! delegates event *production* to one platform backend selected at
//! compile time (windows/linux/macos) with a stat-scan fallback. The
//! fallback also serves as overflow recovery: whenever a backend reports
//! lost events, the index is reconciled with a full scan.
//!
//! Public API is unchanged (`Watcher.init/deinit/start/stop/next/...`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const clock = @import("../../common/clock.zig");
const sync = @import("../../common/sync.zig");
const static_mod = @import("../static_files/serve.zig");
const events = @import("events.zig");

const windows = @import("windows.zig");
const linux = @import("linux.zig");
const macos = @import("macos.zig");

pub const WatchEventKind = events.WatchEventKind;
pub const WatchEvent = events.WatchEvent;
pub const OwnedWatchEvent = events.OwnedWatchEvent;
pub const ReloadStrategy = events.ReloadStrategy;
pub const WatcherConfig = Config;

pub const Config = struct {
    dirPath: []const u8 = "",
    extensions: []const []const u8 = &.{},
    pollIntervalMs: u64 = 50,
    debounceMs: i64 = 50,
    /// Top-level directory names skipped during scans (generated trees).
    /// Empty disables skipping.
    ignoredDirs: []const []const u8 = &.{ "node_modules", ".git", ".zig-cache", "zig-out", ".cache", "dist" },
    /// Callback triggered when a file modification is detected.
    onChange: ?*const fn (event: WatchEvent, userData: ?*anyopaque) void = null,
    userData: ?*anyopaque = null,
    /// Bounds for runaway trees (symlink cycles, huge monorepos).
    maxFiles: usize = 100_000,
    maxDepth: usize = 32,
};

const has_native = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos;

const PlatformBackend = if (!has_native)
    struct {}
else if (builtin.os.tag == .windows)
    windows.Backend
else if (builtin.os.tag == .linux)
    linux.Backend
else
    macos.Backend;

const FileEntry = struct {
    path: []u8,
    mtimeNs: i128,
    size: u64,
};

pub const Watcher = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    entries: std.StringHashMap(FileEntry),
    mutex: sync.Spinlock = .{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    _change_count: std.atomic.Value(usize) = .init(0),
    eventQueue: std.ArrayList(OwnedWatchEvent) = .empty,
    currentEvent: ?OwnedWatchEvent = null,
    coalescer: events.Coalescer = .{},
    native: ?PlatformBackend = null,
    native_failed: bool = false,
    dirty: std.atomic.Value(bool) = .init(false),
    rescans: std.atomic.Value(usize) = .init(0),
    externals_checked_ms: i64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !*Watcher {
        const w = try allocator.create(Watcher);
        errdefer allocator.destroy(w);
        w.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .entries = std.StringHashMap(FileEntry).init(allocator),
            .coalescer = .{ .windowMs = config.debounceMs },
        };
        errdefer w.deinit();
        _ = try w.scan();
        // Drain any baseline scan events so watcher starts clean
        while (w.next()) |_| {}
        w._change_count.store(0, .release);
        w.startNative();
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.stopNative();
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

    /// True when a native OS backend is actively producing events.
    pub fn usingNative(self: *const Watcher) bool {
        return self.native != null;
    }

    fn startNative(self: *Watcher) void {
        if (!has_native) return;
        if (self.config.dirPath.len == 0) return;
        if (builtin.os.tag == .windows) {
            self.native = windows.Backend.init(self.allocator, self.config.dirPath) catch {
                self.native_failed = true;
                return;
            };
        } else if (builtin.os.tag == .linux) {
            self.native = linux.Backend.init(self.allocator, self.io, self.config.dirPath) catch {
                self.native_failed = true;
                return;
            };
        } else if (builtin.os.tag == .macos) {
            self.native = macos.Backend.init(self.allocator, self.io, self.config.dirPath) catch {
                self.native_failed = true;
                return;
            };
        }
    }

    fn stopNative(self: *Watcher) void {
        if (!has_native) return;
        if (builtin.os.tag == .windows) {
            if (self.native) |*nb| nb.deinit();
        } else if (builtin.os.tag == .linux) {
            if (self.native) |*nb| nb.deinit();
        } else if (builtin.os.tag == .macos) {
            if (self.native) |*nb| nb.deinit();
        }
        self.native = null;
    }

    pub fn notifyChange(self: *Watcher, path: []const u8, oldPath: ?[]const u8, kind: WatchEventKind) void {
        self.notifyChangeFull(path, oldPath, kind, false);
    }

    fn notifyChangeFull(self: *Watcher, path: []const u8, oldPath: ?[]const u8, kind: WatchEventKind, is_dir: bool) void {
        const now = clock.millisNow();
        if (!self.coalescer.shouldEmit(now, path, kind)) return;
        _ = self._change_count.fetchAdd(1, .release);

        const owned_path = self.allocator.dupe(u8, path) catch return;
        const owned_old = if (oldPath) |op| (self.allocator.dupe(u8, op) catch null) else null;
        const ev = OwnedWatchEvent{
            .path = owned_path,
            .oldPath = owned_old,
            .kind = kind,
            .strategy = ReloadStrategy.forPath(path),
            .isDirectory = is_dir,
            .timestampMs = now,
        };

        if (self.eventQueue.items.len >= 1024) {
            var dropped = self.eventQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
            self.dirty.store(true, .release);
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

    const SeenFile = struct {
        path: []u8,
        mtimeNs: i128,
        size: u64,
    };

    fn pathDepth(path: []const u8) usize {
        var n: usize = 0;
        for (path) |c| {
            if (c == '/' or c == '\\') n += 1;
        }
        return n;
    }

    /// Performs one scan and returns true if any file was modified, created, or deleted.
    ///
    /// Locking: the walk and all stats run LOCK-FREE into scratch
    /// buffers; only the map diff takes the spinlock (microseconds, no
    /// IO under lock). Every tracked file is statted at most once per
    /// scan. `notifyChange` callers must hold the lock (all internal
    /// call sites do; direct external calls are single-threaded test
    /// helpers only).
    pub fn scan(self: *Watcher) !bool {
        const io = self.io;

        // Phase 1 (no lock): recursive walk + stat into scratch.
        var seen = std.ArrayList(SeenFile).empty;
        defer {
            for (seen.items) |*f| self.allocator.free(f.path);
            seen.deinit(self.allocator);
        }
        if (self.config.dirPath.len > 0) {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, self.config.dirPath, .{ .iterate = true }) catch null;

            if (dir) |*d| {
                defer d.close(io);
                var walker = d.walk(self.allocator) catch null;
                if (walker) |*w| {
                    defer w.deinit();
                    while (w.next(io) catch null) |entry| {
                        if (seen.items.len >= self.config.maxFiles) break;
                        if (entry.kind != .file) continue;
                        if (pathDepth(entry.path) > self.config.maxDepth) continue;

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
                        if (events.isEditorTempFile(entry.path)) continue;

                        // Skip generated trees (node_modules, caches, build output).
                        if (self.isIgnoredPath(entry.path)) continue;

                        const full_path = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, entry.path }) catch continue;

                        if (static_mod.statPath(io, full_path)) |st| {
                            seen.append(self.allocator, .{
                                .path = full_path,
                                .mtimeNs = st.mtimeNs,
                                .size = st.size,
                            }) catch {
                                self.allocator.free(full_path);
                                continue;
                            };
                        } else {
                            self.allocator.free(full_path);
                        }
                    }
                }
            }
        }

        // Membership set over scratch paths (borrowed; `seen` outlives it).
        var seen_set = std.StringHashMap(void).init(self.allocator);
        defer seen_set.deinit();
        for (seen.items) |*f| {
            seen_set.put(f.path, {}) catch continue;
        }

        // Phase 2 (brief lock): diff scratch against tracked entries.
        self.mutex.lock();
        defer self.mutex.unlock();

        var changed = false;
        for (seen.items) |*f| {
            if (self.entries.getPtr(f.path)) |val| {
                if (val.mtimeNs != f.mtimeNs or val.size != f.size) {
                    val.mtimeNs = f.mtimeNs;
                    val.size = f.size;
                    changed = true;
                    self.notifyChange(f.path, null, .modified);
                }
            } else {
                // New file detected; ownership moves into the map.
                const owned_path = self.allocator.dupe(u8, f.path) catch continue;
                self.entries.put(owned_path, .{
                    .path = owned_path,
                    .mtimeNs = f.mtimeNs,
                    .size = f.size,
                }) catch {
                    self.allocator.free(owned_path);
                    continue;
                };
                changed = true;
                self.notifyChange(f.path, null, .created);
            }
        }

        // Tracked files absent from the walk (watchFile extras, deletions):
        // stat once here — files covered by the walk are never re-statted.
        var deleted_keys = std.ArrayList([]const u8).empty;
        defer deleted_keys.deinit(self.allocator);

        var it_entries = self.entries.iterator();
        while (it_entries.next()) |entry| {
            if (seen_set.contains(entry.key_ptr.*)) continue;
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

    /// Reconciles one subtree after a directory-granularity native event
    /// (macOS) or a dirty/overflow mark: stat-walks `dir`, emits precise
    /// file events, and adopts new files. Bounded by maxFiles/maxDepth.
    pub fn reconcileDir(self: *Watcher, dir: []const u8) !void {
        const io = self.io;
        var seen = std.ArrayList(SeenFile).empty;
        defer {
            for (seen.items) |*f| self.allocator.free(f.path);
            seen.deinit(self.allocator);
        }
        const cwd: std.Io.Dir = .cwd();
        var d = cwd.openDir(io, dir, .{ .iterate = true }) catch return;
        defer d.close(io);
        var walker = d.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (seen.items.len >= self.config.maxFiles) break;
            if (entry.kind != .file) continue;
            if (pathDepth(entry.path) > self.config.maxDepth) continue;
            if (events.isEditorTempFile(entry.path)) continue;
            const full_path = std.Io.Dir.path.join(self.allocator, &.{ dir, entry.path }) catch continue;
            if (static_mod.statPath(io, full_path)) |st| {
                seen.append(self.allocator, .{ .path = full_path, .mtimeNs = st.mtimeNs, .size = st.size }) catch {
                    self.allocator.free(full_path);
                    continue;
                };
            } else {
                self.allocator.free(full_path);
            }
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        for (seen.items) |*f| {
            if (self.entries.getPtr(f.path)) |val| {
                if (val.mtimeNs != f.mtimeNs or val.size != f.size) {
                    val.mtimeNs = f.mtimeNs;
                    val.size = f.size;
                    self.notifyChange(f.path, null, .modified);
                }
            } else {
                const owned_path = self.allocator.dupe(u8, f.path) catch continue;
                self.entries.put(owned_path, .{ .path = owned_path, .mtimeNs = f.mtimeNs, .size = f.size }) catch {
                    self.allocator.free(owned_path);
                    continue;
                };
                self.notifyChange(f.path, null, .created);
            }
        }
        var gone = std.ArrayList([]const u8).empty;
        defer gone.deinit(self.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, dir)) continue;
            var found = false;
            for (seen.items) |*f| {
                if (std.mem.eql(u8, f.path, entry.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found and static_mod.statPath(io, entry.key_ptr.*) == null) {
                gone.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (gone.items) |del_path| {
            if (self.entries.fetchRemove(del_path)) |kv| {
                self.notifyChange(del_path, null, .deleted);
                self.allocator.free(kv.key);
            }
        }
    }

    /// Stats explicitly registered files living outside the watch root.
    /// Native backends cover the root subtree; these singles are cheap.
    fn pollExternals(self: *Watcher) void {
        const io = self.io;
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const p = entry.key_ptr.*;
            if (self.config.dirPath.len > 0 and std.mem.startsWith(u8, p, self.config.dirPath)) continue;
            if (static_mod.statPath(io, p)) |st| {
                if (entry.value_ptr.mtimeNs != st.mtimeNs or entry.value_ptr.size != st.size) {
                    entry.value_ptr.mtimeNs = st.mtimeNs;
                    entry.value_ptr.size = st.size;
                    self.notifyChange(p, null, .modified);
                }
            }
        }
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
    /// Re-registering refreshes in place without leaking the old key.
    /// Stats before locking (no IO under the spinlock).
    pub fn watchFile(self: *Watcher, path: []const u8) !void {
        const st = static_mod.statPath(self.io, path) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.getPtr(path)) |val| {
            val.mtimeNs = st.mtimeNs;
            val.size = st.size;
            return;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.entries.put(owned, .{
            .path = owned,
            .mtimeNs = st.mtimeNs,
            .size = st.size,
        });
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
        if (has_native and builtin.os.tag == .windows) {
            if (self.native) |*nb| nb.cancel();
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn workerLoop(self: *Watcher) void {
        if (self.native != null) {
            var spins: usize = 0;
            while (self.running.load(.acquire)) {
                _ = self.drainNative();
                spins += 1;
                if (spins % 100 == 0) self.pollExternals();
            }
        } else {
            while (self.running.load(.acquire)) {
                _ = self.scan() catch false;
                clock.sleepMillis(self.config.pollIntervalMs);
            }
        }
    }

    /// Single native drain step (also directly testable).
    /// Returns true when the backend asked for a full reconcile.
    pub fn drainNative(self: *Watcher) bool {
        if (!has_native or self.native == null) {
            if (self.dirty.swap(false, .acq_rel)) {
                _ = self.rescans.fetchAdd(1, .release);
                _ = self.scan() catch false;
                return true;
            }
            return false;
        }
        if (builtin.os.tag == .windows) {
            const nb = &(self.native orelse return false);
            const timeout: i32 = @intCast(self.config.pollIntervalMs);
            const evs = nb.poll(self.allocator, timeout) catch return false;
            defer {
                for (evs) |*e| {
                    var mut = e.*;
                    mut.deinit(self.allocator);
                }
                self.allocator.free(evs);
            }
            self.ingestWindows(evs);
            if (nb.dirty) {
                nb.dirty = false;
                self.dirty.store(true, .release);
            }
        } else if (builtin.os.tag == .linux) {
            const nb = &(self.native orelse return false);
            const timeout: i32 = @intCast(self.config.pollIntervalMs);
            const evs = nb.poll(self.allocator, timeout) catch return false;
            defer {
                for (evs) |*e| {
                    var mut = e.*;
                    mut.deinit(self.allocator);
                }
                self.allocator.free(evs);
            }
            self.ingestLinux(evs);
            if (nb.dirty) {
                nb.dirty = false;
                self.dirty.store(true, .release);
            }
        } else if (builtin.os.tag == .macos) {
            const nb = &(self.native orelse return false);
            const timeout: i32 = @intCast(self.config.pollIntervalMs);
            const evs = nb.poll(self.allocator, timeout) catch return false;
            defer {
                for (evs) |*e| {
                    var mut = e.*;
                    mut.deinit(self.allocator);
                }
                self.allocator.free(evs);
            }
            self.ingestMacos(evs);
            if (nb.dirty) {
                nb.dirty = false;
                self.dirty.store(true, .release);
            }
        }
        if (self.dirty.swap(false, .acq_rel)) {
            _ = self.rescans.fetchAdd(1, .release);
            _ = self.scan() catch false;
            return true;
        }
        return false;
    }

    fn ingestWindows(self: *Watcher, evs: []const windows.RawEvent) void {
        if (self.config.dirPath.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (evs) |*e| {
            if (!events.isPathInsideRoot(self.config.dirPath, e.relPath)) continue;
            if (events.isEditorTempFile(e.relPath)) continue;
            const full = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, e.relPath }) catch continue;
            defer self.allocator.free(full);
            switch (e.kind) {
                .created => self.ingestPath(full, .created),
                .modified => self.ingestPath(full, .modified),
                .deleted => self.dropPath(full, .deleted),
                .renamed => {
                    if (e.oldRelPath) |old_rel| {
                        const old_full = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, old_rel }) catch continue;
                        defer self.allocator.free(old_full);
                        self.dropPathSilent(old_full);
                        self.ingestPath(full, .renamed);
                        self.emitRenameLocked(old_full, full);
                    } else {
                        self.ingestPath(full, .created);
                    }
                },
                .overflow => self.dirty.store(true, .release),
            }
        }
    }

    fn ingestLinux(self: *Watcher, evs: []const linux.RawEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < evs.len) {
            const e = &evs[i];
            if (e.kind == .overflow) {
                self.dirty.store(true, .release);
                i += 1;
                continue;
            }
            if (e.kind == .ignored) {
                i += 1;
                continue;
            }
            const full = std.Io.Dir.path.join(self.allocator, &.{ e.dir, e.name }) catch {
                i += 1;
                continue;
            };
            defer self.allocator.free(full);
            if (events.isEditorTempFile(full)) {
                i += 1;
                continue;
            }
            switch (e.kind) {
                .moved_from => {
                    if (i + 1 < evs.len and evs[i + 1].kind == .moved_to and evs[i + 1].cookie == e.cookie) {
                        const n = &evs[i + 1];
                        const new_full = std.Io.Dir.path.join(self.allocator, &.{ n.dir, n.name }) catch {
                            i += 1;
                            continue;
                        };
                        defer self.allocator.free(new_full);
                        self.dropPathSilent(full);
                        self.ingestPath(new_full, .renamed);
                        self.emitRenameLocked(full, new_full);
                        i += 2;
                        continue;
                    }
                    self.dropPath(full, .deleted);
                },
                .moved_to => self.ingestPath(full, .created),
                .created => {
                    if (e.is_dir) {
                        self.notifyChangeFull(full, null, .directoryCreated, true);
                    } else {
                        self.ingestPath(full, .created);
                    }
                },
                .deleted => {
                    if (e.is_dir) {
                        self.dropSubtree(full);
                        self.notifyChangeFull(full, null, .directoryDeleted, true);
                    } else {
                        self.dropPath(full, .deleted);
                    }
                },
                .modified, .attrib => self.ingestPath(full, .modified),
                .overflow, .ignored => {},
            }
            i += 1;
        }
    }

    fn ingestMacos(self: *Watcher, evs: []const macos.RawEvent) void {
        for (evs) |*e| {
            switch (e.kind) {
                .dir_changed => self.reconcileDir(e.dir) catch {},
                .dir_gone => {
                    self.mutex.lock();
                    self.dropSubtree(e.dir);
                    self.notifyChangeFull(e.dir, null, .directoryDeleted, true);
                    self.mutex.unlock();
                },
            }
        }
    }

    /// Stats `path`, emitting created/modified only on real index change.
    /// Caller holds the mutex.
    fn ingestPath(self: *Watcher, path: []const u8, kind: events.WatchEventKind) void {
        if (static_mod.statPath(self.io, path)) |st| {
            if (self.entries.getPtr(path)) |val| {
                if (val.mtimeNs == st.mtimeNs and val.size == st.size) return;
                val.mtimeNs = st.mtimeNs;
                val.size = st.size;
                self.notifyChangeFull(path, null, .modified, false);
            } else {
                const owned = self.allocator.dupe(u8, path) catch return;
                self.entries.put(owned, .{ .path = owned, .mtimeNs = st.mtimeNs, .size = st.size }) catch {
                    self.allocator.free(owned);
                    return;
                };
                self.notifyChangeFull(path, null, kind, false);
            }
        } else {
            self.dropPath(path, .deleted);
        }
    }

    /// Emits a paired rename event. Caller holds the mutex.
    fn emitRenameLocked(self: *Watcher, old_path: []const u8, new_path: []const u8) void {
        const now = clock.millisNow();
        _ = self._change_count.fetchAdd(1, .release);
        const owned_path = self.allocator.dupe(u8, new_path) catch return;
        const owned_old = self.allocator.dupe(u8, old_path) catch {
            self.allocator.free(owned_path);
            return;
        };
        const ev = OwnedWatchEvent{
            .path = owned_path,
            .oldPath = owned_old,
            .kind = .renamed,
            .strategy = ReloadStrategy.forPath(new_path),
            .timestampMs = now,
        };
        if (self.eventQueue.items.len >= 1024) {
            var dropped = self.eventQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
            self.dirty.store(true, .release);
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

    /// Drops one index entry, emitting the given kind. Caller holds the mutex.
    fn dropPath(self: *Watcher, path: []const u8, kind: events.WatchEventKind) void {
        if (self.entries.fetchRemove(path)) |kv| {
            self.notifyChangeFull(path, null, kind, false);
            self.allocator.free(kv.key);
        }
    }

    /// Drops without emitting. Caller holds the mutex.
    fn dropPathSilent(self: *Watcher, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Drops a whole subtree (deleted directory). Caller holds the mutex.
    fn dropSubtree(self: *Watcher, dir: []const u8) void {
        var gone = std.ArrayList([]const u8).empty;
        defer gone.deinit(self.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const p = entry.key_ptr.*;
            if (std.mem.eql(u8, p, dir) or
                (std.mem.startsWith(u8, p, dir) and p.len > dir.len and (p[dir.len] == '/' or p[dir.len] == '\\')))
            {
                gone.append(self.allocator, p) catch {};
            }
        }
        for (gone.items) |p| {
            if (self.entries.fetchRemove(p)) |kv| {
                self.notifyChangeFull(p, null, .deleted, false);
                self.allocator.free(kv.key);
            }
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

    /// Returns the live-reload client JS script (SSE). Correct against
    /// one-shot poll endpoints AND long-lived streams alike:
    ///   * reloads only when the event id CHANGES (not on every connect),
    ///   * hot-swaps stylesheets on `hotReload` without a full reload,
    ///   * never reloads on stream close/error — EventSource reconnects
    ///     on its own, and reloading there loops forever.
    pub fn liveReloadScript(allocator: Allocator, sseUrl: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\<script>
            \\(function() {{
            \\  var lastId = null;
            \\  var es = new EventSource("{s}");
            \\  es.onmessage = function(e) {{
            \\    var id = e.lastEventId || null;
            \\    if (id === null || id === lastId) return;
            \\    var first = (lastId === null);
            \\    lastId = id;
            \\    if (first) return;
            \\    if (e.data === "hotReload") {{
            \\      console.log("[httpx live-reload] Hot-reloading styles...");
            \\      const links = document.querySelectorAll('link[rel="stylesheet"]');
            \\      for (let i = 0; i < links.length; i++) {{
            \\        const link = links[i];
            \\        const url = new URL(link.href, window.location.href);
            \\        url.searchParams.set('_httpx_t', Date.now());
            \\        link.href = url.href;
            \\      }}
            \\    }} else {{
            \\      console.log("[httpx live-reload] Reloading page...");
            \\      location.reload();
            \\    }}
            \\  }};
            \\  es.onerror = function() {{
            \\    console.log("[httpx live-reload] stream closed, reconnecting...");
            \\  }};
            \\}})();
            \\</script>
        , .{sseUrl});
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

test "ignored dirs skip generated trees" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();
    try std.testing.expect(watcher.isIgnoredPath("node_modules/foo.js"));
    try std.testing.expect(watcher.isIgnoredPath(".git/HEAD"));
    try std.testing.expect(!watcher.isIgnoredPath("templates/index.html"));
    try std.testing.expect(!watcher.isIgnoredPath("a.js"));
}

test "watcher tracks registered files" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), watcher.entries.count());
}

test "reload strategy maps extensions correctly" {
    try std.testing.expectEqual(ReloadStrategy.hotReload, ReloadStrategy.forPath("a.css"));
    try std.testing.expectEqual(ReloadStrategy.coldReload, ReloadStrategy.forPath(".env"));
    try std.testing.expectEqual(ReloadStrategy.restart, ReloadStrategy.forPath("src/main.zig"));
}

test "scan detects create/modify/delete across rescans" {
    const fs_mod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const probe = "watcher_scan_probe.tmp";
    fs_mod.deleteFile(probe) catch {};

    var watcher = try Watcher.init(a, io, .{ .extensions = &.{".tmp"} });
    defer watcher.deinit();
    defer fs_mod.deleteFile(probe) catch {};

    // Missing file registers silently with no entry.
    try watcher.watchFile(probe);
    try std.testing.expectEqual(@as(usize, 0), watcher.entries.count());

    // Create + register: baseline, no change yet.
    try fs_mod.writeFile(probe, "v1");
    try watcher.watchFile(probe);
    try std.testing.expect(!try watcher.scan());

    // Re-registering refreshes in place (no duplicate entry, no leak —
    // testing.allocator fails the test on any leak).
    try watcher.watchFile(probe);
    try std.testing.expectEqual(@as(usize, 1), watcher.entries.count());

    // Modify: detected with a .modified event.
    try fs_mod.writeFile(probe, "v2-longer");
    try std.testing.expect(try watcher.scan());
    const ev = watcher.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(WatchEventKind.modified, ev.?.kind);
    try std.testing.expect(!try watcher.scan());

    // Delete: detected with a .deleted event.
    try fs_mod.deleteFile(probe);
    try std.testing.expect(try watcher.scan());
    const ev2 = watcher.next();
    try std.testing.expect(ev2 != null);
    try std.testing.expectEqual(WatchEventKind.deleted, ev2.?.kind);
    try std.testing.expectEqual(@as(usize, 0), watcher.entries.count());
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

fn cleanupTestDir(io: std.Io, root: []const u8) void {
    const cwd: std.Io.Dir = .cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        dir.deleteFile(io, entry.name) catch dir.deleteDir(io, entry.name) catch {};
    }
    cwd.deleteDir(io, root) catch {};
}

test "native backend produces real filesystem events" {
    if (!has_native) return error.SkipZigTest;
    const fs_mod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/watch-native-{d}", .{clock.millisNow()});
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer cleanupTestDir(io, root);

    var watcher = try Watcher.init(a, io, .{ .dirPath = root });
    defer watcher.deinit();
    try std.testing.expect(watcher.usingNative());

    // Prime the native read: OS watchers are edge-triggered and only
    // report changes made after observation starts.
    _ = watcher.drainNative();
    var fbuf: [512]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/ev.txt", .{root});
    try fs_mod.writeFile(fpath, "v1");
    var saw_kind: ?WatchEventKind = null;
    var deadline: usize = 0;
    while (deadline < 60) : (deadline += 1) {
        if (watcher.next()) |e| {
            if (e.kind == .created or e.kind == .modified) {
                saw_kind = e.kind;
                break;
            }
        }
        _ = watcher.drainNative();
        clock.sleepMillis(10);
    }
    try std.testing.expect(saw_kind != null);
}

test "rename pairing survives atomic save patterns" {
    if (!has_native) return error.SkipZigTest;
    const fs_mod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/watch-rename-{d}", .{clock.millisNow()});
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer cleanupTestDir(io, root);

    var watcher = try Watcher.init(a, io, .{ .dirPath = root });
    defer watcher.deinit();
    try std.testing.expect(watcher.usingNative());

    var abuf: [512]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    const apath = try std.fmt.bufPrint(&abuf, "{s}/a.txt", .{root});
    const bpath = try std.fmt.bufPrint(&bbuf, "{s}/b.txt", .{root});
    _ = watcher.drainNative();
    try fs_mod.writeFile(apath, "data");
    var deadline: usize = 0;
    while (watcher.next() == null and deadline < 60) : (deadline += 1) {
        _ = watcher.drainNative();
        clock.sleepMillis(10);
    }
    while (watcher.next()) |_| {}
    {
        const cwd: std.Io.Dir = .cwd();
        try cwd.rename(apath, cwd, bpath, io);
    }
    deadline = 0;
    var saw_rename = false;
    while (deadline < 60) : (deadline += 1) {
        _ = watcher.drainNative();
        while (watcher.next()) |e| {
            if (e.kind == .renamed) saw_rename = true;
        }
        if (saw_rename) break;
        clock.sleepMillis(10);
    }
    try std.testing.expect(saw_rename);
}

test "overflow marks dirty and rescans to reconcile" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();
    watcher.dirty.store(true, .release);
    try std.testing.expect(watcher.drainNative() or !watcher.usingNative());
    try std.testing.expect(!watcher.dirty.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), watcher.rescans.load(.acquire));
}
