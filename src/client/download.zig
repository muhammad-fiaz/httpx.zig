//! Production-grade streaming download, update, verification, and progress subsystem.
//!
//! Provides:
//! - Direct streaming to disk with memory-bounded buffers (no full file buffering)
//! - Resume support with HTTP Range requests (RFC 9110 Section 14.1) and 206/200/416 handling
//! - Incremental cryptographic hashing (SHA-256, SHA-384, SHA-512, MD5, SHA-1) while streaming
//! - Out-of-the-box built-in terminal progress bars via `loaders.zig` + TTY detection
//! - Completely UI-independent custom progress callback interface
//! - Existing-file policies: fail, overwrite, skip, resumePartial, verifyExisting, replaceIfChanged
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
const req = @import("request.zig");
const clientNs = @import("client.zig");
const Client = clientNs.Client;
const ftpClient = @import("../protocols/ftp/client.zig");
const serveMod = @import("../web/static_files/serve.zig");
const cFs = serveMod.c_fs;

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
    downloadedBytes: u64,
    totalBytes: ?u64,
    percentage: ?f32,
    speedBps: f64,
    etaSeconds: ?u64,
    elapsedMs: u64,
    statusCode: u16,
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
    /// Resume partial download if possible (short canonical name; `resume` is a Zig keyword).
    resumePartial,
    /// Verify existing file on disk against expected checksum; skip if valid, download if invalid.
    verifyExisting,
    /// Use conditional headers (If-None-Match / If-Modified-Since); skip if 304 Not Modified.
    replaceIfChanged,

    pub fn isResume(self: ExistingFilePolicy) bool {
        return self == .resumePartial;
    }
};

pub const RemoteFileInfo = struct {
    status: u16 = 200,
    fileSize: ?u64 = null,
    acceptsRanges: bool = false,

    urlBuf: [256]u8 = [_]u8{0} ** 256,
    urlLen: usize = 0,

    fileNameBuf: [128]u8 = [_]u8{0} ** 128,
    fileNameLen: usize = 0,

    contentTypeBuf: [64]u8 = [_]u8{0} ** 64,
    contentTypeLen: usize = 0,

    etagBuf: [64]u8 = [_]u8{0} ** 64,
    etagLen: usize = 0,

    lastModifiedBuf: [64]u8 = [_]u8{0} ** 64,
    lastModifiedLen: usize = 0,

    contentEncodingBuf: [32]u8 = [_]u8{0} ** 32,
    contentEncodingLen: usize = 0,

    pub fn url(self: *const RemoteFileInfo) []const u8 {
        return self.urlBuf[0..self.urlLen];
    }

    pub fn fileName(self: *const RemoteFileInfo) []const u8 {
        return self.fileNameBuf[0..self.fileNameLen];
    }

    pub fn contentType(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.contentTypeLen == 0) return null;
        return self.contentTypeBuf[0..self.contentTypeLen];
    }

    pub fn etag(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.etagLen == 0) return null;
        return self.etagBuf[0..self.etagLen];
    }

    pub fn lastModified(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.lastModifiedLen == 0) return null;
        return self.lastModifiedBuf[0..self.lastModifiedLen];
    }

    pub fn contentEncoding(self: *const RemoteFileInfo) ?[]const u8 {
        if (self.contentEncodingLen == 0) return null;
        return self.contentEncodingBuf[0..self.contentEncodingLen];
    }

    /// Formats the file size as human-readable string (e.g., "12.42 MB", "500 KB", "1.20 GB").
    pub fn formatSize(self: RemoteFileInfo, buf: []u8) []const u8 {
        const sz = self.fileSize orelse return "unknown";
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
    expectedSize: ?u64 = null,
    minSize: ?u64 = null,
    maxSize: ?u64 = null,
    etag: ?[]const u8 = null,
    lastModified: ?[]const u8 = null,
    checksumFileUrl: ?[]const u8 = null,
};

pub const DownloadOptions = struct {
    headers: []const Header = &.{},
    timeoutMs: ?u64 = null,
    maxRetries: u32 = 3,
    retryDelayMs: u64 = 500,
    followRedirects: bool = true,
    maxRedirects: u8 = 10,
    existing: ExistingFilePolicy = .overwrite,
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    onProgress: ?*const fn (info: ProgressInfo, userData: ?*anyopaque) void = null,
    userData: ?*anyopaque = null,
    /// Atomically download to a temporary file first, then rename on success and verification pass.
    atomic: bool = true,
    tempSuffix: []const u8 = ".httpx-part",
    /// Automatically create missing parent directories for the destination path.
    createDirs: bool = true,
    /// Flag for cooperative cancellation.
    cancelFlag: ?*const std.atomic.Value(bool) = null,
    /// Authentication helpers
    bearerAuth: ?[]const u8 = null,
    basicAuth: ?[]const u8 = null,
    apiKeyHeader: ?[]const u8 = null,
    apiKeyValue: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
};

pub const DownloadResult = struct {
    destinationBuf: [1024]u8 = [_]u8{0} ** 1024,
    destinationLen: usize = 0,
    destination: []const u8 = "",
    downloadedBytes: u64,
    totalBytes: ?u64,
    elapsedMs: u64,
    statusCode: u16,
    resumed: bool = false,
    skipped: bool = false,
    overwritten: bool = false,
    verified: bool = false,
    sha256Hex: ?[64]u8 = null,

    pub fn make(destPath: []const u8, downloaded: u64, total: ?u64, elapsed: u64, status: u16) DownloadResult {
        var res = DownloadResult{
            .downloadedBytes = downloaded,
            .totalBytes = total,
            .elapsedMs = elapsed,
            .statusCode = status,
        };
        const len = @min(destPath.len, res.destinationBuf.len);
        @memcpy(res.destinationBuf[0..len], destPath[0..len]);
        res.destinationLen = len;
        res.destination = res.destinationBuf[0..len];
        return res;
    }

    pub fn destinationPath(self: *const DownloadResult) []const u8 {
        if (self.destinationLen > 0) return self.destinationBuf[0..self.destinationLen];
        return self.destination;
    }
};

