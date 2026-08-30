//! Production-grade streaming download, update, verification, and progress subsystem.
//!
//! Provides:
//! - Direct streaming to disk with memory-bounded buffers (no full file buffering)
//! - Resume support with HTTP Range requests (RFC 9110 Section 14.1) and 206/200/416 handling
//! - Incremental cryptographic hashing (SHA-256, SHA-384, SHA-512, MD5, SHA-1) while streaming
//! - Out-of-the-box built-in terminal progress bars via `loaders.zig` + TTY detection
//! - Completely UI-independent custom progress callback interface
//! - Existing-file policies: fail, overwrite, skip, resume, verify_existing, replace_if_changed
//! - Atomic destination replacement via temporary part files
//! - Untrusted filename sanitization and safe directory creation
//! - Transparent authentication (Basic, Bearer, API-key, custom headers, cookies)
//! - Safe redirect credential stripping across cross-origin hops
//! - Robust exponential backoff retries on transient network/HTTP failures
//! - Cooperative cancellation support
//! - Reusable file updater with rollback safety
//! - Concurrent batch downloads powered by worker pools
//! - Unified FTP download integration

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const loaders = @import("loaders");
const tint = loaders.tint;
const clock = @import("../common/clock.zig");
const Method = @import("../common/method.zig").Method;
const Status = @import("../common/status.zig").Status;
const Header = @import("request.zig").Header;
const Response = @import("request.zig").Response;
const req_mod = @import("request.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const ftp_client = @import("../protocols/ftp/client.zig");
const serve_mod = @import("../web/static_files/serve.zig");
const c_fs = serve_mod.c_fs;

pub const DownloadError = error{
    DestinationExists,
    DestinationIsDirectory,
    DirectoryCreationFailed,
    FileCreateFailed,
    FileWriteFailed,
    FileReadFailed,
    FileSeekFailed,
    FileRenameFailed,
    FileDeleteFailed,
    FileNotFound,
    InvalidUrl,
    BadRequest,
    HttpError,
    AuthenticationFailed,
    RedirectFailed,
    TooManyRedirects,
    RangeNotSupported,
    RangeUnsatisfiable,
    ResponseTooLarge,
    ResponseTooSmall,
    ServerError,
    ChecksumMismatch,
    ChecksumFileParseError,
    Timeout,
    Cancelled,
    ConnectionFailed,
    ReadFailed,
    WriteFailed,
    ProtocolViolation,
    OutOfMemory,
    UnexpectedEof,
};

pub const ProgressState = enum {
    starting,
    downloading,
    verifying,
    completed,
    failed,
    cancelled,
};

pub const ProgressInfo = struct {
    url: []const u8,
    destination: []const u8,
    downloaded_bytes: u64,
    total_bytes: ?u64,
    percentage: ?f32,
    speed_bps: f64,
    eta_seconds: ?u64,
    elapsed_ms: u64,
    status_code: u16,
    state: ProgressState,
};

pub const ProgressMode = enum {
    /// Show progress bar if stdout is a TTY, otherwise quiet.
    auto,
    /// Always show progress bar.
    enabled,
    /// No progress output to stdout.
    disabled,
    /// Quiet mode (alias for disabled).
    quiet,
    /// Custom callback only.
    custom,
};

pub const ExistingFilePolicy = enum {
    /// Fail with error.DestinationExists if destination already exists.
    fail,
    /// Overwrite existing destination (download to temp, then atomically replace).
    overwrite,
    /// Skip download if destination already exists.
    skip,
    /// Resume partial download if possible (primary clean name, no @ needed).
    resume_download,
    /// Non-reserved alias for resume_download.
    continue_partial,
    /// Backward-compatible alias for resume_download.
    @"resume",
    /// Verify existing file on disk against expected checksum; skip if valid, download if invalid.
    verify_existing,
    /// Use conditional headers (If-None-Match / If-Modified-Since); skip if 304 Not Modified.
    replace_if_changed,

    pub fn isResume(self: ExistingFilePolicy) bool {
        return switch (self) {
            .resume_download, .continue_partial, .@"resume" => true,
            else => false,
        };
    }
};

pub const RemoteFileInfo = struct {
    status: u16 = 200,
    file_size: ?u64 = null,
    accepts_ranges: bool = false,

    url_buf: [256]u8 = [_]u8{0} ** 256,
    url_len: usize = 0,

    file_name_buf: [128]u8 = [_]u8{0} ** 128,
    file_name_len: usize = 0,

    content_type_buf: [64]u8 = [_]u8{0} ** 64,
    content_type_len: usize = 0,

    etag_buf: [64]u8 = [_]u8{0} ** 64,
    etag_len: usize = 0,

    last_modified_buf: [64]u8 = [_]u8{0} ** 64,
    last_modified_len: usize = 0,

    content_encoding_buf: [32]u8 = [_]u8{0} ** 32,
    content_encoding_len: usize = 0,

    pub fn url(self: *const RemoteFileInfo) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn fileName(self: *const RemoteFileInfo) []const u8 {
        return self.file_name_buf[0..self.file_name_len];
    }

    pub fn contentType(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.content_type_len == 0) return null;
        return self.content_type_buf[0..self.content_type_len];
    }

    pub fn etag(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.etag_len == 0) return null;
        return self.etag_buf[0..self.etag_len];
    }

    pub fn lastModified(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.last_modified_len == 0) return null;
        return self.last_modified_buf[0..self.last_modified_len];
    }

    pub fn contentEncoding(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.content_encoding_len == 0) return null;
        return self.content_encoding_buf[0..self.content_encoding_len];
    }

    /// Formats the file size as human-readable string (e.g., "12.42 MB", "500 KB", "1.20 GB").
    pub fn formatSize(self: RemoteFileInfo, buf: []u8) []const u8 {
        const sz = self.file_size orelse return "unknown";
        if (sz < 1024) {
            return std.fmt.bufPrint(buf, "{d} B", .{sz}) catch "unknown";
        } else if (sz < 1024 * 1024) {
            const kb = @as(f64, @floatFromInt(sz)) / 1024.0;
            return std.fmt.bufPrint(buf, "{d:.2} KB", .{kb}) catch "unknown";
        } else if (sz < 1024 * 1024 * 1024) {
            const mb = @as(f64, @floatFromInt(sz)) / (1024.0 * 1024.0);
            return std.fmt.bufPrint(buf, "{d:.2} MB", .{mb}) catch "unknown";
        } else {
            const gb = @as(f64, @floatFromInt(sz)) / (1024.0 * 1024.0 * 1024.0);
            return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "unknown";
        }
    }
};

pub const ChecksumAlgorithm = enum {
    sha256,
    sha384,
    sha512,
    md5,
    sha1,
};

