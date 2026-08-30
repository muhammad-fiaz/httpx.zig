//! HTML5 tokenizer and DOM builder.
//!
//! Parses a byte slice of HTML into a `dom.Tree` using a streaming tokenizer.
//! Handles void elements, raw-text elements (script/style), comments, DOCTYPE,
//! attributes (quoted/unquoted/boolean), and graceful error recovery.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Tree = dom.Tree;
const Node = dom.Node;
const Attribute = dom.Attribute;
const NO_NODE = dom.NO_NODE;

/// Limits for the HTML parser.
pub const Limits = struct {
    max_nodes: u32 = dom.MAX_NODES,
    max_depth: u32 = dom.MAX_DEPTH,
    max_attrs: u32 = 256,
    max_attr_value: usize = 8192,
    max_text_block: usize = 4 * 1024 * 1024,
};

pub const ParseError = error{
    OutOfMemory,
    TooManyNodes,
    TooDeep,
    TooManyAttributes,
    InputTooLarge,
};

/// HTML void elements — never have children per the HTML5 spec.
const VOID_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} }, .{ "base", {} }, .{ "br", {} }, .{ "col", {} },
    .{ "embed", {} }, .{ "hr", {} }, .{ "img", {} }, .{ "input", {} },
    .{ "link", {} }, .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
    .{ "track", {} }, .{ "wbr", {} },
});

/// Elements whose content is raw text (no child tags parsed inside).
const RAW_TEXT_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    .{ "script", {} }, .{ "style", {} }, .{ "textarea", {} }, .{ "title", {} },
});

pub fn parse(arena: Allocator, html_src: []const u8, limits: Limits) ParseError!Tree {
    var tree = try Tree.initCapacity(arena, @min(html_src.len / 16 + 4, limits.max_nodes));
    errdefer tree.deinit(arena);
    const root = try tree.append(arena, .{ .kind = .document });
    var builder = Builder{
        .arena = arena,
        .tree = &tree,
        .open_stack = .empty,
        .limits = limits,
    };
    try builder.open_stack.append(arena, root);
    try builder.run(html_src);
    return tree;
}

const Builder = struct {
    arena: Allocator,
    tree: *Tree,
    open_stack: std.ArrayList(u32),
    limits: Limits,

    fn currentParent(self: *const Builder) u32 {
        return if (self.open_stack.items.len > 0)
            self.open_stack.items[self.open_stack.items.len - 1]
        else
            0;
    }

    fn depth(self: *const Builder) u32 {
        return @intCast(self.open_stack.items.len);
    }

    fn run(self: *Builder, src: []const u8) ParseError!void {
        var i: usize = 0;
        while (i < src.len) {
            if (src[i] != '<') {
                const start = i;
                while (i < src.len and src[i] != '<') : (i += 1) {}
                const raw = src[start..i];
                if (raw.len > 0) {
                    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0C");
                    if (trimmed.len > 0) {
                        if (raw.len > self.limits.max_text_block) return error.InputTooLarge;
                        const idx = try self.tree.append(self.arena, .{ .kind = .text, .data = raw });
                        self.tree.appendChild(self.currentParent(), idx);
                    } else if (raw.len > 0) {
                        const idx = try self.tree.append(self.arena, .{ .kind = .text, .data = raw });
                        self.tree.appendChild(self.currentParent(), idx);
                    }
                }
                continue;
            }
            i += 1;
            if (i >= src.len) break;

            if (src[i] == '/') {
                i += 1;
                const tag_start = i;
                while (i < src.len and src[i] != '>' and src[i] != ' ') : (i += 1) {}
                const tag = lowerBuf(self.arena, trimRight(src[tag_start..i])) catch src[tag_start..i];
                while (i < src.len and src[i] != '>') : (i += 1) {}
                if (i < src.len) i += 1;
                self.popToTag(tag);
                continue;
            }

            if (src[i] == '!') {
                i += 1;
                if (std.mem.startsWith(u8, src[i..], "--")) {
                    i += 2;
                    const cstart = i;
                    while (i + 2 < src.len) : (i += 1) {
                        if (src[i] == '-' and src[i + 1] == '-' and src[i + 2] == '>') break;
                    }
                    const comment_data = src[cstart..i];
                    if (i + 2 < src.len) i += 3;
                    const idx = try self.tree.append(self.arena, .{ .kind = .comment, .data = comment_data });
                    self.tree.appendChild(self.currentParent(), idx);
                    continue;
                }
                if (std.mem.startsWith(u8, src[i..], "[CDATA[")) {
                    i += 7;
                    const cstart = i;
                    while (i + 2 < src.len) : (i += 1) {
                        if (src[i] == ']' and src[i + 1] == ']' and src[i + 2] == '>') break;
                    }
                    const cdata = src[cstart..i];
                    if (i + 2 < src.len) i += 3;
                    const idx = try self.tree.append(self.arena, .{ .kind = .cdata, .data = cdata });
                    self.tree.appendChild(self.currentParent(), idx);
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(src[i..], "DOCTYPE")) {
                    i += 7;
                    while (i < src.len and src[i] != '>') : (i += 1) {}
                    if (i < src.len) i += 1;
                    const idx = try self.tree.append(self.arena, .{ .kind = .doctype, .data = "html" });
                    self.tree.appendChild(self.currentParent(), idx);
                    continue;
                }
                while (i < src.len and src[i] != '>') : (i += 1) {}
                if (i < src.len) i += 1;
                continue;
            }

            if (src[i] == '?') {
                while (i + 1 < src.len) : (i += 1) {
                    if (src[i] == '?' and src[i + 1] == '>') { i += 2; break; }
                }
                continue;
            }

            const tag_start = i;
            while (i < src.len and !isTagNameEnd(src[i])) : (i += 1) {}
            if (i == tag_start) {
                const idx = try self.tree.append(self.arena, .{ .kind = .text, .data = "<" });
                self.tree.appendChild(self.currentParent(), idx);
                continue;
            }
            const raw_tag = src[tag_start..i];
            const tag = try lowerBuf(self.arena, raw_tag);

            var attrs: std.ArrayList(Attribute) = .empty;
            defer attrs.deinit(self.arena);
            var self_closing = false;
            i = try parseAttrs(self.arena, src, i, &attrs, &self_closing, self.limits);

            if (attrs.items.len > self.limits.max_attrs) return error.TooManyAttributes;

            const owned_attrs = try attrs.toOwnedSlice(self.arena);

            if (self.depth() >= self.limits.max_depth) return error.TooDeep;

            const void_el = VOID_ELEMENTS.has(tag);
            const raw_text = RAW_TEXT_ELEMENTS.has(tag);

            const node_idx = try self.tree.append(self.arena, .{
                .kind = .element,
                .tag = tag,
                .attrs = owned_attrs,
            });
            self.tree.appendChild(self.currentParent(), node_idx);

            if (!void_el and !self_closing) {
                try self.open_stack.append(self.arena, node_idx);

                if (raw_text) {
                    const raw_content = try consumeRawText(src, &i, tag);
                    if (raw_content.len > 0) {
                        const txt_idx = try self.tree.append(self.arena, .{ .kind = .text, .data = raw_content });
                        self.tree.appendChild(node_idx, txt_idx);
                    }
                    _ = self.open_stack.pop();
                }
            }
        }
    }

    fn popToTag(self: *Builder, tag: []const u8) void {
        var k: usize = self.open_stack.items.len;
        while (k > 0) : (k -= 1) {
            const idx = self.open_stack.items[k - 1];
            const node = self.tree.get(idx);
            if (node.kind == .element and node.hasTag(tag)) {
                self.open_stack.shrinkRetainingCapacity(k - 1);
                return;
            }
        }
    }
};

