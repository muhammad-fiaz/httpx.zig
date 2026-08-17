//! MIME type registry and resolution helpers.

const std = @import("std");
const dbg = @import("debug.zig");

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
    .{ .ext = ".opus", .mime = "audio/opus" },
    .{ .ext = ".m4a", .mime = "audio/mp4" },
    .{ .ext = ".avi", .mime = "video/x-msvideo" },
    .{ .ext = ".mov", .mime = "video/quicktime" },
    .{ .ext = ".mkv", .mime = "video/x-matroska" },
    .{ .ext = ".ts", .mime = "video/mp2t" },
    .{ .ext = ".flv", .mime = "video/x-flv" },
    .{ .ext = ".heic", .mime = "image/heic" },
    .{ .ext = ".heif", .mime = "image/heif" },
    .{ .ext = ".jxl", .mime = "image/jxl" },
    .{ .ext = ".apng", .mime = "image/apng" },
    .{ .ext = ".doc", .mime = "application/msword" },
    .{ .ext = ".docx", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ .ext = ".xls", .mime = "application/vnd.ms-excel" },
    .{ .ext = ".xlsx", .mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ .ext = ".ppt", .mime = "application/vnd.ms-powerpoint" },
    .{ .ext = ".pptx", .mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ .ext = ".odt", .mime = "application/vnd.oasis.opendocument.text" },
    .{ .ext = ".ods", .mime = "application/vnd.oasis.opendocument.spreadsheet" },
    .{ .ext = ".wasm", .mime = "application/wasm" },
    .{ .ext = ".ics", .mime = "text/calendar" },
    .{ .ext = ".vcf", .mime = "text/vcard" },
    .{ .ext = ".glb", .mime = "model/gltf-binary" },
    .{ .ext = ".gltf", .mime = "model/gltf+json" },
    .{ .ext = ".hlsl", .mime = "text/x-hlsl" },
    .{ .ext = ".glsl", .mime = "text/x-glsl" },
    .{ .ext = ".proto", .mime = "text/x-protobuf" },
    .{ .ext = ".go", .mime = "text/x-go" },
    .{ .ext = ".rs", .mime = "text/x-rust" },
    .{ .ext = ".py", .mime = "text/x-python" },
    .{ .ext = ".rb", .mime = "text/x-ruby" },
    .{ .ext = ".java", .mime = "text/x-java" },
    .{ .ext = ".c", .mime = "text/x-c" },
    .{ .ext = ".cpp", .mime = "text/x-c++" },
    .{ .ext = ".h", .mime = "text/x-c" },
    .{ .ext = ".hpp", .mime = "text/x-c++" },
    .{ .ext = ".cs", .mime = "text/x-csharp" },
    .{ .ext = ".swift", .mime = "text/x-swift" },
    .{ .ext = ".kt", .mime = "text/x-kotlin" },
    .{ .ext = ".zig", .mime = "text/x-zig" },
    .{ .ext = ".lua", .mime = "text/x-lua" },
    .{ .ext = ".php", .mime = "text/x-php" },
    .{ .ext = ".sql", .mime = "application/sql" },
    .{ .ext = ".graphql", .mime = "application/graphql" },
    .{ .ext = ".gql", .mime = "application/graphql" },
    .{ .ext = ".sh", .mime = "application/x-sh" },
    .{ .ext = ".bat", .mime = "application/x-bat" },
    .{ .ext = ".ps1", .mime = "application/x-powershell" },
    .{ .ext = ".env", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".dockerfile", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".makefile", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".srt", .mime = "application/x-subrip" },
    .{ .ext = ".vtt", .mime = "text/vtt" },
    .{ .ext = ".jsonld", .mime = "application/ld+json" },
    .{ .ext = ".geojson", .mime = "application/geo+json" },
    .{ .ext = ".x3d", .mime = "model/x3d+xml" },
    .{ .ext = ".stl", .mime = "model/stl" },
    .{ .ext = ".obj", .mime = "model/obj" },
    .{ .ext = ".fbx", .mime = "model/fbx" },
    .{ .ext = ".blend", .mime = "application/x-blender" },
    .{ .ext = ".psd", .mime = "image/vnd.adobe.photoshop" },
    .{ .ext = ".ai", .mime = "application/postscript" },
    .{ .ext = ".eps", .mime = "application/postscript" },
    .{ .ext = ".svgz", .mime = "image/svg+xml" },
};

pub fn resolve(path: []const u8) []const u8 {
    dbg.entry("MIME", "resolve");
    defer dbg.exit("MIME", "resolve");
    return resolveOr(path, "application/octet-stream");
}

pub fn resolveOr(path: []const u8, fallback: []const u8) []const u8 {
    dbg.entry("MIME", "resolveOr");
    defer dbg.exit("MIME", "resolveOr");
    return resolveWith(path, &default_mappings, fallback);
}

pub fn resolveWith(path: []const u8, mappings: []const MimeMapping, fallback: []const u8) []const u8 {
    dbg.entry("MIME", "resolveWith");
    defer dbg.exit("MIME", "resolveWith");
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return fallback;

    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(ext, mapping.ext)) {
            return mapping.mime;
        }
    }

    return fallback;
}

test "mimeTypeFromPath maps known extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", resolve("index.html"));
    try std.testing.expectEqualStrings("application/json", resolve("api.json"));
    try std.testing.expectEqualStrings("image/png", resolve("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", resolve("archive.bin"));
}

test "mimeTypeFromPath handles case-insensitive extensions" {
    try std.testing.expectEqualStrings("image/webp", resolve("cover.WEBP"));
    try std.testing.expectEqualStrings("application/wasm", resolve("runtime.WaSm"));
}

test "mimeTypeFromPathOr supports custom fallback" {
    try std.testing.expectEqualStrings("application/x-custom", resolveOr("asset.unknownext", "application/x-custom"));
    try std.testing.expectEqualStrings("application/octet-stream", resolveOr("site.unknown", "application/octet-stream"));
}

test "mimeTypeFromPathWith supports external mappings" {
    const custom = [_]MimeMapping{
        .{ .ext = ".zig", .mime = "text/x-zig" },
        .{ .ext = ".tmpl", .mime = "text/x-template" },
    };

    try std.testing.expectEqualStrings("text/x-zig", resolveWith("main.zig", &custom, "application/octet-stream"));
    try std.testing.expectEqualStrings("text/x-template", resolveWith("view.TMPL", &custom, "application/octet-stream"));
    try std.testing.expectEqualStrings("application/octet-stream", resolveWith("asset.unknown", &custom, "application/octet-stream"));
}