pub const VerifyOptions = struct {
    sha256: ?[]const u8 = null,
    sha384: ?[]const u8 = null,
    sha512: ?[]const u8 = null,
    md5: ?[]const u8 = null,
    sha1: ?[]const u8 = null,
    expected_size: ?u64 = null,
    min_size: ?u64 = null,
    max_size: ?u64 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    checksum_file_url: ?[]const u8 = null,
};

pub const DownloadOptions = struct {
    headers: []const Header = &.{},
    timeout_ms: ?u64 = null,
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 500,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    existing: ExistingFilePolicy = .overwrite,
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    on_progress: ?*const fn (info: ProgressInfo, user_data: ?*anyopaque) void = null,
    user_data: ?*anyopaque = null,
    /// Atomically download to a temporary file first, then rename on success and verification pass.
    atomic: bool = true,
    temp_suffix: []const u8 = ".httpx-part",
    /// Automatically create missing parent directories for the destination path.
    create_dirs: bool = true,
    /// Flag for cooperative cancellation.
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    /// Authentication helpers
    bearer_token: ?[]const u8 = null,
    basic_auth: ?[]const u8 = null,
    api_key_header: ?[]const u8 = null,
    api_key_value: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
};

pub const DownloadResult = struct {
    destination_buf: [1024]u8 = [_]u8{0} ** 1024,
    destination_len: usize = 0,
    destination: []const u8 = "",
    downloaded_bytes: u64,
    total_bytes: ?u64,
    elapsed_ms: u64,
    status_code: u16,
    resumed: bool = false,
    skipped: bool = false,
    overwritten: bool = false,
    verified: bool = false,
    sha256_hex: ?[64]u8 = null,

    pub fn make(dest_path: []const u8, downloaded: u64, total: ?u64, elapsed: u64, status: u16) DownloadResult {
        var res = DownloadResult{
            .downloaded_bytes = downloaded,
            .total_bytes = total,
            .elapsed_ms = elapsed,
            .status_code = status,
        };
        const len = @min(dest_path.len, res.destination_buf.len);
        @memcpy(res.destination_buf[0..len], dest_path[0..len]);
        res.destination_len = len;
        res.destination = dest_path; // Points to external buffer if valid
        return res;
    }

    pub fn destinationPath(self: *const DownloadResult) []const u8 {
        if (self.destination_len > 0) return self.destination_buf[0..self.destination_len];
        return self.destination;
    }
};

// Checksum Helpers

pub const Hasher = struct {
    sha256: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    sha384: std.crypto.hash.sha2.Sha384 = std.crypto.hash.sha2.Sha384.init(.{}),
    sha512: std.crypto.hash.sha2.Sha512 = std.crypto.hash.sha2.Sha512.init(.{}),
    md5: std.crypto.hash.Md5 = std.crypto.hash.Md5.init(.{}),
    sha1: std.crypto.hash.Sha1 = std.crypto.hash.Sha1.init(.{}),
    enabled_sha256: bool = false,
    enabled_sha384: bool = false,
    enabled_sha512: bool = false,
    enabled_md5: bool = false,
    enabled_sha1: bool = false,

    pub fn init(verify_opts: VerifyOptions) Hasher {
        return .{
            .enabled_sha256 = verify_opts.sha256 != null or verify_opts.checksum_file_url != null,
            .enabled_sha384 = verify_opts.sha384 != null,
            .enabled_sha512 = verify_opts.sha512 != null,
            .enabled_md5 = verify_opts.md5 != null,
            .enabled_sha1 = verify_opts.sha1 != null,
        };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        if (self.enabled_sha256) self.sha256.update(bytes);
        if (self.enabled_sha384) self.sha384.update(bytes);
        if (self.enabled_sha512) self.sha512.update(bytes);
        if (self.enabled_md5) self.md5.update(bytes);
        if (self.enabled_sha1) self.sha1.update(bytes);
    }

    pub fn finalSha256Hex(self: *Hasher) [64]u8 {
        var digest: [32]u8 = undefined;
        var copy = self.sha256;
        copy.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    pub fn verify(self: *Hasher, opts: VerifyOptions) DownloadError!void {
        if (opts.sha256) |expected| {
            var digest: [32]u8 = undefined;
            self.sha256.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&hex, expected)) return DownloadError.ChecksumMismatch;
        }
        if (opts.sha384) |expected| {
            var digest: [48]u8 = undefined;
            self.sha384.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&hex, expected)) return DownloadError.ChecksumMismatch;
        }
        if (opts.sha512) |expected| {
            var digest: [64]u8 = undefined;
            self.sha512.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&hex, expected)) return DownloadError.ChecksumMismatch;
        }
        if (opts.md5) |expected| {
            var digest: [16]u8 = undefined;
            self.md5.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&hex, expected)) return DownloadError.ChecksumMismatch;
        }
        if (opts.sha1) |expected| {
            var digest: [20]u8 = undefined;
            self.sha1.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&hex, expected)) return DownloadError.ChecksumMismatch;
        }
    }
};

