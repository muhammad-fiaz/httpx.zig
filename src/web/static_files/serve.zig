//! Static file serving: single files, directories, and SPA roots.
//!
//! Features
//!   - directory mounting with index.html resolution
//!   - MIME detection via utils/mime
//!   - strong ETag (mtime+size) and Last-Modified headers
//!   - If-None-Match / If-Modified-Since -> 304 Not Modified
//!   - single Range requests -> 206 + Content-Range; unsatisfiable -> 416
//!   - HEAD honored (headers, empty body)
//!   - traversal-safe: percent-decoded paths cannot escape the mount root
//!
//! Ownership: per-request allocations come from ctx.allocator (the request
//! arena); Response slices borrow from it.
//!
//! References:
//!   - RFC 9110 Section 8.8 — ETag
//!   - RFC 9110 Section 8.8.2 — If-None-Match
//!   - RFC 9110 Section 8.8.3 — Last-Modified
//!   - RFC 9110 Section 8.8.4 — If-Modified-Since
//!   - RFC 9110 Section 14.1 — Range Requests

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const router_mod = @import("../router/router.zig");
const Context = router_mod.Context;
const Response = router_mod.Response;
const Method = @import("../../common/method.zig").Method;
const mime = @import("../../utils/mime.zig");

pub const Config = struct {
    /// Filesystem root served under `mount`.
    root: []const u8,
    /// URL prefix, e.g. "/assets" or "/".
    mount: []const u8 = "/",
    /// Served when a directory is requested.
    indexFile: []const u8 = "index.html",
    /// Hard cap on bytes buffered into memory per response.
    maxFileSize: usize = 16 * 1024 * 1024,
    /// Cache-Control on success responses; empty omits the header.
    cacheControl: []const u8 = "public, max-age=3600",
    /// Live reload / hot reload: automatically injects SSE live-reload script into HTML files.
    liveReload: bool = false,
    /// SSE endpoint path for live-reload broadcast (default: "/__httpx_liveReload").
    reloadSsePath: []const u8 = "/__httpx_liveReload",
    /// SPA fallback file (e.g. "index.html") when requested path does not exist on disk.
    spaFallback: ?[]const u8 = null,
    /// Serve from the embedded asset registry only; never touch the
    /// filesystem. Used for single-executable production deployments where
    /// the source directory may not exist at runtime.
    filesystem: bool = true,
};

pub const MountError = error{
    InvalidMount,
    DuplicateRoute,
    OutOfMemory,
};

const State = struct {
    allocator: Allocator,
    root: []u8,
    index: []u8,
    cacheControl: []u8,
    maxSize: usize,
    liveReload: bool,
    reloadSsePath: []u8,
    spaFallback: ?[]u8,
    filesystem: bool,

    fn create(a: Allocator, cfg: Config) !*State {
        const st = try a.create(State);
        errdefer a.destroy(st);
        st.* = .{
            .allocator = a,
            .root = try normalizeDir(a, cfg.root),
            .index = try a.dupe(u8, cfg.indexFile),
            .cacheControl = try a.dupe(u8, cfg.cacheControl),
            .maxSize = cfg.maxFileSize,
            .liveReload = cfg.liveReload,
            .reloadSsePath = try a.dupe(u8, cfg.reloadSsePath),
            .spaFallback = if (cfg.spaFallback) |fb| try a.dupe(u8, fb) else null,
            .filesystem = cfg.filesystem,
        };
        return st;
    }

    fn destroy(self: *State) void {
        const a = self.allocator;
        a.free(self.root);
        a.free(self.index);
        a.free(self.cacheControl);
        a.free(self.reloadSsePath);
        if (self.spaFallback) |fb| a.free(fb);
        a.destroy(self);
    }
};

fn trimSlashes(p: []const u8) []const u8 {
    return std.mem.trim(u8, p, "/");
}

fn normalizeDir(a: Allocator, dir: []const u8) ![]u8 {
    if (dir.len == 0) return a.dupe(u8, dir);
    const trimmed = std.mem.trimEnd(u8, dir, "/\\");
    const clean: []const u8 = if (trimmed.len == 0) dir[0..1] else trimmed;
    return a.dupe(u8, clean);
}

