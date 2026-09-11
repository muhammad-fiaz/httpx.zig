//! HTML5 parser with a Tree-sitter structural foundation.
//!
//! The Tree-sitter HTML grammar below tokenizes source into tags, text,
//! comments, and declarations (with byte ranges and error recovery).
//! The DOM builder consumes those syntax nodes directly, applying HTML5
//! semantics: void elements, raw-text elements (script/style), attribute
//! parsing (quoted/unquoted/boolean), case-insensitive tag matching,
//! source range tracking, and graceful recovery for malformed input.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const ts = @import("treesitter");
const Tree = dom.Tree;
const Node = dom.Node;
const Attribute = dom.Attribute;
const SourceRange = dom.SourceRange;
const SourcePoint = dom.SourcePoint;
const NO_NODE = dom.NO_NODE;

pub const HtmlTree = ts.Tree;
pub const HtmlNode = ts.Node;

const html_sym_end: u16 = 0;
const html_sym_open_tag: u16 = 1;
const html_sym_close_tag: u16 = 2;
const html_sym_selfclose_tag: u16 = 3;
const html_sym_comment: u16 = 4;
const html_sym_doctype: u16 = 5;
const html_sym_pi: u16 = 6;
const html_sym_text: u16 = 7;
const html_sym_program: u16 = 8;
const html_sym_nodes: u16 = 9;
const html_sym_node: u16 = 10;
const html_sym_error: u16 = 11;

fn isHtmlTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.';
}

fn matchHtmlTagName(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isHtmlTagChar(source[i])) : (i += 1) {}
    return i - start;
}

fn matchHtmlOpenTag(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<') return null;
    const c1 = source[start + 1];
    if (c1 == '/' or c1 == '!' or c1 == '?') return null;
    if (!std.ascii.isAlphabetic(c1)) return null;
    var i = start + 1 + matchHtmlTagName(source, start + 1);
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

fn matchHtmlCloseTag(source: []const u8, start: usize) ?usize {
    if (start + 3 > source.len or source[start] != '<' or source[start + 1] != '/') return null;
    var i = start + 2;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
    const name_len = matchHtmlTagName(source, i);
    if (name_len == 0) return null;
    i += name_len;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
    if (i >= source.len or source[i] != '>') return null;
    return i + 1 - start;
}

fn matchHtmlSelfCloseTag(source: []const u8, start: usize) ?usize {
    if (start + 3 > source.len or source[start] != '<') return null;
    const c1 = source[start + 1];
    if (c1 == '/' or c1 == '!' or c1 == '?') return null;
    if (!std.ascii.isAlphabetic(c1)) return null;
    var i = start + 1 + matchHtmlTagName(source, start + 1);
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

fn matchHtmlComment(source: []const u8, start: usize) ?usize {
    if (start + 4 > source.len) return null;
    if (!std.mem.eql(u8, source[start .. start + 4], "<!--")) return null;
    const close = std.mem.indexOfPos(u8, source, start + 4, "-->") orelse return source.len - start;
    return close + 3 - start;
}

fn matchHtmlDoctype(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<' or source[start + 1] != '!') return null;
    if (start + 4 <= source.len and std.mem.eql(u8, source[start .. start + 4], "<!--")) return null;
    var i = start + 2;
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
        if (c == '>') return i + 1 - start;
        i += 1;
    }
    return null;
}

fn matchHtmlPi(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len or source[start] != '<' or source[start + 1] != '?') return null;
    const close = std.mem.indexOfPos(u8, source, start + 2, "?>") orelse return null;
    return close + 2 - start;
}

fn matchHtmlText(source: []const u8, start: usize) ?usize {
    if (start >= source.len) return null;
    if (source[start] == '<') {
        if (start + 1 >= source.len) return 1;
        const n = source[start + 1];
        if (std.ascii.isAlphabetic(n) or n == '/' or n == '!' or n == '?') return null;
        return 1;
    }
    var i = start;
    while (i < source.len and source[i] != '<') : (i += 1) {}
    return i - start;
}