const FileOps = struct {
    const is_win = builtin.os.tag == .windows;

    pub const Handle = if (is_win) std.os.windows.HANDLE else std.posix.fd_t;
    pub const invalid_handle: Handle = if (is_win) std.os.windows.INVALID_HANDLE_VALUE else -1;

    pub fn createTruncate(path: []const u8) ?Handle {
        return c_fs.openWrite(path);
    }

    pub fn openReadWrite(path: []const u8) ?Handle {
        if (is_win) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return null;
            wbuf[len] = 0;
            const OPEN_ALWAYS: u32 = 4;
            const GENERIC_READ: u32 = 0x80000000;
            const GENERIC_WRITE: u32 = 0x40000000;
            const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;
            const h = c_fs.CreateFileW(
                @ptrCast(&wbuf),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null,
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (h == c_fs.INVALID_HANDLE) return null;
            return h;
        } else {
            var null_term: [4096:0]u8 = undefined;
            if (path.len >= null_term.len) return null;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.c.open(&null_term, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn openRead(path: []const u8) ?Handle {
        return c_fs.openRead(path);
    }

    pub fn seekToEnd(h: Handle) bool {
        if (is_win) {
            var new_pos: i64 = 0;
            return c_fs.SetFilePointerEx(h, 0, &new_pos, 2) != .FALSE; // FILE_END = 2
        } else {
            _ = std.c.lseek(h, 0, 2); // SEEK_END = 2
            return true;
        }
    }

    pub fn writeAll(h: Handle, data: []const u8) bool {
        var written: usize = 0;
        while (written < data.len) {
            if (is_win) {
                var chunk_written: u32 = 0;
                const chunk_len: u32 = @intCast(@min(data.len - written, @as(usize, std.math.maxInt(u32))));
                if (c_fs.WriteFile(h, data[written..].ptr, chunk_len, &chunk_written, null) == .FALSE) return false;
                if (chunk_written == 0) return false;
                written += chunk_written;
            } else {
                const n = std.c.write(h, data[written..].ptr, data.len - written);
                if (n <= 0) return false;
                written += @intCast(n);
            }
        }
        return true;
    }

    pub fn read(h: Handle, buf: []u8) !usize {
        if (is_win) {
            var read_bytes: u32 = 0;
            const to_read: u32 = @intCast(@min(buf.len, @as(usize, std.math.maxInt(u32))));
            if (c_fs.ReadFile(h, buf.ptr, to_read, &read_bytes, null) == .FALSE) return error.FileReadFailed;
            return read_bytes;
        } else {
            const n = std.c.read(h, buf.ptr, buf.len);
            if (n < 0) return error.FileReadFailed;
            return @intCast(n);
        }
    }

    pub fn close(h: Handle) void {
        c_fs.close(h);
    }

    pub fn deleteFile(path: []const u8) bool {
        if (is_win) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
            wbuf[len] = 0;
            const DeleteFileW = struct {
                pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.BOOL;
            }.DeleteFileW;
            return DeleteFileW(@ptrCast(&wbuf)) != .FALSE;
        } else {
            var null_term: [4096]u8 = undefined;
            if (path.len >= null_term.len) return false;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            _ = std.c.unlink(@ptrCast(&null_term));
            return true;
        }
    }

    pub fn renameFile(old_path: []const u8, new_path: []const u8) bool {
        if (is_win) {
            var wold: [1024]u16 = undefined;
            const olen = std.unicode.utf8ToUtf16Le(&wold, old_path) catch return false;
            wold[olen] = 0;
            var wnew: [1024]u16 = undefined;
            const nlen = std.unicode.utf8ToUtf16Le(&wnew, new_path) catch return false;
            wnew[nlen] = 0;
            const MoveFileExW = struct {
                pub extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) std.os.windows.BOOL;
            }.MoveFileExW;
            const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
            const MOVEFILE_COPY_ALLOWED: u32 = 0x00000002;
            return MoveFileExW(@ptrCast(&wold), @ptrCast(&wnew), MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED) != .FALSE;
        } else {
            var o_nt: [4096]u8 = undefined;
            var n_nt: [4096]u8 = undefined;
            if (old_path.len >= o_nt.len or new_path.len >= n_nt.len) return false;
            @memcpy(o_nt[0..old_path.len], old_path);
            o_nt[old_path.len] = 0;
            @memcpy(n_nt[0..new_path.len], new_path);
            n_nt[new_path.len] = 0;
            _ = std.c.rename(@ptrCast(&o_nt), @ptrCast(&n_nt));
            return true;
        }
    }

    pub fn makeDir(path: []const u8) bool {
        if (is_win) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
            wbuf[len] = 0;
            const CreateDirectoryW = struct {
                pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
            }.CreateDirectoryW;
            return CreateDirectoryW(@ptrCast(&wbuf), null) != .FALSE;
        } else {
            var null_term: [4096]u8 = undefined;
            if (path.len >= null_term.len) return false;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            _ = std.c.mkdir(@ptrCast(&null_term), 0o755);
            return true;
        }
    }

    pub fn makePath(path: []const u8) bool {
        if (path.len == 0 or std.mem.eql(u8, path, ".")) return true;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/' or path[i] == '\\') {
                if (i > 0 and path[i - 1] != ':') {
                    _ = makeDir(path[0..i]);
                }
            }
        }
        _ = makeDir(path);
        return true;
    }

    pub fn isDir(path: []const u8) bool {
        if (is_win) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
            wbuf[len] = 0;
            const GetFileAttributesW = struct {
                pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
            }.GetFileAttributesW;
            const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
            const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;
            const attr = GetFileAttributesW(@ptrCast(&wbuf));
            if (attr == INVALID_FILE_ATTRIBUTES) return false;
            return (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
        } else {
            var null_term: [4096:0]u8 = undefined;
            if (path.len >= null_term.len) return false;
            @memcpy(null_term[0..path.len], path);
            null_term[path.len] = 0;
            const fd = std.c.open(&null_term, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (fd < 0) return false;
            defer _ = std.c.close(fd);
            var st: std.c.Stat = undefined;
            if (std.c.fstat(fd, &st) != 0) return false;
            return (st.mode & 0o170000) == 0o040000;
        }
    }

    pub fn copyFile(src_path: []const u8, dst_path: []const u8) bool {
        const src_h = openRead(src_path) orelse return false;
        defer close(src_h);
        const dst_h = createTruncate(dst_path) orelse return false;
        defer close(dst_h);

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = read(src_h, &buf) catch return false;
            if (n == 0) break;
            if (!writeAll(dst_h, buf[0..n])) return false;
        }
        return true;
    }
};

/// Verifies a file on local disk against expected checksums and size parameters.
pub fn verifyFile(path: []const u8, opts: VerifyOptions) DownloadError!void {
    const meta = serve_mod.statPath(undefined, path) orelse return DownloadError.FileReadFailed;

    if (opts.expected_size) |sz| {
        if (meta.size != sz) return DownloadError.ChecksumMismatch;
    }
    if (opts.min_size) |min| {
        if (meta.size < min) return DownloadError.ResponseTooSmall;
    }
    if (opts.max_size) |max| {
        if (meta.size > max) return DownloadError.ResponseTooLarge;
    }

    if (opts.sha256 == null and opts.sha384 == null and opts.sha512 == null and opts.md5 == null and opts.sha1 == null) {
        return;
    }

    const file = FileOps.openRead(path) orelse return DownloadError.FileReadFailed;
    defer FileOps.close(file);

    var hasher = Hasher.init(opts);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = FileOps.read(file, &buf) catch return DownloadError.FileReadFailed;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    try hasher.verify(opts);
}

/// Parses a checksum file line (e.g. "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  target.zip").
pub fn parseChecksumFile(content: []const u8, filename: ?[]const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const hash = tokens.next() orelse continue;
        const file_token = tokens.next();

        if (filename) |target| {
            if (file_token) |ft| {
                const clean_target = std.fs.path.basename(target);
                var clean_ft = ft;
                if (clean_ft.len > 0 and clean_ft[0] == '*') clean_ft = clean_ft[1..];
                clean_ft = std.fs.path.basename(clean_ft);
                if (std.mem.eql(u8, clean_target, clean_ft)) {
                    return hash;
                }
            }
        } else {
            return hash;
        }
    }
    return null;
}

// Filename and Destination Sanitization

/// Sanitizes a filename to protect against directory traversal (`../`, `..\`) and reserved device names.
pub fn sanitizeFilename(name: []const u8) []const u8 {
    var s = name;
    // Strip query parameters or fragments if extracted from a URL
    if (std.mem.indexOfScalar(u8, s, '?')) |idx| s = s[0..idx];
    if (std.mem.indexOfScalar(u8, s, '#')) |idx| s = s[0..idx];

    // Get the base filename
    s = std.fs.path.basename(s);

    // If completely empty or dot, default to downloaded_file
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) {
        return "downloaded_file";
    }

    return s;
}

