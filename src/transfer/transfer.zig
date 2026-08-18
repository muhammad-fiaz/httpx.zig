const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const fs = std.fs;
const time = std.time;
const testing = std.testing;
const Allocator = mem.Allocator;
const any_io = @import("../io/any_io.zig");
const threadIo = any_io.threadIo;

pub const Progress = struct {
    bytes_transferred: u64,
    total_bytes: ?u64,
    elapsed_ns: u64,

    pub fn percentage(self: Progress) ?f64 {
        const total = self.total_bytes orelse return null;
        if (total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.bytes_transferred)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    pub fn bytesPerSecond(self: Progress) u64 {
        if (self.elapsed_ns == 0) return 0;
        const seconds = self.elapsed_ns / time.ns_per_s;
        if (seconds == 0) {
            return self.bytes_transferred * time.ns_per_s / self.elapsed_ns;
        }
        return self.bytes_transferred / seconds;
    }

    pub fn estimatedRemainingNs(self: Progress) ?u64 {
        const total = self.total_bytes orelse return null;
        if (self.bytes_transferred == 0 or self.elapsed_ns == 0) return null;
        if (self.bytes_transferred >= total) return 0;
        const remaining_bytes = total - self.bytes_transferred;
        const bps = self.bytesPerSecond();
        if (bps == 0) return null;
        return remaining_bytes * time.ns_per_s / bps;
    }
};

pub const ProgressCallback = *const fn (progress: Progress) void;

pub const ChecksumAlgorithm = enum {
    sha256,
    sha512,
    md5,
};

pub const Checksum = struct {
    algorithm: ChecksumAlgorithm,
    digest: [64]u8,
    len: u8,

    pub fn hex(self: Checksum, buf: *[128]u8) []const u8 {
        const hex_chars = "0123456789abcdef";
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            buf[i * 2] = hex_chars[self.digest[i] >> 4];
            buf[i * 2 + 1] = hex_chars[self.digest[i] & 0x0f];
        }
        return buf[0 .. self.len * 2];
    }

    pub fn eql(self: Checksum, other: Checksum) bool {
        if (self.algorithm != other.algorithm) return false;
        if (self.len != other.len) return false;
        for (self.digest[0..self.len], other.digest[0..self.len]) |a, b| {
            if (a != b) return false;
        }
        return true;
    }
};

pub const ChecksumStream = struct {
    algorithm: ChecksumAlgorithm,
    hasher_sha256: ?crypto.hash.sha2.Sha256 = null,
    hasher_sha512: ?crypto.hash.sha2.Sha512 = null,
    hasher_md5: ?crypto.hash.Md5 = null,
    total_bytes: u64 = 0,

    pub fn init(algorithm: ChecksumAlgorithm) ChecksumStream {
        return .{
            .algorithm = algorithm,
            .hasher_sha256 = if (algorithm == .sha256) crypto.hash.sha2.Sha256.init(.{}) else null,
            .hasher_sha512 = if (algorithm == .sha512) crypto.hash.sha2.Sha512.init(.{}) else null,
            .hasher_md5 = if (algorithm == .md5) crypto.hash.Md5.init(.{}) else null,
        };
    }

    pub fn update(self: *ChecksumStream, data: []const u8) void {
        switch (self.algorithm) {
            .sha256 => {
                if (self.hasher_sha256) |*h| h.update(data);
            },
            .sha512 => {
                if (self.hasher_sha512) |*h| h.update(data);
            },
            .md5 => {
                if (self.hasher_md5) |*h| h.update(data);
            },
        }
        self.total_bytes += data.len;
    }

    pub fn final(self: *ChecksumStream) Checksum {
        var result: Checksum = undefined;
        result.algorithm = self.algorithm;
        switch (self.algorithm) {
            .sha256 => {
                var hash: [32]u8 = undefined;
                if (self.hasher_sha256) |*h| h.final(&hash);
                @memcpy(result.digest[0..32], &hash);
                result.len = 32;
            },
            .sha512 => {
                var hash: [64]u8 = undefined;
                if (self.hasher_sha512) |*h| h.final(&hash);
                @memcpy(result.digest[0..64], &hash);
                result.len = 64;
            },
            .md5 => {
                var hash: [16]u8 = undefined;
                if (self.hasher_md5) |*h| h.final(&hash);
                @memcpy(result.digest[0..16], &hash);
                result.len = 16;
            },
        }
        return result;
    }
};

