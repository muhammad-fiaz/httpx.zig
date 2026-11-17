//! Metadata and helpers shared by the documentation UI asset bundles.

const std = @import("std");

pub const File = struct {
    name: []const u8,
    contentType: []const u8,
    data: []const u8,
};

pub fn find(files: []const File, name: []const u8) ?*const File {
    for (files) |*file| {
        if (std.mem.eql(u8, file.name, name)) return file;
    }
    return null;
}

/// Reads the `name version` header of a vendored `VERSION.txt` file.
pub fn versionFromManifest(comptime manifest: []const u8) []const u8 {
    return comptime blk: {
        const end = std.mem.indexOfScalar(u8, manifest, '\n') orelse manifest.len;
        const line = std.mem.trim(u8, manifest[0..end], " \t\r");
        const separator = std.mem.lastIndexOfScalar(u8, line, ' ') orelse
            @compileError("vendor VERSION.txt must start with a package name and version");
        break :blk line[separator + 1 ..];
    };
}

test "parses a manifest header" {
    try std.testing.expectEqualStrings("1.2.3", versionFromManifest("pkg 1.2.3\nSource: https://example.com\n"));
    try std.testing.expectEqualStrings("2.0.0", versionFromManifest("@scope/pkg 2.0.0"));
}
