//! GraphiQL assets. Import this module only when GraphiQL is enabled.

const assets = @import("assetFile.zig");
const File = assets.File;

pub const names = [_][]const u8{
    "graphiql.js",
    "graphiql.css",
    "editor.worker.js",
    "json.worker.js",
    "codicon-mxdk0fnd.ttf",
};
pub const files = [_]File{
    .{ .name = names[0], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/graphiql/graphiql.js") },
    .{ .name = names[1], .contentType = "text/css; charset=utf-8", .data = @embedFile("../../assets/graphiql/graphiql.css") },
    .{ .name = names[2], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/graphiql/editor.worker.js") },
    .{ .name = names[3], .contentType = "text/javascript; charset=utf-8", .data = @embedFile("../../assets/graphiql/json.worker.js") },
    .{ .name = names[4], .contentType = "font/ttf", .data = @embedFile("../../assets/graphiql/codicon-mxdk0fnd.ttf") },
};
pub fn find(name: []const u8) ?*const File {
    return assets.find(&files, name);
}

pub const version = assets.versionFromManifest(@embedFile("../../assets/graphiql/VERSION.txt"));