pub const ResumeInfo = struct {
    bytes_downloaded: u64,
    total_bytes: ?u64,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    accept_range: bool = true,

    pub fn formatRangeHeader(self: ResumeInfo, buf: *[64]u8) []const u8 {
        const total = self.total_bytes orelse 0;
        if (total == 0) return "";
        return std.fmt.bufPrint(buf, "bytes={d}-", .{self.bytes_downloaded}) catch "";
    }

    pub fn canResume(self: ResumeInfo) bool {
        return self.accept_range and self.bytes_downloaded > 0;
    }
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const DownloadConfig = struct {
    allocator: Allocator,
    timeout_ms: u64 = 30_000,
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 1000,
    max_redirects: u32 = 10,
    overwrite: bool = false,
    atomic: bool = false,
    allow_resume: bool = false,
    follow_redirects: bool = true,
    progress_callback: ?ProgressCallback = null,
    checksum: ?ChecksumAlgorithm = null,
    headers: ?[]const HeaderEntry = null,
    ca_bundle: ?[]const u8 = null,
    insecure: bool = false,
};

pub const UploadConfig = struct {
    allocator: Allocator,
    timeout_ms: u64 = 30_000,
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 1000,
    chunked: bool = false,
    content_type: ?[]const u8 = null,
    progress_callback: ?ProgressCallback = null,
    headers: ?[]const HeaderEntry = null,
};

pub const TransferError = error{
    ConnectionFailed,
    Timeout,
    TooManyRedirects,
    InvalidRange,
    ChecksumMismatch,
    FileNotFound,
    AccessDenied,
    DiskFull,
    InvalidUrl,
    TlsError,
    Cancelled,
    ProtocolError,
    ServerError,
    RedirectLoop,
    ClosedByRemote,
    UnexpectedEof,
    WriteFailed,
    ReadFailed,
    TempFileCreateFailed,
    TempFileRenameFailed,
    InvalidResponse,
    InsufficientBuffer,
    UnsupportedEncoding,
    EncodingError,
    DecodingError,
    InvalidHeader,
    MissingContentLength,
    OperationAborted,
    ResourceBusy,
    SymLinkLoop,
    FileAlreadyExists,
};

pub const CancelToken = struct {
    cancelled: bool = false,
    mu: std.Io.Mutex = .init,

    pub fn cancel(self: *CancelToken) void {
        const io = threadIo();
        self.mu.lock(io) catch unreachable;
        defer self.mu.unlock(io);
        self.cancelled = true;
    }

    pub fn isCancelled(self: *CancelToken) bool {
        const io = threadIo();
        self.mu.lock(io) catch unreachable;
        defer self.mu.unlock(io);
        return self.cancelled;
    }

    pub fn check(self: *const CancelToken) TransferError!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub const TransferStats = struct {
    bytes_transferred: u64 = 0,
    total_bytes: ?u64 = null,
    start_time: u64 = 0,
    end_time: u64 = 0,
    retries: u32 = 0,
    checksum: ?Checksum = null,

    pub fn elapsedNs(self: TransferStats) u64 {
        if (self.end_time > 0) return self.end_time - self.start_time;
        return time.timestamp() - @as(i64, @intCast(self.start_time));
    }

    pub fn averageBps(self: TransferStats) u64 {
        const elapsed = self.elapsedNs();
        if (elapsed == 0) return 0;
        return self.bytes_transferred * time.ns_per_s / elapsed;
    }
};

pub const AtomicDownloader = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) AtomicDownloader {
        return .{ .allocator = allocator };
    }

    pub fn tempPath(self: AtomicDownloader, final_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.httpx-tmp", .{final_path});
    }

    pub fn commit(self: AtomicDownloader, temp_path: []const u8, final_path: []const u8) !void {
        _ = self;
        try fs.cwd().rename(temp_path, final_path);
    }

    pub fn cleanup(self: AtomicDownloader, temp_path: []const u8) void {
        _ = self;
        fs.cwd().deleteFile(temp_path) catch {};
    }
};

