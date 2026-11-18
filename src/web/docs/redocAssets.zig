//! ReDoc assets. Import this module only when ReDoc is enabled.

const assets = @import("assetFile.zig");
const File = assets.File;

pub const names = [_][]const u8{"redoc.standalone.js"};
pub const files = [_]File{.{ .name = names[0], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/redoc/redoc.standalone.js") }};
pub fn find(name: []const u8) ?*const File {
    return assets.find(&files, name);
}

pub const version = assets.versionFromManifest(@embedFile("../../assets/redoc/VERSION.txt"));
