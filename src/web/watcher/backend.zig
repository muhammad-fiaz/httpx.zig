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
const staticMod = @import("../static_files/serve.zig");
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
    /// Directory names pruned from the walk at any depth (generated trees).
    /// Empty disables pruning.
    ignoredDirs: []const []const u8 = &.{ "node_modules", ".git", ".zig-cache", "zig-out", "zig-pkg", ".cache", "dist" },
    /// Callback triggered when a file modification is detected.
    onChange: ?*const fn (event: WatchEvent, userData: ?*anyopaque) void = null,
    userData: ?*anyopaque = null,
    /// Bounds for runaway trees (symlink cycles, huge monorepos).
    maxFiles: usize = 100_000,
    maxDepth: usize = 32,
};

const hasNative = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos;

const PlatformBackend = if (!hasNative)
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
    /// `onChange` invocations waiting to run. Producers only ever append
    /// here, so a callback that calls back into the watcher cannot deadlock
    /// against the index lock the producer was holding.
    callbackQueue: std.ArrayList(OwnedWatchEvent) = .empty,
    callbackMutex: sync.Spinlock = .{},
    coalescer: events.Coalescer = .{},
    native: ?PlatformBackend = null,
    nativeFailed: bool = false,
    dirty: std.atomic.Value(bool) = .init(false),
    rescans: std.atomic.Value(usize) = .init(0),
    externalsCheckedMs: i64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !*Watcher {
        const w = try allocator.create(Watcher);
        w.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .entries = std.StringHashMap(FileEntry).init(allocator),
            .coalescer = .{ .windowMs = config.debounceMs },
        };
        errdefer w.deinit();
        _ = try w.scan();
        // The first walk reports every existing file as created. That is a
        // baseline, not a change, so the queues are emptied without ever
        // delivering a callback.
        while (w.next()) |_| {}
        w.clearCallbacks();
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
        for (self.callbackQueue.items) |*ev| {
            ev.deinit(self.allocator);
        }
        self.callbackQueue.deinit(self.allocator);
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
        if (!hasNative) return;
        if (self.config.dirPath.len == 0) return;
        if (builtin.os.tag == .windows) {
            self.native = windows.Backend.init(self.allocator, self.config.dirPath) catch {
                self.nativeFailed = true;
                return;
            };
        } else if (builtin.os.tag == .linux) {
            self.native = linux.Backend.init(self.allocator, self.io, self.config.dirPath) catch {
                self.nativeFailed = true;
                return;
            };
        } else if (builtin.os.tag == .macos) {
            self.native = macos.Backend.init(self.allocator, self.io, self.config.dirPath) catch {
                self.nativeFailed = true;
                return;
            };
        }
    }

    fn stopNative(self: *Watcher) void {
        if (!hasNative) return;
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

    fn notifyChangeFull(self: *Watcher, path: []const u8, oldPath: ?[]const u8, kind: WatchEventKind, isDir: bool) void {
        const now = clock.millisNow();
        if (!self.coalescer.shouldEmit(now, path, kind)) return;
        _ = self._change_count.fetchAdd(1, .release);

        const ownedPath = self.allocator.dupe(u8, path) catch return;
        const ownedOld = if (oldPath) |op| (self.allocator.dupe(u8, op) catch null) else null;
        const ev = OwnedWatchEvent{
            .path = ownedPath,
            .oldPath = ownedOld,
            .kind = kind,
            .strategy = ReloadStrategy.forPath(path),
            .isDirectory = isDir,
            .timestampMs = now,
        };

        if (self.eventQueue.items.len >= 1024) {
            var dropped = self.eventQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
            self.dirty.store(true, .release);
        }

        self.eventQueue.append(self.allocator, ev) catch {
            var mutEv = ev;
            mutEv.deinit(self.allocator);
            return;
        };

        self.enqueueCallback(ev);
    }

    /// Takes an independent copy of `ev` for the callback queue. The event is
    /// already owned by `eventQueue`, and both queues hand their copies to
    /// `OwnedWatchEvent.deinit`, so the paths must be duplicated rather than
    /// shared.
    fn enqueueCallback(self: *Watcher, ev: OwnedWatchEvent) void {
        if (self.config.onChange == null) return;
        const path = self.allocator.dupe(u8, ev.path) catch return;
        errdefer self.allocator.free(path);
        const oldPath: ?[]u8 = if (ev.oldPath) |op| (self.allocator.dupe(u8, op) catch null) else null;

        const copy = OwnedWatchEvent{
            .path = path,
            .oldPath = oldPath,
            .kind = ev.kind,
            .strategy = ev.strategy,
            .isDirectory = ev.isDirectory,
            .timestampMs = ev.timestampMs,
        };
        self.callbackMutex.lock();
        defer self.callbackMutex.unlock();
        if (self.callbackQueue.items.len >= 1024) {
            var dropped = self.callbackQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
            self.dirty.store(true, .release);
        }
        self.callbackQueue.append(self.allocator, copy) catch {
            var mut = copy;
            mut.deinit(self.allocator);
        };
    }

    /// Drops queued callbacks without invoking them. Used to discard the
    /// baseline the first walk produces.
    fn clearCallbacks(self: *Watcher) void {
        self.callbackMutex.lock();
        defer self.callbackMutex.unlock();
        for (self.callbackQueue.items) |*ev| ev.deinit(self.allocator);
        self.callbackQueue.clearRetainingCapacity();
    }

    /// Runs queued `onChange` callbacks. Called by the worker loop with no
    /// watcher lock held, so a callback may safely call `next`,
    /// `changeCount`, or `stop`.
    pub fn dispatchCallbacks(self: *Watcher) void {
        const cb = self.config.onChange orelse return;
        while (true) {
            self.callbackMutex.lock();
            if (self.callbackQueue.items.len == 0) {
                self.callbackMutex.unlock();
                return;
            }
            var ev = self.callbackQueue.orderedRemove(0);
            self.callbackMutex.unlock();
            {
                defer ev.deinit(self.allocator);
                cb(ev.asView(), self.config.userData);
            }
        }
    }

    const SeenFile = struct {
        path: []u8,
        mtimeNs: i128,
        size: u64,
    };

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
                var walker = d.walkSelectively(self.allocator) catch null;
                if (walker) |*w| {
                    defer w.deinit();
                    while (w.next(io) catch null) |entry| {
                        if (seen.items.len >= self.config.maxFiles) break;
                        if (entry.depth() > self.config.maxDepth) continue;
                        if (entry.kind == .directory) {
                            if (self.isIgnoredPath(entry.path)) continue;
                            w.enter(io, entry) catch continue;
                            continue;
                        }
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
                        if (events.isEditorTempFile(entry.path)) continue;

                        // Skip generated trees (nodeModules, caches, build output).
                        if (self.isIgnoredPath(entry.path)) continue;

                        const fullPath = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, entry.path }) catch continue;

                        if (staticMod.statPath(io, fullPath)) |st| {
                            seen.append(self.allocator, .{
                                .path = fullPath,
                                .mtimeNs = st.mtimeNs,
                                .size = st.size,
                            }) catch {
                                self.allocator.free(fullPath);
                                continue;
                            };
                        } else {
                            self.allocator.free(fullPath);
                        }
                    }
                }
            }
        }

        // Membership set over scratch paths (borrowed; `seen` outlives it).
        var seenSet = std.StringHashMap(void).init(self.allocator);
        defer seenSet.deinit();
        for (seen.items) |*f| {
            seenSet.put(f.path, {}) catch continue;
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
                const ownedPath = self.allocator.dupe(u8, f.path) catch continue;
                self.entries.put(ownedPath, .{
                    .path = ownedPath,
                    .mtimeNs = f.mtimeNs,
                    .size = f.size,
                }) catch {
                    self.allocator.free(ownedPath);
                    continue;
                };
                changed = true;
                self.notifyChange(f.path, null, .created);
            }
        }

        // Tracked files absent from the walk (watchFile extras, deletions):
        // stat once here — files covered by the walk are never re-statted.
        var deletedKeys = std.ArrayList([]const u8).empty;
        defer deletedKeys.deinit(self.allocator);

        var itEntries = self.entries.iterator();
        while (itEntries.next()) |entry| {
            if (seenSet.contains(entry.key_ptr.*)) continue;
            if (staticMod.statPath(io, entry.key_ptr.*)) |st| {
                if (entry.value_ptr.mtimeNs != st.mtimeNs or entry.value_ptr.size != st.size) {
                    entry.value_ptr.mtimeNs = st.mtimeNs;
                    entry.value_ptr.size = st.size;
                    changed = true;
                    self.notifyChange(entry.key_ptr.*, null, .modified);
                }
            } else {
                deletedKeys.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (deletedKeys.items) |delPath| {
            if (self.entries.fetchRemove(delPath)) |kv| {
                changed = true;
                self.notifyChange(delPath, null, .deleted);
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
        var walker = d.walkSelectively(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (seen.items.len >= self.config.maxFiles) break;
            if (entry.depth() > self.config.maxDepth) continue;
            if (entry.kind == .directory) {
                if (self.isIgnoredPath(entry.path)) continue;
                walker.enter(io, entry) catch continue;
                continue;
            }
            if (entry.kind != .file) continue;
            if (events.isEditorTempFile(entry.path)) continue;
            if (self.isIgnoredPath(entry.path)) continue;
            const fullPath = std.Io.Dir.path.join(self.allocator, &.{ dir, entry.path }) catch continue;
            if (staticMod.statPath(io, fullPath)) |st| {
                seen.append(self.allocator, .{ .path = fullPath, .mtimeNs = st.mtimeNs, .size = st.size }) catch {
                    self.allocator.free(fullPath);
                    continue;
                };
            } else {
                self.allocator.free(fullPath);
            }
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        // Unknown paths are rename-target candidates; emitting their
        // created events is deferred until rename pairing runs below.
        var createdIdx = std.ArrayList(usize).empty;
        defer createdIdx.deinit(self.allocator);
        for (seen.items, 0..) |*f, si| {
            if (self.entries.getPtr(f.path)) |val| {
                if (val.mtimeNs != f.mtimeNs or val.size != f.size) {
                    val.mtimeNs = f.mtimeNs;
                    val.size = f.size;
                    self.notifyChange(f.path, null, .modified);
                }
            } else {
                createdIdx.append(self.allocator, si) catch {};
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
            if (!found and staticMod.statPath(io, entry.key_ptr.*) == null) {
                gone.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        // Pair renames before emitting anything: a deleted entry and a
        // created file with identical size AND mtime is a rename, not a
        // delete+create (rename preserves mtime). Same shapes as the
        // Linux/Windows native rename paths: silent drop of the old
        // path, ingest of the new one, plus the paired rename event.
        // Unpaired entries keep the previous created/deleted behavior.
        // Paired targets leave createdIdx via swapRemove, so the final
        // loop only sees genuinely new files.
        for (gone.items) |delPath| {
            const old = self.entries.get(delPath) orelse continue;
            var pair: ?usize = null;
            for (createdIdx.items, 0..) |si, ci| {
                const f = &seen.items[si];
                if (f.size == old.size and f.mtimeNs == old.mtimeNs) {
                    pair = ci;
                    break;
                }
            }
            if (pair) |ci| {
                const si = createdIdx.swapRemove(ci);
                const newPath = seen.items[si].path;
                // Copy the old path BEFORE dropPathSilent frees the
                // tracked key it borrows; emitting afterwards would
                // duplicate freed memory.
                const oldOwned = self.allocator.dupe(u8, delPath) catch continue;
                self.dropPathSilent(delPath);
                self.ingestPath(newPath, .renamed);
                self.emitRenameLocked(oldOwned, newPath);
                self.allocator.free(oldOwned);
            } else if (self.entries.fetchRemove(delPath)) |kv| {
                self.notifyChange(delPath, null, .deleted);
                self.allocator.free(kv.key);
            }
        }
        for (createdIdx.items) |si| {
            const f = &seen.items[si];
            const ownedPath = self.allocator.dupe(u8, f.path) catch continue;
            self.entries.put(ownedPath, .{ .path = ownedPath, .mtimeNs = f.mtimeNs, .size = f.size }) catch {
                self.allocator.free(ownedPath);
                continue;
            };
            self.notifyChange(f.path, null, .created);
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
            if (staticMod.statPath(io, p)) |st| {
                if (entry.value_ptr.mtimeNs != st.mtimeNs or entry.value_ptr.size != st.size) {
                    entry.value_ptr.mtimeNs = st.mtimeNs;
                    entry.value_ptr.size = st.size;
                    self.notifyChange(p, null, .modified);
                }
            }
        }
    }

    /// True when any component of `path` names an ignored directory.
    /// Matching every component rather than only the first is what keeps a
    /// watch rooted at `.` from descending into `docs/node_modules`, which
    /// is where the overwhelming majority of a JS-hosting repo's files live.
    pub fn isIgnoredPath(self: *const Watcher, path: []const u8) bool {
        if (self.config.ignoredDirs.len == 0) return false;
        var it = std.mem.splitAny(u8, path, "/\\");
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) continue;
            for (self.config.ignoredDirs) |ignored| {
                if (std.mem.eql(u8, part, ignored)) return true;
            }
        }
        return false;
    }

    /// Registers a specific file path to actively watch for modifications.
    /// Re-registering refreshes in place without leaking the old key.
    /// Stats before locking (no IO under the spinlock).
    pub fn watchFile(self: *Watcher, path: []const u8) !void {
        const st = staticMod.statPath(self.io, path) orelse return;
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
        if (hasNative and builtin.os.tag == .windows) {
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
                self.dispatchCallbacks();
                spins += 1;
                if (spins % 100 == 0) self.pollExternals();
            }
        } else {
            while (self.running.load(.acquire)) {
                _ = self.scan() catch false;
                self.dispatchCallbacks();
                clock.sleepMillis(self.config.pollIntervalMs);
            }
        }
        self.dispatchCallbacks();
    }

    /// Single native drain step (also directly testable).
    /// Returns true when the backend asked for a full reconcile.
    pub fn drainNative(self: *Watcher) bool {
        if (!hasNative or self.native == null) {
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
            if (self.isIgnoredPath(e.relPath)) continue;
            if (events.isEditorTempFile(e.relPath)) continue;
            const full = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, e.relPath }) catch continue;
            defer self.allocator.free(full);
            switch (e.kind) {
                .created => self.ingestPath(full, .created),
                .modified => self.ingestPath(full, .modified),
                .deleted => self.dropPath(full, .deleted),
                .renamed => {
                    if (e.oldRelPath) |oldRel| {
                        const oldFull = std.Io.Dir.path.join(self.allocator, &.{ self.config.dirPath, oldRel }) catch continue;
                        defer self.allocator.free(oldFull);
                        self.dropPathSilent(oldFull);
                        self.ingestPath(full, .renamed);
                        self.emitRenameLocked(oldFull, full);
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
            if (self.isIgnoredPath(e.name)) {
                i += 1;
                continue;
            }
            if (events.isEditorTempFile(full)) {
                i += 1;
                continue;
            }
            switch (e.kind) {
                .movedFrom => {
                    if (i + 1 < evs.len and evs[i + 1].kind == .movedTo and evs[i + 1].cookie == e.cookie) {
                        const n = &evs[i + 1];
                        const newFull = std.Io.Dir.path.join(self.allocator, &.{ n.dir, n.name }) catch {
                            i += 1;
                            continue;
                        };
                        defer self.allocator.free(newFull);
                        self.dropPathSilent(full);
                        self.ingestPath(newFull, .renamed);
                        self.emitRenameLocked(full, newFull);
                        i += 2;
                        continue;
                    }
                    self.dropPath(full, .deleted);
                },
                .movedTo => self.ingestPath(full, .created),
                .created => {
                    if (e.isDir) {
                        self.notifyChangeFull(full, null, .directoryCreated, true);
                    } else {
                        self.ingestPath(full, .created);
                    }
                },
                .deleted => {
                    if (e.isDir) {
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
                .dirChanged => self.reconcileDir(e.dir) catch {},
                .dirGone => {
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
        if (staticMod.statPath(self.io, path)) |st| {
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
    fn emitRenameLocked(self: *Watcher, oldPath: []const u8, newPath: []const u8) void {
        const now = clock.millisNow();
        _ = self._change_count.fetchAdd(1, .release);
        const ownedPath = self.allocator.dupe(u8, newPath) catch return;
        const ownedOld = self.allocator.dupe(u8, oldPath) catch {
            self.allocator.free(ownedPath);
            return;
        };
        const ev = OwnedWatchEvent{
            .path = ownedPath,
            .oldPath = ownedOld,
            .kind = .renamed,
            .strategy = ReloadStrategy.forPath(newPath),
            .timestampMs = now,
        };
        if (self.eventQueue.items.len >= 1024) {
            var dropped = self.eventQueue.orderedRemove(0);
            dropped.deinit(self.allocator);
            self.dirty.store(true, .release);
        }
        self.eventQueue.append(self.allocator, ev) catch {
            var mutEv = ev;
            mutEv.deinit(self.allocator);
            return;
        };
        self.enqueueCallback(ev);
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

test "ignored dirs match at any depth, not just the root" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();

    // A watch rooted at "." must not descend into a nested dependency tree,
    // which is where a JS-hosting repo keeps the bulk of its files.
    try std.testing.expect(watcher.isIgnoredPath("docs/node_modules/vitepress/dist/index.js"));
    try std.testing.expect(watcher.isIgnoredPath("examples/web/node_modules/x/y.js"));
    try std.testing.expect(watcher.isIgnoredPath("a/b/c/.git/HEAD"));
    try std.testing.expect(watcher.isIgnoredPath(".zig-cache/o/abc/x.o"));
    try std.testing.expect(watcher.isIgnoredPath("build/zig-out/bin/app"));

    // Windows separators arrive from the native backends.
    try std.testing.expect(watcher.isIgnoredPath("docs\\node_modules\\x\\y.js"));

    // Real content still counts.
    try std.testing.expect(!watcher.isIgnoredPath("src/main.zig"));
    try std.testing.expect(!watcher.isIgnoredPath("docs/node_modules.md"));
    try std.testing.expect(!watcher.isIgnoredPath("a/node_modules_helper/b.js"));
}

test "scan prunes ignored directories instead of only filtering their files" {
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-prune-{d}", .{clock.millisNow()});
    var subbuf: [512]u8 = undefined;
    const keptPath = try std.fmt.bufPrint(&subbuf, "{s}/kept.txt", .{root});
    const modulesPath = try std.fmt.allocPrint(a, "{s}/node_modules", .{root});
    defer a.free(modulesPath);
    const pkgPath = try std.fmt.allocPrint(a, "{s}/pkg", .{modulesPath});
    defer a.free(pkgPath);
    const droppedPath = try std.fmt.allocPrint(a, "{s}/dropped.txt", .{pkgPath});
    defer a.free(droppedPath);

    const cwd: std.Io.Dir = .cwd();
    cwd.createDir(io, ".zig-cache", .default_dir) catch {};
    cwd.createDir(io, root, .default_dir) catch {};
    cwd.createDir(io, modulesPath, .default_dir) catch {};
    cwd.createDir(io, pkgPath, .default_dir) catch {};
    defer cleanupTestDir(io, root);

    try fsMod.writeFile(keptPath, "keep");
    try fsMod.writeFile(droppedPath, "drop");

    var watcher = try Watcher.init(a, io, .{ .dirPath = root });
    defer watcher.deinit();

    var sawKept = false;
    var it = watcher.entries.iterator();
    while (it.next()) |entry| {
        if (std.mem.indexOf(u8, entry.key_ptr.*, "node_modules") != null) {
            return error.IgnoredDirectoryWasIndexed;
        }
        if (std.mem.endsWith(u8, entry.key_ptr.*, "kept.txt")) sawKept = true;
    }
    try std.testing.expect(sawKept);
}

test "watcher tracks registered files" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var watcher = try Watcher.init(a, io, .{});
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), watcher.entries.count());
}

test "the initial scan reports nothing to observers" {
    // Every file present at startup arrives as `created` from the first
    // walk. Those are the baseline, so neither the event queue, the callback
    // queue, nor the change count may report them.
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-baseline-{d}", .{clock.millisNow()});
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer cleanupTestDir(io, root);

    var fbuf: [512]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/a.txt", .{root});
    try fsMod.writeFile(fpath, "v1");
    const f2 = try std.fmt.bufPrint(&fbuf, "{s}/b.txt", .{root});
    try fsMod.writeFile(f2, "v2");

    BaselineProbe.calls = 0;
    var watcher = try Watcher.init(a, io, .{ .dirPath = root, .onChange = BaselineProbe.onChange });
    defer watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), BaselineProbe.calls);
    try std.testing.expectEqual(@as(u64, 0), watcher.changeCount());
    try std.testing.expect(!watcher.hasChanges());

    // A real change after startup still reports.
    try fsMod.writeFile(fpath, "v1-longer");
    _ = try watcher.scan();
    watcher.dispatchCallbacks();
    try std.testing.expect(BaselineProbe.calls >= 1);
    try std.testing.expect(watcher.changeCount() >= 1);
}

test "reload strategy maps extensions correctly" {
    try std.testing.expectEqual(ReloadStrategy.hotReload, ReloadStrategy.forPath("a.css"));
    try std.testing.expectEqual(ReloadStrategy.coldReload, ReloadStrategy.forPath(".env"));
    try std.testing.expectEqual(ReloadStrategy.restart, ReloadStrategy.forPath("src/main.zig"));
}

test "scan detects create/modify/delete across rescans" {
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const probe = "watcher_scan_probe.tmp";
    fsMod.deleteFile(probe) catch {};

    var watcher = try Watcher.init(a, io, .{ .extensions = &.{".tmp"} });
    defer watcher.deinit();
    defer fsMod.deleteFile(probe) catch {};

    // Missing file registers silently with no entry.
    try watcher.watchFile(probe);
    try std.testing.expectEqual(@as(usize, 0), watcher.entries.count());

    // Create + register: baseline, no change yet.
    try fsMod.writeFile(probe, "v1");
    try watcher.watchFile(probe);
    try std.testing.expect(!try watcher.scan());

    // Re-registering refreshes in place (no duplicate entry, no leak —
    // testing.allocator fails the test on any leak).
    try watcher.watchFile(probe);
    try std.testing.expectEqual(@as(usize, 1), watcher.entries.count());

    // Modify: detected with a .modified event.
    try fsMod.writeFile(probe, "v2-longer");
    try std.testing.expect(try watcher.scan());
    const ev = watcher.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(WatchEventKind.modified, ev.?.kind);
    try std.testing.expect(!try watcher.scan());

    // Delete: detected with a .deleted event.
    try fsMod.deleteFile(probe);
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
    if (!hasNative) return error.SkipZigTest;
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-native-{d}", .{clock.millisNow()});
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
    try fsMod.writeFile(fpath, "v1");
    var sawKind: ?WatchEventKind = null;
    var deadline: usize = 0;
    while (deadline < 60) : (deadline += 1) {
        if (watcher.next()) |e| {
            if (e.kind == .created or e.kind == .modified) {
                sawKind = e.kind;
                break;
            }
        }
        _ = watcher.drainNative();
        clock.sleepMillis(10);
    }
    try std.testing.expect(sawKind != null);
}

test "rename pairing survives atomic save patterns" {
    if (!hasNative) return error.SkipZigTest;
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-rename-{d}", .{clock.millisNow()});
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
    try fsMod.writeFile(apath, "data");
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
    var sawRename = false;
    while (deadline < 60) : (deadline += 1) {
        _ = watcher.drainNative();
        while (watcher.next()) |e| {
            if (e.kind == .renamed) sawRename = true;
        }
        if (sawRename) break;
        clock.sleepMillis(10);
    }
    try std.testing.expect(sawRename);
}

test "reconcileDir pairs renames from stat-walk diffs" {
    // Backend-agnostic coverage for the directory-granularity path
    // (macOS kqueue): a stat-walk diff that loses a tracked file and
    // gains an untracked one with identical size+mtime is a rename.
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-reconcile-{d}", .{clock.millisNow()});
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer cleanupTestDir(io, root);

    var watcher = try Watcher.init(a, io, .{ .dirPath = root });
    defer watcher.deinit();

    var abuf: [512]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    const apath = try std.fmt.bufPrint(&abuf, "{s}/a.txt", .{root});
    const bpath = try std.fmt.bufPrint(&bbuf, "{s}/b.txt", .{root});
    try fsMod.writeFile(apath, "data");
    try watcher.reconcileDir(root);
    while (watcher.next()) |_| {}
    {
        const cwd: std.Io.Dir = .cwd();
        try cwd.rename(apath, cwd, bpath, io);
    }
    try watcher.reconcileDir(root);
    var sawRename = false;
    var sawOld = false;
    // Tracked keys use path.join separators (backslash on Windows),
    // so build the expectation the same way instead of assuming '/'.
    const expectedOld = try std.Io.Dir.path.join(a, &.{ root, "a.txt" });
    defer a.free(expectedOld);
    while (watcher.next()) |e| {
        if (e.kind == .renamed) {
            sawRename = true;
            if (e.oldPath) |op| sawOld = sawOld or std.mem.eql(u8, op, expectedOld);
        }
    }
    try std.testing.expect(sawRename);
    try std.testing.expect(sawOld);
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

/// Test sink proving an `onChange` callback can re-enter the watcher.
/// File scope so the callback body can reference the struct itself.
const ReentrantProbe = struct {
    var watcher: ?*Watcher = null;
    var calls: usize = 0;
    var dequeued: bool = false;

    fn reset() void {
        watcher = null;
        calls = 0;
        dequeued = false;
    }

    fn onChange(_: WatchEvent, _: ?*anyopaque) void {
        const w = watcher orelse return;
        calls += 1;
        // Both take the index lock the producer held while queuing.
        _ = w.changeCount();
        if (w.next() != null) dequeued = true;
    }
};

test "onChange callback may re-enter the watcher without deadlocking" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    ReentrantProbe.reset();

    var watcher = try Watcher.init(a, io, .{ .onChange = ReentrantProbe.onChange });
    defer watcher.deinit();
    ReentrantProbe.watcher = watcher;

    watcher.notifyChange("reentrant.css", null, .created);
    watcher.dispatchCallbacks();

    try std.testing.expectEqual(@as(usize, 1), ReentrantProbe.calls);
    try std.testing.expect(ReentrantProbe.dequeued);
    try std.testing.expectEqual(@as(u64, 1), watcher.changeCount());
}

/// Test sink for path-ownership: records calls without draining the queue,
/// so an event stays live in both queues at `deinit`.
const DrainProbe = struct {
    var calls: usize = 0;

    fn onChange(_: WatchEvent, _: ?*anyopaque) void {
        calls += 1;
    }
};

/// Test sink counting how many change callbacks a watcher has delivered.
const BaselineProbe = struct {
    var calls: usize = 0;

    fn onChange(_: WatchEvent, _: ?*anyopaque) void {
        calls += 1;
    }
};

test "callback and event queues own separate copies of each path" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    DrainProbe.calls = 0;

    var watcher = try Watcher.init(a, io, .{ .onChange = DrainProbe.onChange });
    defer watcher.deinit();

    // Left undrained in both queues on purpose: deinit frees each queue's
    // copies, so sharing the pointer would be a double free here.
    watcher.notifyChange("shared.css", null, .created);
    watcher.dispatchCallbacks();
    try std.testing.expectEqual(@as(usize, 1), DrainProbe.calls);
    try std.testing.expect(watcher.hasChanges());
}

test "stop joins the worker so no callback outlives the watcher" {
    const fsMod = @import("../../utils/fs.zig");
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var pathBuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathBuf, ".zig-cache/watch-stop-{d}", .{clock.millisNow()});
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer cleanupTestDir(io, root);

    const Counter = struct {
        var afterStop: usize = 0;
        var stopped: bool = false;

        fn onChange(_: WatchEvent, _: ?*anyopaque) void {
            if (stopped) afterStop += 1;
        }
    };
    Counter.afterStop = 0;
    Counter.stopped = false;

    var watcher = try Watcher.init(a, io, .{ .dirPath = root, .onChange = Counter.onChange });
    try watcher.start();
    try std.testing.expect(watcher.isRunning());

    var fbuf: [512]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/a.txt", .{root});
    try fsMod.writeFile(fpath, "v1");

    watcher.stop();
    Counter.stopped = true;
    try std.testing.expect(!watcher.isRunning());
    try std.testing.expect(watcher.thread == null);

    // Nothing may fire after stop() returns.
    clock.sleepMillis(50);
    try std.testing.expectEqual(@as(usize, 0), Counter.afterStop);

    watcher.deinit();
}
