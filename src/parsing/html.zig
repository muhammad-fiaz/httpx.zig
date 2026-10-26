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

const htmlSymEnd: u16 = 0;
const htmlSymOpenTag: u16 = 1;
const htmlSymCloseTag: u16 = 2;
const htmlSymSelfcloseTag: u16 = 3;
const htmlSymComment: u16 = 4;
const htmlSymDoctype: u16 = 5;
const htmlSymPi: u16 = 6;
const htmlSymText: u16 = 7;
const htmlSymProgram: u16 = 8;
const htmlSymNodes: u16 = 9;
const htmlSymNode: u16 = 10;
const htmlSymError: u16 = 11;

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
    var inQuote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (inQuote != 0) {
            if (c == inQuote) inQuote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            inQuote = c;
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
    const nameLen = matchHtmlTagName(source, i);
    if (nameLen == 0) return null;
    i += nameLen;
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
    var inQuote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (inQuote != 0) {
            if (c == inQuote) inQuote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            inQuote = c;
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
    var inQuote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (inQuote != 0) {
            if (c == inQuote) inQuote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            inQuote = c;
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

const htmlSymbolTable: []const ts.language_mod.symbols.SymbolInfo = &.{
    .{ .id = htmlSymEnd, .name = "end", .kind = .end, .metadata = .{ .visible = false, .named = false } },
    .{ .id = htmlSymOpenTag, .name = "open_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymCloseTag, .name = "close_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymSelfcloseTag, .name = "selfclose_tag", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymComment, .name = "comment", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymDoctype, .name = "doctype", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymPi, .name = "pi", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymText, .name = "text", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymProgram, .name = "program", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymNodes, .name = "nodes", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymNode, .name = "node", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = htmlSymError, .name = "ERROR", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
};

const htmlTokenMatchers: []const ts.language_mod.TokenMatcher = &.{
    .{ .symbol = htmlSymComment, .match = matchHtmlComment },
    .{ .symbol = htmlSymDoctype, .match = matchHtmlDoctype },
    .{ .symbol = htmlSymPi, .match = matchHtmlPi },
    .{ .symbol = htmlSymCloseTag, .match = matchHtmlCloseTag },
    .{ .symbol = htmlSymSelfcloseTag, .match = matchHtmlSelfCloseTag },
    .{ .symbol = htmlSymOpenTag, .match = matchHtmlOpenTag },
    .{ .symbol = htmlSymText, .match = matchHtmlText },
};

const htmlS0Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .shift = 6 } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .shift = 12 } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .shift = 7 } },
    .{ .symbol = htmlSymText, .action = .{ .shift = 8 } },
    .{ .symbol = htmlSymComment, .action = .{ .shift = 9 } },
    .{ .symbol = htmlSymDoctype, .action = .{ .shift = 10 } },
    .{ .symbol = htmlSymPi, .action = .{ .shift = 11 } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymProgram, .child_count = 0, .production_id = 0 } } },
};
const htmlS0Gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = htmlSymProgram, .state = 1 },
    .{ .symbol = htmlSymNodes, .state = 2 },
    .{ .symbol = htmlSymNode, .state = 3 },
};
const htmlS1Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymEnd, .action = .accept },
};
const htmlS2Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .shift = 6 } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .shift = 12 } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .shift = 7 } },
    .{ .symbol = htmlSymText, .action = .{ .shift = 8 } },
    .{ .symbol = htmlSymComment, .action = .{ .shift = 9 } },
    .{ .symbol = htmlSymDoctype, .action = .{ .shift = 10 } },
    .{ .symbol = htmlSymPi, .action = .{ .shift = 11 } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymProgram, .child_count = 1, .production_id = 1 } } },
};
const htmlS2Gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = htmlSymNode, .state = 4 },
};
const htmlS3Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 1, .production_id = 2 } } },
};
const htmlS4Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNodes, .child_count = 2, .production_id = 3 } } },
};
const htmlS5Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 4 } } },
};
const htmlS6Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 5 } } },
};
const htmlS7Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 6 } } },
};
const htmlS8Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 7 } } },
};
const htmlS9Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 8 } } },
};
const htmlS10Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 9 } } },
};
const htmlS11Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 10 } } },
};

const htmlS12Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = htmlSymOpenTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymCloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymSelfcloseTag, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymComment, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymDoctype, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymPi, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymText, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
    .{ .symbol = htmlSymEnd, .action = .{ .reduce = .{ .symbol = htmlSymNode, .child_count = 1, .production_id = 11 } } },
};

