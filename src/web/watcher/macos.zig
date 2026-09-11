//! macOS native filesystem backend (kqueue EVFILT_VNODE).
//!
//! kqueue was chosen over FSEvents deliberately: FSEvents requires
//! Objective-C/CoreFoundation linking, while kqueue is available through
//! the C library on every macOS target with no extra dependencies.
//! Tradeoff vs FSEvents: kqueue reports directory-level granularity (no
//! per-file names), so the facade reconciles an affected directory with a
//! targeted stat walk. Only compiled on macOS; selected by backend.zig
//! through comptime dispatch.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;
const EV_ERROR: u16 = 0x4000;
const NOTE_DELETE: u32 = 0x00000001;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;
const NOTE_RENAME: u32 = 0x00000020;
const NOTE_REVOKE: u32 = 0x00000040;

const VNODE_MASK: u32 = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_REVOKE;

extern "c" fn close(fd: c_int) c_int;

pub const RawEvent = struct {
    /// Watched directory path that changed (owned).
    dir: []u8,
    kind: RawKind,

    pub fn deinit(self: *RawEvent, allocator: Allocator) void {
        allocator.free(self.dir);
    }
};

pub const RawKind = enum {
    dir_changed,
    dir_gone,
};

const WatchedDir = struct {
    fd: std.posix.fd_t,
    path: []u8,
};

pub const Backend = struct {
    allocator: Allocator,
    io: std.Io,
    kq: c_int = -1,
    /// udata index -> watched directory (fd stays open for the watch).
    dirs: std.ArrayList(WatchedDir),
    /// path -> index in dirs (owned keys for lookup).
    by_path: std.StringHashMap(usize),
    dirty: bool = false,

    pub fn init(allocator: Allocator, io: std.Io, root: []const u8) !Backend {
        var self = Backend{
            .allocator = allocator,
            .io = io,
            .dirs = std.ArrayList(WatchedDir).empty,
            .by_path = std.StringHashMap(usize).init(allocator),
        };
        errdefer self.deinit();
        self.kq = std.c.kqueue();
        if (self.kq < 0) return error.WatchInitFailed;
        try self.watchRecursive(root);
        return self;
    }

    pub fn deinit(self: *Backend) void {
        for (self.dirs.items) |*w| {
            _ = close(w.fd);
            self.allocator.free(w.path);
        }
        self.dirs.deinit(self.allocator);
        // by_path keys borrow dirs[].path (no separate allocation),
        // so only the table itself is released here.
        self.by_path.deinit();
        if (self.kq >= 0) {
            _ = close(self.kq);
            self.kq = -1;
        }
    }

    fn watchOne(self: *Backend, path: []const u8) void {
        if (self.by_path.contains(path)) return;
        const cpath = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(cpath);
        const fd = std.posix.openat(std.posix.AT.FDCWD, cpath, .{ .ACCMODE = .RDONLY }, 0) catch return;
        // Single ownership: dirs[].path owns the bytes; by_path only
        // borrows the slice. Freeing both (as separate frees) would
        // double-free the same allocation on deinit/removeWatch.
        const owned_path = self.allocator.dupe(u8, path) catch {
            _ = close(fd);
            return;
        };
        const idx = self.dirs.items.len;
        self.dirs.append(self.allocator, .{ .fd = fd, .path = owned_path }) catch {
            self.allocator.free(owned_path);
            _ = close(fd);
            return;
        };
        self.by_path.put(owned_path, idx) catch {
            _ = self.dirs.pop();
            self.allocator.free(owned_path);
            _ = close(fd);
            return;
        };
        var change = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = VNODE_MASK,
            .data = 0,
            .udata = idx,
        };
        var evts: [1]std.c.Kevent = undefined;
        const rc = std.c.kevent(self.kq, @ptrCast(&change), 1, &evts, 0, null);
        if (rc < 0) {
            _ = self.by_path.remove(owned_path);
            _ = self.dirs.pop();
            self.allocator.free(owned_path);
            _ = close(fd);
            return;
        }
    }

    fn watchRecursive(self: *Backend, root: []const u8) !void {
        self.watchOne(root);
        const cwd: std.Io.Dir = .cwd();
        var dir = cwd.openDir(self.io, root, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var walker = dir.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.path.len > 512) continue;
            var buf: [1024]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, entry.path }) catch continue;
            self.watchOne(full);
        }
    }

    /// Blocks up to timeout_ms for directory-level changes.
    pub fn poll(self: *Backend, allocator: Allocator, timeout_ms: i32) ![]RawEvent {
        var out = std.ArrayList(RawEvent).empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.kq < 0) return out.toOwnedSlice(allocator);
        var evts: [64]std.c.Kevent = undefined;
        var no_changes: [0]std.c.Kevent = .{};
        var ts = std.c.timespec{ .sec = @divTrunc(timeout_ms, 1000), .nsec = @mod(timeout_ms, 1000) * 1_000_000 };
        if (timeout_ms < 0) {
            const n = std.c.kevent(self.kq, &no_changes, 0, &evts, evts.len, null);
            if (n <= 0) return out.toOwnedSlice(allocator);
            try self.translate(allocator, &out, evts[0..@intCast(n)]);
            return out.toOwnedSlice(allocator);
        }
        const n = std.c.kevent(self.kq, &no_changes, 0, &evts, evts.len, &ts);
        if (n < 0) return out.toOwnedSlice(allocator);
        if (n == 0) return out.toOwnedSlice(allocator);
        try self.translate(allocator, &out, evts[0..@intCast(n)]);
        return out.toOwnedSlice(allocator);
    }

    fn translate(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), evts: []std.c.Kevent) !void {
        for (evts) |ev| {
            if (ev.flags & EV_ERROR != 0) {
                self.dirty = true;
                continue;
            }
            const idx: usize = @intCast(ev.udata);
            if (idx >= self.dirs.items.len) continue;
            const dir_path = self.dirs.items[idx].path;
            if (ev.fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE) != 0) {
                // Copy the path BEFORE removeWatch frees it.
                const gone = try allocator.dupe(u8, dir_path);
                errdefer allocator.free(gone);
                self.removeWatch(idx);
                try out.append(allocator, .{
                    .dir = gone,
                    .kind = .dir_gone,
                });
                continue;
            }
            if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB) != 0) {
                self.adoptNewSubdirs(dir_path);
                try out.append(allocator, .{
                    .dir = try allocator.dupe(u8, dir_path),
                    .kind = .dir_changed,
                });
            }
        }
    }

    fn removeWatch(self: *Backend, idx: usize) void {
        if (idx >= self.dirs.items.len) return;
        const removed = self.dirs.orderedRemove(idx);
        _ = close(removed.fd);
        // Borrowed map key: drop the entry without freeing; the bytes
        // are freed once below via removed.path.
        _ = self.by_path.remove(removed.path);
        self.allocator.free(removed.path);
        var it = self.by_path.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > idx) entry.value_ptr.* -= 1;
        }
    }

    fn adoptNewSubdirs(self: *Backend, dir_path: []const u8) void {
        const cwd: std.Io.Dir = .cwd();
        var dir = cwd.openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 512) continue;
            var buf: [1024]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            self.watchOne(full);
        }
    }
};

test "kqueue backend registers a root" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var backend = try Backend.init(a, io, ".");
    defer backend.deinit();
    try std.testing.expect(backend.dirs.items.len >= 1);
    try std.testing.expect(!backend.dirty);
}
