//! Template loader with path traversal protection and secure file reading.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
pub const TemplateError = err_mod.TemplateError;

pub const LoaderConfig = struct {
    directory: []const u8 = "templates",
    max_file_size: usize = 10 * 1024 * 1024, // 10MB
};

pub const Loader = struct {
    directory: []const u8,
    max_file_size: usize,

    pub fn init(config: LoaderConfig) Loader {
        return .{
            .directory = config.directory,
            .max_file_size = config.max_file_size,
        };
    }

    /// Safely checks whether a relative path contains directory traversal.
    pub fn isSafeRelativePath(rel_path: []const u8) bool {
        if (rel_path.len == 0) return false;

        // Reject null bytes
        if (std.mem.indexOfScalar(u8, rel_path, 0) != null) return false;

        // Reject leading slashes or backslashes (absolute paths)
        if (rel_path[0] == '/' or rel_path[0] == '\\') return false;

        // Reject Windows drive letters (e.g. C:, D:)
        if (rel_path.len >= 2 and rel_path[1] == ':' and std.ascii.isAlphabetic(rel_path[0])) {
            return false;
        }

        // Reject UNC paths (starting with \\ or //)
        if (rel_path.len >= 2 and ((rel_path[0] == '\\' and rel_path[1] == '\\') or (rel_path[0] == '/' and rel_path[1] == '/'))) {
            return false;
        }

        // Reject any component that is ".."
        var it = std.mem.tokenizeAny(u8, rel_path, "/\\");
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return false;
        }

        return true;
    }

    /// Resolves and safely joins base directory with relative template name.
    pub fn resolvePath(self: Loader, allocator: Allocator, name: []const u8) ![]u8 {
        if (!isSafeRelativePath(name)) {
            return TemplateError.PathTraversal;
        }

        return try std.Io.Dir.path.join(allocator, &.{ self.directory, name });
    }

    /// Reads template source file into an allocated buffer.
    pub fn load(self: Loader, allocator: Allocator, name: []const u8) ![]u8 {
        // 1. Check embedded assets registry first for single-file deployment
        const assets_mod = @import("../assets.zig");
        if (assets_mod.getEmbedded(name)) |embedded| {
            if (embedded.content.len > self.max_file_size) return TemplateError.SizeLimitExceeded;
            return allocator.dupe(u8, embedded.content);
        }

        var pref_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&pref_buf, "{s}/{s}", .{ self.directory, name })) |pref_path| {
            if (assets_mod.getEmbedded(pref_path)) |embedded| {
                if (embedded.content.len > self.max_file_size) return TemplateError.SizeLimitExceeded;
                return allocator.dupe(u8, embedded.content);
            }
        } else |_| {}

        // 2. Fall back to filesystem read
        const full_path = try self.resolvePath(allocator, name);
        defer allocator.free(full_path);

        return readFileDirect(allocator, full_path, self.max_file_size);
    }
};

const static_serve = @import("../static_files/serve.zig");
const c_fs = static_serve.c_fs;

fn readFileDirect(a: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const h = c_fs.openRead(path) orelse return TemplateError.TemplateNotFound;
    defer c_fs.close(h);

    if (c_fs.is_win) {
        var size: i64 = 0;
        if (c_fs.GetFileSizeEx(h, &size) == @as(std.os.windows.BOOL, @enumFromInt(0))) return TemplateError.IoError;
        const fsize: usize = @intCast(@max(0, size));
        if (fsize > max_size) return TemplateError.SizeLimitExceeded;

        const buf = try a.alloc(u8, fsize);
        errdefer a.free(buf);

        var total: usize = 0;
        while (total < fsize) {
            var bytes_read: u32 = 0;
            const ok = c_fs.ReadFile(h, buf[total..].ptr, @intCast(@min(fsize - total, 0xFFFF_FFFF)), &bytes_read, null);
            if (ok == @as(std.os.windows.BOOL, @enumFromInt(0))) return TemplateError.IoError;
            if (bytes_read == 0) break;
            total += bytes_read;
        }
        if (total != fsize) return TemplateError.IoError;
        return buf;
    } else {
        const stat = std.posix.fstat(h) catch return TemplateError.IoError;
        const fsize: usize = @intCast(stat.size);
        if (fsize > max_size) return TemplateError.SizeLimitExceeded;

        const buf = try a.alloc(u8, fsize);
        errdefer a.free(buf);

        var total: usize = 0;
        while (total < fsize) {
            const n = std.posix.read(h, buf[total..]) catch return TemplateError.IoError;
            if (n == 0) break;
            total += n;
        }
        if (total != fsize) return TemplateError.IoError;
        return buf;
    }
}

test "Loader rejects unsafe paths and traversal" {
    const testing = std.testing;

    try testing.expect(Loader.isSafeRelativePath("index.html"));
    try testing.expect(Loader.isSafeRelativePath("partials/header.html"));
    try testing.expect(Loader.isSafeRelativePath("users/profile/view.html"));

    // Traversal attempts
    try testing.expect(!Loader.isSafeRelativePath("../secret.html"));
    try testing.expect(!Loader.isSafeRelativePath("..\\secret.html"));
    try testing.expect(!Loader.isSafeRelativePath("partials/../../secret.html"));
    try testing.expect(!Loader.isSafeRelativePath("/etc/passwd"));
    try testing.expect(!Loader.isSafeRelativePath("\\windows\\system32"));
    try testing.expect(!Loader.isSafeRelativePath("C:\\autoexec.bat"));
    try testing.expect(!Loader.isSafeRelativePath("\\\\server\\share\\file.html"));
}