const html_symbol_table: []const ts.language_mod.symbols.SymbolInfo = &.{
    .{ .id = html_sym_end, .name = "end", .kind = .end, .metadata = .{ .visible = false, .named = false } },
    .{ .id = html_sym_open_tag, .name = "open_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_close_tag, .name = "close_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_selfclose_tag, .name = "selfclose_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_comment, .name = "comment", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_doctype, .name = "doctype", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_pi, .name = "pi", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_text, .name = "text", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_program, .name = "program", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_nodes, .name = "nodes", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_node, .name = "node", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = html_sym_error, .name = "ERROR", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
};

const html_token_matchers: []const ts.language_mod.TokenMatcher = &.{
    .{ .symbol = html_sym_comment, .match = matchHtmlComment },
    .{ .symbol = html_sym_doctype, .match = matchHtmlDoctype },
    .{ .symbol = html_sym_pi, .match = matchHtmlPi },
    .{ .symbol = html_sym_close_tag, .match = matchHtmlCloseTag },
    .{ .symbol = html_sym_selfclose_tag, .match = matchHtmlSelfCloseTag },
    .{ .symbol = html_sym_open_tag, .match = matchHtmlOpenTag },
    .{ .symbol = html_sym_text, .match = matchHtmlText },
};

const html_s0_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .shift = 6 } },
    .{ .symbol = html_sym_close_tag, .action = .{ .shift = 12 } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .shift = 7 } },
    .{ .symbol = html_sym_text, .action = .{ .shift = 8 } },
    .{ .symbol = html_sym_comment, .action = .{ .shift = 9 } },
    .{ .symbol = html_sym_doctype, .action = .{ .shift = 10 } },
    .{ .symbol = html_sym_pi, .action = .{ .shift = 11 } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_program, .child_count = 0, .production_id = 0 } } },
};
const html_s0_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = html_sym_program, .state = 1 },
    .{ .symbol = html_sym_nodes, .state = 2 },
    .{ .symbol = html_sym_node, .state = 3 },
};
const html_s1_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_end, .action = .accept },
};
const html_s2_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .shift = 6 } },
    .{ .symbol = html_sym_close_tag, .action = .{ .shift = 12 } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .shift = 7 } },
    .{ .symbol = html_sym_text, .action = .{ .shift = 8 } },
    .{ .symbol = html_sym_comment, .action = .{ .shift = 9 } },
    .{ .symbol = html_sym_doctype, .action = .{ .shift = 10 } },
    .{ .symbol = html_sym_pi, .action = .{ .shift = 11 } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_program, .child_count = 1, .production_id = 1 } } },
};
const html_s2_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = html_sym_node, .state = 4 },
};
const html_s3_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 1, .production_id = 2 } } },
};
const html_s4_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_nodes, .child_count = 2, .production_id = 3 } } },
};
const html_s5_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 4 } } },
};
const html_s6_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 5 } } },
};
const html_s7_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 6 } } },
};
const html_s8_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 7 } } },
};
const html_s9_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 8 } } },
};
const html_s10_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 9 } } },
};
const html_s11_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 10 } } },
};

const html_s12_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = html_sym_open_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_close_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_selfclose_tag, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_comment, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_doctype, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_pi, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_text, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = html_sym_end, .action = .{ .reduce = .{ .symbol = html_sym_node, .child_count = 1, .production_id = 11 } } },
};

const html_parse_states: []const ts.language_mod.tables.ParseState = &.{
    .{ .actions = html_s0_actions, .gotos = html_s0_gotos },
    .{ .actions = html_s1_actions },
    .{ .actions = html_s2_actions, .gotos = html_s2_gotos },
    .{ .actions = html_s3_actions },
    .{ .actions = html_s4_actions },
    .{ .actions = html_s5_actions },
    .{ .actions = html_s6_actions },
    .{ .actions = html_s7_actions },
    .{ .actions = html_s8_actions },
    .{ .actions = html_s9_actions },
    .{ .actions = html_s10_actions },
    .{ .actions = html_s11_actions },
    .{ .actions = html_s12_actions },
};

