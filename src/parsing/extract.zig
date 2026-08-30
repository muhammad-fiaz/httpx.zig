//! Content extraction from parsed DOM trees.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Tree = dom.Tree;
const NO_NODE = dom.NO_NODE;

pub const Metadata = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    keywords: []const u8 = "",
    author: []const u8 = "",
    canonical: []const u8 = "",
    og_title: []const u8 = "",
    og_description: []const u8 = "",
    og_image: []const u8 = "",
    og_url: []const u8 = "",
    og_type: []const u8 = "",
    og_site_name: []const u8 = "",
    twitter_card: []const u8 = "",
    twitter_title: []const u8 = "",
    twitter_description: []const u8 = "",
    twitter_image: []const u8 = "",
    twitter_site: []const u8 = "",
    charset: []const u8 = "",
    viewport: []const u8 = "",
    robots: []const u8 = "",
    language: []const u8 = "",
    generator: []const u8 = "",
};

pub fn extractMetadata(tree: *const Tree, allocator: Allocator) !Metadata {
    var meta = Metadata{};
    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element) continue;

        if (node.hasTag("title")) {
            const child = node.first_child;
            if (child != NO_NODE and tree.get(child).kind == .text) {
                meta.title = std.mem.trim(u8, tree.get(child).data, " \t\r\n");
            }
            continue;
        }

        if (node.hasTag("html")) {
            if (node.attr("lang")) |lang| meta.language = lang;
            continue;
        }

        if (node.hasTag("meta")) {
            const name = node.attr("name") orelse node.attr("http-equiv") orelse "";
            const property = node.attr("property") orelse "";
            const content = node.attr("content") orelse "";
            const charset = node.attr("charset") orelse "";

            if (charset.len > 0) meta.charset = charset;

            if (std.ascii.eqlIgnoreCase(name, "description")) meta.description = content;
            if (std.ascii.eqlIgnoreCase(name, "keywords")) meta.keywords = content;
            if (std.ascii.eqlIgnoreCase(name, "author")) meta.author = content;
            if (std.ascii.eqlIgnoreCase(name, "viewport")) meta.viewport = content;
            if (std.ascii.eqlIgnoreCase(name, "robots")) meta.robots = content;
            if (std.ascii.eqlIgnoreCase(name, "generator")) meta.generator = content;

            if (std.ascii.eqlIgnoreCase(property, "og:title")) meta.og_title = content;
            if (std.ascii.eqlIgnoreCase(property, "og:description")) meta.og_description = content;
            if (std.ascii.eqlIgnoreCase(property, "og:image")) meta.og_image = content;
            if (std.ascii.eqlIgnoreCase(property, "og:url")) meta.og_url = content;
            if (std.ascii.eqlIgnoreCase(property, "og:type")) meta.og_type = content;
            if (std.ascii.eqlIgnoreCase(property, "og:site_name")) meta.og_site_name = content;

            if (std.ascii.eqlIgnoreCase(name, "twitter:card")) meta.twitter_card = content;
            if (std.ascii.eqlIgnoreCase(name, "twitter:title")) meta.twitter_title = content;
            if (std.ascii.eqlIgnoreCase(name, "twitter:description")) meta.twitter_description = content;
            if (std.ascii.eqlIgnoreCase(name, "twitter:image")) meta.twitter_image = content;
            if (std.ascii.eqlIgnoreCase(name, "twitter:site")) meta.twitter_site = content;
            continue;
        }

        if (node.hasTag("link")) {
            if (node.attr("rel")) |rel| {
                if (std.ascii.eqlIgnoreCase(rel, "canonical")) {
                    meta.canonical = node.attr("href") orelse "";
                }
            }
            continue;
        }
    }

    return meta;
}

pub const Link = struct {
    href: []const u8,
    text: []const u8 = "",
    rel: []const u8 = "",
    title: []const u8 = "",
    source: []const u8 = "a",
};

pub fn extractLinks(tree: *const Tree, allocator: Allocator) ![]Link {
    var links: std.ArrayList(Link) = .empty;

    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element) continue;

        if (node.hasTag("a") or node.hasTag("area")) {
            const href = node.attr("href") orelse continue;
            if (href.len == 0) continue;
            const link_text = blk: {
                var txt: std.ArrayList(u8) = .empty;
                defer txt.deinit(allocator);
                var child = node.first_child;
                while (child != NO_NODE) {
                    const c = tree.get(child);
                    if (c.kind == .text) try txt.appendSlice(allocator, c.data);
                    child = c.next_sibling;
                }
                break :blk try txt.toOwnedSlice(allocator);
            };
            defer allocator.free(link_text);
            try links.append(allocator, .{
                .href = href,
                .text = try allocator.dupe(u8, std.mem.trim(u8, link_text, " \t\r\n")),
                .rel = node.attr("rel") orelse "",
                .title = node.attr("title") orelse "",
                .source = if (node.hasTag("a")) "a" else "area",
            });
        } else if (node.hasTag("link")) {
            const href = node.attr("href") orelse continue;
            if (href.len == 0) continue;
            try links.append(allocator, .{
                .href = href,
                .rel = node.attr("rel") orelse "",
                .title = node.attr("title") orelse "",
                .source = "link",
            });
        }
    }

    return links.toOwnedSlice(allocator);
}

pub const FormField = struct {
    name: []const u8,
    kind: []const u8 = "text",
    value: []const u8 = "",
    placeholder: []const u8 = "",
    required: bool = false,
    disabled: bool = false,
    options: []const []const u8 = &.{},
};

pub const Form = struct {
    action: []const u8 = "",
    method: []const u8 = "get",
    enctype: []const u8 = "application/x-www-form-urlencoded",
    fields: []const FormField = &.{},
};

