//! Template syntax tokenizer and AST parser.
//!
//! Parses template source containing:
//!   - Expressions: {{ value }}, {{ user.name }}
//!   - Conditionals: {% if cond %}, {% else %}, {% endif %}
//!   - Loops: {% for item in items %}, {% endfor %}
//!   - Inheritance: {% extends "base.html" %}, {% block name %}, {% endblock %}
//!   - Partials: {% include "file.html" %}
//!   - Comments: {# comment #}

const std = @import("std");
const Allocator = std.mem.Allocator;
const errMod = @import("templateError.zig");
const ts = @import("treesitter");
pub const TemplateError = errMod.TemplateError;
pub const SourceError = errMod.SourceError;
pub const lineColFromOffset = errMod.lineColFromOffset;

pub const TemplateTree = ts.Tree;

const tmplSymEnd: u16 = 0;
const tmplSymText: u16 = 1;
const tmplSymExpression: u16 = 2;
const tmplSymDirective: u16 = 3;
const tmplSymComment: u16 = 4;
const tmplSymProgram: u16 = 5;
const tmplSymItems: u16 = 6;
const tmplSymItem: u16 = 7;
const tmplSymError: u16 = 8;

fn matchTemplateExpression(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len) return null;
    if (source[start] != '{' or source[start + 1] != '{') return null;
    const close = std.mem.indexOfPos(u8, source, start + 2, "}}") orelse return null;
    return close + 2 - start;
}

fn matchTemplateDirective(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len) return null;
    if (source[start] != '{' or source[start + 1] != '%') return null;
    const close = std.mem.indexOfPos(u8, source, start + 2, "%}") orelse return null;
    return close + 2 - start;
}

fn matchTemplateComment(source: []const u8, start: usize) ?usize {
    if (start + 2 > source.len) return null;
    if (source[start] != '{' or source[start + 1] != '#') return null;
    const close = std.mem.indexOfPos(u8, source, start + 2, "#}") orelse return null;
    return close + 2 - start;
}

fn matchTemplateText(source: []const u8, start: usize) ?usize {
    if (start >= source.len) return null;
    if (source[start] == '{' and start + 1 < source.len) {
        const n = source[start + 1];
        if (n == '{' or n == '%' or n == '#') return null;
    }
    var i = start;
    while (i < source.len) {
        if (source[i] == '{' and i + 1 < source.len) {
            const n = source[i + 1];
            if (n == '{' or n == '%' or n == '#') break;
        }
        i += 1;
    }
    if (i == start) return null;
    return i - start;
}

const tmplSymbolTable: []const ts.language_mod.symbols.SymbolInfo = &.{
    .{ .id = tmplSymEnd, .name = "end", .kind = .end, .metadata = .{ .visible = false, .named = false } },
    .{ .id = tmplSymText, .name = "text", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymExpression, .name = "expression", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymDirective, .name = "directive", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymComment, .name = "comment", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymProgram, .name = "program", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymItems, .name = "items", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymItem, .name = "item", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmplSymError, .name = "ERROR", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
};

const tmplTokenMatchers: []const ts.language_mod.TokenMatcher = &.{
    .{ .symbol = tmplSymExpression, .match = matchTemplateExpression },
    .{ .symbol = tmplSymDirective, .match = matchTemplateDirective },
    .{ .symbol = tmplSymComment, .match = matchTemplateComment },
    .{ .symbol = tmplSymText, .match = matchTemplateText },
};

const tmplS0Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .shift = 5 } },
    .{ .symbol = tmplSymExpression, .action = .{ .shift = 6 } },
    .{ .symbol = tmplSymDirective, .action = .{ .shift = 7 } },
    .{ .symbol = tmplSymComment, .action = .{ .shift = 8 } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymProgram, .child_count = 0, .production_id = 0 } } },
};
const tmplS0Gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = tmplSymProgram, .state = 1 },
    .{ .symbol = tmplSymItems, .state = 2 },
    .{ .symbol = tmplSymItem, .state = 3 },
};
const tmplS1Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymEnd, .action = .accept },
};
const tmplS2Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .shift = 5 } },
    .{ .symbol = tmplSymExpression, .action = .{ .shift = 6 } },
    .{ .symbol = tmplSymDirective, .action = .{ .shift = 7 } },
    .{ .symbol = tmplSymComment, .action = .{ .shift = 8 } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymProgram, .child_count = 1, .production_id = 1 } } },
};
const tmplS2Gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = tmplSymItem, .state = 4 },
};
const tmplS3Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 1, .production_id = 2 } } },
};
const tmplS4Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItems, .child_count = 2, .production_id = 3 } } },
};
const tmplS5Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 4 } } },
};
const tmplS6Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 5 } } },
};
const tmplS7Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 6 } } },
};
const tmplS8Actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmplSymText, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmplSymExpression, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmplSymDirective, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmplSymComment, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmplSymEnd, .action = .{ .reduce = .{ .symbol = tmplSymItem, .child_count = 1, .production_id = 7 } } },
};

const tmplParseStates: []const ts.language_mod.tables.ParseState = &.{
    .{ .actions = tmplS0Actions, .gotos = tmplS0Gotos },
    .{ .actions = tmplS1Actions },
    .{ .actions = tmplS2Actions, .gotos = tmplS2Gotos },
    .{ .actions = tmplS3Actions },
    .{ .actions = tmplS4Actions },
    .{ .actions = tmplS5Actions },
    .{ .actions = tmplS6Actions },
    .{ .actions = tmplS7Actions },
    .{ .actions = tmplS8Actions },
};

pub const templateLanguage: ts.Language = .{
    .metadata = .{
        .name = "template",
        .abi_version = ts.language_mod.metadata.current_abi_version,
        .version = "0.0.1",
        .symbol_count = 9,
        .state_count = 9,
        .field_count = 0,
    },
    .symbols = tmplSymbolTable,
    .token_matchers = tmplTokenMatchers,
    .extra_symbols = &.{},
    .table = .{
        .states = tmplParseStates,
        .start_state = 0,
        .end_symbol = tmplSymEnd,
        .error_symbol = tmplSymError,
    },
    .fields = .{},
};

fn parseTemplateTree(allocator: Allocator, src: []const u8) !TemplateTree {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(templateLanguage) catch return error.InvalidTemplate;
    return parser.parseString(src) catch return error.InvalidTemplate;
}

const TsTokenKind = enum { text, expression, directive, comment };

const TsToken = struct {
    kind: TsTokenKind,
    start: usize,
    end: usize,
};

fn collectTemplateTokens(tree: *const TemplateTree, allocator: Allocator) ![]TsToken {
    var out = std.ArrayList(TsToken).empty;
    errdefer out.deinit(allocator);
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, tree.rootNode());
    var ordered = std.ArrayList(ts.Node).empty;
    defer ordered.deinit(allocator);
    while (stack.pop()) |cur| {
        const t = cur.nodeType();
        if (std.mem.eql(u8, t, "text")) {
            try ordered.append(allocator, cur);
            continue;
        }
        if (std.mem.eql(u8, t, "expression")) {
            try ordered.append(allocator, cur);
            continue;
        }
        if (std.mem.eql(u8, t, "directive")) {
            try ordered.append(allocator, cur);
            continue;
        }
        if (std.mem.eql(u8, t, "comment")) {
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
        const kind: TsTokenKind = if (std.mem.eql(u8, t, "text")) .text else if (std.mem.eql(u8, t, "expression")) .expression else if (std.mem.eql(u8, t, "directive")) .directive else .comment;
        try out.append(allocator, .{ .kind = kind, .start = n.startByte(), .end = n.endByte() });
    }
    return out.toOwnedSlice(allocator);
}

pub const ElifBranch = struct {
    condition: []const u8,
    bodyNodes: []const TemplateNode,
    startByte: usize,
    line: usize,
    col: usize,
};

pub const MacroParam = struct {
    name: []const u8,
    default: ?[]const u8 = null,
    /// `*args` collects surplus positionals, `**kwargs` surplus keywords.
    star: bool = false,
    starStar: bool = false,
};

pub const ImportName = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

pub const CallArg = struct {
    name: ?[]const u8 = null,
    value: []const u8,
};

/// Splits a comma-separated argument list at top level only, respecting
/// nested parens/brackets/braces and quoted strings.
pub fn splitTopLevel(a: Allocator, s: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(a);
    var depthParen: usize = 0;
    var depthBrack: usize = 0;
    var depthBrace: usize = 0;
    var quote: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < s.len) {
                i += 2;
                continue;
            }
            if (c == quote) quote = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(' => depthParen += 1,
            ')' => depthParen -|= 1,
            '[' => depthBrack += 1,
            ']' => depthBrack -|= 1,
            '{' => depthBrace += 1,
            '}' => depthBrace -|= 1,
            ',' => {
                if (depthParen == 0 and depthBrack == 0 and depthBrace == 0) {
                    try out.append(a, std.mem.trim(u8, s[start..i], " \t\r\n"));
                    start = i + 1;
                }
            },
            else => {},
        }
        i += 1;
    }
    const tail = std.mem.trim(u8, s[start..], " \t\r\n");
    if (tail.len > 0) try out.append(a, tail);
    return out.toOwnedSlice(a);
}