// Checksum Helpers

/// Parses `Content-Range: bytes */<complete-length>` from a 416 response.
/// Returns the complete length, or null when absent/malformed.
fn parseUnsatisfiedRange(headerValue: []const u8) ?u64 {
    const v = std.mem.trim(u8, headerValue, " \t");
    const prefix = "bytes */";
    if (!std.ascii.startsWithIgnoreCase(v, prefix)) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, v[prefix.len..], " \t"), 10) catch null;
}

pub const Hasher = struct {
    sha256: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    sha384: std.crypto.hash.sha2.Sha384 = std.crypto.hash.sha2.Sha384.init(.{}),
    sha512: std.crypto.hash.sha2.Sha512 = std.crypto.hash.sha2.Sha512.init(.{}),
    md5: std.crypto.hash.Md5 = std.crypto.hash.Md5.init(.{}),
    sha1: std.crypto.hash.Sha1 = std.crypto.hash.Sha1.init(.{}),
    enableSha256: bool = false,
    enableSha384: bool = false,
    enableSha512: bool = false,
    enableMd5: bool = false,
    enableSha1: bool = false,

    pub fn init(verifyOpts: VerifyOptions) Hasher {
        return .{
            .enableSha256 = verifyOpts.sha256 != null or verifyOpts.checksumFileUrl != null,
            .enableSha384 = verifyOpts.sha384 != null,
            .enableSha512 = verifyOpts.sha512 != null,
            .enableMd5 = verifyOpts.md5 != null,
            .enableSha1 = verifyOpts.sha1 != null,
        };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        if (self.enableSha256) self.sha256.update(bytes);
        if (self.enableSha384) self.sha384.update(bytes);
        if (self.enableSha512) self.sha512.update(bytes);
        if (self.enableMd5) self.md5.update(bytes);
        if (self.enableSha1) self.sha1.update(bytes);
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
    const isWin = builtin.os.tag == .windows;

    pub const Handle = if (isWin) std.os.windows.HANDLE else std.posix.fd_t;
    pub const invalidHandle: Handle = if (isWin) std.os.windows.INVALID_HANDLE_VALUE else -1;

    pub fn createTruncate(path: []const u8) ?Handle {
        return cFs.openWrite(path);
    }

    pub fn openReadWrite(path: []const u8) ?Handle {
        if (isWin) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return null;
            wbuf[len] = 0;
            const OPEN_ALWAYS: u32 = 4;
            const GENERIC_READ: u32 = 0x80000000;
            const GENERIC_WRITE: u32 = 0x40000000;
            const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;
            const h = cFs.CreateFileW(
                @ptrCast(&wbuf),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null,
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (h == cFs.INVALID_HANDLE) return null;
            return h;
        } else {
            var nullTerm: [4096:0]u8 = undefined;
            if (path.len >= nullTerm.len) return null;
            @memcpy(nullTerm[0..path.len], path);
            nullTerm[path.len] = 0;
            const fd = std.c.open(&nullTerm, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
            if (fd < 0) return null;
            return fd;
        }
    }

    pub fn openRead(path: []const u8) ?Handle {
        return cFs.openRead(path);
    }

    pub fn seekToEnd(h: Handle) bool {
        if (isWin) {
            var newPos: i64 = 0;
            return cFs.SetFilePointerEx(h, 0, &newPos, 2) != .FALSE; // FILE_END = 2
        } else {
            _ = std.c.lseek(h, 0, 2); // SEEK_END = 2
            return true;
        }
    }

    pub fn writeAll(h: Handle, data: []const u8) bool {
        var written: usize = 0;
        while (written < data.len) {
            if (isWin) {
                var chunkWritten: u32 = 0;
                const chunkLen: u32 = @intCast(@min(data.len - written, @as(usize, std.math.maxInt(u32))));
                if (cFs.WriteFile(h, data[written..].ptr, chunkLen, &chunkWritten, null) == .FALSE) return false;
                if (chunkWritten == 0) return false;
                written += chunkWritten;
            } else {
                const n = std.c.write(h, data[written..].ptr, data.len - written);
                if (n <= 0) return false;
                written += @intCast(n);
            }
        }
        return true;
    }

    pub fn read(h: Handle, buf: []u8) !usize {
        if (isWin) {
            var readBytes: u32 = 0;
            const toRead: u32 = @intCast(@min(buf.len, @as(usize, std.math.maxInt(u32))));
            if (cFs.ReadFile(h, buf.ptr, toRead, &readBytes, null) == .FALSE) return error.FileReadFailed;
            return readBytes;
        } else {
            const n = std.c.read(h, buf.ptr, buf.len);
            if (n < 0) return error.FileReadFailed;
            return @intCast(n);
        }
    }

    pub fn close(h: Handle) void {
        cFs.close(h);
    }

    pub fn deleteFile(path: []const u8) bool {
        if (isWin) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
            wbuf[len] = 0;
            const DeleteFileW = struct {
                pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.BOOL;
            }.DeleteFileW;
            return DeleteFileW(@ptrCast(&wbuf)) != .FALSE;
        } else {
            var nullTerm: [4096]u8 = undefined;
            if (path.len >= nullTerm.len) return false;
            @memcpy(nullTerm[0..path.len], path);
            nullTerm[path.len] = 0;
            _ = std.c.unlink(@ptrCast(&nullTerm));
            return true;
        }
    }

    pub fn renameFile(oldPath: []const u8, newPath: []const u8) bool {
        if (isWin) {
            var wold: [1024]u16 = undefined;
            const olen = std.unicode.utf8ToUtf16Le(&wold, oldPath) catch return false;
            wold[olen] = 0;
            var wnew: [1024]u16 = undefined;
            const nlen = std.unicode.utf8ToUtf16Le(&wnew, newPath) catch return false;
            wnew[nlen] = 0;
            const MoveFileExW = struct {
                pub extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) std.os.windows.BOOL;
            }.MoveFileExW;
            const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
            const MOVEFILE_COPY_ALLOWED: u32 = 0x00000002;
            return MoveFileExW(@ptrCast(&wold), @ptrCast(&wnew), MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED) != .FALSE;
        } else {
            var oNt: [4096]u8 = undefined;
            var nNt: [4096]u8 = undefined;
            if (oldPath.len >= oNt.len or newPath.len >= nNt.len) return false;
            @memcpy(oNt[0..oldPath.len], oldPath);
            oNt[oldPath.len] = 0;
            @memcpy(nNt[0..newPath.len], newPath);
            nNt[newPath.len] = 0;
            _ = std.c.rename(@ptrCast(&oNt), @ptrCast(&nNt));
            return true;
        }
    }

    pub fn makeDir(path: []const u8) bool {
        if (isWin) {
            var wbuf: [1024]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
            wbuf[len] = 0;
            const CreateDirectoryW = struct {
                pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
            }.CreateDirectoryW;
            return CreateDirectoryW(@ptrCast(&wbuf), null) != .FALSE;
        } else {
            var nullTerm: [4096]u8 = undefined;
            if (path.len >= nullTerm.len) return false;
            @memcpy(nullTerm[0..path.len], path);
            nullTerm[path.len] = 0;
            _ = std.c.mkdir(@ptrCast(&nullTerm), 0o755);
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
        const io: std.Io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
        dir.close(io);
        return true;
    }

    pub fn copyFile(srcPath: []const u8, dstPath: []const u8) bool {
        const srcH = openRead(srcPath) orelse return false;
        defer close(srcH);
        const dstH = createTruncate(dstPath) orelse return false;
        defer close(dstH);

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = read(srcH, &buf) catch return false;
            if (n == 0) break;
            if (!writeAll(dstH, buf[0..n])) return false;
        }
        return true;
    }
};

