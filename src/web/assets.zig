//! Unified Asset System: Embedded & Filesystem Assets for Single-File Deployment.
//!
//! Provides a single, coherent abstraction for web assets (HTML, templates, CSS, JS,
//! images, SPA files). An asset can either be:
//!   - Embedded directly in the binary (Single-file production mode, zero disk I/O)
//!   - Served from the filesystem (Development mode with watcher & live reload)
//!
//! The application API (Context.render, server.static, server.spa) is identical
//! regardless of whether assets are embedded or filesystem-backed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mime = @import("../utils/mime.zig");
const sync = @import("../common/sync.zig");

/// A single web asset (HTML, template, CSS, JS, image, font, etc.).
pub const Asset = struct {
    /// Normalized logical web path (e.g. "index.html", "css/app.css").
    path: []const u8,
    /// Immutable byte content.
    content: []const u8,
    /// MIME content type (e.g. "text/html; charset=utf-8").
    content_type: []const u8,
    /// Strong ETag for conditional HTTP requests (e.g. "\"a1b2c3d4\"").
    etag: []const u8,
    /// Modification timestamp in nanoseconds.
    mtime_ns: i128 = 0,
    /// True if embedded in binary memory; false if loaded from disk.
    is_embedded: bool = true,
};

/// Thread-safe registry for embedded production assets and filesystem fallback.
pub const AssetStore = struct {
    allocator: Allocator,
    assets: std.StringHashMap(Asset),
    lock: sync.Spinlock = .{},
    fs_root: ?[]const u8 = null,

    pub fn init(allocator: Allocator) AssetStore {
        return .{
            .allocator = allocator,
            .assets = std.StringHashMap(Asset).init(allocator),
            .fs_root = null,
        };
    }

    pub fn deinit(self: *AssetStore) void {
        self.lock.lock();
        var it = self.assets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.etag);
        }
        self.assets.deinit();
        self.lock.unlock();
    }

    /// Normalizes path by stripping leading slashes and converting Windows backslashes to forward slashes.
    pub fn normalizePath(buf: []u8, raw_path: []const u8) []const u8 {
        var trimmed = raw_path;
        while (trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '\\')) {
            trimmed = trimmed[1..];
        }
        const copy_len = @min(buf.len, trimmed.len);
        for (trimmed[0..copy_len], 0..) |c, i| {
            buf[i] = if (c == '\\') '/' else c;
        }
        return buf[0..copy_len];
    }

    /// Registers an embedded asset into the store.
    pub fn register(
        self: *AssetStore,
        raw_path: []const u8,
        content: []const u8,
        custom_content_type: ?[]const u8,
    ) !void {
        var norm_buf: [512]u8 = undefined;
        const norm_path = normalizePath(&norm_buf, raw_path);

        const owned_key = try self.allocator.dupe(u8, norm_path);
        errdefer self.allocator.free(owned_key);

        const ct = custom_content_type orelse mime.byExtension(norm_path);

        // Generate deterministic ETag from content hash
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash_buf, .{});
        const hex = std.fmt.bytesToHex(hash_buf[0..8], .lower);
        const etag_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{&hex});
        errdefer self.allocator.free(etag_str);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.assets.fetchRemove(norm_path)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.etag);
        }

        try self.assets.put(owned_key, .{
            .path = owned_key,
            .content = content,
            .content_type = ct,
            .etag = etag_str,
            .mtime_ns = 0,
            .is_embedded = true,
        });
    }

    /// Looks up an asset by logical path.
    pub fn get(self: *AssetStore, raw_path: []const u8) ?Asset {
        var norm_buf: [512]u8 = undefined;
        const norm_path = normalizePath(&norm_buf, raw_path);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.assets.get(norm_path)) |a| {
            return a;
        }

        // Try directory index fallback (e.g. "" or "admin" -> "index.html" or "admin/index.html")
        if (norm_path.len == 0) {
            return self.assets.get("index.html");
        }

        var idx_buf: [512]u8 = undefined;
        const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/index.html", .{norm_path}) catch return null;
        return self.assets.get(idx_path);
    }

    /// Returns true if the store has an embedded asset for the given path.
    pub fn has(self: *AssetStore, raw_path: []const u8) bool {
        return self.get(raw_path) != null;
    }

    /// Returns the total count of registered embedded assets.
    pub fn count(self: *AssetStore) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.assets.count();
    }
};

// Global default asset store for application-wide single-file embedding
var g_asset_store: ?AssetStore = null;
var g_asset_lock: sync.Spinlock = .{};

pub fn globalStore(allocator: Allocator) *AssetStore {
    g_asset_lock.lock();
    defer g_asset_lock.unlock();

    if (g_asset_store == null) {
        g_asset_store = AssetStore.init(allocator);
    }
    return &g_asset_store.?;
}

/// Registers an embedded asset into the global registry.
pub fn registerEmbedded(
    allocator: Allocator,
    path: []const u8,
    content: []const u8,
    content_type: ?[]const u8,
) !void {
    const store = globalStore(allocator);
    try store.register(path, content, content_type);
}

/// Retrieves an embedded asset from the global registry.
pub fn getEmbedded(raw_path: []const u8) ?Asset {
    g_asset_lock.lock();
    defer g_asset_lock.unlock();

    if (g_asset_store) |*store| {
        return store.get(raw_path);
    }
    return null;
}

/// Checks if an embedded asset exists in the global registry.
pub fn hasEmbedded(raw_path: []const u8) bool {
    return getEmbedded(raw_path) != null;
}

test "AssetStore register and lookup" {
    const alloc = std.testing.allocator;
    var store = AssetStore.init(alloc);
    defer store.deinit();

    try store.register("index.html", "<h1>Hello Embedded</h1>", null);
    try store.register("css\\style.css", "body { color: red; }", null);

    const a1 = store.get("index.html");
    try std.testing.expect(a1 != null);
    try std.testing.expectEqualStrings("<h1>Hello Embedded</h1>", a1.?.content);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", a1.?.content_type);
    try std.testing.expect(a1.?.is_embedded);

    // Test backslash normalization
    const a2 = store.get("css/style.css");
    try std.testing.expect(a2 != null);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", a2.?.content_type);

    // Test missing asset
    try std.testing.expect(store.get("missing.js") == null);
}
