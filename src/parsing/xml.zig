//! Lightweight XML parser for httpx.zig.
//!
//! Parses XML into a dom.Tree. Preserves tag case and CDATA sections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Tree = dom.Tree;
const Attribute = dom.Attribute;

pub const ParseError = error{
    OutOfMemory,
    TooManyNodes,
    TooDeep,
    TooManyAttributes,
    MalformedXml,
    InputTooLarge,
};

pub const Options = struct {
    lenient: bool = true,
    max_nodes: u32 = dom.MAX_NODES,
    max_depth: u32 = dom.MAX_DEPTH,
    max_attrs: u32 = 256,
    max_attr_value: usize = 8192,
};

pub fn parse(arena: Allocator, xml_src: []const u8, opts: Options) ParseError!Tree {
    var tree = try Tree.initCapacity(arena, @min(xml_src.len / 12 + 4, opts.max_nodes));
    errdefer tree.deinit(arena);
    const root = try tree.append(arena, .{ .kind = .document });
    var p = Parser{
        .arena = arena,
        .tree = &tree,
        .src = xml_src,
        .opts = opts,
    };
    try p.open_stack.append(arena, root);
    try p.run();
    return tree;
}

const Parser = struct {
    arena: Allocator,
    tree: *Tree,
    src: []const u8,
    pos: usize = 0,
    opts: Options,
    open_stack: std.ArrayList(u32) = .empty,

    fn cur(self: *const Parser) u32 {
        return if (self.open_stack.items.len > 0)
            self.open_stack.items[self.open_stack.items.len - 1]
        else
            0;
    }

    fn run(self: *Parser) ParseError!void {
        while (self.pos < self.src.len) {
            if (self.src[self.pos] != '<') {
                try self.consumeText();
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.src.len) break;

            switch (self.src[self.pos]) {
                '/' => try self.consumeEndTag(),
                '!' => try self.consumeBang(),
                '?' => try self.consumePI(),
                else => try self.consumeStartTag(),
            }
        }
    }

    fn consumeText(self: *Parser) ParseError!void {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '<') : (self.pos += 1) {}
        const raw = self.src[start..self.pos];
        if (raw.len == 0) return;
        const idx = try self.tree.append(self.arena, .{ .kind = .text, .data = raw });
        self.tree.appendChild(self.cur(), idx);
    }

    fn consumeEndTag(self: *Parser) ParseError!void {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '>' and self.src[self.pos] != ' ') : (self.pos += 1) {}
        const tag = std.mem.trim(u8, self.src[start..self.pos], " \t\r\n");
        while (self.pos < self.src.len and self.src[self.pos] != '>') : (self.pos += 1) {}
        if (self.pos < self.src.len) self.pos += 1;

        var k = self.open_stack.items.len;
        while (k > 0) : (k -= 1) {
            const idx = self.open_stack.items[k - 1];
            const node = self.tree.get(idx);
            if (node.kind == .element and std.mem.eql(u8, node.tag, tag)) {
                self.open_stack.shrinkRetainingCapacity(k - 1);
                return;
            }
        }
        if (!self.opts.lenient) return error.MalformedXml;
    }

    fn consumeBang(self: *Parser) ParseError!void {
        self.pos += 1;
        if (std.mem.startsWith(u8, self.src[self.pos..], "--")) {
            self.pos += 2;
            const start = self.pos;
            while (self.pos + 2 < self.src.len) : (self.pos += 1) {
                if (self.src[self.pos] == '-' and self.src[self.pos + 1] == '-' and self.src[self.pos + 2] == '>') break;
            }
            const data = self.src[start..self.pos];
            if (self.pos + 2 < self.src.len) self.pos += 3;
            const idx = try self.tree.append(self.arena, .{ .kind = .comment, .data = data });
            self.tree.appendChild(self.cur(), idx);
            return;
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "[CDATA[")) {
            self.pos += 7;
            const start = self.pos;
            while (self.pos + 2 < self.src.len) : (self.pos += 1) {
                if (self.src[self.pos] == ']' and self.src[self.pos + 1] == ']' and self.src[self.pos + 2] == '>') break;
            }
            const data = self.src[start..self.pos];
            if (self.pos + 2 < self.src.len) self.pos += 3;
            const idx = try self.tree.append(self.arena, .{ .kind = .cdata, .data = data });
            self.tree.appendChild(self.cur(), idx);
            return;
        }
        while (self.pos < self.src.len and self.src[self.pos] != '>') : (self.pos += 1) {}
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn consumePI(self: *Parser) ParseError!void {
        while (self.pos + 1 < self.src.len) : (self.pos += 1) {
            if (self.src[self.pos] == '?' and self.src[self.pos + 1] == '>') {
                self.pos += 2;
                break;
            }
        }
    }

    fn consumeStartTag(self: *Parser) ParseError!void {
        if (self.open_stack.items.len >= self.opts.max_depth) return error.TooDeep;

        const tag_start = self.pos;
        while (self.pos < self.src.len and !isStop(self.src[self.pos])) : (self.pos += 1) {}
        const tag = self.src[tag_start..self.pos];
        if (tag.len == 0) {
            while (self.pos < self.src.len and self.src[self.pos] != '>') : (self.pos += 1) {}
            if (self.pos < self.src.len) self.pos += 1;
            return;
        }

        var attrs: std.ArrayList(Attribute) = .empty;
        defer attrs.deinit(self.arena);
        var self_closing = false;
        self.pos = try parseAttrs(self.arena, self.src, self.pos, &attrs, &self_closing, self.opts.max_attr_value);
        if (attrs.items.len > self.opts.max_attrs) return error.TooManyAttributes;
        const owned = try attrs.toOwnedSlice(self.arena);

        const node_idx = try self.tree.append(self.arena, .{
            .kind = .element,
            .tag = tag,
            .attrs = owned,
        });
        self.tree.appendChild(self.cur(), node_idx);

        if (!self_closing) {
            try self.open_stack.append(self.arena, node_idx);
        }
    }
};

fn isStop(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0C' or c == '>' or c == '/';
}

fn parseAttrs(
    arena: Allocator,
    src: []const u8,
    start: usize,
    attrs: *std.ArrayList(Attribute),
    self_closing: *bool,
    max_val: usize,
) ParseError!usize {
    var i = start;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) : (i += 1) {}
        if (i >= src.len) break;
        if (src[i] == '>') { i += 1; break; }
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '>') { self_closing.* = true; i += 2; break; }

        const name_start = i;
        while (i < src.len and src[i] != '=' and src[i] != '>' and src[i] != '/' and
            src[i] != ' ' and src[i] != '\t' and src[i] != '\r' and src[i] != '\n') : (i += 1) {}
        if (i == name_start) { i += 1; continue; }
        const attr_name = src[name_start..i];

        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
        if (i >= src.len or src[i] != '=') {
            try attrs.append(arena, .{ .name = attr_name, .value = "" });
            continue;
        }
        i += 1;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}

        var val: []const u8 = "";
        if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
            const q = src[i]; i += 1;
            const vs = i;
            while (i < src.len and src[i] != q) : (i += 1) {}
            val = src[vs..i];
            if (i < src.len) i += 1;
        } else {
            const vs = i;
            while (i < src.len and src[i] != ' ' and src[i] != '>' and src[i] != '/') : (i += 1) {}
            val = src[vs..i];
        }
        if (val.len > max_val) return error.InputTooLarge;
        try attrs.append(arena, .{ .name = attr_name, .value = val });
    }
    return i;
}