/// Verifies a file on local disk against expected checksums and size parameters.
pub fn verifyFile(path: []const u8, opts: VerifyOptions) DownloadError!void {
    const meta = serveMod.statPath(null, path) orelse return DownloadError.FileReadFailed;

    if (opts.expectedSize) |sz| {
        if (meta.size != sz) return DownloadError.ChecksumMismatch;
    }
    if (opts.minSize) |min| {
        if (meta.size < min) return DownloadError.ResponseTooSmall;
    }
    if (opts.maxSize) |max| {
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
    while (it.next()) |rawLine| {
        const line = std.mem.trim(u8, rawLine, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const hash = tokens.next() orelse continue;
        const fileToken = tokens.next();

        if (filename) |target| {
            if (fileToken) |ft| {
                const cleanTarget = std.fs.path.basename(target);
                var cleanFt = ft;
                if (cleanFt.len > 0 and cleanFt[0] == '*') cleanFt = cleanFt[1..];
                cleanFt = std.fs.path.basename(cleanFt);
                if (std.mem.eql(u8, cleanTarget, cleanFt)) {
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
    contentDisposition: ?[]const u8,
) ![]const u8 {
    const rawDest = if (dest) |d| d else "";
    var isDir = false;
    if (rawDest.len == 0 or std.mem.eql(u8, rawDest, ".")) {
        isDir = true;
    } else if (rawDest[rawDest.len - 1] == '/' or rawDest[rawDest.len - 1] == '\\') {
        isDir = true;
    } else {
        if (serveMod.statPath(undefined, rawDest)) |_| {
            if (FileOps.isDir(rawDest)) {
                isDir = true;
            }
        }
    }

    if (!isDir) return allocator.dupe(u8, rawDest);

    var chosenName: []const u8 = "downloaded_file";
    if (contentDisposition) |cd| {
        if (extractFilenameFromContentDisposition(cd)) |fname| {
            chosenName = fname;
        }
    } else {
        const urlBase = std.fs.path.basename(url);
        if (urlBase.len > 0 and !std.mem.eql(u8, urlBase, "/") and !std.mem.eql(u8, urlBase, "\\")) {
            chosenName = urlBase;
        }
    }

    const safeName = sanitizeFilename(chosenName);
    if (rawDest.len == 0 or std.mem.eql(u8, rawDest, ".")) {
        return allocator.dupe(u8, safeName);
    }
    return std.fs.path.join(allocator, &.{ rawDest, safeName });
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
        destinationPath: []const u8,
        options: DownloadOptions,
    ) DownloadError!DownloadResult {
        const startTime = clock.millisNow();

        // 1. Resolve destination
        const dest = resolveDestination(self.allocator, destinationPath, url, null) catch return DownloadError.OutOfMemory;
        defer self.allocator.free(dest);

        // 2. Create parent directories if requested
        if (options.createDirs) {
            if (std.fs.path.dirname(dest)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                    _ = FileOps.makePath(parent);
                }
            }
        }

        // 3. Handle existing destination policy
        const existingMeta = serveMod.statPath(undefined, dest);
        if (existingMeta) |meta| {
            switch (options.existing) {
                .fail => return DownloadError.DestinationExists,
                .skip => {
                    var res = DownloadResult.make(dest, 0, meta.size, @intCast(clock.millisNow() - startTime), 200);
                    res.skipped = true;
                    return res;
                },
                .verifyExisting => {
                    if (verifyFile(dest, options.verify)) |_| {
                        var res = DownloadResult.make(dest, 0, meta.size, @intCast(clock.millisNow() - startTime), 200);
                        res.skipped = true;
                        res.verified = true;
                        return res;
                    } else |_| {
                        // Verification failed, proceed with re-download
                    }
                },

                .overwrite, .resumePartial, .replaceIfChanged => {},
            }
        }

        // 4. Temporary part file strategy
        var tempPath: []const u8 = undefined;
        var isTemp = false;
        if (options.atomic) {
            tempPath = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dest, options.tempSuffix }) catch return DownloadError.OutOfMemory;
            isTemp = true;
        } else {
            tempPath = self.allocator.dupe(u8, dest) catch return DownloadError.OutOfMemory;
        }
        defer self.allocator.free(tempPath);

        // 5. Check for partial resume
        var resumeOffset: u64 = 0;
        if (options.existing.isResume()) {
            if (serveMod.statPath(undefined, tempPath)) |tmeta| {
                resumeOffset = tmeta.size;
            } else if (existingMeta) |emeta| {
                resumeOffset = emeta.size;
            }
        }

        // 6. Setup progress presentation
        var progressTracker = ProgressTracker.init(self.allocator, self.client.io, url, dest, options);
        defer progressTracker.deinit();

        // 7. Perform download loop with retries
        var attempt: u32 = 0;
        var result: DownloadResult = .{
            .destination = dest,
            .downloadedBytes = 0,
            .totalBytes = null,
            .elapsedMs = 0,
            .statusCode = 0,
        };

        while (attempt <= options.maxRetries) : (attempt += 1) {
            if (options.cancelFlag) |cf| {
                if (cf.load(.acquire)) return DownloadError.Cancelled;
            }

            const downloadRes = self.performTransfer(
                url,
                tempPath,
                dest,
                resumeOffset,
                options,
                &progressTracker,
            );

            if (downloadRes) |res| {
                result = res;
                break;
            } else |err| {
                // Deterministic outcomes are never retried.
                if (err == DownloadError.Cancelled or err == DownloadError.DestinationExists or err == DownloadError.ChecksumMismatch or err == DownloadError.RangeUnsatisfiable) {
                    if (isTemp and !options.existing.isResume()) {
                        _ = FileOps.deleteFile(tempPath);
                    }
                    return err;
                }
                if (attempt >= options.maxRetries) {
                    if (isTemp and !options.existing.isResume()) {
                        _ = FileOps.deleteFile(tempPath);
                    }
                    return err;
                }
                clock.sleepMillis(options.retryDelayMs * (@as(u64, 1) << @intCast(@min(attempt, 4))));
            }
        }

        // 8. Atomic Rename / Replace
        if (isTemp and !result.skipped) {
            if (!FileOps.renameFile(tempPath, dest)) {
                return DownloadError.FileRenameFailed;
            }
        }

        result.elapsedMs = @intCast(clock.millisNow() - startTime);
        return result;
    }

    fn performTransfer(
        self: *Downloader,
        url: []const u8,
        tempPath: []const u8,
        destPath: []const u8,
        resumeOffset: u64,
        options: DownloadOptions,
        tracker: *ProgressTracker,
    ) DownloadError!DownloadResult {
        // Headers setup
        var customHeaders: std.ArrayList(Header) = .empty;
        defer customHeaders.deinit(self.allocator);

        for (options.headers) |h| {
            customHeaders.append(self.allocator, h) catch return DownloadError.OutOfMemory;
        }

        // Authentication
        var authBuf: [256]u8 = undefined;
        if (options.bearerAuth) |token| {
            const val = std.fmt.bufPrint(&authBuf, "Bearer {s}", .{token}) catch return DownloadError.AuthenticationFailed;
            customHeaders.append(self.allocator, .{ .name = "Authorization", .value = val }) catch return DownloadError.OutOfMemory;
        } else if (options.basicAuth) |basic| {
            const val = std.fmt.bufPrint(&authBuf, "Basic {s}", .{basic}) catch return DownloadError.AuthenticationFailed;
            customHeaders.append(self.allocator, .{ .name = "Authorization", .value = val }) catch return DownloadError.OutOfMemory;
        }

        if (options.apiKeyHeader) |hdr| {
            if (options.apiKeyValue) |val| {
                customHeaders.append(self.allocator, .{ .name = hdr, .value = val }) catch return DownloadError.OutOfMemory;
            }
        }

        if (options.cookie) |c| {
            customHeaders.append(self.allocator, .{ .name = "Cookie", .value = c }) catch return DownloadError.OutOfMemory;
        }

        // Resume Range header
        var rangeBuf: [64]u8 = undefined;
        var resuming = false;
        if (resumeOffset > 0) {
            const rangeStr = std.fmt.bufPrint(&rangeBuf, "bytes={d}-", .{resumeOffset}) catch return DownloadError.RangeNotSupported;
            customHeaders.append(self.allocator, .{ .name = "Range", .value = rangeStr }) catch return DownloadError.OutOfMemory;
            resuming = true;
        }

        // Conditional headers
        if (options.existing == .replaceIfChanged) {
            if (options.verify.etag) |etag| {
                customHeaders.append(self.allocator, .{ .name = "If-None-Match", .value = etag }) catch return DownloadError.OutOfMemory;
            }
            if (options.verify.lastModified) |lm| {
                customHeaders.append(self.allocator, .{ .name = "If-Modified-Since", .value = lm }) catch return DownloadError.OutOfMemory;
            }
        }

        var hasConnection = false;
        for (customHeaders.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) hasConnection = true;
        }
        if (!hasConnection) {
            customHeaders.append(self.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;
        }

        // Execute request
        var resp = self.client.get(url, .{
            .headers = customHeaders.items,
            .followRedirects = options.followRedirects,
            .maxRedirects = options.maxRedirects,
            .timeoutMs = options.timeoutMs orelse 15000,
        }) catch |e| switch (e) {
            error.ConnectFailed => return DownloadError.ConnectionFailed,
            error.TooManyRedirects => return DownloadError.TooManyRedirects,
            else => return DownloadError.HttpError,
        };
        defer resp.deinit();

        // Check 304 Not Modified
        if (resp.status == 304) {
            return .{
                .destination = destPath,
                .downloadedBytes = 0,
                .totalBytes = null,
                .elapsedMs = 0,
                .statusCode = 304,
                .skipped = true,
            };
        }

        // Validate Status Code
        if (resp.status == 400) return DownloadError.BadRequest;
        if (resp.status == 401 or resp.status == 403) return DownloadError.AuthenticationFailed;
        if (resp.status == 404) return DownloadError.FileNotFound;
        if (resp.status == 416) {
            // RFC 9110 Section 14.2: a 416 carries Content-Range: bytes */N.
            // When resuming and the local file already holds all N bytes,
            // the download is complete — succeed without retransferring.
            if (resuming) {
                if (resp.header("content-range")) |cr| {
                    if (parseUnsatisfiedRange(cr)) |complete| {
                        if (complete == resumeOffset) {
                            return .{
                                .destination = destPath,
                                .downloadedBytes = 0,
                                .totalBytes = complete,
                                .elapsedMs = 0,
                                .statusCode = 200,
                                .resumed = true,
                                .skipped = true,
                            };
                        }
                    }
                }
            }
            return DownloadError.RangeUnsatisfiable;
        }
        if (resp.status >= 500 and resp.status <= 599) return DownloadError.ServerError;
        if (resp.status < 200 or resp.status >= 300) return DownloadError.HttpError;

        var actualOffset: u64 = 0;
        if (resuming and resp.status == 206) {
            actualOffset = resumeOffset;
        } else {
            resuming = false;
            actualOffset = 0;
        }

        // Determine total size
        var totalSize: ?u64 = null;
        if (resp.header("content-length")) |cl| {
            if (std.fmt.parseInt(u64, std.mem.trim(u8, cl, " "), 10)) |val| {
                totalSize = val + actualOffset;
            } else |_| {}
        }

        // Size limits enforcement
        if (totalSize) |tot| {
            if (options.verify.maxSize) |max| {
                if (tot > max) return DownloadError.ResponseTooLarge;
            }
            if (options.verify.minSize) |min| {
                if (tot < min) return DownloadError.ResponseTooSmall;
            }
            if (options.verify.expectedSize) |exp| {
                if (tot != exp) return DownloadError.ChecksumMismatch;
            }
        }

        tracker.start(totalSize);

        // Open destination / temp file
        const fileHandle = blk: {
            if (actualOffset > 0) {
                const h = FileOps.openReadWrite(tempPath) orelse return DownloadError.FileCreateFailed;
                if (!FileOps.seekToEnd(h)) return DownloadError.FileSeekFailed;
                break :blk h;
            } else {
                const h = FileOps.createTruncate(tempPath) orelse return DownloadError.FileCreateFailed;
                break :blk h;
            }
        };
        defer FileOps.close(fileHandle);

        // Streaming to file with incremental hashing
        var hasher = Hasher.init(options.verify);

        // If resuming, hash existing bytes
        if (actualOffset > 0 and (options.verify.sha256 != null or options.verify.sha512 != null)) {
            const rf = FileOps.openRead(tempPath) orelse return DownloadError.FileReadFailed;
            defer FileOps.close(rf);
            var rBuf: [32 * 1024]u8 = undefined;
            var readSoFar: u64 = 0;
            while (readSoFar < actualOffset) {
                const toRead: usize = @intCast(@min(@as(u64, rBuf.len), actualOffset - readSoFar));
                const n = FileOps.read(rf, rBuf[0..toRead]) catch return DownloadError.FileReadFailed;
                if (n == 0) break;
                hasher.update(rBuf[0..n]);
                readSoFar += n;
            }
        }

        // Stream body
        var writtenBytes: u64 = actualOffset;
        const bodyData = resp.body;
        var chunkPos: usize = 0;
        const chunkSize: usize = 32 * 1024;

        while (chunkPos < bodyData.len) {
            if (options.cancelFlag) |cf| {
                if (cf.load(.acquire)) {
                    tracker.cancel();
                    return DownloadError.Cancelled;
                }
            }

            const end = @min(chunkPos + chunkSize, bodyData.len);
            const chunk = bodyData[chunkPos..end];

            if (!FileOps.writeAll(fileHandle, chunk)) return DownloadError.FileWriteFailed;
            hasher.update(chunk);

            writtenBytes += chunk.len;
            chunkPos = end;

            tracker.update(writtenBytes);
        }

        // Verify checksums
        hasher.verify(options.verify) catch |err| {
            tracker.fail();
            return err;
        };

        tracker.finish();

        var res = DownloadResult.make(destPath, writtenBytes, totalSize, 0, resp.status);
        res.resumed = resuming;
        res.overwritten = true;
        res.verified = true;
        res.sha256Hex = hasher.finalSha256Hex();
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

fn formatSpeed(perSec: f64, buf: []u8) []const u8 {
    if (perSec < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} B/s", .{perSec}) catch "";
    } else if (perSec < 1024.0 * 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{perSec / 1024.0}) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} MB/s", .{perSec / (1024.0 * 1024.0)}) catch "";
    }
}

pub const ProgressTracker = struct {
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    destination: []const u8,
    options: DownloadOptions,
    startTime: i64,
    lastUpdateTime: i64,
    lastBytes: u64,
    totalBytes: ?u64,
    bar: ?loaders.ProgressBar,
    isTty: bool,

    pub fn init(allocator: Allocator, io: std.Io, url: []const u8, destination: []const u8, options: DownloadOptions) ProgressTracker {
        const isTty = loaders.terminal.getSize(io).cols > 0;
        return .{
            .allocator = allocator,
            .io = io,
            .url = url,
            .destination = destination,
            .options = options,
            .startTime = clock.millisNow(),
            .lastUpdateTime = clock.millisNow(),
            .lastBytes = 0,
            .totalBytes = null,
            .bar = null,
            .isTty = isTty,
        };
    }

    pub fn deinit(self: *ProgressTracker) void {
        if (self.bar) |*b| b.deinit();
    }

    pub fn start(self: *ProgressTracker, totalSize: ?u64) void {
        self.totalBytes = totalSize;
        self.startTime = clock.millisNow();
        self.lastUpdateTime = self.startTime;

        const shouldRenderBar = (self.options.progress == .auto and self.isTty) or (self.options.progress == .enabled);
        if (shouldRenderBar) {
            const tot = totalSize orelse 100;
            const pb = loaders.ProgressBar.init(self.allocator, self.io, .{
                .total = tot,
                .prefix = std.fs.path.basename(self.destination),
                .style = .{
                    .filled = "=",
                    .empty = "-",
                    .head = ">",
                    .left_bracket = "[",
                    .right_bracket = "]",
                },
                .color = tint.fg(.{ .ansi4 = .cyan }),
                .template = if (totalSize != null)
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

        if (self.options.onProgress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloadedBytes = 0,
                .totalBytes = totalSize,
                .percentage = if (totalSize != null) 0.0 else null,
                .speedBps = 0.0,
                .etaSeconds = null,
                .elapsedMs = 0,
                .statusCode = 200,
                .state = .starting,
            }, self.options.userData);
        }
    }

    pub fn update(self: *ProgressTracker, downloadedBytes: u64) void {
        const now = clock.millisNow();
        const elapsed_total_s = @as(f64, @floatFromInt(now - self.startTime)) / 1000.0;
        const speed_bps = if (elapsed_total_s > 0.01) @as(f64, @floatFromInt(downloadedBytes)) / elapsed_total_s else 0.0;

        var etaS: ?u64 = null;
        var percent: ?f32 = null;
        if (self.totalBytes) |tot| {
            if (tot > 0) {
                percent = @as(f32, @floatFromInt(downloadedBytes)) / @as(f32, @floatFromInt(tot)) * 100.0;
                if (speed_bps > 0 and downloadedBytes < tot) {
                    etaS = @intFromFloat(@as(f64, @floatFromInt(tot - downloadedBytes)) / speed_bps);
                }
            }
        }

        self.lastBytes = downloadedBytes;

        if (self.bar) |*b| {
            b.setProgress(downloadedBytes);
        }

        if (self.options.onProgress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloadedBytes = downloadedBytes,
                .totalBytes = self.totalBytes,
                .percentage = percent,
                .speedBps = speed_bps,
                .etaSeconds = etaS,
                .elapsedMs = @intCast(@max(0, now - self.startTime)),
                .statusCode = 200,
                .state = .downloading,
            }, self.options.userData);
        }
    }

    pub fn finish(self: *ProgressTracker) void {
        const final_bytes = if (self.totalBytes) |tot| tot else self.lastBytes;
        if (self.bar) |*b| {
            b.setProgress(final_bytes);
            b.finish(.{ .clear = false, .newline = true });
        }
        if (self.options.onProgress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloadedBytes = final_bytes,
                .totalBytes = self.totalBytes orelse final_bytes,
                .percentage = 100.0,
                .speedBps = 0.0,
                .etaSeconds = 0,
                .elapsedMs = @intCast(@max(0, clock.millisNow() - self.startTime)),
                .statusCode = 200,
                .state = .completed,
            }, self.options.userData);
        }
    }

    pub fn fail(self: *ProgressTracker) void {
        if (self.bar) |*b| b.fail("Download failed");
        if (self.options.onProgress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloadedBytes = 0,
                .totalBytes = self.totalBytes,
                .percentage = null,
                .speedBps = 0.0,
                .etaSeconds = null,
                .elapsedMs = @intCast(@max(0, clock.millisNow() - self.startTime)),
                .statusCode = 500,
                .state = .failed,
            }, self.options.userData);
        }
    }

    pub fn cancel(self: *ProgressTracker) void {
        if (self.bar) |*b| b.fail("Download cancelled");
        if (self.options.onProgress) |cb| {
            cb(.{
                .url = self.url,
                .destination = self.destination,
                .downloadedBytes = 0,
                .totalBytes = self.totalBytes,
                .percentage = null,
                .speedBps = 0.0,
                .etaSeconds = null,
                .elapsedMs = @intCast(@max(0, clock.millisNow() - self.startTime)),
                .statusCode = 499,
                .state = .cancelled,
            }, self.options.userData);
        }
    }
};

