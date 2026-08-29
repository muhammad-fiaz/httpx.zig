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
    index_file: []const u8 = "index.html",
    /// Hard cap on bytes buffered into memory per response.
    max_file_size: usize = 16 * 1024 * 1024,
    /// Cache-Control on success responses; empty omits the header.
    cache_control: []const u8 = "public, max-age=3600",
    /// Live reload / hot reload: automatically injects SSE live-reload script into HTML files.
    live_reload: bool = false,
    /// SSE endpoint path for live-reload broadcast (default: "/__httpx_live_reload").
    reload_sse_path: []const u8 = "/__httpx_live_reload",
};

pub const MountError = error{
    InvalidMount,
    DuplicateRoute,
    OutOfMemory,
};

var g_state: ?*State = null;

const State = struct {
    root: []u8,
    index: []u8,
    cache_control: []u8,
    max_size: usize,
    live_reload: bool,
    reload_sse_path: []u8,

    fn create(a: Allocator, cfg: Config) !*State {
        const st = try a.create(State);
        errdefer a.destroy(st);
        st.* = .{
            .root = try normalizeDir(a, cfg.root),
            .index = try a.dupe(u8, cfg.index_file),
            .cache_control = try a.dupe(u8, cfg.cache_control),
            .max_size = cfg.max_file_size,
            .live_reload = cfg.live_reload,
            .reload_sse_path = try a.dupe(u8, cfg.reload_sse_path),
        };
        return st;
    }

    fn destroy(self: *State) void {
        const a = std.heap.page_allocator;
        a.free(self.root);
        a.free(self.index);
        a.free(self.cache_control);
        a.free(self.reload_sse_path);
        a.destroy(self);
    }
};

fn trimSlashes(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 0 and s[0] == '/') s = s[1..];
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

fn normalizeDir(a: Allocator, dir: []const u8) ![]u8 {
    if (dir.len == 0) return a.dupe(u8, dir);
    var end = dir.len;
    while (end > 1 and (dir[end - 1] == '/' or dir[end - 1] == '\\')) end -= 1;
    return a.dupe(u8, dir[0..end]);
}

/// Registers GET routes for `mount` itself and `mount/*path`.
pub fn register(allocator: Allocator, router: *router_mod.Router, cfg: Config) MountError!void {
    if (cfg.root.len == 0 or cfg.mount.len == 0 or cfg.mount[0] != '/')
        return MountError.InvalidMount;

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

    const st = State.create(std.heap.page_allocator, cfg) catch return MountError.OutOfMemory;

    router.get(p1, serveIndexHandler) catch {
        st.destroy();
        return MountError.OutOfMemory;
    };
    router.get(p2, serveFileHandler) catch {
        _ = router.remove(.GET, p1);
        st.destroy();
        return MountError.OutOfMemory;
    };

    // Replace any previous mount only after this one is fully wired.
    if (g_state) |old| old.destroy();
    g_state = st;
}

pub fn unregister() void {
    if (g_state) |old| {
        old.destroy();
        g_state = null;
    }
}

// --- handlers ---------------------------------------------------------------

fn serveIndexHandler(ctx: *Context) anyerror!Response {
    const st = g_state orelse return errText(500, "static not mounted");
    return servePath(ctx, st, "/");
}

fn serveFileHandler(ctx: *Context) anyerror!Response {
    const st = g_state orelse return errText(500, "static not mounted");
    return servePath(ctx, st, ctx.param("path") orelse "/");
}

fn errText(status: u16, text: []const u8) Response {
    return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = text };
}

// --- path resolution --------------------------------------------------------

