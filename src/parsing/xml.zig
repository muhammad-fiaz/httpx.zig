//! XML parser with a Tree-sitter structural foundation.
//!
//! The Tree-sitter XML grammar below tokenizes source into tags, text,
//! comments, CDATA, and processing instructions. The DOM builder consumes
//! those syntax nodes directly, preserving tag case and namespaces.
//! Parses XML into a dom.Tree. Preserves tag case and CDATA sections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const ts = @import("treesitter");
const Tree = dom.Tree;
const Attribute = dom.Attribute;

pub const XmlTree = ts.Tree;
pub const XmlNode = ts.Node;

const xml_sym_end: u16 = 0;
const xml_sym_open_tag: u16 = 1;
const xml_sym_close_tag: u16 = 2;
const xml_sym_selfclose_tag: u16 = 3;
const xml_sym_comment: u16 = 4;
const xml_sym_cdata: u16 = 5;
const xml_sym_pi: u16 = 6;
const xml_sym_doctype: u16 = 7;
const xml_sym_text: u16 = 8;
const xml_sym_program: u16 = 9;
const xml_sym_nodes: u16 = 10;
const xml_sym_node: u16 = 11;
const xml_sym_error: u16 = 12;

fn isXmlTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.' or c == '?';
}

fn xmlTagNameLen(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isXmlTagChar(source[i])) : (i += 1) {}
    return i - start;
}

fn matchXmlOpenTag(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<') return null;
    const c1 = source[start + 1];
    if (c1 == '/' or c1 == '!' or c1 == '?') return null;
    if (!std.ascii.isAlphabetic(c1) and c1 != '_' and c1 != ':') return null;
    var i = start + 1 + xmlTagNameLen(source, start + 1);
    var in_quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            i += 1;
            continue;
        }
        if (c == '>') {
            if (i > start + 1 and source[i - 1] == '/') return null;
            return i + 1 - start;
        }
        i += 1;
    }
    return null;
}

fn matchXmlCloseTag(source: []const u8, start: usize) ?usize {
    if (start + 3 > source.len or source[start] != '<' or source[start + 1] != '/') return null;
    var i = start + 2;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
    if (xmlTagNameLen(source, i) == 0) return null;
    i += xmlTagNameLen(source, i);
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
    if (i >= source.len or source[i] != '>') return null;
    return i + 1 - start;
}

fn matchXmlSelfCloseTag(source: []const u8, start: usize) ?usize {
    if (start + 3 > source.len or source[start] != '<') return null;
    const c1 = source[start + 1];
    if (c1 == '/' or c1 == '!' or c1 == '?') return null;
    if (!std.ascii.isAlphabetic(c1) and c1 != '_' and c1 != ':') return null;
    var i = start + 1 + xmlTagNameLen(source, start + 1);
    var in_quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            i += 1;
            continue;
        }
        if (c == '>' and i > start + 1 and source[i - 1] == '/') return i + 1 - start;
        if (c == '>') return null;
        i += 1;
    }
    return null;
}

fn matchXmlComment(source: []const u8, start: usize) ?usize {
    if (start + 4 > source.len) return null;
    if (!std.mem.eql(u8, source[start .. start + 4], "<!--")) return null;
    const close = std.mem.indexOfPos(u8, source, start + 4, "-->") orelse return source.len - start;
    return close + 3 - start;
}

fn matchXmlCdata(source: []const u8, start: usize) ?usize {
    if (start + 9 > source.len) return null;
    if (!std.mem.eql(u8, source[start .. start + 9], "<![CDATA[")) return null;
    const close = std.mem.indexOfPos(u8, source, start + 9, "]]>") orelse return source.len - start;
    return close + 3 - start;
}

fn matchXmlPi(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<' or source[start + 1] != '?') return null;
    const close = std.mem.indexOfPos(u8, source, start + 2, "?>") orelse return null;
    return close + 2 - start;
}