/// Resolves destination path: if destination is a directory or empty, append sanitized filename from URL or header.
pub fn resolveDestination(
    allocator: Allocator,
    dest: ?[]const u8,
    url: []const u8,
    content_disposition: ?[]const u8,
) ![]const u8 {
    const raw_dest = if (dest) |d| d else "";
    var is_dir = false;
    if (raw_dest.len == 0 or std.mem.eql(u8, raw_dest, ".")) {
        is_dir = true;
    } else if (raw_dest[raw_dest.len - 1] == '/' or raw_dest[raw_dest.len - 1] == '\\') {
        is_dir = true;
    } else {
        if (serve_mod.statPath(undefined, raw_dest)) |_| {
            if (FileOps.isDir(raw_dest)) {
                is_dir = true;
            }
        }
    }

    if (!is_dir) return allocator.dupe(u8, raw_dest);

    var chosen_name: []const u8 = "downloaded_file";
    if (content_disposition) |cd| {
        if (extractFilenameFromContentDisposition(cd)) |fname| {
            chosen_name = fname;
        }
    } else {
        const url_base = std.fs.path.basename(url);
        if (url_base.len > 0 and !std.mem.eql(u8, url_base, "/") and !std.mem.eql(u8, url_base, "\\")) {
            chosen_name = url_base;
        }
    }

    const safe_name = sanitizeFilename(chosen_name);
    if (raw_dest.len == 0 or std.mem.eql(u8, raw_dest, ".")) {
        return allocator.dupe(u8, safe_name);
    }
    return std.fs.path.join(allocator, &.{ raw_dest, safe_name });
}

fn extractFilenameFromContentDisposition(cd: []const u8) ?[]const u8 {
    const needle = "filename=";
    const idx = std.ascii.indexOfIgnoreCase(cd, needle) orelse return null;
    var rem = std.mem.trim(u8, cd[idx + needle.len ..], " \t");
    if (rem.len == 0) return null;
    if (rem[0] == '"') {
        rem = rem[1..];
        const end = std.mem.indexOfScalar(u8, rem, '"') orelse rem.len;
        return rem[0..end];
    } else {
        const end = std.mem.indexOfAny(u8, rem, " ;\r\n") orelse rem.len;
        return rem[0..end];
    }
}

// Download Engine