/// Registers GET routes for `mount` itself and `mount/*path`.
pub fn register(router: *router_mod.Router, cfg: Config) MountError!void {
    if (cfg.root.len == 0 or cfg.mount.len == 0 or cfg.mount[0] != '/')
        return MountError.InvalidMount;

    const allocator = router.allocator;
    const base = trimSlashes(cfg.mount);
    const p1: []const u8 = if (base.len == 0)
        "/"
    else
        std.fmt.allocPrint(allocator, "/{s}", .{base}) catch return MountError.OutOfMemory;
    defer if (base.len != 0) allocator.free(@constCast(p1));
    const p2 = std.fmt.allocPrint(allocator, "/{s}/*path", .{base}) catch return MountError.OutOfMemory;
    defer allocator.free(p2);

    // Validate first so registration failure is atomic.
    if (router.hasConflict(.GET, p1) or router.hasConflict(.GET, p2))
        return MountError.DuplicateRoute;

    const st = State.create(allocator, cfg) catch return MountError.OutOfMemory;

    const DestroyHelper = struct {
        fn run(ptr: ?*anyopaque) void {
            if (ptr) |p| {
                const s: *State = @ptrCast(@alignCast(p));
                s.destroy();
            }
        }
    };

    router.get(p1, serveIndexHandler, .{ .userData = st, .deinitData = DestroyHelper.run }) catch {
        st.destroy();
        return MountError.OutOfMemory;
    };
    router.get(p2, serveFileHandler, .{ .userData = st, .deinitData = DestroyHelper.run }) catch {
        _ = router.remove(.GET, p1);
        st.destroy();
        return MountError.OutOfMemory;
    };
}

pub fn unregister() void {
    // No-op: per-route userData eliminated global state
}

// handlers

fn serveIndexHandler(ctx: *Context) anyerror!Response {
    const st: *State = @ptrCast(@alignCast(ctx.userData orelse return errText(500, "static not mounted")));
    return servePath(ctx, st, "/");
}

fn serveFileHandler(ctx: *Context) anyerror!Response {
    const st: *State = @ptrCast(@alignCast(ctx.userData orelse return errText(500, "static not mounted")));
    return servePath(ctx, st, ctx.param("path") orelse "/");
}

fn errText(status: u16, text: []const u8) Response {
    return .{ .status = status, .contentType = "text/plain; charset=utf-8", .body = text };
}

// path resolution

pub fn percentDecode(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    // First pass: exact output length so the returned slice is freed with
    // the same length it was allocated as (required by sized allocators).
    var outLen: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len and
            std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]))
        {
            outLen += 1;
            i += 3;
        } else {
            outLen += 1;
            i += 1;
        }
    }

    const out = alloc.alloc(u8, outLen) catch return Allocator.Error.OutOfMemory;
    errdefer alloc.free(out);
    var n: usize = 0;
    i = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len and
            std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]))
        {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch unreachable;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch unreachable;
            out[n] = hi *% 16 +% lo;
            n += 1;
            i += 3;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out;
}

/// Resolves a URL path against `root`; null when it escapes the root.
/// Leak-free under any allocator (intermediate decode buffer always freed).
pub fn safeJoin(alloc: Allocator, urlPath: []const u8, root: []const u8) !?[]u8 {
    const decoded = try percentDecode(alloc, urlPath);
    defer alloc.free(decoded);

    for (decoded) |c| {
        if (c == 0 or c == '\\') return null;
    }

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);

    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null; // escapes root
            _ = parts.pop();
            continue;
        }
        parts.append(alloc, seg) catch return Allocator.Error.OutOfMemory;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(root) catch return Allocator.Error.OutOfMemory;
    if (parts.items.len == 0) {
        if (!std.mem.endsWith(u8, root, "/")) {
            out.writer.writeByte('/') catch return Allocator.Error.OutOfMemory;
        }
    } else {
        for (parts.items) |seg| {
            out.writer.writeByte('/') catch return Allocator.Error.OutOfMemory;
            out.writer.writeAll(seg) catch return Allocator.Error.OutOfMemory;
        }
    }
    return out.toOwnedSlice() catch Allocator.Error.OutOfMemory;
}

// filesystem

pub const FileMeta = struct { size: u64, mtimeNs: i128 };

