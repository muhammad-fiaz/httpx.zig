//! Minimal MIME type detection by file extension.
//!
//! Covers common web types; unknown extensions default to
//! application/octet-stream. Lookups are case-insensitive.

const std = @import("std");

const mime_map = std.static_string_map.StaticStringMap([]const u8).initComptime(.{
    .{ "html", "text/html; charset=utf-8" },
    .{ "htm", "text/html; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "js", "text/javascript; charset=utf-8" },
    .{ "mjs", "text/javascript; charset=utf-8" },
    .{ "json", "application/json; charset=utf-8" },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "md", "text/markdown; charset=utf-8" },
    .{ "xml", "application/xml; charset=utf-8" },
    .{ "csv", "text/csv; charset=utf-8" },
    .{ "pdf", "application/pdf" },
    .{ "wasm", "application/wasm" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },
    .{ "avif", "image/avif" },
    .{ "svg", "image/svg+xml" },
    .{ "ico", "image/x-icon" },
    .{ "bmp", "image/bmp" },
    .{ "woff", "font/woff" },
    .{ "woff2", "font/woff2" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },
    .{ "mp3", "audio/mpeg" },
    .{ "wav", "audio/wav" },
    .{ "ogg", "audio/ogg" },
    .{ "flac", "audio/flac" },
    .{ "mp4", "video/mp4" },
    .{ "webm", "video/webm" },
    .{ "mov", "video/quicktime" },
    .{ "zip", "application/zip" },
    .{ "gz", "application/gzip" },
    .{ "tar", "application/x-tar" },
    .{ "map", "application/json; charset=utf-8" },
    .{ "webmanifest", "application/manifest+json" },
});

/// MIME type for a path's extension. Always returns a usable value with O(1) lookup.
pub fn fromPath(path: []const u8) []const u8 {
    const name = blk: {
        const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse break :blk path;
        break :blk path[idx + 1 ..];
    };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return octet_stream;
    const ext = name[dot + 1 ..];
    if (ext.len == 0) return octet_stream;

    var lower: [16]u8 = undefined;
    if (ext.len > lower.len) return octet_stream;
    for (ext, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const key = lower[0..ext.len];

    return mime_map.get(key) orelse octet_stream;
}

pub const octet_stream = "application/octet-stream";

test "detects common types case-insensitively" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromPath("/a/b/Index.HTML"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", fromPath("data.json"));
    try std.testing.expectEqualStrings("image/png", fromPath("x.PNG"));
    try std.testing.expectEqualStrings("font/woff2", fromPath("/fonts/main.woff2"));
}

test "falls back to octet stream" {
    try std.testing.expectEqualStrings(octet_stream, fromPath("file.unknownext123456789"));
    try std.testing.expectEqualStrings(octet_stream, fromPath("noextension"));
    try std.testing.expectEqualStrings(octet_stream, fromPath("trailing."));
}
