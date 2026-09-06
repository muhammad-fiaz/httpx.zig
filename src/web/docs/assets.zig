//! Vendored documentation UI assets, embedded at compile time.
//!
//! One library, offline by default: the Swagger UI / ReDoc / Scalar bundles
//! live in `src/assets/` and are linked into every binary that references
//! them. Nothing is fetched from a CDN at runtime.
//!
//! Provenance + update process for each vendor is documented in
//! `src/assets/<vendor>/VERSION.txt`.

const std = @import("std");

pub const swagger_ui_version = "5.32.14";
pub const redoc_version = "2.5.3";
pub const scalar_version = "1.66.1";
pub const graphiql_version = "5.3.0";

/// A single embedded asset file.
pub const File = struct {
    /// URL path segment, e.g. "swagger-ui-bundle.js".
    name: []const u8,
    content_type: []const u8,
    data: []const u8,
};

pub const Kind = enum {
    swagger_ui,
    redoc,
    scalar,
    graphiql,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .swagger_ui => "swagger-ui",
            .redoc => "redoc",
            .scalar => "scalar",
            .graphiql => "graphiql",
        };
    }
};

pub const swagger_files = [_]File{
    .{ .name = "swagger-ui-bundle.js", .content_type = "text/javascript; charset=utf-8", .data = swagger_ui_bundle_js },
    .{ .name = "swagger-ui-standalone-preset.js", .content_type = "text/javascript; charset=utf-8", .data = swagger_ui_standalone_preset_js },
    .{ .name = "swagger-ui.css", .content_type = "text/css; charset=utf-8", .data = swagger_ui_css },
    .{ .name = "oauth2-redirect.html", .content_type = "text/html; charset=utf-8", .data = oauth2_redirect_html },
    .{ .name = "favicon-16x16.png", .content_type = "image/png", .data = favicon_16_png },
    .{ .name = "favicon-32x32.png", .content_type = "image/png", .data = favicon_32_png },
};

pub const redoc_files = [_]File{
    .{ .name = "redoc.standalone.js", .content_type = "text/javascript; charset=utf-8", .data = redoc_standalone_js },
};

pub const scalar_files = [_]File{
    .{ .name = "standalone.js", .content_type = "text/javascript; charset=utf-8", .data = scalar_standalone_js },
};

pub const graphiql_files = [_]File{
    .{ .name = "graphiql.js", .content_type = "text/javascript; charset=utf-8", .data = graphiql_js },
    .{ .name = "graphiql.css", .content_type = "text/css; charset=utf-8", .data = graphiql_css },
    .{ .name = "editor.worker.js", .content_type = "text/javascript; charset=utf-8", .data = graphiql_editor_worker_js },
    .{ .name = "json.worker.js", .content_type = "text/javascript; charset=utf-8", .data = graphiql_json_worker_js },
    .{ .name = "graphql.worker.js", .content_type = "text/javascript; charset=utf-8", .data = graphiql_graphql_worker_js },
};

pub const swagger_ui_bundle_js = @embedFile("../../assets/swagger-ui/swagger-ui-bundle.js");
pub const swagger_ui_standalone_preset_js = @embedFile("../../assets/swagger-ui/swagger-ui-standalone-preset.js");
pub const swagger_ui_css = @embedFile("../../assets/swagger-ui/swagger-ui.css");
pub const oauth2_redirect_html = @embedFile("../../assets/swagger-ui/oauth2-redirect.html");
pub const favicon_16_png = @embedFile("../../assets/swagger-ui/favicon-16x16.png");
pub const favicon_32_png = @embedFile("../../assets/swagger-ui/favicon-32x32.png");
pub const redoc_standalone_js = @embedFile("../../assets/redoc/redoc.standalone.js");
pub const scalar_standalone_js = @embedFile("../../assets/scalar/standalone.js");
pub const graphiql_js = @embedFile("../../assets/graphiql/graphiql.js");
pub const graphiql_css = @embedFile("../../assets/graphiql/graphiql.css");
pub const graphiql_editor_worker_js = @embedFile("../../assets/graphiql/editor.worker.js");
pub const graphiql_json_worker_js = @embedFile("../../assets/graphiql/json.worker.js");
pub const graphiql_graphql_worker_js = @embedFile("../../assets/graphiql/graphql.worker.js");

/// All files belonging to a vendor bundle.
pub fn files(kind: Kind) []const File {
    return switch (kind) {
        .swagger_ui => &swagger_files,
        .redoc => &redoc_files,
        .scalar => &scalar_files,
        .graphiql => &graphiql_files,
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
    for (swagger_files) |f| {
        const hit = find(.swagger_ui, f.name);
        try std.testing.expect(hit != null);
        try std.testing.expect(hit.?.data.len > 0);
        try std.testing.expectEqualStrings(f.content_type, hit.?.content_type);
    }
}

test "finds every vendored graphiql file" {
    for (graphiql_files) |f| {
        const hit = find(.graphiql, f.name);
        try std.testing.expect(hit != null);
        try std.testing.expect(hit.?.data.len > 0);
        try std.testing.expectEqualStrings(f.content_type, hit.?.content_type);
    }
}

test "lookup miss returns null" {
    try std.testing.expect(find(.swagger_ui, "does-not-exist.js") == null);
    try std.testing.expect(find(.redoc, "swagger-ui.css") == null);
    try std.testing.expect(find(.graphiql, "unknown.wasm") == null);
}

test "vendored versions are the pinned releases" {
    try std.testing.expectEqualStrings("5.32.14", swagger_ui_version);
    try std.testing.expectEqualStrings("2.5.3", redoc_version);
    try std.testing.expectEqualStrings("1.66.1", scalar_version);
    try std.testing.expectEqualStrings("5.3.0", graphiql_version);
}

test "bundles carry their version markers" {
    // Guards against silently re-vendoring the wrong release.
    try std.testing.expect(std.mem.indexOf(u8, swagger_ui_bundle_js, "5.32.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, redoc_standalone_js, "2.5.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, scalar_standalone_js, "1.66.1") != null);
    try std.testing.expect(graphiql_js.len > 1000);
}