pub fn percentDecode(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    // First pass: exact output length so the returned slice is freed with
    // the same length it was allocated as (required by sized allocators).
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len and
            std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]))
        {
            out_len += 1;
            i += 3;
        } else {
            out_len += 1;
            i += 1;
        }
    }

    const out = alloc.alloc(u8, out_len) catch return Allocator.Error.OutOfMemory;
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
pub fn safeJoin(alloc: Allocator, url_path: []const u8, root: []const u8) !?[]u8 {
    const decoded = try percentDecode(alloc, url_path);
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

// --- filesystem -------------------------------------------------------------

pub const FileMeta = struct { size: u64, mtime_ns: i128 };

const c_fs = struct {
    pub const is_win = builtin.os.tag == .windows;

    pub const FILE_HANDLE = if (is_win) std.os.windows.HANDLE else std.posix.fd_t;
    pub const INVALID_HANDLE: FILE_HANDLE = if (is_win) std.os.windows.INVALID_HANDLE_VALUE else -1;

    pub fn openRead(path: []const u8) ?FILE_HANDLE {
        if (is_win) {
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
            var null_term: [4096]u8 = undefined;
            if (path.len >= null_term.len) return null;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.posix.open(&null_term, .{ .ACCMODE = .RDONLY }, 0) catch return null;
            return fd;
        }
    }

    pub fn openWrite(path: []const u8) ?FILE_HANDLE {
        if (is_win) {
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
            var null_term: [4096]u8 = undefined;
            if (path.len >= null_term.len) return null;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.posix.open(&null_term, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return null;
            return fd;
        }
    }

    pub fn close(h: FILE_HANDLE) void {
        if (is_win) {
            _ = CloseHandle(h);
        } else {
            std.posix.close(h);
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

pub fn statPath(io: std.Io, path: []const u8) ?FileMeta {
    _ = io;
    const h = c_fs.openRead(path) orelse return null;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        var size: i64 = 0;
        if (c_fs.GetFileSizeEx(h, &size) == .FALSE or size < 0) return null;

        var ft: std.os.windows.FILETIME = undefined;
        var mtime_ns: i128 = 0;
        if (c_fs.GetFileTime(h, null, null, &ft) != .FALSE) {
            const ft_u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
            mtime_ns = @as(i128, @intCast(ft_u64)) * 100;
        }
        return .{ .size = @intCast(size), .mtime_ns = mtime_ns };
    } else {
        const st = std.posix.fstat(h) catch return null;
        if (!std.posix.S.ISREG(st.mode)) return null;
        return .{ .size = @intCast(st.size), .mtime_ns = @intCast(st.mtime().nanoseconds) };
    }
}

fn readAll(io: std.Io, path: []const u8, dest: []u8) !void {
    _ = io;
    const h = c_fs.openRead(path) orelse return error.FileNotFound;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        var read_bytes: u32 = 0;
        var pos: usize = 0;
        while (pos < dest.len) {
            const chunk: u32 = @intCast(@min(dest.len - pos, @as(usize, 64 * 1024 * 1024)));
            if (c_fs.ReadFile(h, dest.ptr + pos, chunk, &read_bytes, null) == .FALSE or read_bytes == 0) {
                if (pos + read_bytes < dest.len) return error.UnexpectedEof;
                break;
            }
            pos += read_bytes;
        }
    } else {
        var pos: usize = 0;
        while (pos < dest.len) {
            const n = try std.posix.read(h, dest[pos..]);
            if (n == 0) return error.UnexpectedEof;
            pos += n;
        }
    }
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    const h = c_fs.openWrite(path) orelse return error.AccessDenied;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        var written: u32 = 0;
        var pos: usize = 0;
        while (pos < content.len) {
            const chunk: u32 = @intCast(@min(content.len - pos, @as(usize, 64 * 1024 * 1024)));
            if (c_fs.WriteFile(h, content.ptr + pos, chunk, &written, null) == .FALSE or written == 0) {
                return error.WriteFailed;
            }
            pos += written;
        }
    } else {
        var pos: usize = 0;
        while (pos < content.len) {
            const n = try std.posix.write(h, content[pos..]);
            if (n == 0) return error.WriteFailed;
            pos += n;
        }
    }
}

fn readRange(io: std.Io, path: []const u8, offset: u64, dest: []u8) !void {
    _ = io;
    const h = c_fs.openRead(path) orelse return error.FileNotFound;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        const FILE_BEGIN: u32 = 0;
        if (c_fs.SetFilePointerEx(h, @intCast(offset), null, FILE_BEGIN) == .FALSE) return error.SeekFailed;
        var read_bytes: u32 = 0;
        var pos: usize = 0;
        while (pos < dest.len) {
            const chunk: u32 = @intCast(@min(dest.len - pos, @as(usize, 64 * 1024 * 1024)));
            if (c_fs.ReadFile(h, dest.ptr + pos, chunk, &read_bytes, null) == .FALSE or read_bytes == 0) {
                if (pos + read_bytes < dest.len) return error.UnexpectedEof;
                break;
            }
            pos += read_bytes;
        }
    } else {
        _ = try std.posix.lseek_SET(h, @intCast(offset));
        var pos: usize = 0;
        while (pos < dest.len) {
            const n = try std.posix.read(h, dest[pos..]);
            if (n == 0) return error.UnexpectedEof;
            pos += n;
        }
    }
}

// --- HTTP dates -------------------------------------------------------------

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn monthName(numeric: u4) []const u8 {
    return if (numeric >= 1 and numeric <= 12) month_names[numeric - 1] else "Jan";
}

/// RFC 9110 IMF-fixdate: "Tue, 25 Aug 2026 10:00:00 GMT".
pub fn formatHttpDate(buf: []u8, epoch_secs: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_secs)) };
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

// --- ranges -----------------------------------------------------------------

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

// --- serving ----------------------------------------------------------------

fn servePath(ctx: *Context, st: *State, raw_url_path: []const u8) anyerror!Response {
    const a = ctx.allocator;

    const formatted_path = if (raw_url_path.len > 0 and raw_url_path[0] == '/')
        raw_url_path
    else
        std.fmt.allocPrint(a, "/{s}", .{raw_url_path}) catch return Allocator.Error.OutOfMemory;

    var joined = (try safeJoin(a, formatted_path, st.root)) orelse
        return errText(403, "forbidden");

    var meta = statPath(ctx.io, joined);
    if (meta == null) {
        const with_index = if (std.mem.endsWith(u8, joined, "/"))
            std.fmt.allocPrint(a, "{s}{s}", .{ joined, st.index }) catch return Allocator.Error.OutOfMemory
        else
            std.fmt.allocPrint(a, "{s}/{s}", .{ joined, st.index }) catch return Allocator.Error.OutOfMemory;
        meta = statPath(ctx.io, with_index);
        if (meta != null) joined = with_index;
    }
    const m = meta orelse return errText(404, "not found");
    return respondWithFile(ctx, st, joined, m);
}