pub const htmlLanguage: ts.Language = .{
    .metadata = .{
        .name = "html",
        .abi_version = ts.language_mod.metadata.current_abi_version,
        .version = "0.0.1",
        .symbol_count = 12,
        .state_count = 13,
        .field_count = 0,
    },
    .symbols = html_symbol_table,
    .token_matchers = html_token_matchers,
    .extra_symbols = &.{},
    .table = .{
        .states = html_parse_states,
        .start_state = 0,
        .end_symbol = html_sym_end,
        .error_symbol = html_sym_error,
    },
    .fields = .{},
};

fn parseHtmlTree(allocator: Allocator, src: []const u8) ParseError!HtmlTree {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(htmlLanguage) catch return error.OutOfMemory;
    return parser.parseString(src) catch return error.OutOfMemory;
}

const HtmlTokenKind = enum { open_tag, close_tag, selfclose_tag, comment, doctype, pi, text };

const HtmlToken = struct {
    kind: HtmlTokenKind,
    start: usize,
    end: usize,
};

fn collectHtmlTokens(tree: *const HtmlTree, allocator: Allocator) Allocator.Error![]HtmlToken {
    var out = std.ArrayList(HtmlToken).empty;
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
            std.mem.eql(u8, t, "doctype") or std.mem.eql(u8, t, "pi") or
            std.mem.eql(u8, t, "text"))
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
        const kind: HtmlTokenKind = if (std.mem.eql(u8, t, "open_tag")) .open_tag else if (std.mem.eql(u8, t, "close_tag")) .close_tag else if (std.mem.eql(u8, t, "selfclose_tag")) .selfclose_tag else if (std.mem.eql(u8, t, "comment")) .comment else if (std.mem.eql(u8, t, "doctype")) .doctype else if (std.mem.eql(u8, t, "pi")) .pi else .text;
        try out.append(allocator, .{ .kind = kind, .start = n.startByte(), .end = n.endByte() });
    }
    return out.toOwnedSlice(allocator);
}

pub fn changedRanges(allocator: Allocator, oldSrc: []const u8, newSrc: []const u8) !usize {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(htmlLanguage) catch return error.OutOfMemory;
    var old_tree = parser.parseString(oldSrc) catch return error.OutOfMemory;
    defer old_tree.deinit();
    const edit = ts.InputEdit{
        .start_byte = 0,
        .old_end_byte = @intCast(oldSrc.len),
        .new_end_byte = @intCast(newSrc.len),
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = pointForOffsetTs(oldSrc, oldSrc.len),
        .new_end_point = pointForOffsetTs(newSrc, newSrc.len),
    };
    var new_tree = parser.parse(&old_tree, edit, newSrc) catch return error.OutOfMemory;
    defer new_tree.deinit();
    const ranges = ts.getChangedRanges(allocator, &old_tree, &new_tree) catch return error.OutOfMemory;
    defer ts.freeChangedRanges(allocator, ranges);
    return ranges.len;
}

fn pointForOffsetTs(source: []const u8, offset: usize) ts.Point {
    const clamped = @min(offset, source.len);
    var row: u32 = 0;
    var col: u32 = 0;
    for (source[0..clamped]) |b| {
        if (b == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .column = col };
}

/// Limits for the HTML parser.
pub const Limits = struct {
    maxNodes: u32 = dom.MAX_NODES,
    maxDepth: u32 = dom.MAX_DEPTH,
    maxAttrs: u32 = 256,
    maxAttrValue: usize = 8192,
    maxTextBlock: usize = 4 * 1024 * 1024,
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
    .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
    .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
    .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
    .{ "track", {} }, .{ "wbr", {} },
});