/// Parses call arguments `a, b=c` into positional values and kwargs.
pub fn parseCallSig(a: Allocator, s: []const u8) !struct { name: []const u8, args: []CallArg } {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return error.InvalidSignature;
    const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return error.InvalidSignature;
    if (close < open) return error.InvalidSignature;
    const name = std.mem.trim(u8, s[0..open], " \t\r\n");
    if (name.len == 0) return error.InvalidSignature;
    const inner = std.mem.trim(u8, s[open + 1 .. close], " \t\r\n");
    var args = std.ArrayList(CallArg).empty;
    errdefer args.deinit(a);
    if (inner.len > 0) {
        const parts = try splitTopLevel(a, inner);
        defer a.free(parts);
        for (parts) |part| {
            if (part.len == 0) continue;
            if (splitNameValue(part)) |nv| {
                if (nv.name.len == 0 or nv.value.len == 0) return error.InvalidSignature;
                try args.append(a, .{ .name = nv.name, .value = nv.value });
            } else {
                try args.append(a, .{ .value = part });
            }
        }
    }
    return .{ .name = name, .args = try args.toOwnedSlice(a) };
}

pub const MacroDef = struct {
    name: []const u8,
    params: []const MacroParam,
    bodyNodes: []const TemplateNode,
    /// True when imported `with context`: the macro body may see template
    /// data. Plain definitions render isolated (Jinja default).
    withContext: bool = false,
    startByte: usize,
    line: usize,
    col: usize,
};

