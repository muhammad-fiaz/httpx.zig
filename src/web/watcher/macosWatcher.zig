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
    dirChanged,
    dirGone,
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
    byPath: std.StringHashMap(usize),
    recursive: bool = true,
    dirty: bool = false,

    pub fn init(allocator: Allocator, io: std.Io, root: []const u8, recursive: bool) !Backend {
        var self = Backend{
            .allocator = allocator,
            .io = io,
            .dirs = std.ArrayList(WatchedDir).empty,
            .byPath = std.StringHashMap(usize).init(allocator),
            .recursive = recursive,
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
        // byPath keys borrow dirs[].path (no separate allocation),
        // so only the table itself is released here.
        self.byPath.deinit();
        if (self.kq >= 0) {
            _ = close(self.kq);
            self.kq = -1;
        }
    }

    fn watchOne(self: *Backend, path: []const u8) void {
        if (self.byPath.contains(path)) return;
        const cpath = self.allocator.dupeSentinel(u8, path, 0) catch return;
        defer self.allocator.free(cpath);
        const fd = std.posix.openat(std.posix.AT.FDCWD, cpath, .{ .ACCMODE = .RDONLY }, 0) catch return;
        // Single ownership: dirs[].path owns the bytes; byPath only
        // borrows the slice. Freeing both (as separate frees) would
        // double-free the same allocation on deinit/removeWatch.
        const ownedPath = self.allocator.dupe(u8, path) catch {
            _ = close(fd);
            return;
        };
        const idx = self.dirs.items.len;
        self.dirs.append(self.allocator, .{ .fd = fd, .path = ownedPath }) catch {
            self.allocator.free(ownedPath);
            _ = close(fd);
            return;
        };
        self.byPath.put(ownedPath, idx) catch {
            _ = self.dirs.pop();
            self.allocator.free(ownedPath);
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
            _ = self.byPath.remove(ownedPath);
            _ = self.dirs.pop();
            self.allocator.free(ownedPath);
            _ = close(fd);
            return;
        }
    }

    fn watchRecursive(self: *Backend, root: []const u8) !void {
        self.watchOne(root);
        if (!self.recursive) return;
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

    /// Blocks up to timeoutMs for directory-level changes.
    pub fn poll(self: *Backend, allocator: Allocator, timeoutMs: i32) ![]RawEvent {
        var out = std.ArrayList(RawEvent).empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.kq < 0) return out.toOwnedSlice(allocator);
        var evts: [64]std.c.Kevent = undefined;
        var noChanges: [0]std.c.Kevent = .{};
        var ts = std.c.timespec{ .sec = @divTrunc(timeoutMs, 1000), .nsec = @mod(timeoutMs, 1000) * 1_000_000 };
        if (timeoutMs < 0) {
            const n = std.c.kevent(self.kq, &noChanges, 0, &evts, evts.len, null);
            if (n <= 0) return out.toOwnedSlice(allocator);
            try self.translate(allocator, &out, evts[0..@intCast(n)]);
            return out.toOwnedSlice(allocator);
        }
        const n = std.c.kevent(self.kq, &noChanges, 0, &evts, evts.len, &ts);
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
            const dirPath = self.dirs.items[idx].path;
            if (ev.fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE) != 0) {
                // Copy the path BEFORE removeWatch frees it.
                const gone = try allocator.dupe(u8, dirPath);
                errdefer allocator.free(gone);
                self.removeWatch(idx);
                try out.append(allocator, .{
                    .dir = gone,
                    .kind = .dirGone,
                });
                continue;
            }
            if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB) != 0) {
                self.adoptNewSubdirs(dirPath);
                try out.append(allocator, .{
                    .dir = try allocator.dupe(u8, dirPath),
                    .kind = .dirChanged,
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
        _ = self.byPath.remove(removed.path);
        self.allocator.free(removed.path);
        var it = self.byPath.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > idx) entry.value_ptr.* -= 1;
        }
    }

    fn adoptNewSubdirs(self: *Backend, dirPath: []const u8) void {
        if (!self.recursive) return;
        const cwd: std.Io.Dir = .cwd();
        var dir = cwd.openDir(self.io, dirPath, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 512) continue;
            var buf: [1024]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dirPath, entry.name }) catch continue;
            self.watchOne(full);
        }
    }
};

test "kqueue backend registers a root" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var backend = try Backend.init(a, io, ".", true);
    defer backend.deinit();
    try std.testing.expect(backend.dirs.items.len >= 1);
    try std.testing.expect(!backend.dirty);
}