/// Elements whose content is raw text (no child tags parsed inside).
const RAW_TEXT_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    .{ "script", {} }, .{ "style", {} }, .{ "textarea", {} }, .{ "title", {} },
});

pub fn parse(arena: Allocator, htmlSrc: []const u8, limits: Limits) ParseError!Tree {
    var tree = try Tree.initCapacity(arena, @min(htmlSrc.len / 16 + 4, limits.maxNodes));
    errdefer tree.deinit(arena);
    const root = try tree.append(arena, .{
        .kind = .document,
        .range = .{
            .startByte = 0,
            .endByte = @intCast(htmlSrc.len),
            .startPoint = .{ .row = 0, .column = 0 },
            .endPoint = pointForOffset(htmlSrc, htmlSrc.len),
        },
    });
    var builder = Builder{
        .arena = arena,
        .tree = &tree,
        .openStack = .empty,
        .limits = limits,
    };
    try builder.openStack.append(arena, root);
    var ts_tree = try parseHtmlTree(arena, htmlSrc);
    defer ts_tree.deinit();
    const tokens = try collectHtmlTokens(&ts_tree, arena);
    try builder.runTokens(htmlSrc, tokens, ts_tree.hasError());
    return tree;
}

const Builder = struct {
    arena: Allocator,
    tree: *Tree,
    openStack: std.ArrayList(u32),
    limits: Limits,

    fn currentParent(self: *const Builder) u32 {
        return if (self.openStack.items.len > 0)
            self.openStack.items[self.openStack.items.len - 1]
        else
            0;
    }

    fn depth(self: *const Builder) u32 {
        return @intCast(self.openStack.items.len);
    }

    fn runTokens(self: *Builder, src: []const u8, tokens: []const HtmlToken, had_error: bool) ParseError!void {
        self.tree.getMut(self.openStack.items[0]).hasError = had_error;
        var covered: usize = 0;
        var ti: usize = 0;
        while (ti < tokens.len) {
            const tok = tokens[ti];
            if (tok.start > covered) {
                try self.appendText(src, src[covered..tok.start], covered, tok.start, true);
                covered = tok.start;
            }
            switch (tok.kind) {
                .text => {
                    try self.appendText(src, src[tok.start..tok.end], tok.start, tok.end, false);
                    ti += 1;
                },
                .comment => {
                    const raw = src[tok.start..tok.end];
                    const data = if (raw.len >= 7 and std.mem.eql(u8, raw[0..4], "<!--") and std.mem.endsWith(u8, raw, "-->"))
                        raw[4 .. raw.len - 3]
                    else
                        raw;
                    const idx = try self.tree.append(self.arena, .{
                        .kind = .comment,
                        .data = data,
                        .range = makeRange(src, tok.start, tok.end),
                    });
                    self.tree.appendChild(self.currentParent(), idx);
                    ti += 1;
                },
                .doctype => {
                    const idx = try self.tree.append(self.arena, .{
                        .kind = .doctype,
                        .data = "html",
                        .range = makeRange(src, tok.start, tok.end),
                    });
                    self.tree.appendChild(self.currentParent(), idx);
                    ti += 1;
                },
                .pi => {
                    ti += 1;
                },
                .selfclose_tag => {
                    const info = try self.parseTagToken(src[tok.start..tok.end], tok.start, src);
                    const nodeIdx = try self.tree.append(self.arena, .{
                        .kind = .element,
                        .tag = info.tag,
                        .attrs = info.attrs,
                        .range = makeRange(src, tok.start, tok.end),
                    });
                    self.tree.appendChild(self.currentParent(), nodeIdx);
                    ti += 1;
                },
                .open_tag => {
                    const info = try self.parseTagToken(src[tok.start..tok.end], tok.start, src);
                    if (self.depth() >= self.limits.maxDepth) return error.TooDeep;
                    const nodeIdx = try self.tree.append(self.arena, .{
                        .kind = .element,
                        .tag = info.tag,
                        .attrs = info.attrs,
                        .range = makeRange(src, tok.start, tok.end),
                    });
                    self.tree.appendChild(self.currentParent(), nodeIdx);
                    if (VOID_ELEMENTS.has(info.tag)) {
                        ti += 1;
                        continue;
                    }
                    try self.openStack.append(self.arena, nodeIdx);
                    if (RAW_TEXT_ELEMENTS.has(info.tag)) {
                        var j = ti + 1;
                        var close_idx: ?usize = null;
                        while (j < tokens.len) : (j += 1) {
                            if (tokens[j].kind == .close_tag and closeTagNameEql(src[tokens[j].start..tokens[j].end], info.tag)) {
                                close_idx = j;
                                break;
                            }
                        }
                        const content_end = if (close_idx) |cj| tokens[cj].start else src.len;
                        if (content_end > tok.end) {
                            const raw_content = src[tok.end..content_end];
                            const txt_idx = try self.tree.append(self.arena, .{
                                .kind = .text,
                                .data = raw_content,
                                .range = makeRange(src, tok.end, content_end),
                            });
                            self.tree.appendChild(nodeIdx, txt_idx);
                        }
                        if (close_idx) |cj| {
                            self.tree.getMut(nodeIdx).range.endByte = @intCast(tokens[cj].end);
                            self.tree.getMut(nodeIdx).range.endPoint = pointForOffset(src, tokens[cj].end);
                            covered = @max(covered, tokens[cj].end);
                            ti = cj + 1;
                        } else {
                            self.tree.getMut(nodeIdx).range.endByte = @intCast(src.len);
                            self.tree.getMut(nodeIdx).range.endPoint = pointForOffset(src, src.len);
                            covered = @max(covered, src.len);
                            ti = tokens.len;
                        }
                        _ = self.openStack.pop();
                        continue;
                    }
                    ti += 1;
                },
                .close_tag => {
                    const name = closeTagName(src[tok.start..tok.end]);
                    const tag = lowerBuf(self.arena, name) catch name;
                    self.popToTag(tag, tok.end, src);
                    ti += 1;
                },
            }
            covered = @max(covered, tok.end);
        }
        if (covered < src.len) {
            try self.appendText(src, src[covered..], covered, src.len, true);
        }
        if (self.openStack.items.len > 1) {
            self.tree.getMut(self.openStack.items[0]).hasError = true;
        }
    }

    fn appendText(self: *Builder, src: []const u8, raw: []const u8, start: usize, end: usize, is_error: bool) ParseError!void {
        if (raw.len == 0) return;
        if (raw.len > self.limits.maxTextBlock) return error.InputTooLarge;
        const idx = try self.tree.append(self.arena, .{
            .kind = .text,
            .data = raw,
            .range = makeRange(src, start, end),
            .hasError = is_error,
        });
        self.tree.appendChild(self.currentParent(), idx);
    }

    const TagInfo = struct {
        tag: []const u8,
        attrs: []const Attribute,
    };

    fn parseTagToken(self: *Builder, slice: []const u8, abs_start: usize, src: []const u8) ParseError!TagInfo {
        _ = abs_start;
        _ = src;
        var name_end: usize = 1;
        while (name_end < slice.len and !isTagNameEnd(slice[name_end])) : (name_end += 1) {}
        const tag = try lowerBuf(self.arena, slice[1..name_end]);
        var attrs: std.ArrayList(Attribute) = .empty;
        defer attrs.deinit(self.arena);
        var selfClosing = false;
        _ = try parseAttrs(self.arena, slice, name_end, &attrs, &selfClosing, self.limits);
        if (attrs.items.len > self.limits.maxAttrs) return error.TooManyAttributes;
        return .{ .tag = tag, .attrs = try attrs.toOwnedSlice(self.arena) };
    }

    fn closeTagName(slice: []const u8) []const u8 {
        var inner = slice;
        if (inner.len >= 2 and inner[0] == '<' and inner[1] == '/') inner = inner[2..];
        if (inner.len > 0 and inner[inner.len - 1] == '>') inner = inner[0 .. inner.len - 1];
        return std.mem.trim(u8, inner, " \t\r\n\x0C");
    }

    fn closeTagNameEql(slice: []const u8, tag: []const u8) bool {
        return std.ascii.eqlIgnoreCase(closeTagName(slice), tag);
    }

    fn popToTag(self: *Builder, tag: []const u8, end_offset: usize, src: []const u8) void {
        var k: usize = self.openStack.items.len;
        while (k > 0) : (k -= 1) {
            const idx = self.openStack.items[k - 1];
            const node = self.tree.getMut(idx);
            if (node.kind == .element and node.hasTag(tag)) {
                node.range.endByte = @intCast(end_offset);
                node.range.endPoint = pointForOffset(src, end_offset);
                self.openStack.shrinkRetainingCapacity(k - 1);
                return;
            }
        }
    }
};