fn matchXmlDoctype(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<' or source[start + 1] != '!') return null;
    if (start + 9 <= source.len and std.mem.eql(u8, source[start .. start + 9], "<![CDATA[")) return null;
    if (start + 4 <= source.len and std.mem.eql(u8, source[start .. start + 4], "<!--")) return null;
    var i = start + 2;
    var depth: usize = 0;
    var in_quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            i += 1;
            continue;
        }
        if (c == '[') depth += 1;
        if (c == '>') {
            if (depth == 0) return i + 1 - start;
            depth -= 0;
        }
        if (c == ']' and depth > 0) depth -= 1;
        i += 1;
    }
    return null;
}

fn matchXmlText(source: []const u8, start: usize) ?usize {
    if (start >= source.len) return null;
    if (source[start] == '<') {
        if (start + 1 >= source.len) return 1;
        const n = source[start + 1];
        if (std.ascii.isAlphabetic(n) or n == '_' or n == ':' or n == '/' or n == '!' or n == '?') return null;
        return 1;
    }
    var i = start;
    while (i < source.len and source[i] != '<') : (i += 1) {}
    return i - start;
}

const xml_symbol_table: []const ts.language_mod.symbols.SymbolInfo = &.{
    .{ .id = xml_sym_end, .name = "end", .kind = .end, .metadata = .{ .visible = false, .named = false } },
    .{ .id = xml_sym_open_tag, .name = "open_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_close_tag, .name = "close_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_selfclose_tag, .name = "selfclose_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_comment, .name = "comment", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_cdata, .name = "cdata", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_pi, .name = "pi", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_doctype, .name = "doctype", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_text, .name = "text", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_program, .name = "program", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_nodes, .name = "nodes", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_node, .name = "node", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = xml_sym_error, .name = "ERROR", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
};

const xml_token_matchers: []const ts.language_mod.TokenMatcher = &.{
    .{ .symbol = xml_sym_cdata, .match = matchXmlCdata },
    .{ .symbol = xml_sym_comment, .match = matchXmlComment },
    .{ .symbol = xml_sym_pi, .match = matchXmlPi },
    .{ .symbol = xml_sym_doctype, .match = matchXmlDoctype },
    .{ .symbol = xml_sym_close_tag, .match = matchXmlCloseTag },
    .{ .symbol = xml_sym_selfclose_tag, .match = matchXmlSelfCloseTag },
    .{ .symbol = xml_sym_open_tag, .match = matchXmlOpenTag },
    .{ .symbol = xml_sym_text, .match = matchXmlText },
};

const xml_s0_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_open_tag, .action = .{ .shift = 6 } },
    .{ .symbol = xml_sym_close_tag, .action = .{ .shift = 12 } },
    .{ .symbol = xml_sym_selfclose_tag, .action = .{ .shift = 7 } },
    .{ .symbol = xml_sym_text, .action = .{ .shift = 8 } },
    .{ .symbol = xml_sym_comment, .action = .{ .shift = 9 } },
    .{ .symbol = xml_sym_cdata, .action = .{ .shift = 10 } },
    .{ .symbol = xml_sym_pi, .action = .{ .shift = 13 } },
    .{ .symbol = xml_sym_doctype, .action = .{ .shift = 14 } },
    .{ .symbol = xml_sym_end, .action = .{ .reduce = .{ .symbol = xml_sym_program, .child_count = 0, .production_id = 0 } } },
};
const xml_s0_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = xml_sym_program, .state = 1 },
    .{ .symbol = xml_sym_nodes, .state = 2 },
    .{ .symbol = xml_sym_node, .state = 3 },
};
const xml_s1_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_end, .action = .accept },
};
const xml_s2_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_open_tag, .action = .{ .shift = 6 } },
    .{ .symbol = xml_sym_close_tag, .action = .{ .shift = 12 } },
    .{ .symbol = xml_sym_selfclose_tag, .action = .{ .shift = 7 } },
    .{ .symbol = xml_sym_text, .action = .{ .shift = 8 } },
    .{ .symbol = xml_sym_comment, .action = .{ .shift = 9 } },
    .{ .symbol = xml_sym_cdata, .action = .{ .shift = 10 } },
    .{ .symbol = xml_sym_pi, .action = .{ .shift = 13 } },
    .{ .symbol = xml_sym_doctype, .action = .{ .shift = 14 } },
    .{ .symbol = xml_sym_end, .action = .{ .reduce = .{ .symbol = xml_sym_program, .child_count = 1, .production_id = 1 } } },
};
const xml_s2_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = xml_sym_node, .state = 4 },
};
const xml_s3_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_open_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_close_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_text, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_comment, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_cdata, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_pi, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_doctype, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = xml_sym_end, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 1, .production_id = 2 } } },
};
const xml_s4_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_open_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_close_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_text, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_comment, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_cdata, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_pi, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_doctype, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = xml_sym_end, .action = .{ .reduce = .{ .symbol = xml_sym_nodes, .child_count = 2, .production_id = 3 } } },
};
const xml_s5_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = xml_sym_open_tag, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_close_tag, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_text, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_comment, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_cdata, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_pi, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_doctype, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = xml_sym_end, .action = .{ .reduce = .{ .symbol = xml_sym_node, .child_count = 1, .production_id = 4 } } },
};

