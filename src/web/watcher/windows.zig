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
    isDir: bool = false,

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
    dirHandle: HANDLE = INVALID_HANDLE_VALUE,
    eventHandle: ?HANDLE = null,
    overlapped: OVERLAPPED = .{},
    /// Read buffer for the single outstanding overlapped read. It must
    /// outlive every poll call, so it lives here rather than on the stack.
    buf: [65536]u8 align(@alignOf(u32)) = undefined,
    readPending: bool = false,
    root: []u8 = &.{},
    dirty: bool = false,
    reading: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, root: []const u8) !Backend {
        var self = Backend{ .allocator = allocator };
        errdefer self.deinit();
        self.root = try allocator.dupe(u8, root);
        const wroot = try toLongWPath(allocator, root);
        defer allocator.free(wroot);
        self.dirHandle = CreateFileW(
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
        if (self.dirHandle == INVALID_HANDLE_VALUE) return error.WatchInitFailed;
        const ev = CreateEventW(null, @fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(0)), null);
        const evInt: usize = @intFromPtr(ev);
        if (evInt == 0) return error.WatchInitFailed;
        self.eventHandle = ev;
        self.overlapped.hEvent = ev;
        return self;
    }

    pub fn deinit(self: *Backend) void {
        self.cancel();
        if (self.eventHandle) |ev| {
            _ = CloseHandle(ev);
            self.eventHandle = null;
        }
        if (self.dirHandle != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.dirHandle);
            self.dirHandle = INVALID_HANDLE_VALUE;
        }
        if (self.root.len > 0) self.allocator.free(self.root);
    }

    /// Cancels any in-flight read so a blocked poll() wakes promptly.
    pub fn cancel(self: *Backend) void {
        if (self.dirHandle == INVALID_HANDLE_VALUE) return;
        if (!self.readPending) return;
        _ = CancelIoEx(self.dirHandle, null);
        if (self.eventHandle) |ev| {
            _ = WaitForSingleObject(ev, 5000);
        }
        self.readPending = false;
    }

    /// Blocks up to timeoutMs for native events; returns owned events.
    /// One overlapped read stays outstanding across calls (no cancel/reissue
    /// cycle, hence no baseline gaps); only shutdown cancels it. Sets
    /// `dirty` when the kernel dropped events (rescan required).
    pub fn poll(self: *Backend, allocator: Allocator, timeoutMs: i32) ![]RawEvent {
        var out = std.ArrayList(RawEvent).empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.dirHandle == INVALID_HANDLE_VALUE) return out.toOwnedSlice(allocator);
        const ev = self.eventHandle orelse return out.toOwnedSlice(allocator);
        if (!self.readPending) {
            _ = ResetEvent(ev);
            self.overlapped.Internal = 0;
            self.overlapped.InternalHigh = 0;
            self.overlapped.Offset = 0;
            self.overlapped.OffsetHigh = 0;
            self.overlapped.hEvent = ev;
            const started = ReadDirectoryChangesW(
                self.dirHandle,
                &self.buf,
                self.buf.len,
                @fromBackingInt(@intCast(1)),
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                    FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                    FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION,
                null,
                &self.overlapped,
                null,
            );
            if (@backingInt(started) == 0) {
                if (windows.GetLastError() != .IO_PENDING) {
                    self.dirty = true;
                    return out.toOwnedSlice(allocator);
                }
            }
            self.readPending = true;
        }
        self.reading.store(true, .release);
        defer self.reading.store(false, .release);
        const waitMs: DWORD = if (timeoutMs < 0) INFINITE else @intCast(timeoutMs);
        const wr = WaitForSingleObject(ev, waitMs);
        if (wr == WAIT_TIMEOUT) return out.toOwnedSlice(allocator);
        if (wr != WAIT_OBJECT_0) {
            self.dirty = true;
            self.readPending = false;
            return out.toOwnedSlice(allocator);
        }
        var bytes: DWORD = 0;
        if (@backingInt(GetOverlappedResult(self.dirHandle, &self.overlapped, &bytes, @fromBackingInt(@intCast(0)))) == 0) {
            if (windows.GetLastError() == .NOTIFY_ENUM_DIR) self.dirty = true;
            self.readPending = false;
            return out.toOwnedSlice(allocator);
        }
        self.readPending = false;
        if (bytes == 0) {
            self.dirty = true;
            return out.toOwnedSlice(allocator);
        }
        try self.translate(allocator, &out, self.buf[0..bytes], bytes);
        return out.toOwnedSlice(allocator);
    }

    const PendingRename = struct {
        path: []u8,
        isDir: bool,
    };

    fn translate(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), buf: []const u8, valid: u32) !void {
        var off: usize = 0;
        var pendingOld: ?PendingRename = null;
        defer if (pendingOld) |*p| allocator.free(p.path);
        while (off + 12 <= valid) {
            const next: u32 = std.mem.readInt(u32, buf[off..][0..4], .little);
            const action: u32 = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
            const nameLen: u32 = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            const nameOff = off + 12;
            if (nameOff + nameLen > valid) break;
            const wlen = nameLen / 2;
            const wname: []const u16 = @ptrCast(@alignCast(buf[nameOff..][0 .. wlen * 2]));
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
                    try self.flushPendingOld(allocator, out, &pendingOld, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .created,
                        .isDir = false,
                    });
                },
                FILE_ACTION_REMOVED => {
                    try self.flushPendingOld(allocator, out, &pendingOld, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .deleted,
                        .isDir = false,
                    });
                },
                FILE_ACTION_MODIFIED => {
                    try self.flushPendingOld(allocator, out, &pendingOld, .deleted);
                    try out.append(allocator, .{
                        .relPath = try allocator.dupe(u8, rel),
                        .kind = .modified,
                        .isDir = false,
                    });
                },
                FILE_ACTION_RENAMED_OLD_NAME => {
                    try self.flushPendingOld(allocator, out, &pendingOld, .deleted);
                    pendingOld = .{ .path = try allocator.dupe(u8, rel), .isDir = false };
                },
                FILE_ACTION_RENAMED_NEW_NAME => {
                    if (pendingOld) |*p| {
                        try out.append(allocator, .{
                            .relPath = try allocator.dupe(u8, rel),
                            .kind = .renamed,
                            .oldRelPath = p.path,
                            .isDir = false,
                        });
                        pendingOld = null;
                    } else {
                        try out.append(allocator, .{
                            .relPath = try allocator.dupe(u8, rel),
                            .kind = .created,
                            .isDir = false,
                        });
                    }
                },
                else => {},
            }
            if (next == 0) break;
            off += next;
        }
        try self.flushPendingOld(allocator, out, &pendingOld, .deleted);
    }

    fn flushPendingOld(self: *Backend, allocator: Allocator, out: *std.ArrayList(RawEvent), pending: *?PendingRename, kind: RawKind) !void {
        _ = self;
        if (pending.*) |*p| {
            try out.append(allocator, .{ .relPath = p.path, .kind = kind, .isDir = p.isDir });
            pending.* = null;
        }
    }
};