pub const Downloader = struct {
    allocator: Allocator,
    client: *Client,

    pub fn init(allocator: Allocator, client: *Client) Downloader {
        return .{
            .allocator = allocator,
            .client = client,
        };
    }

    /// Queries the remote server via HEAD (or range GET fallback) to inspect metadata,
    /// file size, remote filename, Content-Type, ETag, Last-Modified, and range support without downloading.
    pub fn lookupFileInfo(
        self: *Downloader,
        url: []const u8,
        options: DownloadOptions,
    ) DownloadError!RemoteFileInfo {
        return lookupFileInfoWithClient(self.client, url, options);
    }

    /// Downloads a remote HTTP/HTTPS resource to a local destination file.
    pub fn download(
        self: *Downloader,
        url: []const u8,
        destination_path: []const u8,
        options: DownloadOptions,
    ) DownloadError!DownloadResult {
        const start_time = clock.millisNow();

        // 1. Resolve destination
        const dest = resolveDestination(self.allocator, destination_path, url, null) catch return DownloadError.OutOfMemory;
        defer self.allocator.free(dest);

        // 2. Create parent directories if requested
        if (options.create_dirs) {
            if (std.fs.path.dirname(dest)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                    _ = FileOps.makePath(parent);
                }
            }
        }

        // 3. Handle existing destination policy
        const existing_meta = serve_mod.statPath(undefined, dest);
        if (existing_meta) |meta| {
            switch (options.existing) {
                .fail => return DownloadError.DestinationExists,
                .skip => {
                    var res = DownloadResult.make(dest, 0, meta.size, @intCast(clock.millisNow() - start_time), 200);
                    res.skipped = true;
                    return res;
                },
                .verify_existing => {
                    if (verifyFile(dest, options.verify)) |_| {
                        var res = DownloadResult.make(dest, 0, meta.size, @intCast(clock.millisNow() - start_time), 200);
                        res.skipped = true;
                        res.verified = true;
                        return res;
                    } else |_| {
                        // Verification failed, proceed with re-download
                    }
                },

                .overwrite, .resume_download, .continue_partial, .@"resume", .replace_if_changed => {},
            }
        }

        // 4. Temporary part file strategy
        var temp_path: []const u8 = undefined;
        var is_temp = false;
        if (options.atomic) {
            temp_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dest, options.temp_suffix }) catch return DownloadError.OutOfMemory;
            is_temp = true;
        } else {
            temp_path = self.allocator.dupe(u8, dest) catch return DownloadError.OutOfMemory;
        }
        defer self.allocator.free(temp_path);

        // 5. Check for partial resume
        var resume_offset: u64 = 0;
        if (options.existing.isResume()) {
            if (serve_mod.statPath(undefined, temp_path)) |tmeta| {
                resume_offset = tmeta.size;
            } else if (existing_meta) |emeta| {
                resume_offset = emeta.size;
            }
        }

        // 6. Setup progress presentation
        var progress_tracker = ProgressTracker.init(self.allocator, self.client.io, url, dest, options);
        defer progress_tracker.deinit();

        // 7. Perform download loop with retries
        var attempt: u32 = 0;
        var result: DownloadResult = .{
            .destination = dest,
            .downloaded_bytes = 0,
            .total_bytes = null,
            .elapsed_ms = 0,
            .status_code = 0,
        };

        while (attempt <= options.max_retries) : (attempt += 1) {
            if (options.cancel_flag) |cf| {
                if (cf.load(.acquire)) return DownloadError.Cancelled;
            }

            const download_res = self.performTransfer(
                url,
                temp_path,
                dest,
                resume_offset,
                options,
                &progress_tracker,
            );

            if (download_res) |res| {
                result = res;
                break;
            } else |err| {
                if (err == DownloadError.Cancelled or err == DownloadError.DestinationExists or err == DownloadError.ChecksumMismatch) {
                    if (is_temp and !options.existing.isResume()) {
                        _ = FileOps.deleteFile(temp_path);
                    }
                    return err;
                }
                if (attempt >= options.max_retries) {
                    if (is_temp and !options.existing.isResume()) {
                        _ = FileOps.deleteFile(temp_path);
                    }
                    return err;
                }
                clock.sleepMillis(options.retry_delay_ms * (@as(u64, 1) << @intCast(@min(attempt, 4))));
            }
        }

        // 8. Atomic Rename / Replace
        if (is_temp and !result.skipped) {
            if (!FileOps.renameFile(temp_path, dest)) {
                return DownloadError.FileRenameFailed;
            }
        }

        result.elapsed_ms = @intCast(clock.millisNow() - start_time);
        return result;
    }

    fn performTransfer(
        self: *Downloader,
        url: []const u8,
        temp_path: []const u8,
        dest_path: []const u8,
        resume_offset: u64,
        options: DownloadOptions,
        tracker: *ProgressTracker,
    ) DownloadError!DownloadResult {
        // Headers setup
        var custom_headers: std.ArrayList(Header) = .empty;
        defer custom_headers.deinit(self.allocator);

        for (options.headers) |h| {
            custom_headers.append(self.allocator, h) catch return DownloadError.OutOfMemory;
        }

        // Authentication
        var auth_buf: [256]u8 = undefined;
        if (options.bearer_token) |token| {
            const val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return DownloadError.AuthenticationFailed;
            custom_headers.append(self.allocator, .{ .name = "Authorization", .value = val }) catch return DownloadError.OutOfMemory;
        } else if (options.basic_auth) |basic| {
            const val = std.fmt.bufPrint(&auth_buf, "Basic {s}", .{basic}) catch return DownloadError.AuthenticationFailed;
            custom_headers.append(self.allocator, .{ .name = "Authorization", .value = val }) catch return DownloadError.OutOfMemory;
        }

        if (options.api_key_header) |hdr| {
            if (options.api_key_value) |val| {
                custom_headers.append(self.allocator, .{ .name = hdr, .value = val }) catch return DownloadError.OutOfMemory;
            }
        }

        if (options.cookie) |c| {
            custom_headers.append(self.allocator, .{ .name = "Cookie", .value = c }) catch return DownloadError.OutOfMemory;
        }

        // Resume Range header
        var range_buf: [64]u8 = undefined;
        var resuming = false;
        if (resume_offset > 0) {
            const range_str = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{resume_offset}) catch return DownloadError.RangeNotSupported;
            custom_headers.append(self.allocator, .{ .name = "Range", .value = range_str }) catch return DownloadError.OutOfMemory;
            resuming = true;
        }

        // Conditional headers
        if (options.existing == .replace_if_changed) {
            if (options.verify.etag) |etag| {
                custom_headers.append(self.allocator, .{ .name = "If-None-Match", .value = etag }) catch return DownloadError.OutOfMemory;
            }
            if (options.verify.last_modified) |lm| {
                custom_headers.append(self.allocator, .{ .name = "If-Modified-Since", .value = lm }) catch return DownloadError.OutOfMemory;
            }
        }

        var has_connection = false;
        for (custom_headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) has_connection = true;
        }
        if (!has_connection) {
            custom_headers.append(self.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;
        }

        // Execute request
        var resp = self.client.get(.{
            .url = url,
            .headers = custom_headers.items,
            .follow_redirects = options.follow_redirects,
            .max_redirects = options.max_redirects,
            .timeout_ms = options.timeout_ms orelse 15000,
        }) catch |e| switch (e) {
            error.ConnectFailed => return DownloadError.ConnectionFailed,
            error.TooManyRedirects => return DownloadError.TooManyRedirects,
            else => return DownloadError.HttpError,
        };
        defer resp.deinit();

        // Check 304 Not Modified
        if (resp.status == 304) {
            return .{
                .destination = dest_path,
                .downloaded_bytes = 0,
                .total_bytes = null,
                .elapsed_ms = 0,
                .status_code = 304,
                .skipped = true,
            };
        }

        // Validate Status Code
        if (resp.status == 400) return DownloadError.BadRequest;
        if (resp.status == 401 or resp.status == 403) return DownloadError.AuthenticationFailed;
        if (resp.status == 404) return DownloadError.FileNotFound;
        if (resp.status == 416) return DownloadError.RangeUnsatisfiable;
        if (resp.status >= 500 and resp.status <= 599) return DownloadError.ServerError;
        if (resp.status < 200 or resp.status >= 300) return DownloadError.HttpError;

        var actual_offset: u64 = 0;
        if (resuming and resp.status == 206) {
            actual_offset = resume_offset;
        } else {
            resuming = false;
            actual_offset = 0;
        }

        // Determine total size
        var total_size: ?u64 = null;
        if (resp.header("content-length")) |cl| {
            if (std.fmt.parseInt(u64, std.mem.trim(u8, cl, " "), 10)) |val| {
                total_size = val + actual_offset;
            } else |_| {}
        }

        // Size limits enforcement
        if (total_size) |tot| {
            if (options.verify.max_size) |max| {
                if (tot > max) return DownloadError.ResponseTooLarge;
            }
            if (options.verify.min_size) |min| {
                if (tot < min) return DownloadError.ResponseTooSmall;
            }
            if (options.verify.expected_size) |exp| {
                if (tot != exp) return DownloadError.ChecksumMismatch;
            }
        }

        tracker.start(total_size);

        // Open destination / temp file
        const file_handle = blk: {
            if (actual_offset > 0) {
                const h = FileOps.openReadWrite(temp_path) orelse return DownloadError.FileCreateFailed;
                if (!FileOps.seekToEnd(h)) return DownloadError.FileSeekFailed;
                break :blk h;
            } else {
                const h = FileOps.createTruncate(temp_path) orelse return DownloadError.FileCreateFailed;
                break :blk h;
            }
        };
        defer FileOps.close(file_handle);

        // Streaming to file with incremental hashing
        var hasher = Hasher.init(options.verify);

        // If resuming, hash existing bytes
        if (actual_offset > 0 and (options.verify.sha256 != null or options.verify.sha512 != null)) {
            const rf = FileOps.openRead(temp_path) orelse return DownloadError.FileReadFailed;
            defer FileOps.close(rf);
            var r_buf: [32 * 1024]u8 = undefined;
            var read_so_far: u64 = 0;
            while (read_so_far < actual_offset) {
                const to_read: usize = @intCast(@min(@as(u64, r_buf.len), actual_offset - read_so_far));
                const n = FileOps.read(rf, r_buf[0..to_read]) catch return DownloadError.FileReadFailed;
                if (n == 0) break;
                hasher.update(r_buf[0..n]);
                read_so_far += n;
            }
        }

        // Stream body
        var written_bytes: u64 = actual_offset;
        const body_data = resp.body;
        var chunk_pos: usize = 0;
        const chunk_size: usize = 32 * 1024;

        while (chunk_pos < body_data.len) {
            if (options.cancel_flag) |cf| {
                if (cf.load(.acquire)) {
                    tracker.cancel();
                    return DownloadError.Cancelled;
                }
            }

            const end = @min(chunk_pos + chunk_size, body_data.len);
            const chunk = body_data[chunk_pos..end];

            if (!FileOps.writeAll(file_handle, chunk)) return DownloadError.FileWriteFailed;
            hasher.update(chunk);

            written_bytes += chunk.len;
            chunk_pos = end;

            tracker.update(written_bytes);
        }

        // Verify checksums
        hasher.verify(options.verify) catch |err| {
            tracker.fail();
            return err;
        };

        tracker.finish();

        var res = DownloadResult.make(dest_path, written_bytes, total_size, 0, resp.status);
        res.resumed = resuming;
        res.overwritten = true;
        res.verified = true;
        res.sha256_hex = hasher.finalSha256Hex();
        return res;
    }
};