const xml_parse_states: []const ts.language_mod.tables.ParseState = &.{
    .{ .actions = xml_s0_actions, .gotos = xml_s0_gotos },
    .{ .actions = xml_s1_actions },
    .{ .actions = xml_s2_actions, .gotos = xml_s2_gotos },
    .{ .actions = xml_s3_actions },
    .{ .actions = xml_s4_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
    .{ .actions = xml_s5_actions },
};

pub const xmlLanguage: ts.Language = .{
    .metadata = .{
        .name = "xml",
        .abi_version = ts.language_mod.metadata.current_abi_version,
        .version = "0.0.1",
        .symbol_count = 13,
        .state_count = 15,
        .field_count = 0,
    },
    .symbols = xml_symbol_table,
    .token_matchers = xml_token_matchers,
    .extra_symbols = &.{},
    .table = .{
        .states = xml_parse_states,
        .start_state = 0,
        .end_symbol = xml_sym_end,
        .error_symbol = xml_sym_error,
    },
    .fields = .{},
};

fn parseXmlTree(allocator: Allocator, src: []const u8) ParseError!XmlTree {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(xmlLanguage) catch return error.OutOfMemory;
    return parser.parseString(src) catch return error.OutOfMemory;
}

const XmlTokenKind = enum { open_tag, close_tag, selfclose_tag, comment, cdata, pi, doctype, text };

const XmlToken = struct {
    kind: XmlTokenKind,
    start: usize,
    end: usize,
};

fn collectXmlTokens(tree: *const XmlTree, allocator: Allocator) Allocator.Error![]XmlToken {
    var out = std.ArrayList(XmlToken).empty;
    errdefer out.deinit(allocator);
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, tree.rootNode());
    var ordered = std.ArrayList(ts.Node).empty;
    defer ordered.deinit(allocator);
    while (stack.pop()) |cur| {
        const t = cur.nodeType();
        if (std.mem.eql(u8, t, "open_tag") or std.mem.eql(u8, t, "close_tag") or
            std.mem.eql(u8, t, "selfclose_tag") or std.mem.eql(u8, t, "comment") or
            std.mem.eql(u8, t, "cdata") or std.mem.eql(u8, t, "pi") or
            std.mem.eql(u8, t, "doctype") or std.mem.eql(u8, t, "text"))
        {
            try ordered.append(allocator, cur);
            continue;
        }
        var i: u32 = cur.childCount();
        while (i > 0) {
            i -= 1;
            if (cur.child(i)) |c| try stack.append(allocator, c);
        }
    }
    std.mem.sort(ts.Node, ordered.items, {}, struct {
        fn less(_: void, a: ts.Node, b: ts.Node) bool {
            return a.startByte() < b.startByte();
        }
    }.less);
    for (ordered.items) |n| {
        const t = n.nodeType();
        const kind: XmlTokenKind = if (std.mem.eql(u8, t, "open_tag")) .open_tag else if (std.mem.eql(u8, t, "close_tag")) .close_tag else if (std.mem.eql(u8, t, "selfclose_tag")) .selfclose_tag else if (std.mem.eql(u8, t, "comment")) .comment else if (std.mem.eql(u8, t, "cdata")) .cdata else if (std.mem.eql(u8, t, "pi")) .pi else if (std.mem.eql(u8, t, "doctype")) .doctype else .text;
        try out.append(allocator, .{ .kind = kind, .start = n.startByte(), .end = n.endByte() });
    }
    return out.toOwnedSlice(allocator);
}

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
    maxNodes: u32 = dom.MAX_NODES,
    maxDepth: u32 = dom.MAX_DEPTH,
    maxAttrs: u32 = 256,
    maxAttrValue: usize = 8192,
};

