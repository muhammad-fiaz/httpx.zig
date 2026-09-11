//! Windows native filesystem backend (ReadDirectoryChangesW).
//!
//! One directory handle per watch root with subtree watching, overlapped
//! IO plus an event object for bounded waits, rename old/new pairing,
//! UTF-16 path conversion, long-path (`\\?\`) support, and
//! CancelIoEx-driven shutdown. Only compiled on Windows; selected by
//! backend.zig through comptime dispatch.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const GENERIC_READ: DWORD = 0x80000000;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const FILE_SHARE_DELETE: DWORD = 0x00000004;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const FILE_LIST_DIRECTORY: DWORD = 0x00000001;

const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
const FILE_NOTIFY_CHANGE_ATTRIBUTES: DWORD = 0x00000004;
const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;
const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x00000040;

pub const FILE_ACTION_ADDED: DWORD = 0x00000001;
pub const FILE_ACTION_REMOVED: DWORD = 0x00000002;
pub const FILE_ACTION_MODIFIED: DWORD = 0x00000003;
pub const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 0x00000004;
pub const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 0x00000005;

const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT: DWORD = 258;
const WAIT_FAILED: DWORD = 0xFFFFFFFF;
const INFINITE: DWORD = 0xFFFFFFFF;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: HANDLE = undefined,
};

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: *anyopaque,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) HANDLE;

extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetOverlappedResult(hFile: HANDLE, lpOverlapped: *OVERLAPPED, lpNumberOfBytesTransferred: *DWORD, bWait: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;

pub const RawEvent = struct {
    /// Path relative to the watch root, `/`-separated (owned).
    relPath: []u8,
    kind: RawKind,
    /// Previous relative path for renames (owned, null otherwise).
    oldRelPath: ?[]u8 = null,
    is_dir: bool = false,

    pub fn deinit(self: *RawEvent, allocator: Allocator) void {
        allocator.free(self.relPath);
        if (self.oldRelPath) |op| allocator.free(op);
    }
};

pub const RawKind = enum {
    created,
    deleted,
    modified,
    renamed,
    overflow,
};

pub const Backend = struct {
    allocator: Allocator,
    dir_handle: HANDLE = INVALID_HANDLE_VALUE,
    event_handle: ?HANDLE = null,
    overlapped: OVERLAPPED = .{},
    /// Read buffer for the single outstanding overlapped read. It must
    /// outlive every poll call, so it lives here rather than on the stack.
    buf: [65536]u8 align(@alignOf(u32)) = undefined,
    read_pending: bool = false,
    root: []u8 = &.{},
    dirty: bool = false,
    reading: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, root: []const u8) !Backend {
        var self = Backend{ .allocator = allocator };
        errdefer self.deinit();
        self.root = try allocator.dupe(u8, root);
        const wroot = try toLongWPath(allocator, root);
        defer allocator.free(wroot);
        self.dir_handle = CreateFileW(
            wroot.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            // OVERLAPPED is load-bearing: without it ReadDirectoryChangesW
            // executes synchronously and blocks until a change arrives,
            // defeating bounded waits and shutdown.
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (self.dir_handle == INVALID_HANDLE_VALUE) return error.WatchInitFailed;
        const ev = CreateEventW(null, @enumFromInt(1), @enumFromInt(0), null);
        const ev_int: usize = @intFromPtr(ev);
        if (ev_int == 0) return error.WatchInitFailed;
        self.event_handle = ev;
        self.overlapped.hEvent = ev;
        return self;
    }

    pub fn deinit(self: *Backend) void {
        self.cancel();
        if (self.event_handle) |ev| {
            _ = CloseHandle(ev);
            self.event_handle = null;
        }
        if (self.dir_handle != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.dir_handle);
            self.dir_handle = INVALID_HANDLE_VALUE;
        }
        if (self.root.len > 0) self.allocator.free(self.root);
    }

    /// Cancels any in-flight read so a blocked poll() wakes promptly.
    pub fn cancel(self: *Backend) void {
        if (self.dir_handle == INVALID_HANDLE_VALUE) return;
        if (!self.read_pending) return;
        _ = CancelIoEx(self.dir_handle, null);
        if (self.event_handle) |ev| {
            _ = WaitForSingleObject(ev, 5000);
        }
        self.read_pending = false;
    }

    /// Blocks up to timeout_ms for native events; returns owned events.
    /// One overlapped read stays outstanding across calls (no cancel/reissue
    /// cycle, hence no baseline gaps); only shutdown cancels it. Sets
    /// `dirty` when the kernel dropped events (rescan required).
    pub fn poll(self: *Backend, allocator: Allocator, timeout_ms: i32) ![]RawEvent {
        var out = std.ArrayList(RawEvent).empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.dir_handle == INVALID_HANDLE_VALUE) return out.toOwnedSlice(allocator);
        const ev = self.event_handle orelse return out.toOwnedSlice(allocator);
        if (!self.read_pending) {
            _ = ResetEvent(ev);
            self.overlapped.Internal = 0;
            self.overlapped.InternalHigh = 0;
            self.overlapped.Offset = 0;
            self.overlapped.OffsetHigh = 0;
            self.overlapped.hEvent = ev;
            const started = ReadDirectoryChangesW(
                self.dir_handle,
                &self.buf,
                self.buf.len,
                @enumFromInt(1),
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                    FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                    FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION,
                null,
                &self.overlapped,
                null,
            );
            if (@intFromEnum(started) == 0) {
                if (windows.GetLastError() != .IO_PENDING) {
                    self.dirty = true;
                    return out.toOwnedSlice(allocator);
                }
            }
            self.read_pending = true;
        }
        self.reading.store(true, .release);
        defer self.reading.store(false, .release);
        const wait_ms: DWORD = if (timeout_ms < 0) INFINITE else @intCast(timeout_ms);
        const wr = WaitForSingleObject(ev, wait_ms);
        if (wr == WAIT_TIMEOUT) return out.toOwnedSlice(allocator);
        if (wr != WAIT_OBJECT_0) {
            self.dirty = true;
            self.read_pending = false;
            return out.toOwnedSlice(allocator);
        }
        var bytes: DWORD = 0;
        if (@intFromEnum(GetOverlappedResult(self.dir_handle, &self.overlapped, &bytes, @enumFromInt(0))) == 0) {
            if (windows.GetLastError() == .NOTIFY_ENUM_DIR) self.dirty = true;
            self.read_pending = false;
            return out.toOwnedSlice(allocator);
        }
        self.read_pending = false;
        if (bytes == 0) {
            self.dirty = true;
            return out.toOwnedSlice(allocator);
        }
        try self.translate(allocator, &out, self.buf[0..bytes], bytes);
        return out.toOwnedSlice(allocator);
    }

    const PendingRename = struct {
        path: []u8,
        is_dir: bool,
    };

    fn translate(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), buf: []const u8, valid: u32) !void {
        var off: usize = 0;
        var pending_old: ?PendingRename = null;
        defer if (pending_old) |*p| allocator.free(p.path);
        while (off + 12 <= valid) {
            const next: u32 = std.mem.readInt(u32, buf[off..][0..4], .little);
            const action: u32 = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
            const name_len: u32 = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            const name_off = off + 12;
            if (name_off + name_len > valid) break;
            const wlen = name_len / 2;
            const wname: []const u16 = @ptrCast(@alignCast(buf[name_off..][0 .. wlen * 2]));
            const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wname) catch null;
            defer if (utf8) |s| allocator.free(s);
            if (utf8) |s| {
                for (s) |*c| {
                    if (c.* == '\\') c.* = '/';
                }
            }
            const rel = if (utf8) |s| s else "";
            switch (action) {
                FILE_ACTION_ADDED => {
                    try self.flushPendingOld(allocator, out, &pending_old, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .created,
                        .is_dir = false,
                    });
                },
                FILE_ACTION_REMOVED => {
                    try self.flushPendingOld(allocator, out, &pending_old, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .deleted,
                        .is_dir = false,
                    });
                },
                FILE_ACTION_MODIFIED => {
                    try self.flushPendingOld(allocator, out, &pending_old, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .modified,
                        .is_dir = false,
                    });
                },
                FILE_ACTION_RENAMED_OLD_NAME => {
                    try self.flushPendingOld(allocator, out, &pending_old, .deleted);
                    pending_old = .{ .path = try allocator.dupe(u8, rel), .is_dir = false };
                },
                FILE_ACTION_RENAMED_NEW_NAME => {
                    if (pending_old) |*p| {
                        try out.append(allocator, .{
                            .relPath = try allocator.dupe(u8, rel),
                            .kind = .renamed,
                            .oldRelPath = p.path,
                            .is_dir = false,
                        });
                        pending_old = null;
                    } else {
                        try out.append(allocator, .{
                            .relPath = try allocator.dupe(u8, rel),
                            .kind = .created,
                            .is_dir = false,
                        });
                    }
                },
                else => {},
            }
            if (next == 0) break;
            off += next;
        }
        try self.flushPendingOld(allocator, out, &pending_old, .deleted);
    }

    fn flushPendingOld(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), pending: *?PendingRename, kind: RawKind) !void {
        _ = self;
        if (pending.*) |*p| {
            try out.append(allocator, .{ .relPath = p.path, .kind = kind, .is_dir = p.is_dir });
            pending.* = null;
        }
    }
};