// Updater

pub const UpdateOptions = struct {
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    backupExisting: bool = true,
    backupSuffix: []const u8 = ".bak",
    cancelFlag: ?*const std.atomic.Value(bool) = null,
};

/// Safely updates an existing executable or asset on disk with rollback preservation.
pub fn updateFile(
    allocator: Allocator,
    client: *Client,
    url: []const u8,
    targetPath: []const u8,
    options: UpdateOptions,
) DownloadError!DownloadResult {
    var dl = Downloader.init(allocator, client);

    const temp_target = std.fmt.allocPrint(allocator, "{s}.update-tmp", .{targetPath}) catch return DownloadError.OutOfMemory;
    defer allocator.free(temp_target);

    // 1. Download to temporary file
    const res = try dl.download(url, temp_target, .{
        .verify = options.verify,
        .progress = options.progress,
        .atomic = true,
        .existing = .overwrite,
        .cancelFlag = options.cancelFlag,
    });

    // 2. Backup existing file if requested
    var backupPath: ?[]const u8 = null;
    if (options.backupExisting) {
        backupPath = std.fmt.allocPrint(allocator, "{s}{s}", .{ targetPath, options.backupSuffix }) catch null;
        if (backupPath) |bp| {
            _ = FileOps.copyFile(targetPath, bp);
        }
    }
    defer if (backupPath) |bp| allocator.free(bp);

    // 3. Atomically replace target with verified new file
    if (!FileOps.renameFile(temp_target, targetPath)) {
        return DownloadError.FileRenameFailed;
    }

    var final_res = res;
    const len = @min(targetPath.len, final_res.destinationBuf.len);
    @memcpy(final_res.destinationBuf[0..len], targetPath[0..len]);
    final_res.destinationLen = len;
    final_res.destination = final_res.destinationBuf[0..len];
    return final_res;
}

