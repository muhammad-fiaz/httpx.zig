//! Test and inspection facade over the independently imported UI bundles.
//! Production mounting imports each bundle only in its enabled code path.

const std = @import("std");
const assets = @import("assetFile.zig");
const File = assets.File;
const swagger = @import("swaggerAssets.zig");
const redoc = @import("redocAssets.zig");
const scalar = @import("scalarAssets.zig");
const graphiql = @import("graphiqlAssets.zig");

pub const swaggerUiVersion = swagger.version;
pub const redocVersion = redoc.version;
pub const scalarVersion = scalar.version;
pub const graphiqlVersion = graphiql.version;

pub const Kind = enum { swaggerUi, redoc, scalar, graphiql };

pub const swaggerFiles = swagger.files;
pub const redocFiles = redoc.files;
pub const scalarFiles = scalar.files;
pub const graphiqlFiles = graphiql.files;

pub const swaggerUiBundleJs = swaggerFiles[0].data;
pub const swaggerUiStandalonePresetJs = swaggerFiles[1].data;
pub const swaggerUiCss = swaggerFiles[2].data;
pub const oauth2RedirectHtml = swaggerFiles[3].data;
pub const oauth2RedirectJs = swaggerFiles[4].data;
pub const favicon16Png = swaggerFiles[5].data;
pub const favicon32Png = swaggerFiles[6].data;
pub const redocStandaloneJs = redocFiles[0].data;
pub const scalarStandaloneJs = scalarFiles[0].data;
pub const graphiqlJs = graphiqlFiles[0].data;
pub const graphiqlCss = graphiqlFiles[1].data;
pub const graphiqlEditorWorkerJs = graphiqlFiles[2].data;
pub const graphiqlJsonWorkerJs = graphiqlFiles[3].data;
pub const graphiqlCodiconTtf = graphiqlFiles[4].data;

pub fn files(kind: Kind) []const File {
    return switch (kind) {
        .swaggerUi => &swaggerFiles,
        .redoc => &redocFiles,
        .scalar => &scalarFiles,
        .graphiql => &graphiqlFiles,
    };
}

pub fn find(kind: Kind, name: []const u8) ?*const File {
    return assets.find(files(kind), name);
}

test "finds every vendored swagger ui file" {
    for (swaggerFiles) |file| {
        const found = find(.swaggerUi, file.name).?;
        try std.testing.expect(found.data.len > 0);
        try std.testing.expectEqualStrings(file.contentType, found.contentType);
    }
}

test "finds every vendored graphiql file" {
    for (graphiqlFiles) |file| {
        const found = find(.graphiql, file.name).?;
        try std.testing.expect(found.data.len > 0);
        try std.testing.expectEqualStrings(file.contentType, found.contentType);
    }
}

test "lookup miss returns null" {
    try std.testing.expect(find(.swaggerUi, "does-not-exist.js") == null);
    try std.testing.expect(find(.redoc, "swagger-ui.css") == null);
    try std.testing.expect(find(.graphiql, "unknown.wasm") == null);
}

test "vendored versions are pinned releases" {
    try std.testing.expectEqualStrings("5.35.0", swaggerUiVersion);
    try std.testing.expectEqualStrings("3.1.0", redocVersion);
    try std.testing.expectEqualStrings("1.80.0", scalarVersion);
    try std.testing.expect(graphiqlVersion.len > 0);
}

test "bundles carry their version markers" {
    try std.testing.expect(std.mem.indexOf(u8, swaggerUiBundleJs, swaggerUiVersion) != null);
    try std.testing.expect(std.mem.indexOf(u8, redocStandaloneJs, redocVersion) != null);
    try std.testing.expect(std.mem.indexOf(u8, scalarStandaloneJs, scalarVersion) != null);
    try std.testing.expect(graphiqlJs.len > 1000);
}