pub const RangeHeaderBuilder = struct {
    pub fn build(buf: *[128]u8, start: u64, end: ?u64) []const u8 {
        if (end) |e| {
            return std.fmt.bufPrint(buf, "bytes={d}-{d}", .{ start, e }) catch "";
        }
        return std.fmt.bufPrint(buf, "bytes={d}-", .{start}) catch "";
    }

    pub fn parseContentRange(header_value: []const u8) ?struct { start: u64, end: u64, total: ?u64 } {
        if (!std.mem.startsWith(u8, header_value, "bytes ")) return null;
        const rest = header_value[6..];
        const dash = std.mem.indexOf(u8, rest, "-") orelse return null;
        const slash = std.mem.indexOf(u8, rest, "/") orelse return null;
        const start_str = rest[0..dash];
        const end_str = rest[dash + 1 .. slash];
        const total_str = rest[slash + 1 ..];
        const start = std.fmt.parseInt(u64, start_str, 10) catch return null;
        const end_val = std.fmt.parseInt(u64, end_str, 10) catch return null;
        const total: ?u64 = if (std.mem.eql(u8, total_str, "*")) null else std.fmt.parseInt(u64, total_str, 10) catch null;
        return .{ .start = start, .end = end_val, .total = total };
    }
};

pub const ChecksumVerifier = struct {
    expected: Checksum,
    actual: ChecksumStream,

    pub fn init(expected: Checksum) ChecksumVerifier {
        return .{
            .expected = expected,
            .actual = ChecksumStream.init(expected.algorithm),
        };
    }

    pub fn update(self: *ChecksumVerifier, data: []const u8) void {
        self.actual.update(data);
    }

    pub fn verify(self: *ChecksumVerifier) bool {
        const result = self.actual.final();
        return result.eql(self.expected);
    }

    pub fn computed(self: *ChecksumVerifier) Checksum {
        return self.actual.final();
    }
};

pub fn computeChecksum(algorithm: ChecksumAlgorithm, data: []const u8) Checksum {
    var stream = ChecksumStream.init(algorithm);
    stream.update(data);
    return stream.final();
}

pub fn formatBytes(buf: *[32]u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "";
    } else if (bytes < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "";
    } else {
        const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "";
    }
}

pub fn formatDuration(buf: *[32]u8, ns: u64) []const u8 {
    const seconds = ns / time.ns_per_s;
    const millis = (ns % time.ns_per_s) / time.ns_per_ms;
    if (seconds >= 3600) {
        const hours = seconds / 3600;
        const mins = (seconds % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, mins }) catch "";
    } else if (seconds >= 60) {
        const mins = seconds / 60;
        const secs = seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, secs }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d}.{d:0>3}s", .{ seconds, millis }) catch "";
    }
}

test "Progress percentage with known total" {
    const p = Progress{
        .bytes_transferred = 50,
        .total_bytes = 100,
        .elapsed_ns = time.ns_per_s,
    };
    const pct = p.percentage() orelse return error.TestExpectedOptional;
    try testing.expectApproxEqAbs(@as(f64, 50.0), pct, 0.001);
}

test "Progress percentage at completion" {
    const p = Progress{
        .bytes_transferred = 100,
        .total_bytes = 100,
        .elapsed_ns = time.ns_per_s,
    };
    const pct = p.percentage() orelse return error.TestExpectedOptional;
    try testing.expectApproxEqAbs(@as(f64, 100.0), pct, 0.001);
}

test "Progress percentage zero total" {
    const p = Progress{
        .bytes_transferred = 0,
        .total_bytes = 0,
        .elapsed_ns = time.ns_per_s,
    };
    const pct = p.percentage() orelse return error.TestExpectedOptional;
    try testing.expectApproxEqAbs(@as(f64, 100.0), pct, 0.001);
}