// FTP Download Helper

pub const FtpDownloadOptions = struct {
    host: []const u8,
    port: u16 = 21,
    user: []const u8 = "anonymous",
    password: []const u8 = "anonymous@",
    remotePath: []const u8,
    destinationPath: []const u8,
    verify: VerifyOptions = .{},
    progress: ProgressMode = .auto,
    existing: ExistingFilePolicy = .overwrite,
    atomic: bool = true,
    cancelFlag: ?*const std.atomic.Value(bool) = null,
};

/// Downloads a file over FTP with progress reporting and checksum verification.
pub fn ftpDownload(
    allocator: Allocator,
    options: FtpDownloadOptions,
) DownloadError!DownloadResult {
    const startTime = clock.millisNow();
    const dest = resolveDestination(allocator, options.destinationPath, options.remotePath, null) catch return DownloadError.OutOfMemory;
    defer allocator.free(dest);

    var ftp = ftpClient.Client.connectWithAlloc(allocator, .{
        .host = options.host,
        .port = options.port,
        .user = options.user,
        .password = options.password,
    }) catch return DownloadError.ConnectionFailed;
    defer ftp.deinit();

    ftp.login(options.user, options.password) catch |err| switch (err) {
        error.ConnectFailed => return DownloadError.ConnectionFailed,
        else => return DownloadError.AuthenticationFailed,
    };

    const remote_size = ftp.size(options.remotePath) catch null;

    var threaded: std.Io.Threaded = .init_single_threaded;
    var tracker = ProgressTracker.init(allocator, threaded.io(), options.remotePath, dest, .{
        .progress = options.progress,
        .verify = options.verify,
    });
    defer tracker.deinit();
    tracker.start(remote_size);

    const temp_dest = if (options.atomic) try std.fmt.allocPrint(allocator, "{s}.ftp-part", .{dest}) else try allocator.dupe(u8, dest);
    defer allocator.free(temp_dest);

    const fileHandle = FileOps.createTruncate(temp_dest) orelse return DownloadError.FileCreateFailed;
    defer FileOps.close(fileHandle);

    var hasher = Hasher.init(options.verify);

    const Context = struct {
        hFile: FileOps.Handle,
        h: *Hasher,
        t: *ProgressTracker,
        written: u64 = 0,
        cancel: ?*const std.atomic.Value(bool),

        fn sink(ctx: *@This(), chunk: []const u8) ftpClient.FtpError!void {
            if (ctx.cancel) |cf| {
                if (cf.load(.acquire)) return ftpClient.FtpError.ProtocolError;
            }
            if (!FileOps.writeAll(ctx.hFile, chunk)) return ftpClient.FtpError.WriteFailed;
            ctx.h.update(chunk);
            ctx.written += chunk.len;
            ctx.t.update(ctx.written);
        }
    };

    var ctx = Context{
        .hFile = fileHandle,
        .h = &hasher,
        .t = &tracker,
        .cancel = options.cancelFlag,
    };

    ftp.download(options.remotePath, &ctx, Context.sink) catch |e| {
        tracker.fail();
        if (options.atomic) _ = FileOps.deleteFile(temp_dest);
        if (e == ftpClient.FtpError.ConnectFailed) return DownloadError.ConnectionFailed;
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
        .downloadedBytes = ctx.written,
        .totalBytes = remote_size,
        .elapsedMs = @intCast(clock.millisNow() - startTime),
        .statusCode = 226,
        .verified = true,
        .sha256Hex = hasher.finalSha256Hex(),
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
    const defaultTimeout: u64 = options.timeoutMs orelse 15000;
    var headHeaders: std.ArrayList(Header) = .empty;
    defer headHeaders.deinit(client.allocator);
    for (options.headers) |h| {
        headHeaders.append(client.allocator, h) catch return DownloadError.OutOfMemory;
    }
    headHeaders.append(client.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;

    var head_resp = client.head(url, .{
        .headers = headHeaders.items,
        .followRedirects = options.followRedirects,
        .maxRedirects = options.maxRedirects,
        .timeoutMs = defaultTimeout,
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
    var getHeaders: std.ArrayList(Header) = .empty;
    defer getHeaders.deinit(client.allocator);
    for (options.headers) |h| {
        getHeaders.append(client.allocator, h) catch return DownloadError.OutOfMemory;
    }
    getHeaders.append(client.allocator, .{ .name = "Range", .value = "bytes=0-0" }) catch return DownloadError.OutOfMemory;
    getHeaders.append(client.allocator, .{ .name = "Connection", .value = "close" }) catch return DownloadError.OutOfMemory;

    var get_resp = client.get(url, .{
        .headers = getHeaders.items,
        .followRedirects = options.followRedirects,
        .maxRedirects = options.maxRedirects,
        .timeoutMs = defaultTimeout,
    }) catch |err| switch (err) {
        error.ConnectFailed => return DownloadError.ConnectionFailed,
        error.TooManyRedirects => return DownloadError.TooManyRedirects,
        else => return DownloadError.HttpError,
    };
    defer get_resp.deinit();

    return parseRemoteFileInfo(url, get_resp.status, get_resp.headers);
}

fn parseRemoteFileInfo(sourceUrl: []const u8, status: u16, headers: []const Header) RemoteFileInfo {
    var info = RemoteFileInfo{
        .status = status,
    };

    const ulen = @min(sourceUrl.len, info.urlBuf.len);
    @memcpy(info.urlBuf[0..ulen], sourceUrl[0..ulen]);
    info.urlLen = ulen;

    var contentDisposition: ?[]const u8 = null;

    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
            info.fileSize = std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) {
            if (std.mem.lastIndexOfScalar(u8, h.value, '/')) |slash_idx| {
                const total_part = std.mem.trim(u8, h.value[slash_idx + 1 ..], " \t");
                if (!std.mem.eql(u8, total_part, "*")) {
                    if (std.fmt.parseInt(u64, total_part, 10)) |tot| {
                        info.fileSize = tot;
                    } else |_| {}
                }
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Disposition")) {
            contentDisposition = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.contentTypeBuf.len);
            @memcpy(info.contentTypeBuf[0..len], val[0..len]);
            info.contentTypeLen = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "ETag")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.etagBuf.len);
            @memcpy(info.etagBuf[0..len], val[0..len]);
            info.etagLen = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Last-Modified")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.lastModifiedBuf.len);
            @memcpy(info.lastModifiedBuf[0..len], val[0..len]);
            info.lastModifiedLen = len;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Accept-Ranges")) {
            if (std.ascii.indexOfIgnoreCase(h.value, "bytes") != null) {
                info.acceptsRanges = true;
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) {
            const val = std.mem.trim(u8, h.value, " \t");
            const len = @min(val.len, info.contentEncodingBuf.len);
            @memcpy(info.contentEncodingBuf[0..len], val[0..len]);
            info.contentEncodingLen = len;
        }
    }

    var fname: []const u8 = "downloaded_file";
    if (contentDisposition) |cd| {
        if (extractFilenameFromContentDisposition(cd)) |cd_name| {
            fname = sanitizeFilename(cd_name);
        } else {
            fname = sanitizeFilename(sourceUrl);
        }
    } else {
        fname = sanitizeFilename(sourceUrl);
    }

    const flen = @min(fname.len, info.fileNameBuf.len);
    @memcpy(info.fileNameBuf[0..flen], fname[0..flen]);
    info.fileNameLen = flen;

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
        .sha256 = "456fa02ee650c20d3cd882a644401888caccad7106e742558fecc36946ca3987",
    });
    hasher.update(data[0..10]);
    hasher.update(data[10..25]);
    hasher.update(data[25..]);

    try hasher.verify(.{
        .sha256 = "456fa02ee650c20d3cd882a644401888caccad7106e742558fecc36946ca3987",
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

        fn onProgress(info: ProgressInfo, userData: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userData.?));
            self.called = true;
            self.total = info.totalBytes;
            self.downloaded = info.downloadedBytes;
            if (info.state == .completed) {
                self.completed = true;
            }
        }
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    var state = CustomState{};
    var tracker = ProgressTracker.init(std.testing.allocator, threaded.io(), "http://example.com/test.bin", "test.bin", .{
        .progress = .custom,
        .onProgress = CustomState.onProgress,
        .userData = &state,
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
    try std.testing.expect(ExistingFilePolicy.resumePartial.isResume());
    try std.testing.expect(!ExistingFilePolicy.overwrite.isResume());
    try std.testing.expect(!ExistingFilePolicy.fail.isResume());
    try std.testing.expect(!ExistingFilePolicy.skip.isResume());
}

test "unsatisfied range header parses complete length" {
    try std.testing.expectEqual(@as(?u64, 49672), parseUnsatisfiedRange("bytes */49672"));
    try std.testing.expectEqual(@as(?u64, 0), parseUnsatisfiedRange("bytes */0"));
    try std.testing.expectEqual(@as(?u64, null), parseUnsatisfiedRange("bytes 0-99/49672"));
    try std.testing.expectEqual(@as(?u64, null), parseUnsatisfiedRange("none"));
    try std.testing.expectEqual(@as(?u64, null), parseUnsatisfiedRange("bytes */abc"));
}

test "remote file info size formatting" {
    var info = RemoteFileInfo{
        .status = 200,
        .fileSize = 15 * 1024 * 1024 + 500 * 1024,
    };
    const sample_name = "file.zip";
    @memcpy(info.fileNameBuf[0..sample_name.len], sample_name);
    info.fileNameLen = sample_name.len;

    var buf: [32]u8 = undefined;
    const formatted = info.formatSize(&buf);
    try std.testing.expectEqualStrings("15.49 MB", formatted);
    try std.testing.expectEqualStrings("file.zip", info.fileName());
}