pub fn extractForms(tree: *const Tree, allocator: Allocator) ![]Form {
    var forms: std.ArrayList(Form) = .empty;

    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element or !node.hasTag("form")) continue;

        const action = node.attr("action") orelse "";
        const method = node.attr("method") orelse "get";
        const enctype = node.attr("enctype") orelse "application/x-www-form-urlencoded";

        var fields: std.ArrayList(FormField) = .empty;
        try extractFormFields(tree, allocator, idx, &fields);

        try forms.append(allocator, .{
            .action = action,
            .method = method,
            .enctype = enctype,
            .fields = try fields.toOwnedSlice(allocator),
        });
    }

    return forms.toOwnedSlice(allocator);
}

fn extractFormFields(
    tree: *const Tree,
    allocator: Allocator,
    form_idx: u32,
    fields: *std.ArrayList(FormField),
) !void {
    var fw = try tree.walk(allocator, form_idx);
    defer fw.deinit();
    _ = fw.next();

    while (fw.next()) |fidx| {
        const node = tree.get(fidx);
        if (node.kind != .element) continue;

        if (node.hasTag("input") or node.hasTag("textarea") or node.hasTag("select")) {
            const name = node.attr("name") orelse continue;
            const kind = node.attr("type") orelse (if (node.hasTag("textarea")) "textarea" else if (node.hasTag("select")) "select" else "text");
            var opts: []const []const u8 = &.{};
            if (node.hasTag("select")) {
                var opt_list: std.ArrayList([]const u8) = .empty;
                var ow = try tree.walk(allocator, fidx);
                defer ow.deinit();
                _ = ow.next();
                while (ow.next()) |oidx| {
                    const on = tree.get(oidx);
                    if (on.kind == .element and on.hasTag("option")) {
                        const v = on.attr("value") orelse "";
                        try opt_list.append(allocator, v);
                    }
                }
                opts = try opt_list.toOwnedSlice(allocator);
            }
            try fields.append(allocator, .{
                .name = name,
                .kind = kind,
                .value = node.attr("value") orelse "",
                .placeholder = node.attr("placeholder") orelse "",
                .required = node.attr("required") != null,
                .disabled = node.attr("disabled") != null,
                .options = opts,
            });
        } else if (node.hasTag("button")) {
            const name = node.attr("name") orelse continue;
            try fields.append(allocator, .{
                .name = name,
                .kind = node.attr("type") orelse "submit",
                .value = node.attr("value") orelse "",
            });
        }
    }
}

pub const Image = struct {
    src: []const u8,
    alt: []const u8 = "",
    title: []const u8 = "",
    width: []const u8 = "",
    height: []const u8 = "",
    loading: []const u8 = "",
};

pub fn extractImages(tree: *const Tree, allocator: Allocator) ![]Image {
    var images: std.ArrayList(Image) = .empty;

    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element or !node.hasTag("img")) continue;
        const src = node.attr("src") orelse continue;
        if (src.len == 0) continue;
        try images.append(allocator, .{
            .src = src,
            .alt = node.attr("alt") orelse "",
            .title = node.attr("title") orelse "",
            .width = node.attr("width") orelse "",
            .height = node.attr("height") orelse "",
            .loading = node.attr("loading") orelse "",
        });
    }

    return images.toOwnedSlice(allocator);
}

pub const ScriptRef = struct {
    src: []const u8,
    async_: bool = false,
    defer_: bool = false,
    type_: []const u8 = "",
    integrity: []const u8 = "",
};

pub fn extractScripts(tree: *const Tree, allocator: Allocator) ![]ScriptRef {
    var scripts: std.ArrayList(ScriptRef) = .empty;

    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element or !node.hasTag("script")) continue;
        const src = node.attr("src") orelse continue;
        if (src.len == 0) continue;
        try scripts.append(allocator, .{
            .src = src,
            .async_ = node.attr("async") != null,
            .defer_ = node.attr("defer") != null,
            .type_ = node.attr("type") orelse "",
            .integrity = node.attr("integrity") orelse "",
        });
    }

    return scripts.toOwnedSlice(allocator);
}

pub const StyleRef = struct {
    href: []const u8,
    media: []const u8 = "",
    integrity: []const u8 = "",
};

pub fn extractStylesheets(tree: *const Tree, allocator: Allocator) ![]StyleRef {
    var styles: std.ArrayList(StyleRef) = .empty;

    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element or !node.hasTag("link")) continue;
        const rel = node.attr("rel") orelse continue;
        if (!std.ascii.eqlIgnoreCase(rel, "stylesheet")) continue;
        const href = node.attr("href") orelse continue;
        if (href.len == 0) continue;
        try styles.append(allocator, .{
            .href = href,
            .media = node.attr("media") orelse "",
            .integrity = node.attr("integrity") orelse "",
        });
    }

    return styles.toOwnedSlice(allocator);
}

pub fn extractText(tree: *const Tree, allocator: Allocator) ![]u8 {
    return extractNodeText(tree, 0, allocator);
}

pub fn extractNodeText(tree: *const Tree, root_idx: u32, allocator: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var w = try tree.walk(allocator, root_idx);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind == .element) {
            if (node.hasTag("script") or node.hasTag("style") or node.hasTag("noscript")) {
                continue;
            }
        }
        if (node.kind == .text) {
            const trimmed = std.mem.trim(u8, node.data, " \t\r\n\x0C");
            if (trimmed.len > 0) {
                if (buf.items.len > 0) try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, trimmed);
            }
        }
    }

    return buf.toOwnedSlice(allocator);
}
