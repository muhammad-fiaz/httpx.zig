//! Template loader with path traversal protection and secure file reading.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
pub const TemplateError = err_mod.TemplateError;

pub const LoaderConfig = struct {
    directory: []const u8 = "templates",
    maxFileSize: usize = 10 * 1024 * 1024, // 10MB
};

pub const Loader = struct {
    directory: []const u8,
    maxFileSize: usize,

    pub fn init(config: LoaderConfig) Loader {
        return .{
            .directory = config.directory,
            .maxFileSize = config.maxFileSize,
        };
    }

    /// Safely checks whether a relative path contains directory traversal.
    pub fn isSafeRelativePath(relPath: []const u8) bool {
        if (relPath.len == 0) return false;

        // Reject null bytes
        if (std.mem.indexOfScalar(u8, relPath, 0) != null) return false;

        // Reject leading slashes or backslashes (absolute paths)
        if (relPath[0] == '/' or relPath[0] == '\\') return false;

        // Reject Windows drive letters (e.g. C:, D:)
        if (relPath.len >= 2 and relPath[1] == ':' and std.ascii.isAlphabetic(relPath[0])) {
            return false;
        }

        // Reject UNC paths (starting with \\ or //)
        if (relPath.len >= 2 and ((relPath[0] == '\\' and relPath[1] == '\\') or (relPath[0] == '/' and relPath[1] == '/'))) {
            return false;
        }

        // Reject any component that is ".."
        var it = std.mem.tokenizeAny(u8, relPath, "/\\");
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

    /// Reads template source into an allocated buffer: embedded registry
    /// first (single-file deployment), then the filesystem.
    pub fn load(self: Loader, allocator: Allocator, name: []const u8) ![]u8 {
        // 1. Check embedded assets registry first for single-file deployment
        const assets_mod = @import("../assets.zig");
        if (assets_mod.getEmbedded(name)) |embedded| {
            if (embedded.content.len > self.maxFileSize) return TemplateError.SizeLimitExceeded;
            return allocator.dupe(u8, embedded.content);
        }

        var pref_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&pref_buf, "{s}/{s}", .{ self.directory, name })) |pref_path| {
            if (assets_mod.getEmbedded(pref_path)) |embedded| {
                if (embedded.content.len > self.maxFileSize) return TemplateError.SizeLimitExceeded;
                return allocator.dupe(u8, embedded.content);
            }
        } else |_| {}

        // 2. Fall back to filesystem read via the canonical fs helper.
        const full_path = try self.resolvePath(allocator, name);
        defer allocator.free(full_path);

        const fs_mod = @import("../../utils/fs.zig");
        return fs_mod.readFileLimited(allocator, full_path, self.maxFileSize) catch |err| switch (err) {
            error.FileNotFound => TemplateError.TemplateNotFound,
            error.IsDir => TemplateError.TemplateNotFound,
            error.FileTooBig => TemplateError.SizeLimitExceeded,
            error.ReadFailed, error.UnexpectedEof => TemplateError.IoError,
            error.OutOfMemory => TemplateError.OutOfMemory,
        };
    }
};
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