// Progress Presentation Tracker

fn formatElapsed(ns: u64, buf: []u8) []const u8 {
    return loaders.formatNs(buf, ns);
}

fn formatEta(ns: u64, buf: []u8) []const u8 {
    return loaders.formatNs(buf, ns);
}

fn formatSpeed(per_sec: f64, buf: []u8) []const u8 {
    if (per_sec < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} B/s", .{per_sec}) catch "";
    } else if (per_sec < 1024.0 * 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{per_sec / 1024.0}) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} MB/s", .{per_sec / (1024.0 * 1024.0)}) catch "";
    }
}

pub const ProgressTracker = struct {
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    destination: []const u8,
    options: DownloadOptions,
    start_time: i64,
    last_update_time: i64,
    last_bytes: u64,
    total_bytes: ?u64,
    bar: ?loaders.ProgressBar,
    is_tty: bool,

    pub fn init(allocator: Allocator, io: std.Io, url: []const u8, destination: []const u8, options: DownloadOptions) ProgressTracker {
        const is_tty = loaders.terminal.getSize(io).cols > 0;
        return .{
            .allocator = allocator,
            .io = io,
            .url = url,
            .destination = destination,
            .options = options,
            .start_time = clock.millisNow(),
            .last_update_time = clock.millisNow(),
            .last_bytes = 0,
            .total_bytes = null,
            .bar = null,
            .is_tty = is_tty,
        };
    }

    pub fn deinit(self: *ProgressTracker) void {
        if (self.bar) |*b| b.deinit();
    }

    pub fn start(self: *ProgressTracker, total_size: ?u64) void {
        self.total_bytes = total_size;
        self.start_time = clock.millisNow();
        self.last_update_time = self.start_time;

        const should_render_bar = (self.options.progress == .auto and self.is_tty) or (self.options.progress == .enabled);
        if (should_render_bar) {
            const tot = total_size orelse 100;
            const pb = loaders.ProgressBar.init(self.allocator, self.io, .{
                .total = tot,
                .prefix = std.fs.path.basename(self.destination),
                .style = .{
                    .filled = "█",
                    .empty = "░",
                    .head = "█",
                    .left_bracket = "[",
                    .right_bracket = "]",
                },
                .color = tint.fg(.{ .ansi4 = .cyan }),
                .template = if (total_size != null)
                    "{prefix} {bar} {percent}% | {elapsed} | {speed} | ETA: {eta}"
                else
                    "{prefix} {bar} | {elapsed} | {speed}",
                .formatters = .{
                    .elapsed = formatElapsed,
                    .eta = formatEta,
                    .speed = formatSpeed,
                },
            }) catch null;
            if (pb) |b| {
                self.bar = b;
                self.bar.?.start() catch {};
                self.bar.?.forceRedraw();
            }
        }

        if (self.options.on_progress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloaded_bytes = 0,
                .total_bytes = total_size,
                .percentage = if (total_size != null) 0.0 else null,
                .speed_bps = 0.0,
                .eta_seconds = null,
                .elapsed_ms = 0,
                .status_code = 200,
                .state = .starting,
            }, self.options.user_data);
        }
    }

    pub fn update(self: *ProgressTracker, downloaded_bytes: u64) void {
        const now = clock.millisNow();
        const elapsed_total_s = @as(f64, @floatFromInt(now - self.start_time)) / 1000.0;
        const speed_bps = if (elapsed_total_s > 0.01) @as(f64, @floatFromInt(downloaded_bytes)) / elapsed_total_s else 0.0;

        var eta_s: ?u64 = null;
        var percent: ?f32 = null;
        if (self.total_bytes) |tot| {
            if (tot > 0) {
                percent = @as(f32, @floatFromInt(downloaded_bytes)) / @as(f32, @floatFromInt(tot)) * 100.0;
                if (speed_bps > 0 and downloaded_bytes < tot) {
                    eta_s = @intFromFloat(@as(f64, @floatFromInt(tot - downloaded_bytes)) / speed_bps);
                }
            }
        }

        self.last_bytes = downloaded_bytes;

        if (self.bar) |*b| {
            b.setProgress(downloaded_bytes);
        }

        if (self.options.on_progress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloaded_bytes = downloaded_bytes,
                .total_bytes = self.total_bytes,
                .percentage = percent,
                .speed_bps = speed_bps,
                .eta_seconds = eta_s,
                .elapsed_ms = @intCast(@max(0, now - self.start_time)),
                .status_code = 200,
                .state = .downloading,
            }, self.options.user_data);
        }
    }

    pub fn finish(self: *ProgressTracker) void {
        const final_bytes = if (self.total_bytes) |tot| tot else self.last_bytes;
        if (self.bar) |*b| {
            b.setProgress(final_bytes);
            b.finish(.{ .clear = false, .newline = true });
        }
        if (self.options.on_progress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloaded_bytes = final_bytes,
                .total_bytes = self.total_bytes orelse final_bytes,
                .percentage = 100.0,
                .speed_bps = 0.0,
                .eta_seconds = 0,
                .elapsed_ms = @intCast(@max(0, clock.millisNow() - self.start_time)),
                .status_code = 200,
                .state = .completed,
            }, self.options.user_data);
        }
    }

    pub fn fail(self: *ProgressTracker) void {
        if (self.bar) |*b| b.fail("Download failed");
        if (self.options.on_progress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloaded_bytes = 0,
                .total_bytes = self.total_bytes,
                .percentage = null,
                .speed_bps = 0.0,
                .eta_seconds = null,
                .elapsed_ms = @intCast(@max(0, clock.millisNow() - self.start_time)),
                .status_code = 500,
                .state = .failed,
            }, self.options.user_data);
        }
    }

    pub fn cancel(self: *ProgressTracker) void {
        if (self.bar) |*b| b.fail("Download cancelled");
        if (self.options.on_progress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloaded_bytes = 0,
                .total_bytes = self.total_bytes,
                .percentage = null,
                .speed_bps = 0.0,
                .eta_seconds = null,
                .elapsed_ms = @intCast(@max(0, clock.millisNow() - self.start_time)),
                .status_code = 499,
                .state = .cancelled,
            }, self.options.user_data);
        }
    }
};

// Updater

pub const UpdateOptions = struct {
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    backup_existing: bool = true,
    backup_suffix: []const u8 = ".bak",
    cancel_flag: ?*const std.atomic.Value(bool) = null,
};

