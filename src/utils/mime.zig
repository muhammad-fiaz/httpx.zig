//! Minimal MIME type detection by file extension.
//!
//! Covers common web types; unknown extensions default to
//! application/octet-stream. Lookups are case-insensitive.

const std = @import("std");

const Entry = struct { ext: []const u8, mime: []const u8 };

const table = [_]Entry{
    .{ .ext = "html", .mime = "text/html; charset=utf-8" },
    .{ .ext = "htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = "css", .mime = "text/css; charset=utf-8" },
    .{ .ext = "js", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "mjs", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "json", .mime = "application/json; charset=utf-8" },
    .{ .ext = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = "xml", .mime = "application/xml; charset=utf-8" },
    .{ .ext = "csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "bmp", .mime = "image/bmp" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "ttf", .mime = "font/ttf" },
    .{ .ext = "otf", .mime = "font/otf" },
    .{ .ext = "mp3", .mime = "audio/mpeg" },
    .{ .ext = "wav", .mime = "audio/wav" },
    .{ .ext = "ogg", .mime = "audio/ogg" },
    .{ .ext = "flac", .mime = "audio/flac" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "webm", .mime = "video/webm" },
    .{ .ext = "mov", .mime = "video/quicktime" },
    .{ .ext = "zip", .mime = "application/zip" },
    .{ .ext = "gz", .mime = "application/gzip" },
    .{ .ext = "tar", .mime = "application/x-tar" },
    .{ .ext = "map", .mime = "application/json; charset=utf-8" },
    .{ .ext = "webmanifest", .mime = "application/manifest+json" },
};

/// MIME type for a path's extension. Always returns a usable value.
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

    for (table) |e| {
        if (std.mem.eql(u8, e.ext, key)) return e.mime;
    }
    return octet_stream;
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