/// Converts a UTF-8 path to a null-terminated UTF-16 buffer, with a
/// `\\?\` long-path prefix for long absolute paths (classic MAX_PATH).
fn toLongWPath(allocator: Allocator, path: []const u8) ![:0]u16 {
    const abs = path;
    const is_abs = (abs.len >= 3 and abs[1] == ':' and (abs[2] == '\\' or abs[2] == '/')) or
        (abs.len >= 2 and abs[0] == '\\' and abs[1] == '\\');
    const needs_prefix = is_abs and abs.len > 200 and !std.mem.startsWith(u8, abs, "\\\\?\\");
    var out = std.ArrayList(u16).empty;
    errdefer out.deinit(allocator);
    if (needs_prefix) {
        try out.appendSlice(allocator, &[_]u16{ '\\', '\\', '?', '\\' });
    }
    var i: usize = 0;
    while (i < abs.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(abs[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > abs.len) break;
        const cp = std.unicode.utf8Decode(abs[i..][0..cp_len]) catch {
            i += 1;
            continue;
        };
        if (cp < 0x10000) {
            try out.append(allocator, @intCast(cp));
        } else {
            const hi = 0xD800 + @as(u16, @intCast((cp - 0x10000) >> 10));
            const lo = 0xDC00 + @as(u16, @intCast((cp - 0x10000) & 0x3FF));
            try out.appendSlice(allocator, &[_]u16{ hi, lo });
        }
        i += cp_len;
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '/') {
        out.items[out.items.len - 1] = '\\';
    }
    try out.append(allocator, 0);
    const slice = try out.toOwnedSlice(allocator);
    return slice[0 .. slice.len - 1 :0];
}

test "rdc backend watches its root and reports a write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const fs_mod = @import("../../utils/fs.zig");
    const root = ".zig-cache/tmp-rdc-probe";
    {
        const cwd: std.Io.Dir = .cwd();
        cwd.createDir(io, ".zig-cache", .default_dir) catch {};
        cwd.createDir(io, root, .default_dir) catch {};
    }
    defer {
        const cwd: std.Io.Dir = .cwd();
        cwd.deleteDir(io, root) catch {};
    }
    var backend = try Backend.init(a, root);
    defer backend.deinit();
    // Prime the read first: ReadDirectoryChangesW is edge-triggered and
    // only reports changes made after the call starts.
    {
        const primed = try backend.poll(a, 100);
        defer {
            for (primed) |*e| {
                var mut = e.*;
                mut.deinit(a);
            }
            a.free(primed);
        }
    }
    const fpath = try std.fmt.allocPrint(a, "{s}/w.txt", .{root});
    defer a.free(fpath);
    try fs_mod.writeFile(fpath, "hello");
    const evs = try backend.poll(a, 5000);
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