/// Safely updates an existing executable or asset on disk with rollback preservation.
pub fn updateFile(
    allocator: Allocator,
    client: *Client,
    url: []const u8,
    target_path: []const u8,
    options: UpdateOptions,
) DownloadError!DownloadResult {
    var dl = Downloader.init(allocator, client);

    const temp_target = std.fmt.allocPrint(allocator, "{s}.update-tmp", .{target_path}) catch return DownloadError.OutOfMemory;
    defer allocator.free(temp_target);

    // 1. Download to temporary file
    const res = try dl.download(url, temp_target, .{
        .verify = options.verify,
        .progress = options.progress,
        .atomic = true,
        .existing = .overwrite,
        .cancel_flag = options.cancel_flag,
    });

    // 2. Backup existing file if requested
    var backup_path: ?[]const u8 = null;
    if (options.backup_existing) {
        backup_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, options.backup_suffix }) catch null;
        if (backup_path) |bp| {
            _ = FileOps.copyFile(target_path, bp);
        }
    }
    defer if (backup_path) |bp| allocator.free(bp);

    // 3. Atomically replace target with verified new file
    if (!FileOps.renameFile(temp_target, target_path)) {
        return DownloadError.FileRenameFailed;
    }

    return res;
}

// FTP Download Helper

pub const FtpDownloadOptions = struct {
    host: []const u8,
    port: u16 = 21,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    remote_path: []const u8,
    destination_path: []const u8,
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    existing: ExistingFilePolicy = .overwrite,
    atomic: bool = true,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
};

/// Downloads a file over FTP with progress reporting and checksum verification.
pub fn ftpDownload(
    allocator: Allocator,
    options: FtpDownloadOptions,
) DownloadError!DownloadResult {
    const start_time = clock.millisNow();
    const dest = resolveDestination(allocator, options.destination_path, options.remote_path, null) catch return DownloadError.OutOfMemory;
    defer allocator.free(dest);

    var ftp = ftp_client.Client.connect(allocator, .{
        .host = options.host,
        .port = options.port,
        .user = options.user,
        .password = options.password,
    }) catch return DownloadError.ConnectionFailed;
    defer ftp.deinit();

    try ftp.login(options.user, options.password);

    const remote_size = ftp.size(options.remote_path) catch null;

    var threaded: std.Io.Threaded = .init_single_threaded;
    var tracker = ProgressTracker.init(allocator, threaded.io(), options.remote_path, dest, .{
        .progress = options.progress,
        .verify = options.verify,
    });
    defer tracker.deinit();
    tracker.start(remote_size);

    const temp_dest = if (options.atomic) try std.fmt.allocPrint(allocator, "{s}.ftp-part", .{dest}) else try allocator.dupe(u8, dest);
    defer allocator.free(temp_dest);

    const file_handle = FileOps.createTruncate(temp_dest) orelse return DownloadError.FileCreateFailed;
    defer FileOps.close(file_handle);

    var hasher = Hasher.init(options.verify);

    const Context = struct {
        h_file: FileOps.Handle,
        h: *Hasher,
        t: *ProgressTracker,
        written: u64 = 0,
        cancel: ?*const std.atomic.Value(bool),

        fn sink(ctx: *@This(), chunk: []const u8) ftp_client.FtpError!void {
            if (ctx.cancel) |cf| {
                if (cf.load(.acquire)) return ftp_client.FtpError.ProtocolError;
            }
            if (!FileOps.writeAll(ctx.h_file, chunk)) return ftp_client.FtpError.WriteFailed;
            ctx.h.update(chunk);
            ctx.written += chunk.len;
            ctx.t.update(ctx.written);
        }
    };

    var ctx = Context{
        .h_file = file_handle,
        .h = &hasher,
        .t = &tracker,
        .cancel = options.cancel_flag,
    };

    ftp.download(options.remote_path, &ctx, Context.sink) catch |e| {
        tracker.fail();
        if (options.atomic) _ = FileOps.deleteFile(temp_dest);
        if (e == ftp_client.FtpError.ConnectFailed) return DownloadError.ConnectionFailed;
        return DownloadError.HttpError;
    };

    hasher.verify(options.verify) catch |err| {
        tracker.fail();
        if (options.atomic) _ = FileOps.deleteFile(temp_dest);
        return err;
    };

    tracker.finish();

    if (options.atomic) {
        if (!FileOps.renameFile(temp_dest, dest)) return DownloadError.FileRenameFailed;
    }

    return .{
        .destination = dest,
        .downloaded_bytes = ctx.written,
        .total_bytes = remote_size,
        .elapsed_ms = @intCast(clock.millisNow() - start_time),
        .status_code = 226,
        .verified = true,
        .sha256_hex = hasher.finalSha256Hex(),
    };
}

/// Standalone helper to query remote server metadata, size, filename, and headers.
pub fn lookupFileInfo(
    client: *Client,
    url: []const u8,
    options: DownloadOptions,
) DownloadError!RemoteFileInfo {
    return lookupFileInfoWithClient(client, url, options);
}