const htmlParseStates: []const ts.language_mod.tables.ParseState = &.{
    .{ .actions = htmlS0Actions, .gotos = htmlS0Gotos },
    .{ .actions = htmlS1Actions },
    .{ .actions = htmlS2Actions, .gotos = htmlS2Gotos },
    .{ .actions = htmlS3Actions },
    .{ .actions = htmlS4Actions },
    .{ .actions = htmlS5Actions },
    .{ .actions = htmlS6Actions },
    .{ .actions = htmlS7Actions },
    .{ .actions = htmlS8Actions },
    .{ .actions = htmlS9Actions },
    .{ .actions = htmlS10Actions },
    .{ .actions = htmlS11Actions },
    .{ .actions = htmlS12Actions },
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
    .symbols = htmlSymbolTable,
    .token_matchers = htmlTokenMatchers,
    .extra_symbols = &.{},
    .table = .{
        .states = htmlParseStates,
        .start_state = 0,
        .end_symbol = htmlSymEnd,
        .error_symbol = htmlSymError,
    },
    .fields = .{},
};

fn parseHtmlTree(allocator: Allocator, src: []const u8) ParseError!HtmlTree {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(htmlLanguage) catch return error.OutOfMemory;
    return parser.parseString(src) catch return error.OutOfMemory;
}

const HtmlTokenKind = enum { openTag, closeTag, selfcloseTag, comment, doctype, pi, text };

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
        const kind: HtmlTokenKind = if (std.mem.eql(u8, t, "open_tag")) .openTag else if (std.mem.eql(u8, t, "close_tag")) .closeTag else if (std.mem.eql(u8, t, "selfclose_tag")) .selfcloseTag else if (std.mem.eql(u8, t, "comment")) .comment else if (std.mem.eql(u8, t, "doctype")) .doctype else if (std.mem.eql(u8, t, "pi")) .pi else .text;
        try out.append(allocator, .{ .kind = kind, .start = n.startByte(), .end = n.endByte() });
    }
    return out.toOwnedSlice(allocator);
}

