//! Swagger UI assets. Import this module only when Swagger UI is enabled.

const assets = @import("assetFile.zig");
const File = assets.File;

pub const names = [_][]const u8{
    "swagger-ui-bundle.js",
    "swagger-ui-standalone-preset.js",
    "swagger-ui.css",
    "oauth2-redirect.html",
    "oauth2-redirect.js",
    "favicon-16x16.png",
    "favicon-32x32.png",
};

pub const files = [_]File{
    .{ .name = names[0], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/swagger-ui/swagger-ui-bundle.js") },
    .{ .name = names[1], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/swagger-ui/swagger-ui-standalone-preset.js") },
    .{ .name = names[2], .contentType = "text/css; charset=utf-8", .data = @embedFile("../../assets/swagger-ui/swagger-ui.css") },
    .{ .name = names[3], .contentType = "text/html; charset=utf-8", .data = @embedFile("../../assets/swagger-ui/oauth2-redirect.html") },
    .{ .name = names[4], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/swagger-ui/oauth2-redirect.js") },
    .{ .name = names[5], .contentType = "image/png", .data = @embedFile("../../assets/swagger-ui/favicon-16x16.png") },
    .{ .name = names[6], .contentType = "image/png", .data = @embedFile("../../assets/swagger-ui/favicon-32x32.png") },
};

pub fn find(name: []const u8) ?*const File {
    return assets.find(&files, name);
}

pub const version = assets.versionFromManifest(@embedFile("../../assets/swagger-ui/VERSION.txt"));
