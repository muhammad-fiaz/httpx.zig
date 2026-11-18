//! Scalar assets. Import this module only when Scalar is enabled.

const assets = @import("assetFile.zig");
const File = assets.File;

pub const names = [_][]const u8{"standalone.js"};
pub const files = [_]File{.{ .name = names[0], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/scalar/standalone.js") }};
pub fn find(name: []const u8) ?*const File {
    return assets.find(&files, name);
}

pub const version = assets.versionFromManifest(@embedFile("../../assets/scalar/VERSION.txt"));
