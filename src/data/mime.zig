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
    return resolveOr(path, "application/octet-stream");
}

pub fn resolveOr(path: []const u8, fallback: []const u8) []const u8 {
    return resolveWith(path, &default_mappings, fallback);
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

/// Returns true if the given MIME type benefits from HTTP compression.
/// Text-based types, JSON, XML, JavaScript, SVG, etc. are compressible.
/// Already-compressed formats (images, video, audio, archives) are not.
pub fn isCompressible(mime_type: []const u8) bool {
    const t = trimParameters(mime_type);

    if (hasPrefix(t, "text/")) return true;

    if (eql(t, "application/json")) return true;
    if (eql(t, "application/x-ndjson")) return true;
    if (eql(t, "application/ld+json")) return true;
    if (eql(t, "application/geo+json")) return true;
    if (eql(t, "application/javascript")) return true;
    if (eql(t, "application/x-javascript")) return true;
    if (eql(t, "application/xml")) return true;
    if (eql(t, "application/rss+xml")) return true;
    if (eql(t, "application/atom+xml")) return true;
    if (eql(t, "application/soap+xml")) return true;
    if (eql(t, "application/vnd.wap.xhtml+xml")) return true;
    if (eql(t, "application/xhtml+xml")) return true;
    if (eql(t, "application/x-yaml")) return true;
    if (eql(t, "application/yaml")) return true;
    if (eql(t, "application/toml")) return true;
    if (eql(t, "application/sql")) return true;
    if (eql(t, "application/graphql")) return true;
    if (eql(t, "application/wasm")) return true;
    if (eql(t, "application/manifest+json")) return true;
    if (eql(t, "application/x-sh")) return true;
    if (eql(t, "application/x-www-form-urlencoded")) return true;
    if (eql(t, "application/svg+xml")) return true;

    if (eql(t, "image/svg+xml")) return true;

    return false;
}

/// Returns true if the MIME type represents an already-compressed format.
pub fn isAlreadyCompressed(mime_type: []const u8) bool {
    const t = trimParameters(mime_type);

    if (eql(t, "image/jpeg")) return true;
    if (eql(t, "image/png")) return true;
    if (eql(t, "image/webp")) return true;
    if (eql(t, "image/avif")) return true;
    if (eql(t, "image/heic")) return true;
    if (eql(t, "image/heif")) return true;
    if (eql(t, "image/jxl")) return true;
    if (eql(t, "image/gif")) return true;

    if (eql(t, "video/mp4")) return true;
    if (eql(t, "video/webm")) return true;
    if (eql(t, "video/quicktime")) return true;
    if (eql(t, "video/x-matroska")) return true;
    if (eql(t, "video/x-flv")) return true;
    if (eql(t, "video/mp2t")) return true;
    if (eql(t, "video/x-m4v")) return true;
    if (eql(t, "video/avi")) return true;

    if (eql(t, "audio/mpeg")) return true;
    if (eql(t, "audio/ogg")) return true;
    if (eql(t, "audio/flac")) return true;
    if (eql(t, "audio/aac")) return true;
    if (eql(t, "audio/opus")) return true;
    if (eql(t, "audio/mp4")) return true;
    if (eql(t, "audio/wav")) return true;

    if (eql(t, "application/zip")) return true;
    if (eql(t, "application/gzip")) return true;
    if (eql(t, "application/x-gzip")) return true;
    if (eql(t, "application/zstd")) return true;
    if (eql(t, "application/x-bzip2")) return true;
    if (eql(t, "application/x-7z-compressed")) return true;
    if (eql(t, "application/vnd.rar")) return true;
    if (eql(t, "application/x-tar")) return true;
    if (eql(t, "application/pdf")) return true;
    if (eql(t, "application/font-woff")) return true;
    if (eql(t, "font/woff")) return true;
    if (eql(t, "font/woff2")) return true;

    return false;
}

fn trimParameters(mime_type: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, mime_type, ';')) |semi| {
        return std.mem.trim(u8, mime_type[0..semi], " \t");
    }
    return mime_type;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn hasPrefix(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

test "isCompressible text types" {
    try std.testing.expect(isCompressible("text/html"));
    try std.testing.expect(isCompressible("text/plain"));
    try std.testing.expect(isCompressible("text/css"));
    try std.testing.expect(isCompressible("text/javascript"));
    try std.testing.expect(isCompressible("text/html; charset=utf-8"));
}

test "isCompressible application types" {
    try std.testing.expect(isCompressible("application/json"));
    try std.testing.expect(isCompressible("application/javascript"));
    try std.testing.expect(isCompressible("application/xml"));
    try std.testing.expect(isCompressible("application/json; charset=utf-8"));
}

test "isCompressible not compressible" {
    try std.testing.expect(!isCompressible("image/png"));
    try std.testing.expect(!isCompressible("image/jpeg"));
    try std.testing.expect(!isCompressible("video/mp4"));
    try std.testing.expect(!isCompressible("audio/mpeg"));
    try std.testing.expect(!isCompressible("application/zip"));
    try std.testing.expect(!isCompressible("application/gzip"));
}

test "isAlreadyCompressed" {
    try std.testing.expect(isAlreadyCompressed("image/jpeg"));
    try std.testing.expect(isAlreadyCompressed("image/png"));
    try std.testing.expect(isAlreadyCompressed("video/mp4"));
    try std.testing.expect(isAlreadyCompressed("audio/mpeg"));
    try std.testing.expect(isAlreadyCompressed("application/zip"));
    try std.testing.expect(!isAlreadyCompressed("text/html"));
    try std.testing.expect(!isAlreadyCompressed("application/json"));
}
