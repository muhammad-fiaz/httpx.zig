//! Shared MIME registry for paths, extensions, and media types.
//!
//! Unknown extensions return `null` from `lookupExtension` and `extensionFor`;
//! callers serving an unknown file can use `octetStream` explicitly. Reverse
//! lookup uses the first registry extension for media types with aliases.

const std = @import("std");
const mediaTypeConstants = @import("mediaType.zig");

const Entry = struct { extension: []const u8, mediaType: []const u8 };

const entries = [_]Entry{
    .{ .extension = "html", .mediaType = mediaTypeConstants.textHtmlUtf8 },
    .{ .extension = "htm", .mediaType = mediaTypeConstants.textHtmlUtf8 },
    .{ .extension = "css", .mediaType = "text/css; charset=utf-8" },
    .{ .extension = "js", .mediaType = "text/javascript; charset=utf-8" },
    .{ .extension = "mjs", .mediaType = "text/javascript; charset=utf-8" },
    .{ .extension = "json", .mediaType = mediaTypeConstants.applicationJsonUtf8 },
    .{ .extension = "txt", .mediaType = mediaTypeConstants.textPlainUtf8 },
    .{ .extension = "md", .mediaType = "text/markdown; charset=utf-8" },
    .{ .extension = "xml", .mediaType = "application/xml; charset=utf-8" },
    .{ .extension = "csv", .mediaType = "text/csv; charset=utf-8" },
    .{ .extension = "pdf", .mediaType = "application/pdf" },
    .{ .extension = "wasm", .mediaType = "application/wasm" },
    .{ .extension = "png", .mediaType = "image/png" },
    .{ .extension = "jpg", .mediaType = "image/jpeg" },
    .{ .extension = "jpeg", .mediaType = "image/jpeg" },
    .{ .extension = "gif", .mediaType = "image/gif" },
    .{ .extension = "webp", .mediaType = "image/webp" },
    .{ .extension = "avif", .mediaType = "image/avif" },
    .{ .extension = "svg", .mediaType = "image/svg+xml" },
    .{ .extension = "ico", .mediaType = "image/x-icon" },
    .{ .extension = "bmp", .mediaType = "image/bmp" },
    .{ .extension = "woff", .mediaType = "font/woff" },
    .{ .extension = "woff2", .mediaType = "font/woff2" },
    .{ .extension = "ttf", .mediaType = "font/ttf" },
    .{ .extension = "otf", .mediaType = "font/otf" },
    .{ .extension = "mp3", .mediaType = "audio/mpeg" },
    .{ .extension = "wav", .mediaType = "audio/wav" },
    .{ .extension = "ogg", .mediaType = "audio/ogg" },
    .{ .extension = "flac", .mediaType = "audio/flac" },
    .{ .extension = "mp4", .mediaType = "video/mp4" },
    .{ .extension = "webm", .mediaType = "video/webm" },
    .{ .extension = "mov", .mediaType = "video/quicktime" },
    .{ .extension = "zip", .mediaType = "application/zip" },
    .{ .extension = "gz", .mediaType = "application/gzip" },
    .{ .extension = "tar", .mediaType = "application/x-tar" },
    .{ .extension = "map", .mediaType = mediaTypeConstants.applicationJsonUtf8 },
    .{ .extension = "avifs", .mediaType = "image/avif-sequence" },
    .{ .extension = "jxl", .mediaType = "image/jxl" },
    .{ .extension = "apng", .mediaType = "image/apng" },
    .{ .extension = "tif", .mediaType = "image/tiff" },
    .{ .extension = "tiff", .mediaType = "image/tiff" },
    .{ .extension = "heic", .mediaType = "image/heic" },
    .{ .extension = "heif", .mediaType = "image/heif" },
    .{ .extension = "jsonld", .mediaType = "application/ld+json" },
    .{ .extension = "yaml", .mediaType = "application/yaml" },
    .{ .extension = "yml", .mediaType = "application/yaml" },
    .{ .extension = "toml", .mediaType = "application/toml" },
    .{ .extension = "rss", .mediaType = "application/rss+xml" },
    .{ .extension = "atom", .mediaType = "application/atom+xml" },
    .{ .extension = "eot", .mediaType = "application/vnd.ms-fontobject" },
    .{ .extension = "opus", .mediaType = "audio/ogg" },
    .{ .extension = "m4a", .mediaType = "audio/mp4" },
    .{ .extension = "m4v", .mediaType = "video/x-m4v" },
    .{ .extension = "zst", .mediaType = "application/zstd" },
    .{ .extension = "br", .mediaType = "application/x-brotli" },
    .{ .extension = "7z", .mediaType = "application/x-7z-compressed" },
    .{ .extension = "rar", .mediaType = "application/vnd.rar" },
    .{ .extension = "webmanifest", .mediaType = "application/manifest+json" },
};

