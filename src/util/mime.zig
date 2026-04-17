//! MIME type registry and resolution helpers.

const std = @import("std");

pub const MimeMapping = struct {
    ext: []const u8,
    mime: []const u8,
};

pub const default_mappings = [_]MimeMapping{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".cjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".jsonl", .mime = "application/x-ndjson" },
    .{ .ext = ".ndjson", .mime = "application/x-ndjson" },
    .{ .ext = ".xml", .mime = "application/xml" },
    .{ .ext = ".rss", .mime = "application/rss+xml" },
    .{ .ext = ".atom", .mime = "application/atom+xml" },
    .{ .ext = ".yaml", .mime = "application/yaml" },
    .{ .ext = ".yml", .mime = "application/yaml" },
    .{ .ext = ".toml", .mime = "application/toml" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".log", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = ".csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".tar", .mime = "application/x-tar" },
    .{ .ext = ".gz", .mime = "application/gzip" },
    .{ .ext = ".tgz", .mime = "application/gzip" },
    .{ .ext = ".bz2", .mime = "application/x-bzip2" },
    .{ .ext = ".7z", .mime = "application/x-7z-compressed" },
    .{ .ext = ".rar", .mime = "application/vnd.rar" },
    .{ .ext = ".wasm", .mime = "application/wasm" },
    .{ .ext = ".map", .mime = "application/json" },
    .{ .ext = ".webmanifest", .mime = "application/manifest+json" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".avif", .mime = "image/avif" },
    .{ .ext = ".bmp", .mime = "image/bmp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".tif", .mime = "image/tiff" },
    .{ .ext = ".tiff", .mime = "image/tiff" },
    .{ .ext = ".woff", .mime = "font/woff" },
    .{ .ext = ".woff2", .mime = "font/woff2" },
    .{ .ext = ".ttf", .mime = "font/ttf" },
    .{ .ext = ".otf", .mime = "font/otf" },
    .{ .ext = ".eot", .mime = "application/vnd.ms-fontobject" },
    .{ .ext = ".mp4", .mime = "video/mp4" },
    .{ .ext = ".m4v", .mime = "video/x-m4v" },
    .{ .ext = ".webm", .mime = "video/webm" },
    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".wav", .mime = "audio/wav" },
    .{ .ext = ".ogg", .mime = "audio/ogg" },
    .{ .ext = ".flac", .mime = "audio/flac" },
    .{ .ext = ".aac", .mime = "audio/aac" },
};

pub const MimeRegistry = struct {
    mappings: []const MimeMapping,
    fallback: []const u8 = "application/octet-stream",

    pub fn init(mappings: []const MimeMapping, fallback: []const u8) MimeRegistry {
        return .{
            .mappings = mappings,
            .fallback = fallback,
        };
    }

    pub fn withDefaultFallback(mappings: []const MimeMapping) MimeRegistry {
        return .{
            .mappings = mappings,
            .fallback = "application/octet-stream",
        };
    }

    pub fn resolve(self: MimeRegistry, path: []const u8) []const u8 {
        return resolveWith(path, self.mappings, self.fallback);
    }

    pub fn resolveOr(self: MimeRegistry, path: []const u8, fallback: []const u8) []const u8 {
        return resolveWith(path, self.mappings, fallback);
    }
};

pub const default_registry = MimeRegistry.withDefaultFallback(&default_mappings);

pub fn resolve(path: []const u8) []const u8 {
    return default_registry.resolve(path);
}

pub fn resolveOr(path: []const u8, fallback: []const u8) []const u8 {
    return default_registry.resolveOr(path, fallback);
}

pub fn resolveWith(path: []const u8, mappings: []const MimeMapping, fallback: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return fallback;

    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(ext, mapping.ext)) {
            return mapping.mime;
        }
    }

    return fallback;
}

test "mime registry resolves from default mapping" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", resolve("index.html"));
    try std.testing.expectEqualStrings("application/octet-stream", resolve("asset.bin"));
}

test "mime registry supports external mappings" {
    const custom = [_]MimeMapping{
        .{ .ext = ".zig", .mime = "text/x-zig" },
        .{ .ext = ".tmpl", .mime = "text/x-template" },
    };

    const registry = MimeRegistry.withDefaultFallback(&custom);

    try std.testing.expectEqualStrings("text/x-zig", registry.resolve("main.zig"));
    try std.testing.expectEqualStrings("text/x-template", registry.resolve("view.TMPL"));
    try std.testing.expectEqualStrings("application/octet-stream", registry.resolve("blob.unknown"));
}