test "Progress percentage unknown total" {
    const p = Progress{
        .bytes_transferred = 50,
        .total_bytes = null,
        .elapsed_ns = time.ns_per_s,
    };
    try testing.expect(p.percentage() == null);
}

test "Progress bytes per second" {
    const p = Progress{
        .bytes_transferred = 1024 * 1024,
        .total_bytes = 1024 * 1024 * 10,
        .elapsed_ns = time.ns_per_s,
    };
    try testing.expectEqual(@as(u64, 1024 * 1024), p.bytesPerSecond());
}

test "Progress bytes per second zero elapsed" {
    const p = Progress{
        .bytes_transferred = 1024,
        .total_bytes = null,
        .elapsed_ns = 0,
    };
    try testing.expectEqual(@as(u64, 0), p.bytesPerSecond());
}

test "Progress bytes per second sub-second" {
    const p = Progress{
        .bytes_transferred = 500,
        .total_bytes = 1000,
        .elapsed_ns = time.ns_per_s / 2,
    };
    const bps = p.bytesPerSecond();
    try testing.expectEqual(@as(u64, 1000), bps);
}

test "Progress estimated remaining" {
    const p = Progress{
        .bytes_transferred = 250,
        .total_bytes = 1000,
        .elapsed_ns = time.ns_per_s,
    };
    const remaining = p.estimatedRemainingNs() orelse return error.TestExpectedOptional;
    try testing.expectEqual(@as(u64, 3 * time.ns_per_s), remaining);
}

test "Progress estimated remaining null total" {
    const p = Progress{
        .bytes_transferred = 250,
        .total_bytes = null,
        .elapsed_ns = time.ns_per_s,
    };
    try testing.expect(p.estimatedRemainingNs() == null);
}

test "Progress estimated remaining zero transferred" {
    const p = Progress{
        .bytes_transferred = 0,
        .total_bytes = 1000,
        .elapsed_ns = time.ns_per_s,
    };
    try testing.expect(p.estimatedRemainingNs() == null);
}

test "Checksum stream SHA-256 known hash" {
    var stream = ChecksumStream.init(.sha256);
    stream.update("hello");
    const result = stream.final();
    try testing.expectEqual(@as(u8, 32), result.len);
    try testing.expectEqual(ChecksumAlgorithm.sha256, result.algorithm);
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex_str);
}

test "Checksum stream SHA-512 known hash" {
    var stream = ChecksumStream.init(.sha512);
    stream.update("hello");
    const result = stream.final();
    try testing.expectEqual(@as(u8, 64), result.len);
    try testing.expectEqual(ChecksumAlgorithm.sha512, result.algorithm);
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043", hex_str);
}

test "Checksum stream MD5 known hash" {
    var stream = ChecksumStream.init(.md5);
    stream.update("hello");
    const result = stream.final();
    try testing.expectEqual(@as(u8, 16), result.len);
    try testing.expectEqual(ChecksumAlgorithm.md5, result.algorithm);
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", hex_str);
}

test "Checksum stream incremental update" {
    var stream = ChecksumStream.init(.sha256);
    stream.update("hel");
    stream.update("lo");
    const result = stream.final();
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex_str);
}

test "Checksum hex encoding" {
    var c = Checksum{
        .algorithm = .sha256,
        .digest = undefined,
        .len = 4,
    };
    c.digest[0] = 0xde;
    c.digest[1] = 0xad;
    c.digest[2] = 0xbe;
    c.digest[3] = 0xef;
    var hex_buf: [128]u8 = undefined;
    const hex_str = c.hex(&hex_buf);
    try testing.expectEqualStrings("deadbeef", hex_str);
}

test "Checksum equality same" {
    const a = computeChecksum(.sha256, "hello");
    const b = computeChecksum(.sha256, "hello");
    try testing.expect(a.eql(b));
}

test "Checksum equality different data" {
    const a = computeChecksum(.sha256, "hello");
    const b = computeChecksum(.sha256, "world");
    try testing.expect(!a.eql(b));
}

