//! Canonical Filesystem Utilities for HTTPX
//!
//! Provides safe, high-performance, cross-platform file reading, writing,
//! deletion, and path validation using native platform syscalls.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const isWin = builtin.os.tag == .windows;

pub const Stat = struct {
    size: u64,
    mtimeNs: i128,
    isDir: bool,
};

const cFs = struct {
    pub const HANDLE = if (isWin) std.os.windows.HANDLE else c_int;
    pub const INVALID_HANDLE_VALUE: HANDLE = if (isWin) @ptrFromInt(std.math.maxInt(usize)) else -1;
    pub const BOOL = enum(c_int) { FALSE = 0, TRUE = 1 };

    pub const GENERIC_READ: u32 = 0x80000000;
    pub const GENERIC_WRITE: u32 = 0x40000000;
    pub const FILE_SHARE_READ: u32 = 0x00000001;
    pub const FILE_SHARE_WRITE: u32 = 0x00000002;
    pub const OPEN_EXISTING: u32 = 3;
    pub const CREATE_ALWAYS: u32 = 2;
    pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    pub extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    pub extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileTime(
        hFile: HANDLE,
        lpCreationTime: ?*anyopaque,
        lpLastAccessTime: ?*anyopaque,
        lpLastWriteTime: ?*std.os.windows.FILETIME,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;

    pub fn openRead(path: []const u8) ?HANDLE {
        var buf: [1024:0]u8 = undefined;
        if (path.len >= buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;

        if (isWin) {
            const h = CreateFileA(&buf, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            if (h == INVALID_HANDLE_VALUE) return null;
            return h;
        } else {
            const fd = std.c.open(&buf, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn openWrite(path: []const u8) ?HANDLE {
        var buf: [1024:0]u8 = undefined;
        if (path.len >= buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;

        if (isWin) {
            const h = CreateFileA(&buf, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
            if (h == INVALID_HANDLE_VALUE) return null;
            return h;
        } else {
            const flags: std.c.O = .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .TRUNC = true,
            };
            const fd = std.c.open(&buf, flags, @as(std.c.mode_t, 0o666));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn close(h: HANDLE) void {
        if (isWin) {
            _ = CloseHandle(h);
        } else {
            _ = std.c.close(h);
        }
    }
};

/// Writes `content` bytes to the file at `path`, replacing existing contents.
pub fn writeFile(path: []const u8, content: []const u8) !void {
    if (isWin) {
        const h = cFs.openWrite(path) orelse return error.WriteFailed;
        defer cFs.close(h);

        var total_written: usize = 0;
        while (total_written < content.len) {
            var bytesWritten: u32 = 0;
            const to_write: u32 = @intCast(@min(content.len - total_written, std.math.maxInt(u32)));
            if (cFs.WriteFile(h, content[total_written..].ptr, to_write, &bytesWritten, null) == .FALSE) return error.WriteFailed;
            if (bytesWritten == 0) return error.WriteFailed;
            total_written += bytesWritten;
        }
    } else {
        const fd = cFs.openWrite(path) orelse return error.WriteFailed;
        defer cFs.close(fd);

        var total_written: usize = 0;
        while (total_written < content.len) {
            const rc = std.c.write(fd, content[total_written..].ptr, content.len - total_written);
            if (rc <= 0) return error.WriteFailed;
            total_written += @intCast(rc);
        }
    }
}

/// Reads the entire file at `path` into a newly allocated buffer.
/// Rejects directories and files larger than `maxBytes`.
pub fn readFileLimited(allocator: Allocator, path: []const u8, maxBytes: usize) ![]u8 {
    const stat = statPath(null, path) orelse return error.FileNotFound;
    if (stat.isDir) return error.IsDir;
    if (stat.size > maxBytes) return error.FileTooBig;

    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);

    if (isWin) {
        const h = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(h);

        var totalRead: usize = 0;
        while (totalRead < buf.len) {
            var bytes_read: u32 = 0;
            const to_read: u32 = @intCast(@min(buf.len - totalRead, std.math.maxInt(u32)));
            if (cFs.ReadFile(h, buf[totalRead..].ptr, to_read, &bytes_read, null) == .FALSE) return error.ReadFailed;
            if (bytes_read == 0) break;
            totalRead += bytes_read;
        }
        if (totalRead < buf.len) return error.UnexpectedEof;
    } else {
        const fd = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(fd);

        var totalRead: usize = 0;
        while (totalRead < buf.len) {
            const rc = std.c.read(fd, buf[totalRead..].ptr, buf.len - totalRead);
            if (rc < 0) return error.ReadFailed;
            if (rc == 0) break;
            totalRead += @intCast(rc);
        }
        if (totalRead < buf.len) return error.UnexpectedEof;
    }

    return buf;
}

/// Reads the entire file at `path` into a newly allocated buffer.
/// Uses the default 256MB safety cap; see readFileLimited for custom caps.
pub fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    return readFileLimited(allocator, path, 256 * 1024 * 1024);
}

/// Returns stat metadata for the file or directory at `path`.
pub fn statPath(io: ?std.Io, path: []const u8) ?Stat {
    _ = io;
    var buf: [1024:0]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    if (isWin) {
        const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
        const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;
        const attrs = cFs.GetFileAttributesA(&buf);
        if (attrs == INVALID_FILE_ATTRIBUTES) return null;
        const isDirectory = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;

        if (isDirectory) {
            return Stat{
                .size = 0,
                .mtimeNs = 0,
                .isDir = true,
            };
        }

        const h = cFs.openRead(path) orelse return null;
        defer cFs.close(h);

        var size: i64 = 0;
        if (cFs.GetFileSizeEx(h, &size) == .FALSE) return null;

        var ft: std.os.windows.FILETIME = undefined;
        if (cFs.GetFileTime(h, null, null, &ft) == .FALSE) return null;

        const ft_u64: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        const windows_epoch_diff: i128 = 116444736000000000;
        const mtimeNs = (@as(i128, ft_u64) - windows_epoch_diff) * 100;

        return Stat{
            .size = @intCast(@max(0, size)),
            .mtimeNs = mtimeNs,
            .isDir = false,
        };
    } else if (builtin.os.tag == .linux) {
        var null_term: [1024:0]u8 = undefined;
        if (path.len >= null_term.len) return null;
        @memcpy(null_term[0..path.len], path);
        null_term[path.len] = 0;

        var statx_buf: std.os.linux.Statx = undefined;
        const mask: std.os.linux.STATX = .{
            .TYPE = true,
            .SIZE = true,
            .MTIME = true,
        };
        const rc = std.os.linux.statx(
            std.posix.AT.FDCWD,
            &null_term,
            0,
            mask,
            &statx_buf,
        );
        if (@as(isize, @bitCast(rc)) < 0) return null;
        const isDirectory = (statx_buf.mode & std.os.linux.S.IFMT) == std.os.linux.S.IFDIR;

        const mtimeNs = @as(i128, statx_buf.mtime.sec) * std.time.ns_per_s + @as(i128, statx_buf.mtime.nsec);
        return Stat{
            .size = statx_buf.size,
            .mtimeNs = mtimeNs,
            .isDir = isDirectory,
        };
    } else {
        var null_term: [1024:0]u8 = undefined;
        if (path.len >= null_term.len) return null;
        @memcpy(null_term[0..path.len], path);
        null_term[path.len] = 0;

        const stat_fn = switch (builtin.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => switch (builtin.cpu.arch) {
                .x86_64 => struct {
                    extern "c" fn @"stat$INODE64"(noalias p: [*:0]const u8, noalias b: *std.c.Stat) c_int;
                }.@"stat$INODE64",
                else => struct {
                    extern "c" fn stat(noalias p: [*:0]const u8, noalias b: *std.c.Stat) c_int;
                }.stat,
            },
            else => struct {
                extern "c" fn stat(noalias p: [*:0]const u8, noalias b: *std.c.Stat) c_int;
            }.stat,
        };

        var st: std.c.Stat = undefined;
        if (stat_fn(&null_term, &st) != 0) return null;
        const isDirectory = std.c.S.ISDIR(st.mode);

        return Stat{
            .size = @intCast(@max(0, st.size)),
            .mtimeNs = @as(i128, st.mtime().sec) * std.time.ns_per_s + @as(i128, st.mtime().nsec),
            .isDir = isDirectory,
        };
    }
}

/// Returns true if a file or directory exists at `path`.
pub fn fileExists(path: []const u8) bool {
    return statPath(null, path) != null;
}

/// Deletes the file at `path`.
pub fn deleteFile(path: []const u8) !void {
    var buf: [1024:0]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    if (isWin) {
        if (cFs.DeleteFileA(&buf) == .FALSE) return error.DeleteFailed;
    } else {
        if (std.c.unlink(&buf) != 0) return error.DeleteFailed;
    }
}

test "fs write, read, stat, delete" {
    const a = std.testing.allocator;
    const test_path = "test_canonical_fs.tmp";
    defer deleteFile(test_path) catch {};

    try writeFile(test_path, "Hello Canonical FS!");
    try std.testing.expect(fileExists(test_path));

    const st = statPath(null, test_path);
    try std.testing.expect(st != null);
    try std.testing.expectEqual(@as(u64, 19), st.?.size);
    try std.testing.expect(!st.?.isDir);

    const content = try readFileAlloc(a, test_path);
    defer a.free(content);
    try std.testing.expectEqualStrings("Hello Canonical FS!", content);

    try deleteFile(test_path);
    try std.testing.expect(!fileExists(test_path));
}
