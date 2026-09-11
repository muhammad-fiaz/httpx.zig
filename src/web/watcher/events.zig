//! Normalized filesystem event model for the HTTPX watcher.
//!
//! Native backends (windows/linux/macos) translate OS events into this
//! single representation. Also owns file classification (which paths are
//! templates, assets, configs, sources) and save-storm coalescing, so the
//! reload layer sees one logical change per file.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WatchEventKind = enum {
    created,
    modified,
    deleted,
    renamed,
    directoryCreated,
    directoryDeleted,
};

/// Strategy automatically determined for resource reloading (hot/warm/cold/restart).
pub const ReloadStrategy = enum {
    /// Stylesheet (CSS) in-place update without reloading the document.
    hotReload,
    /// HTML / template / static content soft reload (window refresh).
    warmReload,
    /// Configuration, env, schema files (cache invalidation / re-fetch).
    coldReload,
    /// Compiled executable or application source code change requiring restart.
    restart,

    /// Automatically selects the reload strategy based on file path extension.
    pub fn forPath(path: []const u8) ReloadStrategy {
        if (std.mem.endsWith(u8, path, ".css")) return .hotReload;
        if (std.mem.endsWith(u8, path, ".zig")) return .restart;
        if (std.mem.endsWith(u8, path, ".json") or
            std.mem.endsWith(u8, path, ".env") or
            std.mem.endsWith(u8, path, ".toml") or
            std.mem.endsWith(u8, path, ".yaml") or
            std.mem.endsWith(u8, path, ".conf"))
        {
            return .coldReload;
        }
        return .warmReload;
    }
};

pub const WatchEvent = struct {
    path: []const u8,
    oldPath: ?[]const u8 = null,
    kind: WatchEventKind,
    strategy: ReloadStrategy = .warmReload,
    isDirectory: bool = false,
    timestampMs: i64,
};

pub const OwnedWatchEvent = struct {
    path: []u8,
    oldPath: ?[]u8 = null,
    kind: WatchEventKind,
    strategy: ReloadStrategy = .warmReload,
    isDirectory: bool = false,
    timestampMs: i64,

    pub fn deinit(self: *OwnedWatchEvent, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.oldPath) |op| {
            allocator.free(op);
        }
    }

    pub fn asView(self: *const OwnedWatchEvent) WatchEvent {
        return .{
            .path = self.path,
            .oldPath = self.oldPath,
            .kind = self.kind,
            .strategy = self.strategy,
            .isDirectory = self.isDirectory,
            .timestampMs = self.timestampMs,
        };
    }
};

/// What kind of reload pipeline a path belongs to. Tree-sitter analysis
/// applies to template/html/structured kinds only; everything else reloads
/// directly without syntax parsing.
pub const FileKind = enum {
    template,
    html,
    stylesheet,
    script,
    image,
    config,
    source,
    asset,
    ignored,

    pub fn classify(path: []const u8) FileKind {
        if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) {
            return if (isTemplatePath(path)) .template else .html;
        }
        if (std.mem.endsWith(u8, path, ".css")) return .stylesheet;
        if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".ts")) return .script;
        if (std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or
            std.mem.endsWith(u8, path, ".jpeg") or std.mem.endsWith(u8, path, ".gif") or
            std.mem.endsWith(u8, path, ".svg") or std.mem.endsWith(u8, path, ".webp") or
            std.mem.endsWith(u8, path, ".ico") or std.mem.endsWith(u8, path, ".woff") or
            std.mem.endsWith(u8, path, ".woff2") or std.mem.endsWith(u8, path, ".ttf")) return .image;
        if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".toml") or
            std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml") or
            std.mem.endsWith(u8, path, ".env") or std.mem.endsWith(u8, path, ".conf") or
            std.mem.endsWith(u8, path, ".xml")) return .config;
        if (std.mem.endsWith(u8, path, ".zig")) return .source;
        if (std.mem.endsWith(u8, path, ".md")) return .asset;
        return .asset;
    }

    fn isTemplatePath(path: []const u8) bool {
        return std.mem.indexOf(u8, path, "template") != null or
            std.mem.indexOf(u8, path, "views") != null;
    }

    /// True when Tree-sitter structural analysis applies to this kind.
    pub fn wantsStructure(self: FileKind) bool {
        return switch (self) {
            .template, .html, .config => true,
            else => false,
        };
    }
};

