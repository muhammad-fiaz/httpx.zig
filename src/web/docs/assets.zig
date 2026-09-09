//! Vendored documentation UI assets, embedded at compile time.
//!
//! One library, offline by default: the Swagger UI / ReDoc / Scalar bundles
//! live in `src/assets/` and are linked into every binary that references
//! them. Nothing is fetched from a CDN at runtime.
//!
//! Provenance + update process for each vendor is documented in
//! `src/assets/<vendor>/VERSION.txt`.

const std = @import("std");

pub const swaggerUiVersion = "5.32.14";
pub const redocVersion = "2.5.3";
pub const scalarVersion = "1.66.1";
pub const graphiqlVersion = "5.3.0";

/// A single embedded asset file.
pub const File = struct {
    /// URL path segment, e.g. "swagger-ui-bundle.js".
    name: []const u8,
    contentType: []const u8,
    data: []const u8,
};

pub const Kind = enum {
    swaggerUi,
    redoc,
    scalar,
    graphiql,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .swaggerUi => "swagger-ui",
            .redoc => "redoc",
            .scalar => "scalar",
            .graphiql => "graphiql",
        };
    }
};

pub const swaggerFiles = [_]File{
    .{ .name = "swagger-ui-bundle.js", .contentType = "text/javascript; charset=utf-8", .data = swaggerUiBundleJs },
    .{ .name = "swagger-ui-standalone-preset.js", .contentType = "text/javascript; charset=utf-8", .data = swaggerUiStandalonePresetJs },
    .{ .name = "swagger-ui.css", .contentType = "text/css; charset=utf-8", .data = swaggerUiCss },
    .{ .name = "oauth2-redirect.html", .contentType = "text/html; charset=utf-8", .data = oauth2RedirectHtml },
    .{ .name = "favicon-16x16.png", .contentType = "image/png", .data = favicon_16_png },
    .{ .name = "favicon-32x32.png", .contentType = "image/png", .data = favicon_32_png },
};

pub const redocFiles = [_]File{
    .{ .name = "redoc.standalone.js", .contentType = "text/javascript; charset=utf-8", .data = redocStandaloneJs },
};

pub const scalarFiles = [_]File{
    .{ .name = "standalone.js", .contentType = "text/javascript; charset=utf-8", .data = scalarStandaloneJs },
};

pub const graphiqlFiles = [_]File{
    .{ .name = "graphiql.js", .contentType = "text/javascript; charset=utf-8", .data = graphiqlJs },
    .{ .name = "graphiql.css", .contentType = "text/css; charset=utf-8", .data = graphiqlCss },
    .{ .name = "editor.worker.js", .contentType = "text/javascript; charset=utf-8", .data = graphiqlEditorWorkerJs },
    .{ .name = "json.worker.js", .contentType = "text/javascript; charset=utf-8", .data = graphiqlJson_worker_js },
    .{ .name = "graphql.worker.js", .contentType = "text/javascript; charset=utf-8", .data = graphiqlGraphqlWorkerJs },
};

pub const swaggerUiBundleJs = @embedFile("../../assets/swagger-ui/swagger-ui-bundle.js");
pub const swaggerUiStandalonePresetJs = @embedFile("../../assets/swagger-ui/swagger-ui-standalone-preset.js");
pub const swaggerUiCss = @embedFile("../../assets/swagger-ui/swagger-ui.css");
pub const oauth2RedirectHtml = @embedFile("../../assets/swagger-ui/oauth2-redirect.html");
pub const favicon_16_png = @embedFile("../../assets/swagger-ui/favicon-16x16.png");
pub const favicon_32_png = @embedFile("../../assets/swagger-ui/favicon-32x32.png");
pub const redocStandaloneJs = @embedFile("../../assets/redoc/redoc.standalone.js");
pub const scalarStandaloneJs = @embedFile("../../assets/scalar/standalone.js");
pub const graphiqlJs = @embedFile("../../assets/graphiql/graphiql.js");
pub const graphiqlCss = @embedFile("../../assets/graphiql/graphiql.css");
pub const graphiqlEditorWorkerJs = @embedFile("../../assets/graphiql/editor.worker.js");
pub const graphiqlJson_worker_js = @embedFile("../../assets/graphiql/json.worker.js");
pub const graphiqlGraphqlWorkerJs = @embedFile("../../assets/graphiql/graphql.worker.js");

/// All files belonging to a vendor bundle.
pub fn files(kind: Kind) []const File {
    return switch (kind) {
        .swaggerUi => &swaggerFiles,
        .redoc => &redocFiles,
        .scalar => &scalarFiles,
        .graphiql => &graphiqlFiles,
    };
}

/// Exact-name lookup within one vendor bundle.
pub fn find(kind: Kind, name: []const u8) ?*const File {
    for (files(kind)) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// Tests

test "finds every vendored swagger ui file" {
    for (swaggerFiles) |f| {
        const hit = find(.swaggerUi, f.name);
        try std.testing.expect(hit != null);
        try std.testing.expect(hit.?.data.len > 0);
        try std.testing.expectEqualStrings(f.contentType, hit.?.contentType);
    }
}

test "finds every vendored graphiql file" {
    for (graphiqlFiles) |f| {
        const hit = find(.graphiql, f.name);
        try std.testing.expect(hit != null);
        try std.testing.expect(hit.?.data.len > 0);
        try std.testing.expectEqualStrings(f.contentType, hit.?.contentType);
    }
}

test "lookup miss returns null" {
    try std.testing.expect(find(.swaggerUi, "does-not-exist.js") == null);
    try std.testing.expect(find(.redoc, "swagger-ui.css") == null);
    try std.testing.expect(find(.graphiql, "unknown.wasm") == null);
}

test "vendored versions are the pinned releases" {
    try std.testing.expectEqualStrings("5.32.14", swaggerUiVersion);
    try std.testing.expectEqualStrings("2.5.3", redocVersion);
    try std.testing.expectEqualStrings("1.66.1", scalarVersion);
    try std.testing.expectEqualStrings("5.3.0", graphiqlVersion);
}

test "bundles carry their version markers" {
    // Guards against silently re-vendoring the wrong release.
    try std.testing.expect(std.mem.indexOf(u8, swaggerUiBundleJs, "5.32.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, redocStandaloneJs, "2.5.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, scalarStandaloneJs, "1.66.1") != null);
    try std.testing.expect(graphiqlJs.len > 1000);
}