pub fn changedRanges(allocator: Allocator, oldSrc: []const u8, newSrc: []const u8) !usize {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(htmlLanguage) catch return error.OutOfMemory;
    var oldTree = parser.parseString(oldSrc) catch return error.OutOfMemory;
    defer oldTree.deinit();
    const edit = ts.InputEdit{
        .start_byte = 0,
        .old_end_byte = @intCast(oldSrc.len),
        .new_end_byte = @intCast(newSrc.len),
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = pointForOffsetTs(oldSrc, oldSrc.len),
        .new_end_point = pointForOffsetTs(newSrc, newSrc.len),
    };
    var newTree = parser.parse(&oldTree, edit, newSrc) catch return error.OutOfMemory;
    defer newTree.deinit();
    const ranges = ts.getChangedRanges(allocator, &oldTree, &newTree) catch return error.OutOfMemory;
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
    maxInputSize: usize = 64 * 1024 * 1024,
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
    if (htmlSrc.len > limits.maxInputSize) return error.InputTooLarge;
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
    var tsTree = try parseHtmlTree(arena, htmlSrc);
    defer tsTree.deinit();
    const tokens = try collectHtmlTokens(&tsTree, arena);
    try builder.runTokens(htmlSrc, tokens, tsTree.hasError());
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

    fn runTokens(self: *Builder, src: []const u8, tokens: []const HtmlToken, hadError: bool) ParseError!void {
        self.tree.getMut(self.openStack.items[0]).hasError = hadError;
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
                .selfcloseTag => {
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
                .openTag => {
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
                        var closeIdx: ?usize = null;
                        while (j < tokens.len) : (j += 1) {
                            if (tokens[j].kind == .closeTag and closeTagNameEql(src[tokens[j].start..tokens[j].end], info.tag)) {
                                closeIdx = j;
                                break;
                            }
                        }
                        const contentEnd = if (closeIdx) |cj| tokens[cj].start else src.len;
                        if (contentEnd > tok.end) {
                            const rawContent = src[tok.end..contentEnd];
                            const txtIdx = try self.tree.append(self.arena, .{
                                .kind = .text,
                                .data = rawContent,
                                .range = makeRange(src, tok.end, contentEnd),
                            });
                            self.tree.appendChild(nodeIdx, txtIdx);
                        }
                        if (closeIdx) |cj| {
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
                .closeTag => {
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

    fn appendText(self: *Builder, src: []const u8, raw: []const u8, start: usize, end: usize, isError: bool) ParseError!void {
        if (raw.len == 0) return;
        if (raw.len > self.limits.maxTextBlock) return error.InputTooLarge;
        const idx = try self.tree.append(self.arena, .{
            .kind = .text,
            .data = raw,
            .range = makeRange(src, start, end),
            .hasError = isError,
        });
        self.tree.appendChild(self.currentParent(), idx);
    }

    const TagInfo = struct {
        tag: []const u8,
        attrs: []const Attribute,
    };

    fn parseTagToken(self: *Builder, slice: []const u8, absStart: usize, src: []const u8) ParseError!TagInfo {
        _ = absStart;
        _ = src;
        var nameEnd: usize = 1;
        while (nameEnd < slice.len and !isTagNameEnd(slice[nameEnd])) : (nameEnd += 1) {}
        const tag = try lowerBuf(self.arena, slice[1..nameEnd]);
        var attrs: std.ArrayList(Attribute) = .empty;
        defer attrs.deinit(self.arena);
        var selfClosing = false;
        _ = try parseAttrs(self.arena, slice, nameEnd, &attrs, &selfClosing, self.limits);
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

    fn popToTag(self: *Builder, tag: []const u8, endOffset: usize, src: []const u8) void {
        var k: usize = self.openStack.items.len;
        while (k > 0) : (k -= 1) {
            const idx = self.openStack.items[k - 1];
            const node = self.tree.getMut(idx);
            if (node.kind == .element and node.hasTag(tag)) {
                node.range.endByte = @intCast(endOffset);
                node.range.endPoint = pointForOffset(src, endOffset);
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
        while (i < src.len and std.ascii.isWhitespace(src[i])) : (i += 1) {}
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

        const nameStart = i;
        while (i < src.len and !isAttrNameEnd(src[i])) : (i += 1) {}
        if (i == nameStart) {
            i += 1;
            continue;
        }
        const attrName = src[nameStart..i];

        while (i < src.len and std.ascii.isWhitespace(src[i])) : (i += 1) {}

        if (i >= src.len or src[i] != '=') {
            try attrs.append(arena, .{ .name = attrName, .value = "" });
            continue;
        }
        i += 1;
        while (i < src.len and std.ascii.isWhitespace(src[i])) : (i += 1) {}

        var attrValue: []const u8 = "";
        if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
            const quote = src[i];
            i += 1;
            const valStart = i;
            while (i < src.len and src[i] != quote) : (i += 1) {}
            attrValue = src[valStart..i];
            if (i < src.len) i += 1;
        } else {
            const valStart = i;
            while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != '>') : (i += 1) {}
            attrValue = src[valStart..i];
        }
        if (attrValue.len > limits.maxAttrValue) return error.InputTooLarge;
        try attrs.append(arena, .{ .name = attrName, .value = attrValue });
    }
    return i;
}

fn isTagNameEnd(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or
        c == '\x0C' or c == '>' or c == '/' or c == 0;
}

fn isAttrNameEnd(c: u8) bool {
    return c == '=' or c == '>' or c == '/' or std.ascii.isWhitespace(c);
}

fn lowerBuf(arena: Allocator, s: []const u8) Allocator.Error![]u8 {
    const buf = try arena.alloc(u8, s.len);
    return std.ascii.lowerString(buf, s);
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
    var foundA = false;
    var foundBr = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "a")) {
            foundA = true;
            try std.testing.expectEqualStrings("/l", n.attr("href").?);
            try std.testing.expect(n.hasClass("x"));
        }
        if (n.kind == .element and std.mem.eql(u8, n.tag, "br")) foundBr = true;
    }
    try std.testing.expect(foundA and foundBr);
}

test "html parser enforces configured input size before parsing" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.InputTooLarge, parse(arena.allocator(), "<p>x</p>", .{ .maxInputSize = 7 }));

    var arena2 = std.heap.ArenaAllocator.init(a);
    defer arena2.deinit();
    const tree = try parse(arena2.allocator(), "<p>x</p>", .{ .maxInputSize = 8 });
    try std.testing.expectEqual(@as(u32, 3), tree.len());
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

test "html lowercases element names with std.ascii" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "<DIV CLASS=\"X\">hi</DIV>", .{});
    var found = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "div")) found = true;
    }
    try std.testing.expect(found);
}

test "html tracks source ranges from syntax nodes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), "<p>hi</p>", .{});
    var foundP = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "p")) {
            foundP = true;
            try std.testing.expectEqual(@as(u32, 0), n.range.startByte);
            try std.testing.expect(n.range.endByte > n.range.startByte);
        }
    }
    try std.testing.expect(foundP);
}