test "Checksum equality different algorithm" {
    const a = computeChecksum(.sha256, "hello");
    const b = computeChecksum(.md5, "hello");
    try testing.expect(!a.eql(b));
}

test "computeChecksum convenience function" {
    const result = computeChecksum(.md5, "hello");
    try testing.expectEqual(ChecksumAlgorithm.md5, result.algorithm);
    try testing.expectEqual(@as(u8, 16), result.len);
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", hex_str);
}

test "ResumeInfo construction" {
    const ri = ResumeInfo{
        .bytes_downloaded = 1024,
        .total_bytes = 4096,
        .etag = "\"abc123\"",
        .last_modified = "Tue, 01 Jan 2024 00:00:00 GMT",
        .accept_range = true,
    };
    try testing.expectEqual(@as(u64, 1024), ri.bytes_downloaded);
    try testing.expectEqual(@as(?u64, 4096), ri.total_bytes);
    try testing.expect(ri.accept_range);
}

test "ResumeInfo canResume" {
    const can = ResumeInfo{ .bytes_downloaded = 100, .total_bytes = 200, .accept_range = true };
    try testing.expect(can.canResume());

    const no_range = ResumeInfo{ .bytes_downloaded = 100, .total_bytes = 200, .accept_range = false };
    try testing.expect(!no_range.canResume());

    const zero = ResumeInfo{ .bytes_downloaded = 0, .total_bytes = 200, .accept_range = true };
    try testing.expect(!zero.canResume());
}

test "ResumeInfo formatRangeHeader" {
    const ri = ResumeInfo{ .bytes_downloaded = 512, .total_bytes = 1024 };
    var buf: [64]u8 = undefined;
    const header = ri.formatRangeHeader(&buf);
    try testing.expectEqualStrings("bytes=512-", header);
}

test "ResumeInfo formatRangeHeader no total" {
    const ri = ResumeInfo{ .bytes_downloaded = 512, .total_bytes = null };
    var buf: [64]u8 = undefined;
    const header = ri.formatRangeHeader(&buf);
    try testing.expectEqualStrings("", header);
}

test "DownloadConfig defaults" {
    const alloc = testing.allocator;
    const cfg = DownloadConfig{ .allocator = alloc };
    try testing.expectEqual(@as(u64, 30_000), cfg.timeout_ms);
    try testing.expectEqual(@as(u32, 3), cfg.max_retries);
    try testing.expectEqual(@as(u64, 1000), cfg.retry_delay_ms);
    try testing.expectEqual(@as(u32, 10), cfg.max_redirects);
    try testing.expect(!cfg.overwrite);
    try testing.expect(!cfg.atomic);
    try testing.expect(!cfg.allow_resume);
    try testing.expect(cfg.follow_redirects);
    try testing.expect(cfg.progress_callback == null);
    try testing.expect(cfg.checksum == null);
    try testing.expect(cfg.headers == null);
    try testing.expect(cfg.ca_bundle == null);
    try testing.expect(!cfg.insecure);
}

test "UploadConfig defaults" {
    const alloc = testing.allocator;
    const cfg = UploadConfig{ .allocator = alloc };
    try testing.expectEqual(@as(u64, 30_000), cfg.timeout_ms);
    try testing.expectEqual(@as(u32, 3), cfg.max_retries);
    try testing.expectEqual(@as(u64, 1000), cfg.retry_delay_ms);
    try testing.expect(!cfg.chunked);
    try testing.expect(cfg.content_type == null);
    try testing.expect(cfg.progress_callback == null);
    try testing.expect(cfg.headers == null);
}

test "CancelToken basic operations" {
    var token = CancelToken{};
    try testing.expect(!token.isCancelled());
    token.cancel();
    try testing.expect(token.isCancelled());
    try testing.expectError(error.Cancelled, token.check());
}

test "CancelToken check passes when not cancelled" {
    var token = CancelToken{};
    try token.check();
}