pub fn parse(arena: Allocator, xmlSrc: []const u8, opts: Options) ParseError!Tree {
    var tree = try Tree.initCapacity(arena, @min(xmlSrc.len / 12 + 4, opts.maxNodes));
    errdefer tree.deinit(arena);
    const root = try tree.append(arena, .{ .kind = .document });
    var p = Parser{
        .arena = arena,
        .tree = &tree,
        .src = xmlSrc,
        .opts = opts,
    };
    try p.openStack.append(arena, root);
    var ts_tree = try parseXmlTree(arena, xmlSrc);
    defer ts_tree.deinit();
    const tokens = try collectXmlTokens(&ts_tree, arena);
    if (ts_tree.hasError()) tree.getMut(root).hasError = true;
    try p.runTokens(tokens);
    return tree;
}

const Parser = struct {
    arena: Allocator,
    tree: *Tree,
    src: []const u8,
    opts: Options,
    openStack: std.ArrayList(u32) = .empty,

    fn cur(self: *const Parser) u32 {
        return if (self.openStack.items.len > 0)
            self.openStack.items[self.openStack.items.len - 1]
        else
            0;
    }

    fn runTokens(self: *Parser, tokens: []const XmlToken) ParseError!void {
        var covered: usize = 0;
        for (tokens) |tok| {
            if (tok.start > covered) {
                try self.appendText(self.src[covered..tok.start]);
                covered = tok.start;
            }
            switch (tok.kind) {
                .text => {
                    try self.appendText(self.src[tok.start..tok.end]);
                },
                .comment => {
                    const raw = self.src[tok.start..tok.end];
                    const data = if (raw.len >= 7 and std.mem.eql(u8, raw[0..4], "<!--") and std.mem.endsWith(u8, raw, "-->"))
                        raw[4 .. raw.len - 3]
                    else
                        raw;
                    const idx = try self.tree.append(self.arena, .{ .kind = .comment, .data = data });
                    self.tree.appendChild(self.cur(), idx);
                },
                .cdata => {
                    const raw = self.src[tok.start..tok.end];
                    const data = if (raw.len >= 12 and std.mem.eql(u8, raw[0..9], "<![CDATA[") and std.mem.endsWith(u8, raw, "]]>"))
                        raw[9 .. raw.len - 3]
                    else
                        raw;
                    const idx = try self.tree.append(self.arena, .{ .kind = .cdata, .data = data });
                    self.tree.appendChild(self.cur(), idx);
                },
                .pi, .doctype => {},
                .selfclose_tag => {
                    const tag = try self.parseOpenTag(self.src[tok.start..tok.end]);
                    const nodeIdx = try self.tree.append(self.arena, .{
                        .kind = .element,
                        .tag = tag.name,
                        .attrs = tag.attrs,
                    });
                    self.tree.appendChild(self.cur(), nodeIdx);
                },
                .open_tag => {
                    if (self.openStack.items.len >= self.opts.maxDepth) return error.TooDeep;
                    const tag = try self.parseOpenTag(self.src[tok.start..tok.end]);
                    const nodeIdx = try self.tree.append(self.arena, .{
                        .kind = .element,
                        .tag = tag.name,
                        .attrs = tag.attrs,
                    });
                    self.tree.appendChild(self.cur(), nodeIdx);
                    try self.openStack.append(self.arena, nodeIdx);
                },
                .close_tag => {
                    const raw = self.src[tok.start..tok.end];
                    var inner = raw;
                    if (inner.len >= 2) inner = inner[2..];
                    if (inner.len > 0 and inner[inner.len - 1] == '>') inner = inner[0 .. inner.len - 1];
                    const tag = std.mem.trim(u8, inner, " \t\r\n");
                    try self.closeElement(tag);
                },
            }
            covered = @max(covered, tok.end);
        }
        if (covered < self.src.len) {
            try self.appendText(self.src[covered..]);
        }
        if (self.openStack.items.len > 1 and !self.opts.lenient) return error.MalformedXml;
    }

    fn appendText(self: *Parser, raw: []const u8) ParseError!void {
        if (raw.len == 0) return;
        const idx = try self.tree.append(self.arena, .{ .kind = .text, .data = raw });
        self.tree.appendChild(self.cur(), idx);
    }

    const OpenTag = struct {
        name: []const u8,
        attrs: []const Attribute,
    };

    fn parseOpenTag(self: *Parser, slice: []const u8) ParseError!OpenTag {
        var name_end: usize = 1;
        while (name_end < slice.len and !isStop(slice[name_end])) : (name_end += 1) {}
        const name = slice[1..name_end];
        var attrs: std.ArrayList(Attribute) = .empty;
        defer attrs.deinit(self.arena);
        var selfClosing = false;
        _ = try parseAttrs(self.arena, slice, name_end, &attrs, &selfClosing, self.opts.maxAttrValue);
        if (attrs.items.len > self.opts.maxAttrs) return error.TooManyAttributes;
        return .{ .name = name, .attrs = try attrs.toOwnedSlice(self.arena) };
    }

    fn closeElement(self: *Parser, tag: []const u8) ParseError!void {
        var k = self.openStack.items.len;
        while (k > 0) : (k -= 1) {
            const idx = self.openStack.items[k - 1];
            const node = self.tree.get(idx);
            if (node.kind == .element and std.mem.eql(u8, node.tag, tag)) {
                self.openStack.shrinkRetainingCapacity(k - 1);
                return;
            }
        }
        if (!self.opts.lenient) return error.MalformedXml;
    }
};