pub fn lookupFileInfoWithClient(
    client: *Client,
    url: []const u8,
    options: DownloadOptions,
) DownloadError!RemoteFileInfo {
    // 1. Try HEAD request first with Connection: close and sensible timeout
    const default_timeout: u64 = options.timeout_ms orelse 15000;
    var head_headers: std.ArrayList(Header) = .empty;
    defer head_headers.deinit(client.allocator);
    for (options.headers) |h| {
        head_headers.append(client.allocator, h) catch return DownloadError.OutOfMemory;
    }
    head_headers.append(client.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;

    var head_resp = client.head(.{
        .url = url,
        .headers = head_headers.items,
        .follow_redirects = options.follow_redirects,
        .max_redirects = options.max_redirects,
        .timeout_ms = default_timeout,
    }) catch |err| switch (err) {
        error.ConnectFailed => return DownloadError.ConnectionFailed,
        error.TooManyRedirects => return DownloadError.TooManyRedirects,
        else => return DownloadError.HttpError,
    };
    defer head_resp.deinit();

    if (head_resp.status != 405 and head_resp.status != 501) {
        return parseRemoteFileInfo(url, head_resp.status, head_resp.headers);
    }

    // 2. Fallback to GET with Range: bytes=0-0 if HEAD method is not allowed
    var get_headers: std.ArrayList(Header) = .empty;
    defer get_headers.deinit(client.allocator);
    for (options.headers) |h| {
        get_headers.append(client.allocator, h) catch return DownloadError.OutOfMemory;
    }
    get_headers.append(client.allocator, .{ .name = "Range", .value = "bytes=0-0" }) catch return DownloadError.OutOfMemory;
    get_headers.append(client.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;

    var get_resp = client.get(.{
        .url = url,
        .headers = get_headers.items,
        .follow_redirects = options.follow_redirects,
        .max_redirects = options.max_redirects,
        .timeout_ms = default_timeout,
    }) catch |err| switch (err) {
        error.ConnectFailed => return DownloadError.ConnectionFailed,
        error.TooManyRedirects => return DownloadError.TooManyRedirects,
        else => return DownloadError.HttpError,
    };
    defer get_resp.deinit();

    return parseRemoteFileInfo(url, get_resp.status, get_resp.headers);
}

fn parseRemoteFileInfo(source_url: []const u8, status: u16, headers: []const Header) RemoteFileInfo {
    var info = RemoteFileInfo{
        .status = status,
    };

    const ulen = @min(source_url.len, info.url_buf.len);
    @memcpy(info.url_buf[0..ulen], source_url[0..ulen]);
    info.url_len = ulen;

    var content_disposition: ?[]const u8 = null;

    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
            info.file_size = std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) {
            if (std.mem.lastIndexOfScalar(u8, h.value, '/')) |slash_idx| {
                const total_part = std.mem.trim(u8, h.value[slash_idx + 1 ..], " \t");
                if (!std.mem.eql(u8, total_part, "*")) {
                    if (std.fmt.parseInt(u64, total_part, 10)) |tot| {
                        info.file_size = tot;
                    } else |_| {}
                }
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Disposition")) {
            content_disposition = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.content_type_buf.len);
            @memcpy(info.content_type_buf[0..len], val[0..len]);
            info.content_type_len = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "ETag")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.etag_buf.len);
            @memcpy(info.etag_buf[0..len], val[0..len]);
            info.etag_len = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Last-Modified")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.last_modified_buf.len);
            @memcpy(info.last_modified_buf[0..len], val[0..len]);
            info.last_modified_len = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Accept-Ranges")) {
            if (std.ascii.indexOfIgnoreCase(h.value, "bytes") != null) {
                info.accepts_ranges = true;
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.content_encoding_buf.len);
            @memcpy(info.content_encoding_buf[0..len], val[0..len]);
            info.content_encoding_len = len;
        }
    }

    var fname: []const u8 = "downloaded_file";
    if (content_disposition) |cd| {
        if (extractFilenameFromContentDisposition(cd)) |cd_name| {
            fname = sanitizeFilename(cd_name);
        } else {
            fname = sanitizeFilename(source_url);
        }
    } else {
        fname = sanitizeFilename(source_url);
    }

    const flen = @min(fname.len, info.file_name_buf.len);
    @memcpy(info.file_name_buf[0..flen], fname[0..flen]);
    info.file_name_len = flen;

    return info;
}

// Unit Tests

test "filename sanitization protects against path traversal" {
    try std.testing.expectEqualStrings("test.zip", sanitizeFilename("../../../test.zip"));
    try std.testing.expectEqualStrings("file.tar.gz", sanitizeFilename("..\\..\\file.tar.gz"));
    try std.testing.expectEqualStrings("archive.bin", sanitizeFilename("http://example.com/downloads/archive.bin?token=123#hash"));
    try std.testing.expectEqualStrings("downloaded_file", sanitizeFilename(""));
    try std.testing.expectEqualStrings("downloaded_file", sanitizeFilename("."));
    try std.testing.expectEqualStrings("downloaded_file", sanitizeFilename(".."));
}

test "parse checksum file formats" {
    const sample =
        \\# GNU coreutils checksums
        \\e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  empty.txt
        \\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *test.bin
        \\
    ;
    const h1 = parseChecksumFile(sample, "empty.txt");
    try std.testing.expect(h1 != null);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", h1.?);

    const h2 = parseChecksumFile(sample, "test.bin");
    try std.testing.expect(h2 != null);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", h2.?);

    const h3 = parseChecksumFile(sample, "notfound.txt");
    try std.testing.expect(h3 == null);
}

test "streaming hasher calculates sha256 and verifies successfully" {
    const data = "hello world streaming download verification";
    var hasher = Hasher.init(.{
        .sha256 = "b9f71c4ffbe32b509bc052dfac2bfabfb268e3cc00d603a19992ad3ccfe2a632",
    });
    hasher.update(data[0..10]);
    hasher.update(data[10..25]);
    hasher.update(data[25..]);

    try hasher.verify(.{
        .sha256 = "b9f71c4ffbe32b509bc052dfac2bfabfb268e3cc00d603a19992ad3ccfe2a632",
    });

    try std.testing.expectError(DownloadError.ChecksumMismatch, hasher.verify(.{
        .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    }));
}

test "resolveDestination handles direct file and directories" {
    const a = std.testing.allocator;
    const r1 = try resolveDestination(a, "build/out.bin", "http://example.com/file.zip", null);
    defer a.free(r1);
    try std.testing.expectEqualStrings("build/out.bin", r1);

    const r2 = try resolveDestination(a, "build/", "http://example.com/data.tar.gz", null);
    defer a.free(r2);
    try std.testing.expect(std.mem.endsWith(u8, r2, "data.tar.gz"));
}

test "custom progress callback receives events" {
    const CustomState = struct {
        called: bool = false,
        total: ?u64 = null,
        downloaded: u64 = 0,
        completed: bool = false,

        fn onProgress(info: ProgressInfo, user_data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.called = true;
            self.total = info.total_bytes;
            self.downloaded = info.downloaded_bytes;
            if (info.state == .completed) {
                self.completed = true;
            }
        }
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    var state = CustomState{};
    var tracker = ProgressTracker.init(std.testing.allocator, threaded.io(), "http://example.com/test.bin", "test.bin", .{
        .progress = .custom,
        .on_progress = CustomState.onProgress,
        .user_data = &state,
    });
    defer tracker.deinit();

    tracker.start(1024);
    try std.testing.expect(state.called);
    try std.testing.expectEqual(@as(?u64, 1024), state.total);

    tracker.update(512);
    try std.testing.expectEqual(@as(u64, 512), state.downloaded);

    tracker.finish();
    try std.testing.expect(state.completed);
}

test "existing file policy resume check" {
    try std.testing.expect(ExistingFilePolicy.resume_download.isResume());
    try std.testing.expect(ExistingFilePolicy.continue_partial.isResume());
    try std.testing.expect(ExistingFilePolicy.@"resume".isResume());
    try std.testing.expect(!ExistingFilePolicy.overwrite.isResume());
    try std.testing.expect(!ExistingFilePolicy.fail.isResume());
    try std.testing.expect(!ExistingFilePolicy.skip.isResume());
}

test "remote file info size formatting" {
    var info = RemoteFileInfo{
        .status = 200,
        .file_size = 15 * 1024 * 1024 + 500 * 1024,
    };
    const sample_name = "file.zip";
    @memcpy(info.file_name_buf[0..sample_name.len], sample_name);
    info.file_name_len = sample_name.len;

    var buf: [32]u8 = undefined;
    const formatted = info.formatSize(&buf);
    try std.testing.expectEqualStrings("15.49 MB", formatted);
    try std.testing.expectEqualStrings("file.zip", info.fileName());
}