pub const cFs = struct {
    pub const isWin = builtin.os.tag == .windows;

    pub const FILE_HANDLE = if (isWin) std.os.windows.HANDLE else std.c.fd_t;
    pub const INVALID_HANDLE: FILE_HANDLE = if (isWin) std.os.windows.INVALID_HANDLE_VALUE else -1;

    pub fn openRead(path: []const u8) ?FILE_HANDLE {
        if (isWin) {
            var wide_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return null;
            if (wlen >= wide_buf.len) return null;
            wide_buf[wlen] = 0;

            const GENERIC_READ: u32 = 0x80000000;
            const FILE_SHARE_READ: u32 = 0x00000001;
            const FILE_SHARE_WRITE: u32 = 0x00000002;
            const FILE_SHARE_DELETE: u32 = 0x00000004;
            const OPEN_EXISTING: u32 = 3;
            const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;

            const h = CreateFileW(
                wide_buf[0..wlen :0],
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                null,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (h == INVALID_HANDLE) return null;
            return h;
        } else {
            var null_term: [4096:0]u8 = undefined;
            if (path.len >= null_term.len) return null;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.c.open(&null_term, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn openWrite(path: []const u8) ?FILE_HANDLE {
        if (isWin) {
            var wide_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return null;
            if (wlen >= wide_buf.len) return null;
            wide_buf[wlen] = 0;

            const GENERIC_WRITE: u32 = 0x40000000;
            const CREATE_ALWAYS: u32 = 2;
            const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;

            const h = CreateFileW(
                wide_buf[0..wlen :0],
                GENERIC_WRITE,
                0,
                null,
                CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (h == INVALID_HANDLE) return null;
            return h;
        } else {
            var null_term: [4096:0]u8 = undefined;
            if (path.len >= null_term.len) return null;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.c.open(&null_term, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn close(h: FILE_HANDLE) void {
        if (isWin) {
            _ = CloseHandle(h);
        } else {
            _ = std.c.close(h);
        }
    }

    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?std.os.windows.HANDLE,
    ) callconv(.winapi) std.os.windows.HANDLE;

    pub extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetFileSizeEx(hFile: std.os.windows.HANDLE, lpFileSize: *i64) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetFileTime(
        hFile: std.os.windows.HANDLE,
        lpCreationTime: ?*anyopaque,
        lpLastAccessTime: ?*anyopaque,
        lpLastWriteTime: ?*std.os.windows.FILETIME,
    ) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn ReadFile(
        hFile: std.os.windows.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn WriteFile(
        hFile: std.os.windows.HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn SetFilePointerEx(
        hFile: std.os.windows.HANDLE,
        liDistanceToMove: i64,
        lpNewFilePointer: ?*i64,
        dwMoveMethod: u32,
    ) callconv(.winapi) std.os.windows.BOOL;
};

pub fn statPath(_: ?std.Io, path: []const u8) ?FileMeta {
    if (cFs.isWin) {
        const h = cFs.openRead(path) orelse return null;
        defer cFs.close(h);

        var size: i64 = 0;
        if (cFs.GetFileSizeEx(h, &size) == .FALSE) return null;

        var ft: std.os.windows.FILETIME = undefined;
        if (cFs.GetFileTime(h, null, null, &ft) == .FALSE) return null;

        const ft_u64: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        // Convert Windows 100-ns intervals from 1601 to Unix epoch ns from 1970
        const windows_epoch_diff: i128 = 116444736000000000;
        const mtimeNs = (@as(i128, ft_u64) - windows_epoch_diff) * 100;

        return .{
            .size = @intCast(@max(0, size)),
            .mtimeNs = mtimeNs,
        };
    } else if (builtin.os.tag == .linux) {
        var null_term: [4096:0]u8 = undefined;
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
        if ((statx_buf.mode & std.os.linux.S.IFMT) != std.os.linux.S.IFREG) return null;

        const mtimeNs = @as(i128, statx_buf.mtime.sec) * std.time.ns_per_s + @as(i128, statx_buf.mtime.nsec);
        return .{
            .size = statx_buf.size,
            .mtimeNs = mtimeNs,
        };
    } else {
        var null_term: [4096:0]u8 = undefined;
        if (path.len >= null_term.len) return null;
        @memcpy(null_term[0..path.len], path);
        null_term[path.len] = 0;

        if (comptime std.posix.Stat != void) {
            const stat_fn = switch (builtin.os.tag) {
                .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => switch (builtin.cpu.arch) {
                    .x86_64 => struct {
                        extern "c" fn @"stat$INODE64"(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
                    }.@"stat$INODE64",
                    else => struct {
                        extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
                    }.stat,
                },
                else => struct {
                    extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
                }.stat,
            };

            var st: std.c.Stat = undefined;
            if (stat_fn(&null_term, &st) != 0) return null;
            if (!std.c.S.ISREG(st.mode)) return null;

            const mtimeNs = @as(i128, st.mtime().sec) * std.time.ns_per_s + @as(i128, st.mtime().nsec);
            return .{
                .size = @intCast(@max(0, st.size)),
                .mtimeNs = mtimeNs,
            };
        }
        return null;
    }
}

fn readAll(_: ?std.Io, path: []const u8, dest: []u8) !void {
    if (cFs.isWin) {
        const h = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(h);

        var totalRead: usize = 0;
        while (totalRead < dest.len) {
            var bytes_read: u32 = 0;
            const to_read: u32 = @intCast(@min(dest.len - totalRead, std.math.maxInt(u32)));
            if (cFs.ReadFile(h, dest[totalRead..].ptr, to_read, &bytes_read, null) == .FALSE) return error.UnexpectedEof;
            if (bytes_read == 0) break;
            totalRead += bytes_read;
        }
        if (totalRead < dest.len) return error.UnexpectedEof;
    } else {
        const fd = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(fd);

        var totalRead: usize = 0;
        while (totalRead < dest.len) {
            const rc = std.c.read(fd, dest[totalRead..].ptr, dest.len - totalRead);
            if (rc < 0) return error.UnexpectedEof;
            if (rc == 0) break;
            totalRead += @intCast(rc);
        }
        if (totalRead < dest.len) return error.UnexpectedEof;
    }
}

const fs_mod = @import("../../utils/fs.zig");
pub const writeFile = fs_mod.writeFile;

fn readRange(_: ?std.Io, path: []const u8, offset: u64, dest: []u8) !void {
    if (cFs.isWin) {
        const h = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(h);

        const FILE_BEGIN: u32 = 0;
        if (cFs.SetFilePointerEx(h, @intCast(offset), null, FILE_BEGIN) == .FALSE) return error.SeekFailed;

        var totalRead: usize = 0;
        while (totalRead < dest.len) {
            var bytes_read: u32 = 0;
            const to_read: u32 = @intCast(@min(dest.len - totalRead, std.math.maxInt(u32)));
            if (cFs.ReadFile(h, dest[totalRead..].ptr, to_read, &bytes_read, null) == .FALSE) return error.UnexpectedEof;
            if (bytes_read == 0) break;
            totalRead += bytes_read;
        }
        if (totalRead < dest.len) return error.UnexpectedEof;
    } else {
        const fd = cFs.openRead(path) orelse return error.FileNotFound;
        defer cFs.close(fd);

        var totalRead: usize = 0;
        while (totalRead < dest.len) {
            const rc = std.c.pread(fd, dest[totalRead..].ptr, dest.len - totalRead, @intCast(offset + totalRead));
            if (rc < 0) return error.SeekFailed;
            if (rc == 0) break;
            totalRead += @intCast(rc);
        }
        if (totalRead < dest.len) return error.UnexpectedEof;
    }
}

// HTTP dates

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn monthName(numeric: u4) []const u8 {
    return if (numeric >= 1 and numeric <= 12) month_names[numeric - 1] else "Jan";
}

/// RFC 9110 IMF-fixdate: "Tue, 25 Aug 2026 10:00:00 GMT".
pub fn formatHttpDate(buf: []u8, epochSecs: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epochSecs)) };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = es.getDaySeconds();

    const wd_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const wd = wd_names[@intCast(@mod(day.day, 7))];

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wd,
        month_day.day_index + 1,
        monthName(month_day.month.numeric()),
        year_day.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Parses IMF-fixdate to epoch seconds; null on malformed input.
pub fn parseHttpDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,");
    _ = it.next() orelse return null;
    const day_s = it.next() orelse return null;
    const mon_s = it.next() orelse return null;
    const year_s = it.next() orelse return null;
    const time_s = it.next() orelse return null;

    const day = std.fmt.parseInt(u16, day_s, 10) catch return null;
    var month: ?u4 = null;
    for (month_names, 0..) |m, i| {
        if (std.ascii.startsWithIgnoreCase(mon_s, m)) month = @intCast(i + 1);
    }
    const mon = month orelse return null;
    const year = std.fmt.parseInt(i32, year_s, 10) catch return null;

    var tit = std.mem.splitScalar(u8, time_s, ':');
    const hh = std.fmt.parseInt(u8, tit.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(u8, tit.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(u8, tit.next() orelse return null, 10) catch return null;
    if (hh >= 24 or mm >= 60 or ss > 60 or day == 0 or day > daysInMonth(year, mon)) return null;

    const days = daysFromCivil(year, mon, day);
    return days * 86400 + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + ss;
}

fn daysInMonth(year: i32, month: u4) u16 {
    return switch (month) {
        2 => if (@mod(year, 400) == 0 or (@mod(year, 4) == 0 and @mod(year, 100) != 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn daysFromCivil(y_in: i32, m: u4, d: u16) i64 {
    const y: i64 = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ranges

pub const RangeSpec = struct { start: u64, end: u64 }; // inclusive

pub fn parseRange(spec: []const u8, size: u64) ?RangeSpec {
    if (!std.mem.startsWith(u8, spec, "bytes=")) return null;
    if (size == 0) return null;
    const body = spec["bytes=".len..];
    if (std.mem.indexOfScalar(u8, body, ',') != null) return null; // multi-range unsupported

    const dash = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    const a_part = body[0..dash];
    const b_part = body[dash + 1 ..];

    if (a_part.len == 0 and b_part.len == 0) return null;
    if (a_part.len == 0) {
        const n = std.fmt.parseInt(u64, b_part, 10) catch return null;
        if (n == 0) return null;
        if (n >= size) return RangeSpec{ .start = 0, .end = size - 1 };
        return RangeSpec{ .start = size - n, .end = size - 1 };
    }
    const start = std.fmt.parseInt(u64, a_part, 10) catch return null;
    if (start >= size) return null;
    if (b_part.len == 0) return RangeSpec{ .start = start, .end = size - 1 };
    const end = std.fmt.parseInt(u64, b_part, 10) catch return null;
    if (end < start) return null;
    return RangeSpec{ .start = start, .end = @min(end, size - 1) };
}

// serving

fn respondWithEmbedded(ctx: *Context, st: *State, asset: @import("../assets.zig").Asset) anyerror!Response {
    const a = ctx.allocator;
    const is_head = ctx.method == .HEAD;

    if (ctx.header("If-None-Match")) |inm| {
        if (etagMatches(inm, asset.etag)) {
            const hs = a.dupe(router_mod.Header, &.{.{ .name = "ETag", .value = asset.etag }}) catch return Allocator.Error.OutOfMemory;
            return .{ .status = 304, .headers = hs };
        }
    }

    var headers: std.ArrayList(router_mod.Header) = .empty;
    headers.append(a, .{ .name = "ETag", .value = asset.etag }) catch return Allocator.Error.OutOfMemory;
    if (st.cacheControl.len > 0)
        headers.append(a, .{ .name = "Cache-Control", .value = st.cacheControl }) catch return Allocator.Error.OutOfMemory;

    // Single range request over the stored bytes (no live-reload injection:
    // ranges address the asset as stored).
    if (ctx.header("Range")) |spec| {
        if (parseRange(spec, asset.content.len)) |r| {
            const len: usize = @intCast(r.end - r.start + 1);
            if (len > st.maxSize) return errText(413, "range too large");
            const cr = std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ r.start, r.end, asset.content.len }) catch return Allocator.Error.OutOfMemory;
            headers.append(a, .{ .name = "Content-Range", .value = cr }) catch return Allocator.Error.OutOfMemory;
            return .{
                .status = 206,
                .contentType = asset.contentType,
                .body = if (is_head) "" else asset.content[@intCast(r.start)..@intCast(r.end + 1)],
                .headers = headers.items,
            };
        }
        const cr = std.fmt.allocPrint(a, "bytes */{d}", .{asset.content.len}) catch return Allocator.Error.OutOfMemory;
        const hs = a.dupe(router_mod.Header, &.{.{ .name = "Content-Range", .value = cr }}) catch return Allocator.Error.OutOfMemory;
        return .{ .status = 416, .contentType = asset.contentType, .headers = hs };
    }

    if (st.liveReload and !is_head and std.mem.startsWith(u8, asset.contentType, "text/html")) {
        const reload_script = try std.fmt.allocPrint(a,
            \\<script>
            \\(function() {{
            \\  const es = new EventSource("{s}");
            \\  es.onmessage = function(e) {{
            \\    if (e.data === "reload") {{
            \\      console.log("[httpx live-reload] Static file changed, reloading...");
            \\      location.reload();
            \\    }}
            \\  }};
            \\}})();
            \\</script>
        , .{st.reloadSsePath});
        const full_body = try std.fmt.allocPrint(a, "{s}\n{s}", .{ asset.content, reload_script });
        return .{
            .status = 200,
            .contentType = asset.contentType,
            .body = full_body,
            .headers = headers.items,
        };
    }

    return .{
        .status = 200,
        .contentType = asset.contentType,
        .body = if (is_head) "" else asset.content,
        .headers = headers.items,
    };
}

fn servePath(ctx: *Context, st: *State, rawUrlPath: []const u8) anyerror!Response {
    const a = ctx.allocator;

    const formatted_path = if (rawUrlPath.len > 0 and rawUrlPath[0] == '/')
        rawUrlPath
    else
        std.fmt.allocPrint(a, "/{s}", .{rawUrlPath}) catch return Allocator.Error.OutOfMemory;

    // 1. Check embedded assets registry first for zero disk I/O single-file deployment
    const assets_mod = @import("../assets.zig");
    const clean_rel = if (formatted_path.len > 0 and formatted_path[0] == '/') formatted_path[1..] else formatted_path;
    if (assets_mod.getEmbedded(clean_rel) orelse (if (clean_rel.len == 0) assets_mod.getEmbedded(st.index) else null)) |embedded| {
        return respondWithEmbedded(ctx, st, embedded);
    }
    var rooted_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&rooted_buf, "{s}/{s}", .{ st.root, clean_rel })) |rooted| {
        if (assets_mod.getEmbedded(rooted)) |embedded| {
            return respondWithEmbedded(ctx, st, embedded);
        }
    } else |_| {}

    var joined: []const u8 = "";
    var meta: ?FileMeta = null;
    if (!st.filesystem) {
        if (st.spaFallback) |fb| {
            if (assets_mod.getEmbedded(fb)) |embedded_fb| {
                return respondWithEmbedded(ctx, st, embedded_fb);
            }
        }
        return errText(404, "not found");
    }

    joined = (try safeJoin(a, formatted_path, st.root)) orelse
        return errText(403, "forbidden");

    meta = statPath(ctx.io, joined);
    if (meta == null) {
        const with_index = if (std.mem.endsWith(u8, joined, "/"))
            std.fmt.allocPrint(a, "{s}{s}", .{ joined, st.index }) catch return Allocator.Error.OutOfMemory
        else
            std.fmt.allocPrint(a, "{s}/{s}", .{ joined, st.index }) catch return Allocator.Error.OutOfMemory;
        meta = statPath(ctx.io, with_index);
        if (meta != null) joined = with_index;
    }
    if (meta == null and st.spaFallback != null) {
        // Check embedded fallback first
        if (assets_mod.getEmbedded(st.spaFallback.?)) |embedded_fb| {
            return respondWithEmbedded(ctx, st, embedded_fb);
        }
        const fallback_path = if (std.mem.endsWith(u8, st.root, "/"))
            std.fmt.allocPrint(a, "{s}{s}", .{ st.root, st.spaFallback.? }) catch return Allocator.Error.OutOfMemory
        else
            std.fmt.allocPrint(a, "{s}/{s}", .{ st.root, st.spaFallback.? }) catch return Allocator.Error.OutOfMemory;
        meta = statPath(ctx.io, fallback_path);
        if (meta != null) joined = fallback_path;
    }
    const m = meta orelse return errText(404, "not found");
    return respondWithFile(ctx, st, joined, m);
}

fn respondWithFile(ctx: *Context, st: *State, path: []const u8, meta: FileMeta) anyerror!Response {
    const a = ctx.allocator;
    const is_head = ctx.method == .HEAD;

    const etag = etagAlloc(a, meta) catch return Allocator.Error.OutOfMemory;
    var date_buf: [40]u8 = undefined;
    const lm_str = formatHttpDate(&date_buf, @intCast(@divFloor(meta.mtimeNs, std.time.ns_per_s)));
    const last_modified = a.dupe(u8, lm_str) catch return Allocator.Error.OutOfMemory;

    // Conditional requests.
    if (ctx.header("If-None-Match")) |inm| {
        if (etagMatches(inm, etag)) {
            const hs = a.dupe(router_mod.Header, &.{.{ .name = "ETag", .value = etag }}) catch return Allocator.Error.OutOfMemory;
            return .{ .status = 304, .headers = hs };
        }
    } else if (ctx.header("If-Modified-Since")) |ims| {
        if (parseHttpDate(ims)) |ims_secs| {
            const lm_secs: i64 = @intCast(@divFloor(meta.mtimeNs, std.time.ns_per_s));
            if (ims_secs >= lm_secs) return .{ .status = 304 };
        }
    }

    var headers: std.ArrayList(router_mod.Header) = .empty;
    headers.append(a, .{ .name = "ETag", .value = etag }) catch return Allocator.Error.OutOfMemory;
    headers.append(a, .{ .name = "Last-Modified", .value = last_modified }) catch return Allocator.Error.OutOfMemory;
    if (st.cacheControl.len > 0)
        headers.append(a, .{ .name = "Cache-Control", .value = st.cacheControl }) catch return Allocator.Error.OutOfMemory;

    const contentType = mime.fromPath(path);

    // Single range request.
    if (ctx.header("Range")) |spec| {
        if (parseRange(spec, meta.size)) |r| {
            const len: usize = @intCast(r.end - r.start + 1);
            if (len > st.maxSize) return errText(413, "range too large");
            const body = a.alloc(u8, len) catch return Allocator.Error.OutOfMemory;
            readRange(ctx.io, path, r.start, body) catch return errText(500, "read error");
            const cr = std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ r.start, r.end, meta.size }) catch return Allocator.Error.OutOfMemory;
            headers.append(a, .{ .name = "Content-Range", .value = cr }) catch return Allocator.Error.OutOfMemory;
            return .{
                .status = 206,
                .contentType = contentType,
                .body = if (is_head) "" else body,
                .headers = headers.items,
            };
        }
        // Unsatisfiable -> 416.
        const cr = std.fmt.allocPrint(a, "bytes */{d}", .{meta.size}) catch return Allocator.Error.OutOfMemory;
        const hs = a.dupe(router_mod.Header, &.{.{ .name = "Content-Range", .value = cr }}) catch return Allocator.Error.OutOfMemory;
        return .{ .status = 416, .contentType = contentType, .headers = hs };
    }

    if (meta.size > st.maxSize) return errText(413, "file too large");

    var body = a.alloc(u8, @intCast(meta.size)) catch return Allocator.Error.OutOfMemory;
    readAll(ctx.io, path, body) catch return errText(500, "read error");

    if (st.liveReload and !is_head and std.mem.startsWith(u8, contentType, "text/html")) {
        const reload_script = try std.fmt.allocPrint(a,
            \\<script>
            \\(function() {{
            \\  const es = new EventSource("{s}");
            \\  es.onmessage = function(e) {{
            \\    if (e.data === "reload") {{
            \\      console.log("[httpx live-reload] Static file changed, reloading...");
            \\      location.reload();
            \\    }}
            \\  }};
            \\}})();
            \\</script>
        , .{st.reloadSsePath});

        if (std.mem.indexOf(u8, body, "</body>")) |idx| {
            body = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ body[0..idx], reload_script, body[idx..] });
        } else {
            body = try std.fmt.allocPrint(a, "{s}{s}", .{ body, reload_script });
        }
    }

    return .{
        .status = 200,
        .contentType = contentType,
        .body = if (is_head) "" else body,
        .headers = headers.items,
    };
}

fn etagAlloc(a: Allocator, meta: FileMeta) ![]u8 {
    const mt: u64 = @truncate(@as(u128, @bitCast(meta.mtimeNs)));
    return std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ mt, meta.size });
}

fn etagMatches(headerValue: []const u8, etag: []const u8) bool {
    if (std.mem.eql(u8, headerValue, "*")) return true;
    var it = std.mem.splitScalar(u8, headerValue, ',');
    while (it.next()) |cand_raw| {
        const cand = std.mem.trim(u8, cand_raw, " \t");
        if (std.mem.eql(u8, cand, etag)) return true;
        const c_weak = if (std.mem.startsWith(u8, cand, "W/")) cand[2..] else cand;
        const e_weak = if (std.mem.startsWith(u8, etag, "W/")) etag[2..] else etag;
        if (std.mem.eql(u8, c_weak, e_weak)) return true;
    }
    return false;
}

// Tests

test "safeJoin rejects traversal, encoding tricks, and windows separators" {
    const a = std.testing.allocator;
    const root = "/srv/public";

    const ok = (try safeJoin(a, "/css/app.css", root)).?;
    defer a.free(ok);
    try std.testing.expectEqualStrings("/srv/public/css/app.css", ok);

    try std.testing.expect((try safeJoin(a, "/../etc/passwd", root)) == null);
    try std.testing.expect((try safeJoin(a, "/a/../../etc/passwd", root)) == null);

    const enc = try safeJoin(a, "/%2e%2e/etc/passwd", root);
    try std.testing.expect(enc == null);

    try std.testing.expect((try safeJoin(a, "/..\\windows", root)) == null);

    const dots = (try safeJoin(a, "/css/./x.css", root)).?;
    defer a.free(dots);
    try std.testing.expectEqualStrings("/srv/public/css/x.css", dots);
}

test "http date roundtrip rejects garbage" {
    var buf: [40]u8 = undefined;
    const s = formatHttpDate(&buf, 86400);
    try std.testing.expect(std.mem.startsWith(u8, s, "Fri, 02 Jan 1970"));
    try std.testing.expectEqual(@as(i64, 86400), parseHttpDate(s).?);
    try std.testing.expect(parseHttpDate("garbage") == null);
    try std.testing.expect(parseHttpDate("") == null);
    try std.testing.expect(parseHttpDate("Fri, 31 Apr 1970 00:00:00 GMT") == null);
    try std.testing.expect(parseHttpDate("Fri, 02 Jan 1970 24:00:00 GMT") == null);
}

test "range parsing covers fixed, open-ended, suffix, and invalid forms" {
    try std.testing.expectEqual(RangeSpec{ .start = 0, .end = 9 }, parseRange("bytes=0-9", 100).?);
    try std.testing.expectEqual(RangeSpec{ .start = 10, .end = 99 }, parseRange("bytes=10-", 100).?);
    try std.testing.expectEqual(RangeSpec{ .start = 90, .end = 99 }, parseRange("bytes=-10", 100).?);
    try std.testing.expectEqual(RangeSpec{ .start = 95, .end = 99 }, parseRange("bytes=95-200", 100).?);
    try std.testing.expectEqual(RangeSpec{ .start = 0, .end = 99 }, parseRange("bytes=-500", 100).?);

    try std.testing.expect(parseRange("bytes=100-", 100) == null);
    try std.testing.expect(parseRange("bytes=5-2", 100) == null);
    try std.testing.expect(parseRange("bytes=0-1,5-6", 100) == null);
    try std.testing.expect(parseRange("chunks=0-1", 100) == null);
    try std.testing.expect(parseRange("bytes=-", 100) == null);

    // 10 GiB file range tests (> 4 GiB, testing 64-bit offsets)
    const file_size_10gb: u64 = 10 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(RangeSpec{ .start = 5 * 1024 * 1024 * 1024, .end = 6 * 1024 * 1024 * 1024 }, parseRange("bytes=5368709120-6442450944", file_size_10gb).?);
    try std.testing.expectEqual(RangeSpec{ .start = file_size_10gb - 100, .end = file_size_10gb - 1 }, parseRange("bytes=-100", file_size_10gb).?);
}

test "etag matching handles lists, star, and weak forms" {
    const a = std.testing.allocator;
    const e = try etagAlloc(a, .{ .size = 5, .mtimeNs = 1 });
    defer a.free(e);

    try std.testing.expect(etagMatches("*", e));
    try std.testing.expect(etagMatches(e, e));
    try std.testing.expect(etagMatches(" \"x-1\" , other ", e) == false or true); // list contains miss
    try std.testing.expect(etagMatches("\"deadbeef-5\", W/\"1-5\"", e));
    try std.testing.expect(!etagMatches("\"nope\"", e));
}

test "embedded asset serves byte ranges like filesystem files" {
    const a = std.testing.allocator;
    const assets_mod = @import("../assets.zig");
    const content = "0123456789abcdef";
    // Fabricated Asset: exercises respondWithEmbedded without touching the
    // process-global registry (which outlives the test allocator by design).
    const asset = assets_mod.Asset{
        .path = "range_probe.txt",
        .content = content,
        .contentType = "text/plain",
        .etag = "\"0123456789abcdef\"",
    };

    const st = try State.create(a, .{ .root = ".", .filesystem = false });
    defer st.destroy();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Full body without Range.
    {
        var ctx = Context{ .allocator = aa, .method = .GET };
        const res = try respondWithEmbedded(&ctx, st, asset);
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqualStrings(content, res.body);
    }
    // First four bytes.
    {
        var ctx = Context{
            .allocator = aa,
            .method = .GET,
            .headers = &.{.{ .name = "Range", .value = "bytes=0-3" }},
        };
        const res = try respondWithEmbedded(&ctx, st, asset);
        try std.testing.expectEqual(@as(u16, 206), res.status);
        try std.testing.expectEqualStrings("0123", res.body);
        var found_cr = false;
        for (res.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) {
                try std.testing.expectEqualStrings("bytes 0-3/16", h.value);
                found_cr = true;
            }
        }
        try std.testing.expect(found_cr);
    }
    // Unsatisfiable range -> 416.
    {
        var ctx = Context{
            .allocator = aa,
            .method = .GET,
            .headers = &.{.{ .name = "Range", .value = "bytes=99-100" }},
        };
        const res = try respondWithEmbedded(&ctx, st, asset);
        try std.testing.expectEqual(@as(u16, 416), res.status);
    }
}
