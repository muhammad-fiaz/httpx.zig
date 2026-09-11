//! Linux native filesystem backend (inotify).
//!
//! Recursive directory watches with rename pairing via cookies,
//! overflow detection (IN_Q_OVERFLOW), and automatic tracking of
//! newly created directories. Only compiled on Linux; selected by
//! backend.zig through comptime dispatch.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const IN_NONBLOCK: u32 = 0o4000;
const IN_CLOEXEC: u32 = 0o2000000;

pub const IN_ACCESS: u32 = 0x00000001;
pub const IN_MODIFY: u32 = 0x00000002;
pub const IN_ATTRIB: u32 = 0x00000004;
pub const IN_CLOSE_WRITE: u32 = 0x00000008;
pub const IN_MOVED_FROM: u32 = 0x00000040;
pub const IN_MOVED_TO: u32 = 0x00000080;
pub const IN_CREATE: u32 = 0x00000100;
pub const IN_DELETE: u32 = 0x00000200;
pub const IN_DELETE_SELF: u32 = 0x00000400;
pub const IN_MOVE_SELF: u32 = 0x00000800;
pub const IN_IGNORED: u32 = 0x00008000;
pub const IN_ISDIR: u32 = 0x40000000;
pub const IN_Q_OVERFLOW: u32 = 0x00004000;
pub const IN_ONLYDIR: u32 = 0x01000000;

const WATCH_MASK: u32 = IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE |
    IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;

pub const RawEvent = struct {
    /// Watch-relative directory that produced the event (owned).
    dir: []u8,
    /// Entry name within dir, empty for self events (owned).
    name: []u8,
    kind: RawKind,
    cookie: u32 = 0,
    is_dir: bool = false,

    pub fn deinit(self: *RawEvent, allocator: Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.name);
    }
};

pub const RawKind = enum {
    created,
    deleted,
    modified,
    attrib,
    moved_from,
    moved_to,
    overflow,
    ignored,
};

/// Converts a raw Linux syscall return into a file descriptor.
/// Raw syscalls encode -errno in the return value; anything negative is
/// a failure. Never @intCast blindly: a missed error would abort the
/// process with "integer does not fit in destination type" instead of
/// surfacing a catchable WatchInitFailed.
fn syscallFd(rc: usize) !std.posix.fd_t {
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.WatchInitFailed;
    return @intCast(signed);
}

pub const Backend = struct {
    allocator: Allocator,
    io: std.Io,
    fd: std.posix.fd_t = -1,
    /// wd -> watched directory path (owned).
    watches: std.AutoHashMap(i32, []u8),
    root: []u8 = &.{},
    dirty: bool = false,

    pub fn init(allocator: Allocator, io: std.Io, root: []const u8) !Backend {
        var self = Backend{
            .allocator = allocator,
            .io = io,
            .watches = std.AutoHashMap(i32, []u8).init(allocator),
        };
        errdefer self.deinit();
        self.fd = try syscallFd(linux.inotify_init1(IN_NONBLOCK | IN_CLOEXEC));
        self.root = try allocator.dupe(u8, root);
        try self.watchRecursive(root);
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.watches.deinit();
        if (self.root.len > 0) self.allocator.free(self.root);
    }

    fn watchDir(self: *Backend, path: []const u8) void {
        const cpath = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(cpath);
        const wd: i32 = syscallFd(linux.inotify_add_watch(self.fd, cpath, WATCH_MASK | IN_ONLYDIR)) catch return;
        if (self.watches.getPtr(wd)) |old| {
            self.allocator.free(old.*);
            old.* = self.allocator.dupe(u8, path) catch return;
            return;
        }
        const owned = self.allocator.dupe(u8, path) catch return;
        self.watches.put(wd, owned) catch {
            self.allocator.free(owned);
        };
    }

    fn watchRecursive(self: *Backend, root: []const u8) !void {
        self.watchDir(root);
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
            self.watchDir(full);
        }
    }

    /// Blocks up to timeout_ms for events; returns owned events.
    /// Sets `dirty` when the kernel reports overflow or ignored watches.
    pub fn poll(self: *Backend, allocator: Allocator, timeout_ms: i32) ![]RawEvent {
        var out = std.ArrayList(RawEvent).empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.fd < 0) return out.toOwnedSlice(allocator);
        var pfd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, timeout_ms) catch return out.toOwnedSlice(allocator);
        if (ready == 0) return out.toOwnedSlice(allocator);
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            if (n == 0) break;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_len: usize = ev.len;
                const name = if (name_len > 0 and off + @sizeOf(linux.inotify_event) + name_len <= n)
                    std.mem.span(@as([*:0]const u8, @ptrCast(&buf[off + @sizeOf(linux.inotify_event)])))
                else
                    "";
                off += @sizeOf(linux.inotify_event) + name_len;
                try self.translate(allocator, &out, ev, name);
                if (self.dirty) break;
            }
            if (self.dirty) break;
        }
        return out.toOwnedSlice(allocator);
    }

    fn translate(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), ev: *const linux.inotify_event, name: []const u8) !void {
        const mask = ev.mask;
        const dir = if (self.watches.get(ev.wd)) |d| d else return;
        if (mask & IN_Q_OVERFLOW != 0) {
            self.dirty = true;
            try out.append(allocator, .{
                .dir = try allocator.dupe(u8, dir),
                .name = try allocator.dupe(u8, ""),
                .kind = .overflow,
                .is_dir = false,
            });
            return;
        }
        if (mask & IN_IGNORED != 0) {
            if (self.watches.fetchRemove(ev.wd)) |kv| {
                allocator.free(kv.value);
            }
            self.dirty = true;
            return;
        }
        const is_dir = mask & IN_ISDIR != 0;
        const base_kind: ?RawKind = if (mask & IN_MOVED_FROM != 0)
            .moved_from
        else if (mask & IN_MOVED_TO != 0)
            .moved_to
        else if (mask & IN_CREATE != 0)
            .created
        else if (mask & IN_DELETE != 0)
            .deleted
        else if (mask & (IN_MODIFY | IN_CLOSE_WRITE) != 0)
            .modified
        else if (mask & IN_ATTRIB != 0)
            .attrib
        else if (mask & (IN_DELETE_SELF | IN_MOVE_SELF) != 0)
            .deleted
        else
            null;
        const kind = base_kind orelse return;
        if (kind == .created and is_dir) {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch null) |full| {
                self.watchDir(full);
            }
        }
        try out.append(allocator, .{
            .dir = try allocator.dupe(u8, dir),
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .cookie = ev.cookie,
            .is_dir = is_dir,
        });
    }
};

test "inotify backend watches and reports a write" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const fs_mod = @import("../../utils/fs.zig");
    const root = ".zig-cache/tmp-inotify-probe";
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer {
        const cwd: std.Io.Dir = .cwd();
        cwd.deleteDir(io, root) catch {};
    }
    var backend = try Backend.init(a, io, root);
    defer backend.deinit();
    const fpath = try std.fmt.allocPrint(a, "{s}/w.txt", .{root});
    defer a.free(fpath);
    try fs_mod.writeFile(fpath, "hello");
    const evs = try backend.poll(a, 2000);
    defer {
        for (evs) |*e| {
            var mut = e.*;
            mut.deinit(a);
        }
        a.free(evs);
    }
    try std.testing.expect(evs.len > 0);
    try std.testing.expect(!backend.dirty);
}