/// Editor/swap artifacts from atomic saves that must never become events.
pub fn isEditorTempFile(path: []const u8) bool {
    const base = std.Io.Dir.path.basename(path);
    if (std.mem.startsWith(u8, base, ".#") or std.mem.startsWith(u8, base, "#")) return true;
    if (std.mem.endsWith(u8, base, "~") or std.mem.endsWith(u8, base, ".tmp") or std.mem.endsWith(u8, base, ".swp")) return true;
    return false;
}

/// Save-storm coalescing: repeated events for the same path within the
/// debounce window collapse into one logical change. A kind transition
/// (e.g. modified -> deleted) always passes through.
pub const Coalescer = struct {
    windowMs: i64 = 50,
    lastMs: i64 = 0,
    lastKind: WatchEventKind = .modified,
    lastPath: [512]u8 = undefined,
    lastPathLen: usize = 0,

    pub fn shouldEmit(self: *Coalescer, nowMs: i64, path: []const u8, kind: WatchEventKind) bool {
        if (self.windowMs > 0 and (nowMs - self.lastMs) < self.windowMs) {
            if (kind == self.lastKind and
                self.lastPathLen == path.len and
                std.mem.eql(u8, self.lastPath[0..self.lastPathLen], path))
            {
                return false;
            }
        }
        self.lastMs = nowMs;
        self.lastKind = kind;
        const copy_len = @min(path.len, self.lastPath.len);
        @memcpy(self.lastPath[0..copy_len], path[0..copy_len]);
        self.lastPathLen = copy_len;
        return true;
    }
};

/// Rejects paths escaping the configured root: absolute paths, drive or
/// UNC prefixes, and `..` components. Watch roots are relative; anything
/// else is untrusted filesystem-event data.
pub fn isPathInsideRoot(root: []const u8, path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    _ = root;
    return true;
}

test "event classification covers template, asset, config, source" {
    try std.testing.expectEqual(FileKind.template, FileKind.classify("templates/index.html"));
    try std.testing.expectEqual(FileKind.html, FileKind.classify("public/about.html"));
    try std.testing.expectEqual(FileKind.stylesheet, FileKind.classify("a/b.css"));
    try std.testing.expectEqual(FileKind.config, FileKind.classify("config.json"));
    try std.testing.expectEqual(FileKind.source, FileKind.classify("src/main.zig"));
    try std.testing.expectEqual(FileKind.image, FileKind.classify("img/x.png"));
    try std.testing.expect(FileKind.classify("templates/a.html").wantsStructure());
    try std.testing.expect(!FileKind.classify("a.css").wantsStructure());
}

test "coalescer collapses save storms but passes kind transitions" {
    var c = Coalescer{ .windowMs = 10_000 };
    try std.testing.expect(c.shouldEmit(1000, "a.html", .modified));
    try std.testing.expect(!c.shouldEmit(1001, "a.html", .modified));
    try std.testing.expect(c.shouldEmit(1002, "a.html", .deleted));
    try std.testing.expect(c.shouldEmit(1003, "b.html", .modified));
}

test "path validation rejects escapes" {
    try std.testing.expect(isPathInsideRoot("templates", "index.html"));
    try std.testing.expect(isPathInsideRoot("templates", "sub/a.html"));
    try std.testing.expect(!isPathInsideRoot("templates", "../secret.txt"));
    try std.testing.expect(!isPathInsideRoot("templates", "/etc/passwd"));
    try std.testing.expect(!isPathInsideRoot("templates", "C:\\win\\x"));
}
