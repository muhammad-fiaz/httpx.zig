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
    contentType: []const u8,
    /// Strong ETag for conditional HTTP requests (e.g. "\"a1b2c3d4\"").
    etag: []const u8,
    /// Modification timestamp in nanoseconds.
    mtimeNs: i128 = 0,
    /// True if embedded in binary memory; false if loaded from disk.
    isEmbedded: bool = true,
};

/// Thread-safe registry for embedded production assets and filesystem fallback.
pub const AssetStore = struct {
    allocator: Allocator,
    assets: std.StringHashMap(Asset),
    lock: sync.Spinlock = .{},
    fsRoot: ?[]const u8 = null,

    pub fn init(allocator: Allocator) AssetStore {
        return .{
            .allocator = allocator,
            .assets = std.StringHashMap(Asset).init(allocator),
            .fsRoot = null,
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
    pub fn normalizePath(buf: []u8, rawPath: []const u8) []const u8 {
        var trimmed = rawPath;
        while (trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '\\')) {
            trimmed = trimmed[1..];
        }
        const copyLen = @min(buf.len, trimmed.len);
        for (trimmed[0..copyLen], 0..) |c, i| {
            buf[i] = if (c == '\\') '/' else c;
        }
        return buf[0..copyLen];
    }

    /// Registers an embedded asset into the store.
    pub fn register(
        self: *AssetStore,
        rawPath: []const u8,
        content: []const u8,
        customContentType: ?[]const u8,
    ) !void {
        var norm_buf: [512]u8 = undefined;
        const norm_path = normalizePath(&norm_buf, rawPath);

        const owned_key = try self.allocator.dupe(u8, norm_path);
        errdefer self.allocator.free(owned_key);

        const ct = customContentType orelse mime.fromPath(norm_path);

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
            .contentType = ct,
            .etag = etag_str,
            .mtimeNs = 0,
            .isEmbedded = true,
        });
    }

    /// Removes a previously registered embedded asset. No-op if absent.
    pub fn unregister(self: *AssetStore, rawPath: []const u8) void {
        var norm_buf: [512]u8 = undefined;
        const norm_path = normalizePath(&norm_buf, rawPath);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.assets.fetchRemove(norm_path)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.etag);
        }
    }
    /// Looks up an asset by logical path.
    pub fn get(self: *AssetStore, rawPath: []const u8) ?Asset {
        var norm_buf: [512]u8 = undefined;
        const norm_path = normalizePath(&norm_buf, rawPath);

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
    pub fn has(self: *AssetStore, rawPath: []const u8) bool {
        return self.get(rawPath) != null;
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
    contentType: ?[]const u8,
) !void {
    const store = globalStore(allocator);
    try store.register(path, content, contentType);
}

/// One entry of a build-generated embedded directory manifest: a logical
/// web path plus the bytes embedded for it (typically via `@embedFile`).
/// Manifests are generated deterministically sorted by `build.zig` helpers,
/// so registration order never depends on filesystem enumeration order.
pub const EmbeddedFile = struct {
    path: []const u8,
    content: []const u8,
};

/// Registers a whole build-generated manifest with one call. MIME types
/// resolve through the shared MIME system unless an entry needs an
/// override, in which case register that path individually afterwards.
pub fn registerEmbeddedDir(allocator: Allocator, files: []const EmbeddedFile) !void {
    for (files) |f| try registerEmbedded(allocator, f.path, f.content, null);
}

/// Removes a previously registered embedded asset. No-op if absent.
pub fn unregisterEmbedded(allocator: Allocator, rawPath: []const u8) void {
    const store = globalStore(allocator);
    store.unregister(rawPath);
}

/// Retrieves an embedded asset from the global registry.
pub fn getEmbedded(rawPath: []const u8) ?Asset {
    g_asset_lock.lock();
    defer g_asset_lock.unlock();

    if (g_asset_store) |*store| {
        return store.get(rawPath);
    }
    return null;
}

/// Checks if an embedded asset exists in the global registry.
pub fn hasEmbedded(rawPath: []const u8) bool {
    return getEmbedded(rawPath) != null;
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
    try std.testing.expectEqualStrings("text/html; charset=utf-8", a1.?.contentType);
    try std.testing.expect(a1.?.isEmbedded);

    // Test backslash normalization
    const a2 = store.get("css/style.css");
    try std.testing.expect(a2 != null);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", a2.?.contentType);

    // Test missing asset
    try std.testing.expect(store.get("missing.js") == null);
}