pub const TemplateNode = union(enum) {
    text: []const u8,
    expression: struct {
        expr: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
    ifBlock: struct {
        condition: []const u8,
        thenNodes: []const TemplateNode,
        elifBranches: []const ElifBranch,
        elseNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    forLoop: ForLoopInfo,
    setBlock: struct {
        name: []const u8,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    call: struct {
        name: []const u8,
        args: []const CallArg,
        /// `{% call(item) macro() %}` caller parameter declarations.
        callerParams: []const []const u8 = &.{},
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    set: struct {
        name: []const u8,
        valueExpr: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
    macroDef: MacroDef,
    breakLoop: struct {
        startByte: usize,
        line: usize,
        col: usize,
    },
    continueLoop: struct {
        startByte: usize,
        line: usize,
        col: usize,
    },
    block: struct {
        name: []const u8,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    extends: struct {
        parentPath: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
    include: struct {
        templatePath: []const u8,
        /// True when the path is an expression evaluated at render time.
        pathIsExpr: bool = false,
        /// `{% include "x" ignore missing %}` renders nothing when absent.
        ignoreMissing: bool = false,
        /// `with`/`without context`; null means Jinja default (with).
        withContext: ?bool = null,
        startByte: usize,
        line: usize,
        col: usize,
    },
    importAs: struct {
        templatePath: []const u8,
        alias: []const u8,
        withContext: bool = true,
        startByte: usize,
        line: usize,
        col: usize,
    },
    fromImport: struct {
        templatePath: []const u8,
        names: []const ImportName,
        withContext: bool = true,
        startByte: usize,
        line: usize,
        col: usize,
    },
    filterBlock: struct {
        /// Filter expression applied to the rendered body (`upper`,
        /// `truncate(30)`, chains allowed).
        filterExpr: []const u8,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    withBlock: struct {
        assigns: []const CallArg,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    autoescapeBlock: struct {
        enabled: bool,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
};

/// Named payload for `{% for %}` loops (a named type so the renderer
/// can hold recursion frames across the loop body).
pub const ForLoopInfo = struct {
    itemVars: []const []const u8,
    collectionExpr: []const u8,
    /// Optional `if` filter from `{% for x in y if cond %}`.
    filterExpr: ?[]const u8 = null,
    /// `{% for x in y recursive %}` enables `loop(...)` calls.
    recursive: bool = false,
    bodyNodes: []const TemplateNode,
    elseNodes: []const TemplateNode = &.{},
    startByte: usize,
    line: usize,
    col: usize,
};

pub const BlockInfo = struct {
    name: []const u8,
    nodes: []const TemplateNode,
};

pub const TemplateAst = struct {
    nodes: []const TemplateNode,
    extendsPath: ?[]const u8 = null,
    blocks: []const BlockInfo,
    includes: [][]const u8,
    macros: []const MacroDef,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TemplateAst) void {
        self.arena.deinit();
    }
};

/// Strips Jinja whitespace-control dashes from a tag/expression body.
/// Returns the inner content plus whether left/right stripping applies.
pub const DashStrip = struct {
    content: []const u8,
    left: bool = false,
    right: bool = false,
};

pub fn stripDashControl(raw: []const u8) DashStrip {
    // A dash counts as whitespace control ONLY when directly adjacent to
    // the delimiter (`{{- x -}}`); `{{ -x }}` keeps its unary minus
    // (Jinja lexer rule: `-?` immediately follows the opening braces).
    var content = raw;
    var left = false;
    var right = false;
    if (content.len > 0 and content[0] == '-') {
        left = true;
        content = content[1..];
    }
    if (content.len > 0 and content[content.len - 1] == '-') {
        right = true;
        content = content[0 .. content.len - 1];
    }
    content = std.mem.trim(u8, content, " \t\r\n");
    return .{ .content = content, .left = left, .right = right };
}

fn trimTrailingWhitespace(a: Allocator, outNodes: *std.ArrayList(TemplateNode)) void {
    _ = a;
    if (outNodes.items.len == 0) return;
    const last = &outNodes.items[outNodes.items.len - 1];
    if (last.* == .text) {
        const trimmed = std.mem.trimEnd(u8, last.text, " \t\r\n");
        if (trimmed.len == 0) {
            _ = outNodes.pop();
        } else {
            last.text = trimmed;
        }
    }
}

fn trimLeadingWhitespace(text: []const u8) []const u8 {
    return std.mem.trimStart(u8, text, " \t\r\n");
}

fn trimSliceTail(nodes: []const TemplateNode) void {
    if (nodes.len == 0) return;
    const mut: []TemplateNode = @constCast(nodes);
    const last = &mut[mut.len - 1];
    if (last.* == .text) {
        last.text = std.mem.trimEnd(u8, last.text, " \t\r\n");
    }
}

/// Splits `name = value` at the top level, respecting quotes and nesting.
/// Returns null when there is no top-level `=` (or it is `==`).
pub fn splitNameValue(part: []const u8) ?struct { name: []const u8, value: []const u8 } {
    var depth: usize = 0;
    var q: u8 = 0;
    var i: usize = 0;
    while (i < part.len) {
        const c = part[i];
        if (q != 0) {
            if (c == '\\' and i + 1 < part.len) {
                i += 2;
                continue;
            }
            if (c == q) q = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '"', '\'' => q = c,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '=' => {
                if (depth == 0 and (i + 1 >= part.len or part[i + 1] != '=') and (i == 0 or part[i - 1] != '=')) {
                    return .{
                        .name = std.mem.trim(u8, part[0..i], " \t\r\n"),
                        .value = std.mem.trim(u8, part[i + 1 ..], " \t\r\n"),
                    };
                }
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// Finds a standalone word at the top level (outside strings and nesting).
/// Returns its byte offset, or null.
pub fn findTopLevelWord(haystack: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or word.len > haystack.len) return null;
    var depth: usize = 0;
    var q: u8 = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        const c = haystack[i];
        if (q != 0) {
            if (c == '\\' and i + 1 < haystack.len) {
                i += 2;
                continue;
            }
            if (c == q) q = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '"', '\'' => {
                q = c;
                i += 1;
                continue;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        if (depth == 0 and std.ascii.isAlphabetic(word[0]) and (std.ascii.isAlphabetic(c) or c == '_')) {
            if (i + word.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + word.len], word)) {
                const after = i + word.len;
                const beforeOk = i == 0 or (!std.ascii.isAlphanumeric(haystack[i - 1]) and haystack[i - 1] != '_');
                const afterOk = after >= haystack.len or (!std.ascii.isAlphanumeric(haystack[after]) and haystack[after] != '_');
                if (beforeOk and afterOk) return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Removes one surrounding paren pair: `(a, b)` -> `a, b`. Leaves other
/// strings untouched.
pub fn stripParens(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')') {
        var depth: usize = 0;
        var q: u8 = 0;
        var i: usize = 0;
        var balanced = true;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (q != 0) {
                if (c == q) q = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => q = c,
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) {
                        balanced = false;
                        break;
                    }
                    depth -= 1;
                    if (depth == 0 and i != t.len - 1) {
                        balanced = false;
                        break;
                    }
                },
                else => {},
            }
            if (!balanced) break;
        }
        if (balanced and depth == 0) return std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
    }
    return t;
}

/// Splits a trailing `with context` / `without context` suffix.
/// Returns the remainder plus the flag (null when absent).
pub fn splitContextSuffix(s: []const u8) struct { rest: []const u8, withContext: ?bool } {
    var rest = std.mem.trimEnd(u8, s, " \t\r\n");
    if (std.mem.endsWith(u8, rest, "without context")) {
        const cut = rest[0 .. rest.len - "without context".len];
        if (cut.len == 0 or cut[cut.len - 1] == ' ' or cut[cut.len - 1] == '\t' or cut[cut.len - 1] == '\r' or cut[cut.len - 1] == '\n') {
            return .{ .rest = std.mem.trimEnd(u8, cut, " \t\r\n"), .withContext = false };
        }
    }
    if (std.mem.endsWith(u8, rest, "with context")) {
        // Careful: "without context" also ends with "with context"; checked above.
        const cut = rest[0 .. rest.len - "with context".len];
        if (cut.len == 0 or cut[cut.len - 1] == ' ' or cut[cut.len - 1] == '\t' or cut[cut.len - 1] == '\r' or cut[cut.len - 1] == '\n') {
            return .{ .rest = std.mem.trimEnd(u8, cut, " \t\r\n"), .withContext = true };
        }
    }
    return .{ .rest = s, .withContext = null };
}

/// Parses an autoescape flag: true/false (any case), 1/0.
pub fn parseAutoescapeFlag(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

/// Parses an include/import path which is either a quoted literal or an
/// expression, plus trailing `ignore missing` / `with|without context`.
pub fn parseIncludeSpec(a: Allocator, s: []const u8) !struct {
    path: []const u8,
    pathIsExpr: bool,
    ignoreMissing: bool,
    withContext: ?bool,
} {
    _ = a;
    var rest = std.mem.trim(u8, s, " \t\r\n");
    var ignoreMissing = false;
    // Trailing `ignore missing` (checked before context suffix).
    if (std.mem.endsWith(u8, rest, "ignore missing")) {
        const cut = rest[0 .. rest.len - "ignore missing".len];
        if (cut.len > 0 and (cut[cut.len - 1] == ' ' or cut[cut.len - 1] == '\t')) {
            ignoreMissing = true;
            rest = std.mem.trimEnd(u8, cut, " \t\r\n");
        }
    }
    const ctxSplit = splitContextSuffix(rest);
    rest = ctxSplit.rest;
    if (rest.len == 0) return error.InvalidSignature;
    if (parseQuotedString(rest)) |lit| {
        return .{ .path = lit, .pathIsExpr = false, .ignoreMissing = ignoreMissing, .withContext = ctxSplit.withContext };
    }
    // Unquoted remainder is an expression evaluated at render time.
    // A trailing modifier word can only follow a literal path.
    if (ignoreMissing or ctxSplit.withContext != null) return error.InvalidSignature;
    return .{ .path = rest, .pathIsExpr = true, .ignoreMissing = false, .withContext = null };
}

/// Parses `{% import %}` remainder: `"path" as alias [with|without context]`.
pub fn parseImportSpec(s: []const u8) !struct {
    path: []const u8,
    alias: []const u8,
    withContext: bool,
} {
    const ctxSplit = splitContextSuffix(std.mem.trim(u8, s, " \t\r\n"));
    const rest = ctxSplit.rest;
    const asPos = findTopLevelWord(rest, "as") orelse return error.InvalidSignature;
    const rawPath = std.mem.trim(u8, rest[0..asPos], " \t\r\n");
    const alias = std.mem.trim(u8, rest[asPos + 2 ..], " \t\r\n");
    const path = parseQuotedString(rawPath) orelse return error.InvalidSignature;
    if (alias.len == 0) return error.InvalidSignature;
    return .{ .path = path, .alias = alias, .withContext = ctxSplit.withContext orelse false };
}

/// Parses `{% from %}` remainder: `"path" import a, b as c [with|without context]`.
pub fn parseFromSpec(a: Allocator, s: []const u8) !struct {
    path: []const u8,
    names: []ImportName,
    withContext: bool,
} {
    const ctxSplit = splitContextSuffix(std.mem.trim(u8, s, " \t\r\n"));
    const rest = ctxSplit.rest;
    const importPos = findTopLevelWord(rest, "import") orelse return error.InvalidSignature;
    const rawPath = std.mem.trim(u8, rest[0..importPos], " \t\r\n");
    const path = parseQuotedString(rawPath) orelse return error.InvalidSignature;
    const names = try parseFromNames(a, std.mem.trim(u8, rest[importPos + 6 ..], " \t\r\n"));
    return .{ .path = path, .names = names, .withContext = ctxSplit.withContext orelse false };
}

/// Parses `{% for %}` target/collection/filter/recursive parts.
/// `remainder` is the text after `for`: `a, b in coll if cond recursive`.
pub fn parseForHead(remainder: []const u8) ?struct {
    vars: []const u8,
    collection: []const u8,
    filter: ?[]const u8,
    recursive: bool,
} {
    const inPos = findTopLevelWord(remainder, "in") orelse return null;
    const vars = std.mem.trim(u8, remainder[0..inPos], " \t\r\n");
    if (vars.len == 0) return null;
    var rest = std.mem.trim(u8, remainder[inPos + 2 ..], " \t\r\n");
    if (rest.len == 0) return null;
    var recursive = false;
    if (std.mem.endsWith(u8, rest, "recursive")) {
        const cut = rest[0 .. rest.len - "recursive".len];
        if (cut.len > 0 and (cut[cut.len - 1] == ' ' or cut[cut.len - 1] == '\t')) {
            recursive = true;
            rest = std.mem.trimEnd(u8, cut, " \t\r\n");
        }
    }
    var filter: ?[]const u8 = null;
    var collection = rest;
    if (findTopLevelWord(rest, "if")) |ifPos| {
        collection = std.mem.trim(u8, rest[0..ifPos], " \t\r\n");
        filter = std.mem.trim(u8, rest[ifPos + 2 ..], " \t\r\n");
        if (collection.len == 0 or filter.?.len == 0) return null;
    }
    if (collection.len == 0) return null;
    return .{ .vars = vars, .collection = collection, .filter = filter, .recursive = recursive };
}

/// Parses a macro signature `name(arg1, arg2="default", *args, **kwargs)`.
pub fn parseMacroSignature(a: Allocator, s: []const u8) !struct { name: []const u8, params: []MacroParam } {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return error.InvalidSignature;
    const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return error.InvalidSignature;
    if (close < open) return error.InvalidSignature;
    const name = std.mem.trim(u8, s[0..open], " \t\r\n");
    if (name.len == 0) return error.InvalidSignature;
    const argsStr = std.mem.trim(u8, s[open + 1 .. close], " \t\r\n");
    var params = std.ArrayList(MacroParam).empty;
    errdefer params.deinit(a);
    if (argsStr.len > 0) {
        const parts = try splitTopLevel(a, argsStr);
        defer a.free(parts);
        for (parts) |part| {
            if (part.len == 0) continue;
            if (std.mem.startsWith(u8, part, "**")) {
                const pname = std.mem.trim(u8, part[2..], " \t\r\n");
                if (pname.len == 0) return error.InvalidSignature;
                try params.append(a, .{ .name = pname, .starStar = true });
            } else if (std.mem.startsWith(u8, part, "*")) {
                const pname = std.mem.trim(u8, part[1..], " \t\r\n");
                if (pname.len == 0) return error.InvalidSignature;
                try params.append(a, .{ .name = pname, .star = true });
            } else if (splitNameValue(part)) |nv| {
                if (nv.name.len == 0 or nv.value.len == 0) return error.InvalidSignature;
                try params.append(a, .{ .name = nv.name, .default = nv.value });
            } else {
                try params.append(a, .{ .name = part });
            }
        }
    }
    return .{ .name = name, .params = try params.toOwnedSlice(a) };
}

/// Parses `{% with %}` / call-site assignments `a=1, b=x` into CallArgs.
/// Every entry must be `name = expr`.
pub fn parseAssignList(a: Allocator, s: []const u8) ![]CallArg {
    var out = std.ArrayList(CallArg).empty;
    errdefer out.deinit(a);
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return out.toOwnedSlice(a);
    const parts = try splitTopLevel(a, trimmed);
    defer a.free(parts);
    for (parts) |part| {
        if (part.len == 0) continue;
        const nv = splitNameValue(part) orelse return error.InvalidSignature;
        if (nv.name.len == 0 or nv.value.len == 0) return error.InvalidSignature;
        try out.append(a, .{ .name = nv.name, .value = nv.value });
    }
    return out.toOwnedSlice(a);
}

/// Parses `{% from %}` import name lists: `a, b as c`.
pub fn parseFromNames(a: Allocator, s: []const u8) ![]ImportName {
    var out = std.ArrayList(ImportName).empty;
    errdefer out.deinit(a);
    const parts = try splitTopLevel(a, s);
    defer a.free(parts);
    for (parts) |part| {
        if (part.len == 0) continue;
        if (findTopLevelWord(part, "as")) |asPos| {
            const nm = std.mem.trim(u8, part[0..asPos], " \t\r\n");
            const al = std.mem.trim(u8, part[asPos + 2 ..], " \t\r\n");
            if (nm.len == 0 or al.len == 0) return error.InvalidSignature;
            try out.append(a, .{ .name = nm, .alias = al });
        } else {
            try out.append(a, .{ .name = part });
        }
    }
    if (out.items.len == 0) return error.InvalidSignature;
    return out.toOwnedSlice(a);
}

pub const Parser = struct {
    allocator: Allocator,
    templateName: []const u8,
    source: []const u8,
    pos: usize = 0,
    lastError: ?SourceError = null,

    pub fn init(allocator: Allocator, templateName: []const u8, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .templateName = templateName,
            .source = source,
            .pos = 0,
        };
    }

    pub fn parse(self: *Parser) !TemplateAst {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var nodesList = std.ArrayList(TemplateNode).empty;
        var blocksList = std.ArrayList(BlockInfo).empty;
        var includesList = std.ArrayList([]const u8).empty;
        var macrosList = std.ArrayList(MacroDef).empty;
        var extendsPath: ?[]const u8 = null;

        var tsTree = parseTemplateTree(self.allocator, self.source) catch null;
        if (tsTree) |*t| {
            defer {
                var mut: TemplateTree = t.*;
                mut.deinit();
            }
            if (!t.hasError()) {
                const tokens = collectTemplateTokens(t, self.allocator) catch null;
                if (tokens) |toks| {
                    defer self.allocator.free(toks);
                    var cursor: usize = 0;
                    var stripLeading = false;
                    try self.parseTokenNodes(a, toks, &cursor, &nodesList, &blocksList, &includesList, &macrosList, &extendsPath, null, false, &stripLeading);
                    return .{
                        .nodes = try nodesList.toOwnedSlice(a),
                        .extendsPath = extendsPath,
                        .blocks = try blocksList.toOwnedSlice(a),
                        .includes = try includesList.toOwnedSlice(a),
                        .macros = try macrosList.toOwnedSlice(a),
                        .arena = arena,
                    };
                }
            }
        }

        try self.parseNodes(a, &nodesList, &blocksList, &includesList, &extendsPath, null);

        return .{
            .nodes = try nodesList.toOwnedSlice(a),
            .extendsPath = extendsPath,
            .blocks = try blocksList.toOwnedSlice(a),
            .includes = try includesList.toOwnedSlice(a),
            .macros = try macrosList.toOwnedSlice(a),
            .arena = arena,
        };
    }

    /// Extracts the directive command word: the leading alphabetic run,
    /// so `{% call(item) %}` yields `call` just like `{% call x() %}`.
    fn directiveCmd(content: []const u8) []const u8 {
        var i: usize = 0;
        while (i < content.len and std.ascii.isAlphabetic(content[i])) : (i += 1) {}
        if (i == 0) {
            var it = std.mem.tokenizeAny(u8, content, " \t\r\n");
            return it.next() orelse "";
        }
        return content[0..i];
    }

    fn peekDirectiveCmd(self: *Parser, tokens: []const TsToken, at: usize) []const u8 {
        if (at >= tokens.len or tokens[at].kind != .directive) return "";
        const raw = self.source[tokens[at].start + 2 .. tokens[at].end - 2];
        const stripped = stripDashControl(raw);
        return directiveCmd(stripped.content);
    }

    fn isStopCmd(stopTag: ?[]const u8, cmd: []const u8) bool {
        const target = stopTag orelse return false;
        if (std.mem.eql(u8, cmd, target)) return true;
        if (std.mem.eql(u8, target, "endif_or_else")) {
            return std.mem.eql(u8, cmd, "else") or std.mem.eql(u8, cmd, "endif");
        }
        if (std.mem.eql(u8, target, "endif_elif_else")) {
            return std.mem.eql(u8, cmd, "else") or std.mem.eql(u8, cmd, "endif") or std.mem.eql(u8, cmd, "elif");
        }
        if (std.mem.eql(u8, target, "endfor_else")) {
            return std.mem.eql(u8, cmd, "else") or std.mem.eql(u8, cmd, "endfor");
        }
        return false;
    }

    fn applyTagStrip(
        self: *Parser,
        a: Allocator,
        outNodes: *std.ArrayList(TemplateNode),
        stripLeading: *bool,
        tok: TsToken,
    ) void {
        const stripped = stripDashControl(self.source[tok.start + 2 .. tok.end - 2]);
        if (stripped.left) trimTrailingWhitespace(a, outNodes);
        if (stripped.right) stripLeading.* = true;
    }

    fn parseTokenNodes(
        self: *Parser,
        a: Allocator,
        tokens: []const TsToken,
        cursor: *usize,
        outNodes: *std.ArrayList(TemplateNode),
        blocksList: *std.ArrayList(BlockInfo),
        includesList: *std.ArrayList([]const u8),
        macrosList: *std.ArrayList(MacroDef),
        extendsPath: *?[]const u8,
        stopTag: ?[]const u8,
        inLoop: bool,
        stripLeading: *bool,
    ) TemplateError!void {
        while (cursor.* < tokens.len) {
            const tok = tokens[cursor.*];
            switch (tok.kind) {
                .comment => {
                    self.applyTagStrip(a, outNodes, stripLeading, tok);
                    cursor.* += 1;
                    continue;
                },
                .text => {
                    var text = self.source[tok.start..tok.end];
                    if (stripLeading.*) {
                        stripLeading.* = false;
                        text = trimLeadingWhitespace(text);
                    }
                    if (text.len > 0) try outNodes.append(a, .{ .text = text });
                    cursor.* += 1;
                    continue;
                },
                .expression => {
                    self.applyTagStrip(a, outNodes, stripLeading, tok);
                    const stripped = stripDashControl(self.source[tok.start + 2 .. tok.end - 2]);
                    const loc = lineColFromOffset(self.source, tok.start);
                    if (stripped.content.len > 0) try outNodes.append(a, .{
                        .expression = .{ .expr = stripped.content, .startByte = tok.start, .line = loc.line, .col = loc.col },
                    });
                    cursor.* += 1;
                    continue;
                },
                .directive => {
                    const stripped = stripDashControl(self.source[tok.start + 2 .. tok.end - 2]);
                    const tagContent = stripped.content;
                    const tagCmd = directiveCmd(tagContent);
                    if (isStopCmd(stopTag, tagCmd)) {
                        return;
                    }
                    self.applyTagStrip(a, outNodes, stripLeading, tok);
                    const tagStart = tok.start;
                    const loc = lineColFromOffset(self.source, tagStart);
                    cursor.* += 1;
                    if (std.mem.eql(u8, tagCmd, "raw")) {
                        var j = cursor.*;
                        var found: ?usize = null;
                        while (j < tokens.len) : (j += 1) {
                            if (tokens[j].kind == .directive and std.mem.eql(u8, self.peekDirectiveCmd(tokens, j), "endraw")) {
                                found = j;
                                break;
                            }
                        }
                        const close = found orelse {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% raw %}, expected {% endraw %}");
                        };
                        const bodyStart = if (cursor.* < tokens.len) tokens[cursor.*].start else @min(tok.end, self.source.len);
                        var bodyEnd = tokens[close].start;
                        const closeStrip = stripDashControl(self.source[tokens[close].start + 2 .. tokens[close].end - 2]);
                        if (closeStrip.left) {
                            while (bodyEnd > bodyStart) {
                                const c = self.source[bodyEnd - 1];
                                if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
                                bodyEnd -= 1;
                            }
                        }
                        if (bodyEnd > bodyStart) {
                            try outNodes.append(a, .{ .text = self.source[bodyStart..bodyEnd] });
                        }
                        if (closeStrip.right) stripLeading.* = true;
                        cursor.* = close + 1;
                    } else if (std.mem.eql(u8, tagCmd, "if")) {
                        const condition = std.mem.trim(u8, tagContent[2..], " \t\r\n");
                        var thenNodes = std.ArrayList(TemplateNode).empty;
                        var elifBranches = std.ArrayList(ElifBranch).empty;
                        var elseNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &thenNodes, blocksList, includesList, macrosList, extendsPath, "endif_elif_else", inLoop, stripLeading);
                        var tailBody: []const TemplateNode = thenNodes.items;
                        while (true) {
                            const nxt = self.peekDirectiveCmd(tokens, cursor.*);
                            if (std.mem.eql(u8, nxt, "elif")) {
                                const elifTok = tokens[cursor.*];
                                trimSliceTail(tailBody);
                                if (stripDashControl(self.source[elifTok.start + 2 .. elifTok.end - 2]).right) stripLeading.* = true;
                                const elifRaw = stripDashControl(self.source[elifTok.start + 2 .. elifTok.end - 2]);
                                const elifCond = std.mem.trim(u8, elifRaw.content[4..], " \t\r\n");
                                const elifLoc = lineColFromOffset(self.source, elifTok.start);
                                cursor.* += 1;
                                var branchBody = std.ArrayList(TemplateNode).empty;
                                try self.parseTokenNodes(a, tokens, cursor, &branchBody, blocksList, includesList, macrosList, extendsPath, "endif_elif_else", inLoop, stripLeading);
                                try elifBranches.append(a, .{
                                    .condition = elifCond,
                                    .bodyNodes = try branchBody.toOwnedSlice(a),
                                    .startByte = elifTok.start,
                                    .line = elifLoc.line,
                                    .col = elifLoc.col,
                                });
                                tailBody = elifBranches.items[elifBranches.items.len - 1].bodyNodes;
                                continue;
                            }
                            break;
                        }
                        const tail = self.peekDirectiveCmd(tokens, cursor.*);
                        if (std.mem.eql(u8, tail, "else")) {
                            trimSliceTail(tailBody);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                            try self.parseTokenNodes(a, tokens, cursor, &elseNodes, blocksList, includesList, macrosList, extendsPath, "endif", inLoop, stripLeading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endif")) {
                                return self.fail(.unclosedBlock, tagStart, "unclosed {% if %}, expected {% endif %}");
                            }
                            trimSliceTail(elseNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                        } else if (std.mem.eql(u8, tail, "endif")) {
                            trimSliceTail(tailBody);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% if %}, expected {% endif %}");
                        }
                        try outNodes.append(a, .{
                            .ifBlock = .{
                                .condition = condition,
                                .thenNodes = try thenNodes.toOwnedSlice(a),
                                .elifBranches = try elifBranches.toOwnedSlice(a),
                                .elseNodes = try elseNodes.toOwnedSlice(a),
                                .startByte = tagStart,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "elif") or std.mem.eql(u8, tagCmd, "else") or std.mem.eql(u8, tagCmd, "endif")) {
                        return self.fail(.unexpectedToken, tagStart, "unexpected endif/else without matching {% if %}");
                    } else if (std.mem.eql(u8, tagCmd, "for")) {
                        const remainder = std.mem.trim(u8, tagContent[3..], " \t\r\n");
                        const head = parseForHead(remainder) orelse {
                            return self.fail(.syntaxError, tagStart, "invalid for loop syntax, expected '{% for item in items %}'");
                        };
                        // N loop targets: `k, v` or `(k, v)` tuple form.
                        const varParts = try splitTopLevel(a, stripParens(head.vars));
                        defer a.free(varParts);
                        if (varParts.len == 0) {
                            return self.fail(.syntaxError, tagStart, "invalid loop variables, expected '{% for key, value in items %}'");
                        }
                        var itemVars = std.ArrayList([]const u8).empty;
                        errdefer itemVars.deinit(a);
                        for (varParts) |vp| {
                            if (vp.len == 0) {
                                return self.fail(.syntaxError, tagStart, "invalid loop variables, expected '{% for key, value in items %}'");
                            }
                            try itemVars.append(a, vp);
                        }
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        var elseNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endfor_else", true, stripLeading);
                        const forTail = self.peekDirectiveCmd(tokens, cursor.*);
                        if (std.mem.eql(u8, forTail, "else")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                            try self.parseTokenNodes(a, tokens, cursor, &elseNodes, blocksList, includesList, macrosList, extendsPath, "endfor", true, stripLeading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endfor")) {
                                return self.fail(.unclosedBlock, tagStart, "unclosed {% for %}, expected {% endfor %}");
                            }
                            trimSliceTail(elseNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                        } else if (std.mem.eql(u8, forTail, "endfor")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% for %}, expected {% endfor %}");
                        }
                        try outNodes.append(a, .{
                            .forLoop = .{
                                .itemVars = try itemVars.toOwnedSlice(a),
                                .collectionExpr = head.collection,
                                .filterExpr = head.filter,
                                .recursive = head.recursive,
                                .bodyNodes = try bodyNodes.toOwnedSlice(a),
                                .elseNodes = try elseNodes.toOwnedSlice(a),
                                .startByte = tagStart,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "block")) {
                        const blockName = std.mem.trim(u8, tagContent[5..], " \t\r\n");
                        if (blockName.len == 0) {
                            return self.fail(.syntaxError, tagStart, "expected block name in '{% block name %}'");
                        }
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endblock", inLoop, stripLeading);
                        if (std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endblock")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% block %}, expected {% endblock %}");
                        }
                        const ownedBody = try bodyNodes.toOwnedSlice(a);
                        try blocksList.append(a, .{ .name = blockName, .nodes = ownedBody });
                        try outNodes.append(a, .{
                            .block = .{ .name = blockName, .bodyNodes = ownedBody, .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "extends")) {
                        const rawPath = std.mem.trim(u8, tagContent[7..], " \t\r\n");
                        const path = parseQuotedString(rawPath) orelse {
                            return self.fail(.syntaxError, tagStart, "invalid path in '{% extends \"...\" %}'");
                        };
                        extendsPath.* = path;
                        try outNodes.append(a, .{
                            .extends = .{ .parentPath = path, .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "include")) {
                        const spec = parseIncludeSpec(a, std.mem.trim(u8, tagContent[7..], " \t\r\n")) catch {
                            return self.fail(.syntaxError, tagStart, "invalid include syntax, expected '{% include \"...\" [ignore missing] [with|without context] %}'");
                        };
                        if (!spec.pathIsExpr) try includesList.append(a, spec.path);
                        try outNodes.append(a, .{
                            .include = .{
                                .templatePath = spec.path,
                                .pathIsExpr = spec.pathIsExpr,
                                .ignoreMissing = spec.ignoreMissing,
                                .withContext = spec.withContext,
                                .startByte = tagStart,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "import")) {
                        const spec = parseImportSpec(std.mem.trim(u8, tagContent[6..], " \t\r\n")) catch {
                            return self.fail(.syntaxError, tagStart, "invalid import syntax, expected '{% import \"...\" as name [with|without context] %}'");
                        };
                        try outNodes.append(a, .{
                            .importAs = .{
                                .templatePath = spec.path,
                                .alias = spec.alias,
                                .withContext = spec.withContext,
                                .startByte = tagStart,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "from")) {
                        const spec = parseFromSpec(a, std.mem.trim(u8, tagContent[4..], " \t\r\n")) catch {
                            return self.fail(.syntaxError, tagStart, "invalid from-import syntax, expected '{% from \"...\" import a, b as c %}'");
                        };
                        try outNodes.append(a, .{
                            .fromImport = .{
                                .templatePath = spec.path,
                                .names = spec.names,
                                .withContext = spec.withContext,
                                .startByte = tagStart,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "filter") or std.mem.eql(u8, tagCmd, "apply")) {
                        const isApply = std.mem.eql(u8, tagCmd, "apply");
                        const endName: []const u8 = if (isApply) "endapply" else "endfilter";
                        const spec = std.mem.trim(u8, tagContent[if (isApply) 5 else 6..], " \t\r\n");
                        if (spec.len == 0) {
                            return self.fail(.syntaxError, tagStart, "expected a filter after '{% filter %}'");
                        }
                        var filterBody = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &filterBody, blocksList, includesList, macrosList, extendsPath, endName, inLoop, stripLeading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), endName)) {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% filter %}, expected {% endfilter %}");
                        }
                        trimSliceTail(filterBody.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                        cursor.* += 1;
                        try outNodes.append(a, .{
                            .filterBlock = .{ .filterExpr = spec, .bodyNodes = try filterBody.toOwnedSlice(a), .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "with")) {
                        const remainder = std.mem.trim(u8, tagContent[4..], " \t\r\n");
                        const assigns = parseAssignList(a, remainder) catch {
                            return self.fail(.syntaxError, tagStart, "invalid with syntax, expected '{% with a=1, b=x %}'");
                        };
                        var withBody = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &withBody, blocksList, includesList, macrosList, extendsPath, "endwith", inLoop, stripLeading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endwith")) {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% with %}, expected {% endwith %}");
                        }
                        trimSliceTail(withBody.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                        cursor.* += 1;
                        try outNodes.append(a, .{
                            .withBlock = .{ .assigns = assigns, .bodyNodes = try withBody.toOwnedSlice(a), .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "autoescape")) {
                        const remainder = std.mem.trim(u8, tagContent[10..], " \t\r\n");
                        const enabled = parseAutoescapeFlag(remainder) orelse {
                            return self.fail(.syntaxError, tagStart, "invalid autoescape flag, expected true or false");
                        };
                        var aeBody = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &aeBody, blocksList, includesList, macrosList, extendsPath, "endautoescape", inLoop, stripLeading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endautoescape")) {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% autoescape %}, expected {% endautoescape %}");
                        }
                        trimSliceTail(aeBody.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                        cursor.* += 1;
                        try outNodes.append(a, .{
                            .autoescapeBlock = .{ .enabled = enabled, .bodyNodes = try aeBody.toOwnedSlice(a), .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "set")) {
                        const remainder = std.mem.trim(u8, tagContent[3..], " \t\r\n");
                        if (std.mem.indexOfScalar(u8, remainder, '=')) |eq| {
                            const name = std.mem.trim(u8, remainder[0..eq], " \t\r\n");
                            const valueExpr = std.mem.trim(u8, remainder[eq + 1 ..], " \t\r\n");
                            if (name.len == 0 or valueExpr.len == 0) {
                                return self.fail(.syntaxError, tagStart, "invalid set syntax, expected '{% set name = value %}'");
                            }
                            try outNodes.append(a, .{
                                .set = .{ .name = name, .valueExpr = valueExpr, .startByte = tagStart, .line = loc.line, .col = loc.col },
                            });
                        } else {
                            if (remainder.len == 0) {
                                return self.fail(.syntaxError, tagStart, "invalid set syntax, expected '{% set name = value %}' or '{% set name %}...{% endset %}'");
                            }
                            var setBody = std.ArrayList(TemplateNode).empty;
                            try self.parseTokenNodes(a, tokens, cursor, &setBody, blocksList, includesList, macrosList, extendsPath, "endset", inLoop, stripLeading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endset")) {
                                return self.fail(.unclosedBlock, tagStart, "unclosed {% set %}, expected {% endset %}");
                            }
                            trimSliceTail(setBody.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                            cursor.* += 1;
                            try outNodes.append(a, .{
                                .setBlock = .{ .name = remainder, .bodyNodes = try setBody.toOwnedSlice(a), .startByte = tagStart, .line = loc.line, .col = loc.col },
                            });
                        }
                    } else if (std.mem.eql(u8, tagCmd, "call")) {
                        var sig = std.mem.trim(u8, tagContent[4..], " \t\r\n");
                        // `{% call(item) macro() %}` declares caller parameters.
                        var callerParams: []const []const u8 = &.{};
                        if (sig.len > 0 and sig[0] == '(') {
                            var depth: usize = 0;
                            var qi: u8 = 0;
                            var ci: usize = 0;
                            var closeAt: ?usize = null;
                            while (ci < sig.len) : (ci += 1) {
                                const c = sig[ci];
                                if (qi != 0) {
                                    if (c == qi) qi = 0;
                                    continue;
                                }
                                switch (c) {
                                    '"', '\'' => qi = c,
                                    '(' => depth += 1,
                                    ')' => {
                                        depth -= 1;
                                        if (depth == 0) {
                                            closeAt = ci;
                                            break;
                                        }
                                    },
                                    else => {},
                                }
                                if (closeAt != null) break;
                            }
                            const close = closeAt orelse {
                                return self.fail(.syntaxError, tagStart, "invalid call syntax, expected '{% call [(args)] name(args) %}'");
                            };
                            const paramList = try splitTopLevel(a, sig[1..close]);
                            defer a.free(paramList);
                            var cp = std.ArrayList([]const u8).empty;
                            errdefer cp.deinit(a);
                            for (paramList) |p| {
                                if (p.len == 0 or splitNameValue(p) != null) {
                                    return self.fail(.syntaxError, tagStart, "caller parameters must be bare names");
                                }
                                try cp.append(a, p);
                            }
                            callerParams = try cp.toOwnedSlice(a);
                            sig = std.mem.trim(u8, sig[close + 1 ..], " \t\r\n");
                        }
                        const parsed = parseCallSig(a, sig) catch {
                            return self.fail(.syntaxError, tagStart, "invalid call syntax, expected '{% call [(args)] name(args) %}'");
                        };
                        var callBody = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &callBody, blocksList, includesList, macrosList, extendsPath, "endcall", inLoop, stripLeading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endcall")) {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% call %}, expected {% endcall %}");
                        }
                        trimSliceTail(callBody.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                        cursor.* += 1;
                        try outNodes.append(a, .{
                            .call = .{ .name = parsed.name, .args = parsed.args, .callerParams = callerParams, .bodyNodes = try callBody.toOwnedSlice(a), .startByte = tagStart, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tagCmd, "macro")) {
                        const sig = std.mem.trim(u8, tagContent[5..], " \t\r\n");
                        const parsed = parseMacroSignature(a, sig) catch {
                            return self.fail(.syntaxError, tagStart, "invalid macro signature, expected '{% macro name(args) %}'");
                        };
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endmacro", inLoop, stripLeading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endmacro")) {
                            return self.fail(.unclosedBlock, tagStart, "unclosed {% macro %}, expected {% endmacro %}");
                        }
                        trimSliceTail(bodyNodes.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) stripLeading.* = true;
                        cursor.* += 1;
                        const def = MacroDef{
                            .name = parsed.name,
                            .params = parsed.params,
                            .bodyNodes = try bodyNodes.toOwnedSlice(a),
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        };
                        try macrosList.append(a, def);
                        try outNodes.append(a, .{ .macroDef = def });
                    } else if (std.mem.eql(u8, tagCmd, "break")) {
                        if (!inLoop) return self.fail(.unexpectedToken, tagStart, "{% break %} outside of a loop");
                        try outNodes.append(a, .{ .breakLoop = .{ .startByte = tagStart, .line = loc.line, .col = loc.col } });
                    } else if (std.mem.eql(u8, tagCmd, "continue")) {
                        if (!inLoop) return self.fail(.unexpectedToken, tagStart, "{% continue %} outside of a loop");
                        try outNodes.append(a, .{ .continueLoop = .{ .startByte = tagStart, .line = loc.line, .col = loc.col } });
                    } else if (std.mem.eql(u8, tagCmd, "endfor") or std.mem.eql(u8, tagCmd, "endblock") or std.mem.eql(u8, tagCmd, "endmacro") or std.mem.eql(u8, tagCmd, "endcall") or std.mem.eql(u8, tagCmd, "endset") or std.mem.eql(u8, tagCmd, "endraw") or std.mem.eql(u8, tagCmd, "endfilter") or std.mem.eql(u8, tagCmd, "endapply") or std.mem.eql(u8, tagCmd, "endwith") or std.mem.eql(u8, tagCmd, "endautoescape")) {
                        return self.fail(.unexpectedToken, tagStart, "unexpected end tag without matching block");
                    } else {
                        return self.fail(.unexpectedToken, tagStart, "unknown template directive");
                    }
                },
            }
        }
    }

    fn fail(self: *Parser, kind: errMod.TemplateErrorKind, offset: usize, message: []const u8) TemplateError {
        const loc = lineColFromOffset(self.source, offset);
        self.lastError = .{
            .kind = kind,
            .templateName = self.templateName,
            .line = loc.line,
            .column = loc.col,
            .byteOffset = offset,
            .message = message,
        };
        return switch (kind) {
            .syntaxError => TemplateError.SyntaxError,
            .unexpectedToken => TemplateError.UnexpectedToken,
            .unclosedBlock => TemplateError.UnclosedBlock,
            .unclosedExpression => TemplateError.UnclosedExpression,
            else => TemplateError.SyntaxError,
        };
    }

    fn parseNodes(
        self: *Parser,
        a: Allocator,
        outNodes: *std.ArrayList(TemplateNode),
        blocksList: *std.ArrayList(BlockInfo),
        includesList: *std.ArrayList([]const u8),
        extendsPath: *?[]const u8,
        stopTag: ?[]const u8,
    ) TemplateError!void {
        while (self.pos < self.source.len) {
            const nextOpen = std.mem.indexOfPos(u8, self.source, self.pos, "{");
            if (nextOpen == null) {
                // Remainder is plain text
                const text = self.source[self.pos..];
                if (text.len > 0) {
                    try outNodes.append(a, .{ .text = text });
                }
                self.pos = self.source.len;
                break;
            }

            const openIdx = nextOpen.?;
            if (openIdx > self.pos) {
                try outNodes.append(a, .{ .text = self.source[self.pos..openIdx] });
                self.pos = openIdx;
            }

            if (openIdx + 1 >= self.source.len) {
                try outNodes.append(a, .{ .text = self.source[openIdx..] });
                self.pos = self.source.len;
                break;
            }

            const second = self.source[openIdx + 1];
            if (second == '{') {
                // Expression: {{ ... }}
                const exprStart = self.pos;
                const closeIdx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "}}") orelse {
                    return self.fail(.unclosedExpression, exprStart, "unclosed expression, expected '}}'");
                };
                const rawExpr = std.mem.trim(u8, self.source[openIdx + 2 .. closeIdx], " \t\r\n");
                const loc = lineColFromOffset(self.source, exprStart);
                try outNodes.append(a, .{
                    .expression = .{
                        .expr = rawExpr,
                        .startByte = exprStart,
                        .line = loc.line,
                        .col = loc.col,
                    },
                });
                self.pos = closeIdx + 2;
            } else if (second == '#') {
                // Comment: {# ... #}
                const closeIdx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "#}") orelse {
                    return self.fail(.syntaxError, openIdx, "unclosed comment, expected '#}'");
                };
                self.pos = closeIdx + 2;
            } else if (second == '%') {
                // Directive: {% ... %}
                const tagStart = self.pos;
                const closeIdx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "%}") orelse {
                    return self.fail(.syntaxError, tagStart, "unclosed directive, expected '%}'");
                };

                const tagContent = std.mem.trim(u8, self.source[openIdx + 2 .. closeIdx], " \t\r\n");
                const tagCmd = directiveCmd(tagContent);

                // Check if this matches stopTag
                if (stopTag) |target| {
                    if (std.mem.eql(u8, tagCmd, target) or
                        (std.mem.eql(u8, target, "endif_or_else") and (std.mem.eql(u8, tagCmd, "else") or std.mem.eql(u8, tagCmd, "endif"))))
                    {
                        // Stop before consuming this tag; parent will consume
                        return;
                    }
                }

                self.pos = closeIdx + 2;
                const loc = lineColFromOffset(self.source, tagStart);

                if (std.mem.eql(u8, tagCmd, "if")) {
                    const condition = std.mem.trim(u8, tagContent[2..], " \t\r\n");
                    var thenNodes = std.ArrayList(TemplateNode).empty;
                    var elseNodes = std.ArrayList(TemplateNode).empty;

                    try self.parseNodes(a, &thenNodes, blocksList, includesList, extendsPath, "endif_or_else");

                    if (self.pos < self.source.len) {
                        const nextDirClose = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosedBlock, tagStart, "expected {% else %} or {% endif %}");
                        };
                        const nextDir = std.mem.trim(u8, self.source[self.pos + 2 .. nextDirClose], " \t\r\n");
                        if (std.mem.startsWith(u8, nextDir, "else")) {
                            self.pos = nextDirClose + 2;
                            try self.parseNodes(a, &elseNodes, blocksList, includesList, extendsPath, "endif");
                            if (self.pos < self.source.len) {
                                const endClose = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                                    return self.fail(.unclosedBlock, tagStart, "expected {% endif %}");
                                };
                                self.pos = endClose + 2;
                            }
                        } else if (std.mem.startsWith(u8, nextDir, "endif")) {
                            self.pos = nextDirClose + 2;
                        }
                    } else {
                        return self.fail(.unclosedBlock, tagStart, "unclosed {% if %}, expected {% endif %}");
                    }

                    try outNodes.append(a, .{
                        .ifBlock = .{
                            .condition = condition,
                            .thenNodes = try thenNodes.toOwnedSlice(a),
                            .elifBranches = &.{},
                            .elseNodes = try elseNodes.toOwnedSlice(a),
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tagCmd, "for")) {
                    // Syntax: {% for item in collection %} (fallback path:
                    // single target, no if-filter or recursion support).
                    const remainder = std.mem.trim(u8, tagContent[3..], " \t\r\n");
                    const inPos = std.mem.indexOf(u8, remainder, " in ") orelse {
                        return self.fail(.syntaxError, tagStart, "invalid for loop syntax, expected '{% for item in items %}'");
                    };
                    const itemVar = std.mem.trim(u8, remainder[0..inPos], " \t\r\n");
                    const collExpr = std.mem.trim(u8, remainder[inPos + 4 ..], " \t\r\n");

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocksList, includesList, extendsPath, "endfor");

                    if (self.pos < self.source.len) {
                        const endClose = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosedBlock, tagStart, "expected {% endfor %}");
                        };
                        self.pos = endClose + 2;
                    } else {
                        return self.fail(.unclosedBlock, tagStart, "unclosed {% for %}, expected {% endfor %}");
                    }

                    const fallbackVars = try a.alloc([]const u8, 1);
                    fallbackVars[0] = itemVar;
                    try outNodes.append(a, .{
                        .forLoop = .{
                            .itemVars = fallbackVars,
                            .collectionExpr = collExpr,
                            .bodyNodes = try bodyNodes.toOwnedSlice(a),
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tagCmd, "block")) {
                    const blockName = std.mem.trim(u8, tagContent[5..], " \t\r\n");
                    if (blockName.len == 0) {
                        return self.fail(.syntaxError, tagStart, "expected block name in '{% block name %}'");
                    }

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocksList, includesList, extendsPath, "endblock");

                    if (self.pos < self.source.len) {
                        const endClose = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosedBlock, tagStart, "expected {% endblock %}");
                        };
                        self.pos = endClose + 2;
                    } else {
                        return self.fail(.unclosedBlock, tagStart, "unclosed {% block %}, expected {% endblock %}");
                    }

                    const ownedBody = try bodyNodes.toOwnedSlice(a);
                    try blocksList.append(a, .{
                        .name = blockName,
                        .nodes = ownedBody,
                    });

                    try outNodes.append(a, .{
                        .block = .{
                            .name = blockName,
                            .bodyNodes = ownedBody,
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tagCmd, "extends")) {
                    const rawPath = std.mem.trim(u8, tagContent[7..], " \t\r\n");
                    const path = parseQuotedString(rawPath) orelse {
                        return self.fail(.syntaxError, tagStart, "invalid path in '{% extends \"...\" %}'");
                    };
                    extendsPath.* = path;
                    try outNodes.append(a, .{
                        .extends = .{
                            .parentPath = path,
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tagCmd, "include")) {
                    const rawPath = std.mem.trim(u8, tagContent[7..], " \t\r\n");
                    const path = parseQuotedString(rawPath) orelse {
                        return self.fail(.syntaxError, tagStart, "invalid path in '{% include \"...\" %}'");
                    };
                    try includesList.append(a, path);
                    try outNodes.append(a, .{
                        .include = .{
                            .templatePath = path,
                            .pathIsExpr = false,
                            .ignoreMissing = false,
                            .withContext = null,
                            .startByte = tagStart,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else {
                    return self.fail(.unexpectedToken, tagStart, "unknown template directive");
                }
            } else {
                // Just a solitary '{'
                try outNodes.append(a, .{ .text = self.source[openIdx .. openIdx + 1] });
                self.pos = openIdx + 1;
            }
        }
    }
};

fn parseQuotedString(s: []const u8) ?[]const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return null;
}

test "Parser parses expressions, conditionals, and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\<h1>{{ title }}</h1>
        \\{% if user %}
        \\  <p>Hello {{ user.name }}</p>
        \\{% else %}
        \\  <p>Guest</p>
        \\{% endif %}
        \\<ul>
        \\{% for item in items %}
        \\  <li>{{ item }}</li>
        \\{% endfor %}
        \\</ul>
    ;

    var parser = Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    try testing.expect(ast.nodes.len > 0);
    try testing.expect(ast.extendsPath == null);
}

test "Parser parses blocks, extends, and includes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\{% extends "base.html" %}
        \\{% block content %}
        \\  {% include "partials/header.html" %}
        \\  <p>Body</p>
        \\{% endblock %}
    ;

    var parser = Parser.init(alloc, "child.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    try testing.expectEqualStrings("base.html", ast.extendsPath.?);
    try testing.expectEqual(@as(usize, 1), ast.blocks.len);
    try testing.expectEqualStrings("content", ast.blocks[0].name);
    try testing.expectEqual(@as(usize, 1), ast.includes.len);
    try testing.expectEqualStrings("partials/header.html", ast.includes[0]);
}

test "Parser fuzzes malformed input without crashing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const evil = [_][]const u8{
        "{{",
        "{%",
        "{#",
        "{{{",
        "{%%}",
        "{{ }}",
        "{% if %}{% if %}{% if %}",
        "{% endif %}{% endif %}",
        "{% for %}",
        "{% for x in %}",
        "{% block %}",
        "{% macro %}",
        "{% macro ( %}x{% endmacro %}",
        "{% set = %}",
        "{% call %}x",
        "{% raw %}unclosed",
        "{{ |upper }}",
        "{{ x| }}",
        "{{ (x }}",
        "{{ [1, }}",
        "{{ {\"a\": } }}",
        "{% extends %}",
        "{% include %}",
        "{% endblock %}",
        "{% else %}",
        "{% elif x %}",
        "\x00\xff{{ x }}\x00",
        "{{ \"unterminated }}",
        "{% if a == %}",
        "{{ a.b.c.d.e }}",
        "{% for a, b, c in x %}{% endfor %}",
        "{{ range( }}",
        "{{ unknown_filter_xyz(1) }}",
    };
    for (evil) |src| {
        var parser = Parser.init(alloc, "fuzz.html", src);
        if (parser.parse()) |ast| {
            var mut = ast;
            mut.deinit();
        } else |_| {}
        try testing.expect(parser.lastError == null or parser.lastError.?.line >= 1);
    }
}

test "Parser reports syntax errors with line/column" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = "line 1\n{% if unclosed %}\nhello";
    var parser = Parser.init(alloc, "bad.html", src);
    const res = parser.parse();
    try testing.expectError(TemplateError.UnclosedBlock, res);
    try testing.expect(parser.lastError != null);
    try testing.expectEqual(@as(usize, 2), parser.lastError.?.line);
}

test "template grammar tokenizes text, expression, directive, comment" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tree = try parseTemplateTree(alloc, "Hello {{ name }}! {% if ok %}yes{% endif %}{# note #}");
    defer tree.deinit();
    try testing.expect(!tree.hasError());
    try testing.expectEqualStrings("program", tree.rootNode().nodeType());
    var foundText = false;
    var foundExpr = false;
    var foundDir = false;
    var foundComment = false;
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, tree.rootNode());
    while (stack.pop()) |cur| {
        const t = cur.nodeType();
        if (std.mem.eql(u8, t, "text")) foundText = true;
        if (std.mem.eql(u8, t, "expression")) {
            foundExpr = true;
            try testing.expectEqualStrings("{{ name }}", cur.text());
        }
        if (std.mem.eql(u8, t, "directive")) foundDir = true;
        if (std.mem.eql(u8, t, "comment")) {
            foundComment = true;
            try testing.expectEqualStrings("{# note #}", cur.text());
        }
        var i: u32 = cur.childCount();
        while (i > 0) {
            i -= 1;
            if (cur.child(i)) |c| try stack.append(alloc, c);
        }
    }
    try testing.expect(foundText and foundExpr and foundDir and foundComment);
}

test "template grammar flags unclosed delimiters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tree = try parseTemplateTree(alloc, "Hello {{ name!");
    defer tree.deinit();
    try testing.expect(tree.hasError());
}

test "template grammar parses empty template" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tree = try parseTemplateTree(alloc, "");
    defer tree.deinit();
    try testing.expect(!tree.hasError());
}

test "Parser tree-driven path preserves syntax positions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = "A{{ x }}B{# c #}C{% if y %}D{% endif %}E";
    var tree = try parseTemplateTree(alloc, src);
    defer tree.deinit();
    try testing.expect(!tree.hasError());

    var parser = Parser.init(alloc, "pos.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var exprStart: ?usize = null;
    for (ast.nodes) |n| {
        if (n == .expression) exprStart = n.expression.startByte;
    }
    try testing.expect(exprStart != null);
    try testing.expectEqual(std.mem.indexOf(u8, src, "{{").?, exprStart.?);
}

test "Parser parses import from filter with autoescape statements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% import \"m.html\" as m %}{% from \"n.html\" import a, b as c %}{% filter upper %}x{% endfilter %}{% apply lower %}Y{% endapply %}{% with k=1 %}v{% endwith %}{% autoescape false %}z{% endautoescape %}";
    var parser = Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 6), ast.nodes.len);
    try testing.expect(ast.nodes[0] == .importAs);
    try testing.expectEqualStrings("m.html", ast.nodes[0].importAs.templatePath);
    try testing.expectEqualStrings("m", ast.nodes[0].importAs.alias);
    try testing.expect(ast.nodes[1] == .fromImport);
    try testing.expectEqual(@as(usize, 2), ast.nodes[1].fromImport.names.len);
    try testing.expectEqualStrings("a", ast.nodes[1].fromImport.names[0].name);
    try testing.expectEqualStrings("c", ast.nodes[1].fromImport.names[1].alias.?);
    try testing.expect(ast.nodes[2] == .filterBlock);
    try testing.expectEqualStrings("upper", ast.nodes[2].filterBlock.filterExpr);
    try testing.expect(ast.nodes[3] == .filterBlock);
    try testing.expect(ast.nodes[4] == .withBlock);
    try testing.expectEqual(@as(usize, 1), ast.nodes[4].withBlock.assigns.len);
    try testing.expectEqualStrings("k", ast.nodes[4].withBlock.assigns[0].name.?);
    try testing.expect(ast.nodes[5] == .autoescapeBlock);
    try testing.expect(!ast.nodes[5].autoescapeBlock.enabled);
}

test "Parser parses for filters recursion and include modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% for x in y if x %}{% endfor %}{% for a, b in z recursive %}{% endfor %}{% include \"p\" ignore missing %}{% include \"q\" without context %}{% include name %}";
    var parser = Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 5), ast.nodes.len);
    const f0 = ast.nodes[0].forLoop;
    try testing.expect(f0.filterExpr != null);
    try testing.expectEqualStrings("x", f0.filterExpr.?);
    try testing.expect(!f0.recursive);
    try testing.expectEqual(@as(usize, 1), f0.itemVars.len);
    const f1 = ast.nodes[1].forLoop;
    try testing.expect(f1.recursive);
    try testing.expectEqual(@as(usize, 2), f1.itemVars.len);
    try testing.expectEqualStrings("a", f1.itemVars[0]);
    try testing.expectEqualStrings("b", f1.itemVars[1]);
    const inc0 = ast.nodes[2].include;
    try testing.expect(inc0.ignoreMissing);
    try testing.expect(!inc0.pathIsExpr);
    const inc1 = ast.nodes[3].include;
    try testing.expect(inc1.withContext != null and !inc1.withContext.?);
    const inc2 = ast.nodes[4].include;
    try testing.expect(inc2.pathIsExpr);
}

test "Parser parses macro star args and call params" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% macro m(a, b=1, *r, **k) %}{% endmacro %}{% call(item) m() %}x{% endcall %}";
    var parser = Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 1), ast.macros.len);
    const params = ast.macros[0].params;
    try testing.expectEqual(@as(usize, 4), params.len);
    try testing.expectEqualStrings("a", params[0].name);
    try testing.expectEqualStrings("b", params[1].name);
    try testing.expect(params[1].default != null);
    try testing.expect(params[2].star);
    try testing.expect(params[3].starStar);
    var foundCall = false;
    for (ast.nodes) |n| {
        if (n == .call) {
            foundCall = true;
            try testing.expectEqual(@as(usize, 1), n.call.callerParams.len);
            try testing.expectEqualStrings("item", n.call.callerParams[0]);
        }
    }
    try testing.expect(foundCall);
}

test "Parser rejects malformed new statements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const bad = [_][]const u8{
        "{% import %}",
        "{% import \"m.html\" %}",
        "{% from \"m.html\" import %}",
        "{% filter %}{% endfilter %}",
        "{% filter upper %}",
        "{% with a %}{% endwith %}",
        "{% autoescape maybe %}x{% endautoescape %}",
        "{% autoescape true %}x",
        "{% for x in %}{% endfor %}",
        "{% call(item %}x{% endcall %}",
        "{% macro m(**) %}{% endmacro %}",
        "{% include %}",
    };
    for (bad) |src| {
        var parser = Parser.init(alloc, "t.html", src);
        if (parser.parse()) |ast| {
            var mut = ast;
            mut.deinit();
            std.debug.print("EXPECTED-ERROR src={s}\n", .{src});
            try testing.expect(false);
        } else |_| {}
    }
}

test "Parser helpers split names values and for heads" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        const nv = splitNameValue("a = b=c");
        try testing.expect(nv != null);
        try testing.expectEqualStrings("a", nv.?.name);
        try testing.expectEqualStrings("b=c", nv.?.value);
    }
    try testing.expect(splitNameValue("a == b") == null);
    {
        const head = parseForHead("x in y if x > 1 recursive").?;
        try testing.expectEqualStrings("x", std.mem.trim(u8, head.vars, " "));
        try testing.expectEqualStrings("y", head.collection);
        try testing.expectEqualStrings("x > 1", head.filter.?);
        try testing.expect(head.recursive);
    }
    {
        const head = parseForHead("(k, v) in items").?;
        try testing.expect(head.filter == null);
        try testing.expect(!head.recursive);
    }
    try testing.expect(parseForHead("x y") == null);
    try testing.expect(parseAutoescapeFlag("True") == true);
    try testing.expect(parseAutoescapeFlag("FALSE") == false);
    try testing.expect(parseAutoescapeFlag("x") == null);
    _ = alloc;
}