fn pointForOffset(source: []const u8, offset: usize) SourcePoint {
    const clamped = @min(offset, source.len);
    var row: u32 = 0;
    var col: u32 = 0;
    for (source[0..clamped]) |b| {
        if (b == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .column = col };
}

fn makeRange(source: []const u8, start: usize, end: usize) SourceRange {
    return .{
        .startByte = @intCast(start),
        .endByte = @intCast(end),
        .startPoint = pointForOffset(source, start),
        .endPoint = pointForOffset(source, end),
    };
}

fn parseAttrs(
    arena: Allocator,
    src: []const u8,
    start: usize,
    attrs: *std.ArrayList(Attribute),
    selfClosing: *bool,
    limits: Limits,
) ParseError!usize {
    var i = start;
    while (i < src.len) {
        while (i < src.len and isWhitespace(src[i])) : (i += 1) {}
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
        while (i < src.len and !isAttrNameEnd(src[i])) : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }
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
        if (attr_value.len > limits.maxAttrValue) return error.InputTooLarge;
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
    return std.ascii.isWhitespace(c);
}

fn lowerBuf(arena: Allocator, s: []const u8) Allocator.Error![]u8 {
    const buf = try arena.alloc(u8, s.len);
    for (buf, 0..) |*b, idx| b.* = std.ascii.toLower(s[idx]);
    return buf;
}

test "html grammar tokenizes document structure" {
    const a = std.testing.allocator;
    var t = try parseHtmlTree(a, "<div class=\"x\">Hi<!--c--></div>");
    defer t.deinit();
    try std.testing.expect(!t.hasError());
    try std.testing.expectEqualStrings("program", t.rootNode().nodeType());
}

test "html parses nested elements with attributes via syntax tree" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var tree = try parse(al, "<html><body><a href=\"/l\" class=\"x y\">Click</a><br><img src=\"i.png\"></body></html>", .{});
    const root = tree.get(0);
    try std.testing.expect(root.kind == .document);
    var found_a = false;
    var found_br = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "a")) {
            found_a = true;
            try std.testing.expectEqualStrings("/l", n.attr("href").?);
            try std.testing.expect(n.hasClass("x"));
        }
        if (n.kind == .element and std.mem.eql(u8, n.tag, "br")) found_br = true;
    }
    try std.testing.expect(found_a and found_br);
}

test "html flags malformed input with error recovery" {
    const a = std.testing.allocator;
    var t = try parseHtmlTree(a, "<div><span>oops");
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var tree = try parse(arena.allocator(), "<div><span>oops", .{});
    try std.testing.expect(tree.get(0).hasError or t.hasError());
}

test "html tracks source ranges from syntax nodes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "<p>hi</p>", .{});
    var found_p = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "p")) {
            found_p = true;
            try std.testing.expectEqual(@as(u32, 0), n.range.startByte);
            try std.testing.expect(n.range.endByte > n.range.startByte);
        }
    }
    try std.testing.expect(found_p);
}