const extensionMap = std.static_string_map.StaticStringMap([]const u8).initComptime(blk: {
    var pairs: [entries.len]struct { []const u8, []const u8 } = undefined;
    for (entries, 0..) |entry, i| pairs[i] = .{ entry.extension, entry.mediaType };
    break :blk pairs;
});

/// Unknown or malformed extensions map to this safe binary media type.
pub const octetStream = mediaTypeConstants.octetStream;
pub const formUrlEncoded = mediaTypeConstants.formUrlEncoded;
pub const multipartFormData = mediaTypeConstants.multipartFormData;
pub const textPlain = mediaTypeConstants.textPlain;
pub const textPlainUtf8 = mediaTypeConstants.textPlainUtf8;
pub const textHtml = mediaTypeConstants.textHtml;
pub const textHtmlUtf8 = mediaTypeConstants.textHtmlUtf8;

/// Looks up an extension without a leading dot. Case is ignored.
pub fn lookupExtension(extension: []const u8) ?[]const u8 {
    if (extension.len == 0 or extension.len > 32) return null;
    var lower: [32]u8 = undefined;
    return extensionMap.get(std.ascii.lowerString(&lower, extension));
}

/// Returns the registered media type for an extension, or `null` if unknown.
pub fn fromExtension(extension: []const u8) ?[]const u8 {
    return lookupExtension(extension);
}

/// Returns the first registered extension for a media type, ignoring case and
/// optional parameters. Aliases such as `.jpg` and `.jpeg` are deterministic.
pub fn extensionFor(mediaType: []const u8) ?[]const u8 {
    const normalized = baseMediaType(mediaType);
    if (normalized.len == 0) return null;
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(baseMediaType(entry.mediaType), normalized)) return entry.extension;
    }
    return null;
}

/// Returns the MIME type of a path. Both `/` and `\\` are path separators.
/// Unknown, extensionless, and trailing-dot paths map to `octetStream`.
pub fn fromPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse 0;
    const name = if (slash == 0 and path.len > 0 and path[0] != '/' and path[0] != '\\') path else path[slash + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return octetStream;
    return lookupExtension(name[dot + 1 ..]) orelse octetStream;
}

/// Returns the JSON helpers and constants shared by REST and GraphQL.
pub const json = @import("json.zig");
pub const applicationJson = json.applicationJson;
pub const applicationJsonUtf8 = json.applicationJsonUtf8;
pub const isJson = json.isJsonMediaType;

/// True when a path maps to one of the recognized JSON media types.
pub fn isJsonPath(path: []const u8) bool {
    return isJson(fromPath(path));
}

fn baseMediaType(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.mem.trim(u8, value[0..end], " \t\r\n");
}

test "MIME registry supports path, extension, reverse, and unknown lookup" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromPath("C:\\site\\index.HTML"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", fromExtension("JSON").?);
    try std.testing.expectEqualStrings("woff2", extensionFor("font/woff2; version=2").?);
    try std.testing.expectEqualStrings("jpg", extensionFor("IMAGE/JPEG").?);
    try std.testing.expect(lookupExtension("unknown") == null);
    try std.testing.expect(extensionFor("application/x-unknown") == null);
    try std.testing.expectEqualStrings(octetStream, fromPath("unknown.extension"));
    try std.testing.expect(isJsonPath("C:\\site\\data.json"));
}