test "RangeHeaderBuilder build" {
    var buf: [128]u8 = undefined;
    const h1 = RangeHeaderBuilder.build(&buf, 0, null);
    try testing.expectEqualStrings("bytes=0-", h1);
    const h2 = RangeHeaderBuilder.build(&buf, 100, 200);
    try testing.expectEqualStrings("bytes=100-200", h2);
}

test "RangeHeaderBuilder parseContentRange" {
    const result = RangeHeaderBuilder.parseContentRange("bytes 0-499/1234") orelse return error.TestExpectedOptional;
    try testing.expectEqual(@as(u64, 0), result.start);
    try testing.expectEqual(@as(u64, 499), result.end);
    try testing.expectEqual(@as(?u64, 1234), result.total);
}

test "RangeHeaderBuilder parseContentRange unknown total" {
    const result = RangeHeaderBuilder.parseContentRange("bytes 0-499/*") orelse return error.TestExpectedOptional;
    try testing.expectEqual(@as(u64, 0), result.start);
    try testing.expectEqual(@as(u64, 499), result.end);
    try testing.expect(result.total == null);
}

test "RangeHeaderBuilder parseContentRange invalid" {
    try testing.expect(RangeHeaderBuilder.parseContentRange("invalid") == null);
    try testing.expect(RangeHeaderBuilder.parseContentRange("bytes") == null);
}

test "ChecksumVerifier match" {
    const expected = computeChecksum(.sha256, "hello");
    var verifier = ChecksumVerifier.init(expected);
    verifier.update("hello");
    try testing.expect(verifier.verify());
}

test "ChecksumVerifier mismatch" {
    const expected = computeChecksum(.sha256, "hello");
    var verifier = ChecksumVerifier.init(expected);
    verifier.update("world");
    try testing.expect(!verifier.verify());
}

test "TransferStats defaults" {
    const stats = TransferStats{};
    try testing.expectEqual(@as(u64, 0), stats.bytes_transferred);
    try testing.expect(stats.total_bytes == null);
    try testing.expectEqual(@as(u32, 0), stats.retries);
    try testing.expect(stats.checksum == null);
}

test "formatBytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try testing.expectEqualStrings("1.0 KB", formatBytes(&buf, 1024));
    try testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    try testing.expectEqualStrings("1.0 MB", formatBytes(&buf, 1024 * 1024));
    try testing.expectEqualStrings("1.0 GB", formatBytes(&buf, 1024 * 1024 * 1024));
}

test "formatDuration" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.000s", formatDuration(&buf, 0));
    try testing.expectEqualStrings("1.500s", formatDuration(&buf, 1500000000));
    try testing.expectEqualStrings("1m 30s", formatDuration(&buf, 90 * time.ns_per_s));
    try testing.expectEqualStrings("1h 0m", formatDuration(&buf, 3600 * time.ns_per_s));
}

test "AtomicDownloader tempPath" {
    const dl = AtomicDownloader.init(testing.allocator);
    const path = try dl.tempPath("/tmp/file.zip");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/file.zip.httpx-tmp", path);
}

test "ChecksumStream total_bytes tracking" {
    var stream = ChecksumStream.init(.sha256);
    try testing.expectEqual(@as(u64, 0), stream.total_bytes);
    stream.update("hello");
    try testing.expectEqual(@as(u64, 5), stream.total_bytes);
    stream.update("world");
    try testing.expectEqual(@as(u64, 10), stream.total_bytes);
}

test "Checksumstream empty input" {
    var stream = ChecksumStream.init(.sha256);
    const result = stream.final();
    var hex_buf: [128]u8 = undefined;
    const hex_str = result.hex(&hex_buf);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex_str);
}

test "Progress callback invocation" {
    const S = struct {
        var invoked: bool = false;
        fn callback(progress: Progress) void {
            _ = progress;
            invoked = true;
        }
    };
    S.invoked = false;
    const p = Progress{
        .bytes_transferred = 100,
        .total_bytes = 200,
        .elapsed_ns = time.ns_per_s,
    };
    S.callback(p);
    try testing.expect(S.invoked);
}