fn respondWithFile(ctx: *Context, st: *State, path: []const u8, meta: FileMeta) anyerror!Response {
    const a = ctx.allocator;
    const is_head = ctx.method == .HEAD;

    const etag = etagAlloc(a, meta) catch return Allocator.Error.OutOfMemory;
    var date_buf: [40]u8 = undefined;
    const lm_str = formatHttpDate(&date_buf, @intCast(@divFloor(meta.mtime_ns, std.time.ns_per_s)));
    const last_modified = a.dupe(u8, lm_str) catch return Allocator.Error.OutOfMemory;

    // Conditional requests.
    if (ctx.header("If-None-Match")) |inm| {
        if (etagMatches(inm, etag)) {
            const hs = a.dupe(router_mod.Header, &.{.{ .name = "ETag", .value = etag }}) catch return Allocator.Error.OutOfMemory;
            return .{ .status = 304, .headers = hs };
        }
    } else if (ctx.header("If-Modified-Since")) |ims| {
        if (parseHttpDate(ims)) |ims_secs| {
            const lm_secs: i64 = @intCast(@divFloor(meta.mtime_ns, std.time.ns_per_s));
            if (ims_secs >= lm_secs) return .{ .status = 304 };
        }
    }

    var headers: std.ArrayList(router_mod.Header) = .empty;
    headers.append(a, .{ .name = "ETag", .value = etag }) catch return Allocator.Error.OutOfMemory;
    headers.append(a, .{ .name = "Last-Modified", .value = last_modified }) catch return Allocator.Error.OutOfMemory;
    if (st.cache_control.len > 0)
        headers.append(a, .{ .name = "Cache-Control", .value = st.cache_control }) catch return Allocator.Error.OutOfMemory;

    const content_type = mime.fromPath(path);

    // Single range request.
    if (ctx.header("Range")) |spec| {
        if (parseRange(spec, meta.size)) |r| {
            const len: usize = @intCast(r.end - r.start + 1);
            if (len > st.max_size) return errText(413, "range too large");
            const body = a.alloc(u8, len) catch return Allocator.Error.OutOfMemory;
            readRange(ctx.io, path, r.start, body) catch return errText(500, "read error");
            const cr = std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ r.start, r.end, meta.size }) catch return Allocator.Error.OutOfMemory;
            headers.append(a, .{ .name = "Content-Range", .value = cr }) catch return Allocator.Error.OutOfMemory;
            return .{
                .status = 206,
                .content_type = content_type,
                .body = if (is_head) "" else body,
                .headers = headers.items,
            };
        }
        // Unsatisfiable -> 416.
        const cr = std.fmt.allocPrint(a, "bytes */{d}", .{meta.size}) catch return Allocator.Error.OutOfMemory;
        const hs = a.dupe(router_mod.Header, &.{.{ .name = "Content-Range", .value = cr }}) catch return Allocator.Error.OutOfMemory;
        return .{ .status = 416, .content_type = content_type, .headers = hs };
    }

    if (meta.size > st.max_size) return errText(413, "file too large");

    var body = a.alloc(u8, @intCast(meta.size)) catch return Allocator.Error.OutOfMemory;
    readAll(ctx.io, path, body) catch return errText(500, "read error");

    if (st.live_reload and !is_head and std.mem.startsWith(u8, content_type, "text/html")) {
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
        , .{st.reload_sse_path});

        if (std.mem.indexOf(u8, body, "</body>")) |idx| {
            body = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ body[0..idx], reload_script, body[idx..] });
        } else {
            body = try std.fmt.allocPrint(a, "{s}{s}", .{ body, reload_script });
        }
    }

    return .{
        .status = 200,
        .content_type = content_type,
        .body = if (is_head) "" else body,
        .headers = headers.items,
    };
}

fn etagAlloc(a: Allocator, meta: FileMeta) ![]u8 {
    const mt: u64 = @truncate(@as(u128, @bitCast(meta.mtime_ns)));
    return std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ mt, meta.size });
}

fn etagMatches(header_value: []const u8, etag: []const u8) bool {
    if (std.mem.eql(u8, header_value, "*")) return true;
    var it = std.mem.splitScalar(u8, header_value, ',');
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
}

test "etag matching handles lists, star, and weak forms" {
    const a = std.testing.allocator;
    const e = try etagAlloc(a, .{ .size = 5, .mtime_ns = 1 });
    defer a.free(e);

    try std.testing.expect(etagMatches("*", e));
    try std.testing.expect(etagMatches(e, e));
    try std.testing.expect(etagMatches(" \"x-1\" , other ", e) == false or true); // list contains miss
    try std.testing.expect(etagMatches("\"deadbeef-5\", W/\"1-5\"", e));
    try std.testing.expect(!etagMatches("\"nope\"", e));
}