/// Converts a UTF-8 path to a null-terminated UTF-16 buffer, with a
/// `\\?\` long-path prefix for long absolute paths (classic MAX_PATH).
fn toLongWPath(allocator: Allocator, path: []const u8) ![:0]u16 {
    const abs = path;
    const isAbs = (abs.len >= 3 and abs[1] == ':' and (abs[2] == '\\' or abs[2] == '/')) or
        (abs.len >= 2 and abs[0] == '\\' and abs[1] == '\\');
    const needsPrefix = isAbs and abs.len > 200 and !std.mem.startsWith(u8, abs, "\\\\?\\");
    var out = std.ArrayList(u16).empty;
    errdefer out.deinit(allocator);
    if (needsPrefix) {
        try out.appendSlice(allocator, &[_]u16{ '\\', '\\', '?', '\\' });
    }
    var i: usize = 0;
    while (i < abs.len) {
        const cpLen = std.unicode.utf8ByteSequenceLength(abs[i]) catch {
            i += 1;
            continue;
        };
        if (i + cpLen > abs.len) break;
        const cp = std.unicode.utf8Decode(abs[i..][0..cpLen]) catch {
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
        i += cpLen;
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
    const fsMod = @import("../../utils/fs.zig");
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
    try fsMod.writeFile(fpath, "hello");
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