fn consumeRawText(src: []const u8, pos: *usize, tag: []const u8) ParseError![]const u8 {
    const start = pos.*;
    var i = start;
    while (i < src.len) {
        if (src[i] != '<') { i += 1; continue; }
        if (i + 1 >= src.len or src[i + 1] != '/') { i += 1; continue; }
        var j = i + 2;
        while (j < src.len and src[j] != '>') : (j += 1) {}
        const candidate = std.mem.trim(u8, src[i + 2 .. j], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(candidate, tag)) {
            const content = src[start..i];
            pos.* = if (j < src.len) j + 1 else j;
            return content;
        }
        i += 1;
    }
    pos.* = src.len;
    return src[start..];
}

fn parseAttrs(
    arena: Allocator,
    src: []const u8,
    start: usize,
    attrs: *std.ArrayList(Attribute),
    self_closing: *bool,
    limits: Limits,
) ParseError!usize {
    var i = start;
    while (i < src.len) {
        while (i < src.len and isWhitespace(src[i])) : (i += 1) {}
        if (i >= src.len) break;

        if (src[i] == '>') { i += 1; break; }
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '>') {
            self_closing.* = true;
            i += 2;
            break;
        }

        const name_start = i;
        while (i < src.len and !isAttrNameEnd(src[i])) : (i += 1) {}
        if (i == name_start) { i += 1; continue; }
        const attr_name = src[name_start..i];

        while (i < src.len and isWhitespace(src[i])) : (i += 1) {}

        if (i >= src.len or src[i] != '=') {
            try attrs.append(arena, .{ .name = attr_name, .value = "" });
            continue;
        }
        i += 1;
        while (i < src.len and isWhitespace(src[i])) : (i += 1) {}

        var attr_value: []const u8 = "";
        if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
            const quote = src[i];
            i += 1;
            const val_start = i;
            while (i < src.len and src[i] != quote) : (i += 1) {}
            attr_value = src[val_start..i];
            if (i < src.len) i += 1;
        } else {
            const val_start = i;
            while (i < src.len and !isWhitespace(src[i]) and src[i] != '>') : (i += 1) {}
            attr_value = src[val_start..i];
        }
        if (attr_value.len > limits.max_attr_value) return error.InputTooLarge;
        try attrs.append(arena, .{ .name = attr_name, .value = attr_value });
    }
    return i;
}

fn isTagNameEnd(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or
        c == '\x0C' or c == '>' or c == '/' or c == 0;
}

fn isAttrNameEnd(c: u8) bool {
    return c == '=' or c == '>' or c == '/' or isWhitespace(c);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0C';
}

fn trimRight(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[0..end];
}

fn lowerBuf(arena: Allocator, s: []const u8) Allocator.Error![]u8 {
    const buf = try arena.alloc(u8, s.len);
    for (buf, 0..) |*b, idx| b.* = std.ascii.toLower(s[idx]);
    return buf;
}