fn isStop(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0C' or c == '>' or c == '/';
}

test "xml grammar tokenizes elements and text" {
    const a = std.testing.allocator;
    var t = try parseXmlTree(a, "<feed xmlns=\"http://a\"><title>x</title></feed>");
    defer t.deinit();
    try std.testing.expect(!t.hasError());
    try std.testing.expectEqualStrings("program", t.rootNode().nodeType());
}

test "xml preserves namespaces and cdata via syntax tree" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "<rss><channel><item><title><![CDATA[Hi]]></title></item></channel></rss>", .{});
    var found_cdata = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .cdata and std.mem.eql(u8, n.data, "Hi")) found_cdata = true;
    }
    try std.testing.expect(found_cdata);
}

test "xml strict mode rejects mismatched tags" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const res = parse(arena.allocator(), "<a><b></a></b>", .{ .lenient = false });
    try std.testing.expectError(error.MalformedXml, res);
}

fn parseAttrs(
    arena: Allocator,
    src: []const u8,
    start: usize,
    attrs: *std.ArrayList(Attribute),
    selfClosing: *bool,
    maxVal: usize,
) ParseError!usize {
    var i = start;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) : (i += 1) {}
        if (i >= src.len) break;
        if (src[i] == '>') {
            i += 1;
            break;
        }
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '>') {
            selfClosing.* = true;
            i += 2;
            break;
        }

        const name_start = i;
        while (i < src.len and src[i] != '=' and src[i] != '>' and src[i] != '/' and
            src[i] != ' ' and src[i] != '\t' and src[i] != '\r' and src[i] != '\n') : (i += 1)
        {}
        if (i == name_start) {
            i += 1;
            continue;
        }
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
            const q = src[i];
            i += 1;
            const vs = i;
            while (i < src.len and src[i] != q) : (i += 1) {}
            val = src[vs..i];
            if (i < src.len) i += 1;
        } else {
            const vs = i;
            while (i < src.len and src[i] != ' ' and src[i] != '>' and src[i] != '/') : (i += 1) {}
            val = src[vs..i];
        }
        if (val.len > maxVal) return error.InputTooLarge;
        try attrs.append(arena, .{ .name = attr_name, .value = val });
    }
    return i;
}
