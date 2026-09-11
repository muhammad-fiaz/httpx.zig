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
const err_mod = @import("error.zig");
const ts = @import("treesitter");
pub const TemplateError = err_mod.TemplateError;
pub const SourceError = err_mod.SourceError;
pub const lineColFromOffset = err_mod.lineColFromOffset;

pub const TemplateTree = ts.Tree;

const tmpl_sym_end: u16 = 0;
const tmpl_sym_text: u16 = 1;
const tmpl_sym_expression: u16 = 2;
const tmpl_sym_directive: u16 = 3;
const tmpl_sym_comment: u16 = 4;
const tmpl_sym_program: u16 = 5;
const tmpl_sym_items: u16 = 6;
const tmpl_sym_item: u16 = 7;
const tmpl_sym_error: u16 = 8;

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

const tmpl_symbol_table: []const ts.language_mod.symbols.SymbolInfo = &.{
    .{ .id = tmpl_sym_end, .name = "end", .kind = .end, .metadata = .{ .visible = false, .named = false } },
    .{ .id = tmpl_sym_text, .name = "text", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_expression, .name = "expression", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_directive, .name = "directive", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_comment, .name = "comment", .kind = .terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_program, .name = "program", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_items, .name = "items", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_item, .name = "item", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
    .{ .id = tmpl_sym_error, .name = "ERROR", .kind = .non_terminal, .metadata = .{ .visible = true, .named = true } },
};

const tmpl_token_matchers: []const ts.language_mod.TokenMatcher = &.{
    .{ .symbol = tmpl_sym_expression, .match = matchTemplateExpression },
    .{ .symbol = tmpl_sym_directive, .match = matchTemplateDirective },
    .{ .symbol = tmpl_sym_comment, .match = matchTemplateComment },
    .{ .symbol = tmpl_sym_text, .match = matchTemplateText },
};

const tmpl_s0_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .shift = 5 } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .shift = 6 } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .shift = 7 } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .shift = 8 } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_program, .child_count = 0, .production_id = 0 } } },
};
const tmpl_s0_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = tmpl_sym_program, .state = 1 },
    .{ .symbol = tmpl_sym_items, .state = 2 },
    .{ .symbol = tmpl_sym_item, .state = 3 },
};
const tmpl_s1_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_end, .action = .accept },
};
const tmpl_s2_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .shift = 5 } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .shift = 6 } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .shift = 7 } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .shift = 8 } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_program, .child_count = 1, .production_id = 1 } } },
};
const tmpl_s2_gotos: []const ts.language_mod.tables.GotoEntry = &.{
    .{ .symbol = tmpl_sym_item, .state = 4 },
};
const tmpl_s3_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 1, .production_id = 2 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 1, .production_id = 2 } } },
};
const tmpl_s4_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 2, .production_id = 3 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_items, .child_count = 2, .production_id = 3 } } },
};
const tmpl_s5_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 4 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 4 } } },
};
const tmpl_s6_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 5 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 5 } } },
};
const tmpl_s7_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 6 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 6 } } },
};
const tmpl_s8_actions: []const ts.language_mod.tables.ActionEntry = &.{
    .{ .symbol = tmpl_sym_text, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmpl_sym_expression, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmpl_sym_directive, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmpl_sym_comment, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 7 } } },
    .{ .symbol = tmpl_sym_end, .action = .{ .reduce = .{ .symbol = tmpl_sym_item, .child_count = 1, .production_id = 7 } } },
};

const tmpl_parse_states: []const ts.language_mod.tables.ParseState = &.{
    .{ .actions = tmpl_s0_actions, .gotos = tmpl_s0_gotos },
    .{ .actions = tmpl_s1_actions },
    .{ .actions = tmpl_s2_actions, .gotos = tmpl_s2_gotos },
    .{ .actions = tmpl_s3_actions },
    .{ .actions = tmpl_s4_actions },
    .{ .actions = tmpl_s5_actions },
    .{ .actions = tmpl_s6_actions },
    .{ .actions = tmpl_s7_actions },
    .{ .actions = tmpl_s8_actions },
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
    .symbols = tmpl_symbol_table,
    .token_matchers = tmpl_token_matchers,
    .extra_symbols = &.{},
    .table = .{
        .states = tmpl_parse_states,
        .start_state = 0,
        .end_symbol = tmpl_sym_end,
        .error_symbol = tmpl_sym_error,
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
    var depth_paren: usize = 0;
    var depth_brack: usize = 0;
    var depth_brace: usize = 0;
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
            '(' => depth_paren += 1,
            ')' => depth_paren -|= 1,
            '[' => depth_brack += 1,
            ']' => depth_brack -|= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -|= 1,
            ',' => {
                if (depth_paren == 0 and depth_brack == 0 and depth_brace == 0) {
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
            var depth: usize = 0;
            var q: u8 = 0;
            var eq: ?usize = null;
            for (part, 0..) |c, idx| {
                if (q != 0) {
                    if (c == q) q = 0;
                    continue;
                }
                switch (c) {
                    '"', '\'' => q = c,
                    '(', '[', '{' => depth += 1,
                    ')', ']', '}' => depth -|= 1,
                    '=' => {
                        if (depth == 0 and (idx + 1 >= part.len or part[idx + 1] != '=')) {
                            eq = idx;
                        }
                    },
                    else => {},
                }
                if (eq != null) break;
            }
            if (eq) |e| {
                try args.append(a, .{
                    .name = std.mem.trim(u8, part[0..e], " \t\r\n"),
                    .value = std.mem.trim(u8, part[e + 1 ..], " \t\r\n"),
                });
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
    forLoop: struct {
        itemVar: []const u8,
        itemVar2: ?[]const u8 = null,
        collectionExpr: []const u8,
        bodyNodes: []const TemplateNode,
        elseNodes: []const TemplateNode = &.{},
        startByte: usize,
        line: usize,
        col: usize,
    },
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
        startByte: usize,
        line: usize,
        col: usize,
    },
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
    var content = std.mem.trim(u8, raw, " \t\r\n");
    var left = false;
    var right = false;
    if (content.len > 0 and content[0] == '-') {
        left = true;
        content = std.mem.trimStart(u8, content[1..], " \t\r\n");
    }
    if (content.len > 0 and content[content.len - 1] == '-') {
        right = true;
        content = std.mem.trimEnd(u8, content[0 .. content.len - 1], " \t\r\n");
    }
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

/// Parses a macro signature `name(arg1, arg2="default")` into name + params.
pub fn parseMacroSignature(a: Allocator, s: []const u8) !struct { name: []const u8, params: []MacroParam } {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return error.InvalidSignature;
    const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return error.InvalidSignature;
    if (close < open) return error.InvalidSignature;
    const name = std.mem.trim(u8, s[0..open], " \t\r\n");
    if (name.len == 0) return error.InvalidSignature;
    const args_str = std.mem.trim(u8, s[open + 1 .. close], " \t\r\n");
    var params = std.ArrayList(MacroParam).empty;
    errdefer params.deinit(a);
    if (args_str.len > 0) {
        var it = std.mem.splitScalar(u8, args_str, ',');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t\r\n");
            if (p.len == 0) continue;
            if (std.mem.indexOfScalar(u8, p, '=')) |eq| {
                const pname = std.mem.trim(u8, p[0..eq], " \t\r\n");
                const dflt = std.mem.trim(u8, p[eq + 1 ..], " \t\r\n");
                try params.append(a, .{ .name = pname, .default = dflt });
            } else {
                try params.append(a, .{ .name = p });
            }
        }
    }
    return .{ .name = name, .params = try params.toOwnedSlice(a) };
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

        var nodes_list = std.ArrayList(TemplateNode).empty;
        var blocksList = std.ArrayList(BlockInfo).empty;
        var includesList = std.ArrayList([]const u8).empty;
        var macrosList = std.ArrayList(MacroDef).empty;
        var extendsPath: ?[]const u8 = null;

        var ts_tree = parseTemplateTree(self.allocator, self.source) catch null;
        if (ts_tree) |*t| {
            defer {
                var mut: TemplateTree = t.*;
                mut.deinit();
            }
            if (!t.hasError()) {
                const tokens = collectTemplateTokens(t, self.allocator) catch null;
                if (tokens) |toks| {
                    defer self.allocator.free(toks);
                    var cursor: usize = 0;
                    var strip_leading = false;
                    try self.parseTokenNodes(a, toks, &cursor, &nodes_list, &blocksList, &includesList, &macrosList, &extendsPath, null, false, &strip_leading);
                    return .{
                        .nodes = try nodes_list.toOwnedSlice(a),
                        .extendsPath = extendsPath,
                        .blocks = try blocksList.toOwnedSlice(a),
                        .includes = try includesList.toOwnedSlice(a),
                        .macros = try macrosList.toOwnedSlice(a),
                        .arena = arena,
                    };
                }
            }
        }

        try self.parseNodes(a, &nodes_list, &blocksList, &includesList, &extendsPath, null);

        return .{
            .nodes = try nodes_list.toOwnedSlice(a),
            .extendsPath = extendsPath,
            .blocks = try blocksList.toOwnedSlice(a),
            .includes = try includesList.toOwnedSlice(a),
            .macros = try macrosList.toOwnedSlice(a),
            .arena = arena,
        };
    }

    fn peekDirectiveCmd(self: *Parser, tokens: []const TsToken, at: usize) []const u8 {
        if (at >= tokens.len or tokens[at].kind != .directive) return "";
        const raw = self.source[tokens[at].start + 2 .. tokens[at].end - 2];
        const stripped = stripDashControl(raw);
        var it = std.mem.tokenizeAny(u8, stripped.content, " \t\r\n");
        return it.next() orelse "";
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
        strip_leading: *bool,
        tok: TsToken,
    ) void {
        const stripped = stripDashControl(self.source[tok.start + 2 .. tok.end - 2]);
        if (stripped.left) trimTrailingWhitespace(a, outNodes);
        if (stripped.right) strip_leading.* = true;
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
        strip_leading: *bool,
    ) TemplateError!void {
        while (cursor.* < tokens.len) {
            const tok = tokens[cursor.*];
            switch (tok.kind) {
                .comment => {
                    self.applyTagStrip(a, outNodes, strip_leading, tok);
                    cursor.* += 1;
                    continue;
                },
                .text => {
                    var text = self.source[tok.start..tok.end];
                    if (strip_leading.*) {
                        strip_leading.* = false;
                        text = trimLeadingWhitespace(text);
                    }
                    if (text.len > 0) try outNodes.append(a, .{ .text = text });
                    cursor.* += 1;
                    continue;
                },
                .expression => {
                    self.applyTagStrip(a, outNodes, strip_leading, tok);
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
                    const tag_content = stripped.content;
                    var tag_it = std.mem.tokenizeAny(u8, tag_content, " \t\r\n");
                    const tag_cmd = tag_it.next() orelse "";
                    if (isStopCmd(stopTag, tag_cmd)) {
                        return;
                    }
                    self.applyTagStrip(a, outNodes, strip_leading, tok);
                    const tag_start = tok.start;
                    const loc = lineColFromOffset(self.source, tag_start);
                    cursor.* += 1;
                    if (std.mem.eql(u8, tag_cmd, "raw")) {
                        var j = cursor.*;
                        var found: ?usize = null;
                        while (j < tokens.len) : (j += 1) {
                            if (tokens[j].kind == .directive and std.mem.eql(u8, self.peekDirectiveCmd(tokens, j), "endraw")) {
                                found = j;
                                break;
                            }
                        }
                        const close = found orelse {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% raw %}, expected {% endraw %}");
                        };
                        const body_start = if (cursor.* < tokens.len) tokens[cursor.*].start else @min(tok.end, self.source.len);
                        var body_end = tokens[close].start;
                        const close_strip = stripDashControl(self.source[tokens[close].start + 2 .. tokens[close].end - 2]);
                        if (close_strip.left) {
                            while (body_end > body_start) {
                                const c = self.source[body_end - 1];
                                if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
                                body_end -= 1;
                            }
                        }
                        if (body_end > body_start) {
                            try outNodes.append(a, .{ .text = self.source[body_start..body_end] });
                        }
                        if (close_strip.right) strip_leading.* = true;
                        cursor.* = close + 1;
                    } else if (std.mem.eql(u8, tag_cmd, "if")) {
                        const condition = std.mem.trim(u8, tag_content[2..], " \t\r\n");
                        var thenNodes = std.ArrayList(TemplateNode).empty;
                        var elifBranches = std.ArrayList(ElifBranch).empty;
                        var elseNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &thenNodes, blocksList, includesList, macrosList, extendsPath, "endif_elif_else", inLoop, strip_leading);
                        var tail_body: []const TemplateNode = thenNodes.items;
                        while (true) {
                            const nxt = self.peekDirectiveCmd(tokens, cursor.*);
                            if (std.mem.eql(u8, nxt, "elif")) {
                                const elif_tok = tokens[cursor.*];
                                trimSliceTail(tail_body);
                                if (stripDashControl(self.source[elif_tok.start + 2 .. elif_tok.end - 2]).right) strip_leading.* = true;
                                const elif_raw = stripDashControl(self.source[elif_tok.start + 2 .. elif_tok.end - 2]);
                                const elif_cond = std.mem.trim(u8, elif_raw.content[4..], " \t\r\n");
                                const elif_loc = lineColFromOffset(self.source, elif_tok.start);
                                cursor.* += 1;
                                var branchBody = std.ArrayList(TemplateNode).empty;
                                try self.parseTokenNodes(a, tokens, cursor, &branchBody, blocksList, includesList, macrosList, extendsPath, "endif_elif_else", inLoop, strip_leading);
                                try elifBranches.append(a, .{
                                    .condition = elif_cond,
                                    .bodyNodes = try branchBody.toOwnedSlice(a),
                                    .startByte = elif_tok.start,
                                    .line = elif_loc.line,
                                    .col = elif_loc.col,
                                });
                                tail_body = elifBranches.items[elifBranches.items.len - 1].bodyNodes;
                                continue;
                            }
                            break;
                        }
                        const tail = self.peekDirectiveCmd(tokens, cursor.*);
                        if (std.mem.eql(u8, tail, "else")) {
                            trimSliceTail(tail_body);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                            try self.parseTokenNodes(a, tokens, cursor, &elseNodes, blocksList, includesList, macrosList, extendsPath, "endif", inLoop, strip_leading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endif")) {
                                return self.fail(.unclosed_block, tag_start, "unclosed {% if %}, expected {% endif %}");
                            }
                            trimSliceTail(elseNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                        } else if (std.mem.eql(u8, tail, "endif")) {
                            trimSliceTail(tail_body);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% if %}, expected {% endif %}");
                        }
                        try outNodes.append(a, .{
                            .ifBlock = .{
                                .condition = condition,
                                .thenNodes = try thenNodes.toOwnedSlice(a),
                                .elifBranches = try elifBranches.toOwnedSlice(a),
                                .elseNodes = try elseNodes.toOwnedSlice(a),
                                .startByte = tag_start,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "elif") or std.mem.eql(u8, tag_cmd, "else") or std.mem.eql(u8, tag_cmd, "endif")) {
                        return self.fail(.unexpectedToken, tag_start, "unexpected endif/else without matching {% if %}");
                    } else if (std.mem.eql(u8, tag_cmd, "for")) {
                        const remainder = std.mem.trim(u8, tag_content[3..], " \t\r\n");
                        const inPos = std.mem.indexOf(u8, remainder, " in ") orelse {
                            return self.fail(.syntaxError, tag_start, "invalid for loop syntax, expected '{% for item in items %}'");
                        };
                        const itemVar = std.mem.trim(u8, remainder[0..inPos], " \t\r\n");
                        const coll_expr = std.mem.trim(u8, remainder[inPos + 4 ..], " \t\r\n");
                        if (itemVar.len == 0 or coll_expr.len == 0) {
                            return self.fail(.syntaxError, tag_start, "invalid for loop syntax, expected '{% for item in items %}'");
                        }
                        var item_name = itemVar;
                        var item_name2: ?[]const u8 = null;
                        if (std.mem.indexOfScalar(u8, itemVar, ',')) |comma| {
                            item_name = std.mem.trim(u8, itemVar[0..comma], " \t\r\n");
                            item_name2 = std.mem.trim(u8, itemVar[comma + 1 ..], " \t\r\n");
                            if (item_name.len == 0 or item_name2.?.len == 0) {
                                return self.fail(.syntaxError, tag_start, "invalid loop variables, expected '{% for key, value in items %}'");
                            }
                        }
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        var elseNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endfor_else", true, strip_leading);
                        const for_tail = self.peekDirectiveCmd(tokens, cursor.*);
                        if (std.mem.eql(u8, for_tail, "else")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                            try self.parseTokenNodes(a, tokens, cursor, &elseNodes, blocksList, includesList, macrosList, extendsPath, "endfor", true, strip_leading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endfor")) {
                                return self.fail(.unclosed_block, tag_start, "unclosed {% for %}, expected {% endfor %}");
                            }
                            trimSliceTail(elseNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                        } else if (std.mem.eql(u8, for_tail, "endfor")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% for %}, expected {% endfor %}");
                        }
                        try outNodes.append(a, .{
                            .forLoop = .{
                                .itemVar = item_name,
                                .itemVar2 = item_name2,
                                .collectionExpr = coll_expr,
                                .bodyNodes = try bodyNodes.toOwnedSlice(a),
                                .elseNodes = try elseNodes.toOwnedSlice(a),
                                .startByte = tag_start,
                                .line = loc.line,
                                .col = loc.col,
                            },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "block")) {
                        const block_name = std.mem.trim(u8, tag_content[5..], " \t\r\n");
                        if (block_name.len == 0) {
                            return self.fail(.syntaxError, tag_start, "expected block name in '{% block name %}'");
                        }
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endblock", inLoop, strip_leading);
                        if (std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endblock")) {
                            trimSliceTail(bodyNodes.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                        } else {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% block %}, expected {% endblock %}");
                        }
                        const owned_body = try bodyNodes.toOwnedSlice(a);
                        try blocksList.append(a, .{ .name = block_name, .nodes = owned_body });
                        try outNodes.append(a, .{
                            .block = .{ .name = block_name, .bodyNodes = owned_body, .startByte = tag_start, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "extends")) {
                        const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                        const path = parseQuotedString(raw_path) orelse {
                            return self.fail(.syntaxError, tag_start, "invalid path in '{% extends \"...\" %}'");
                        };
                        extendsPath.* = path;
                        try outNodes.append(a, .{
                            .extends = .{ .parentPath = path, .startByte = tag_start, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "include")) {
                        const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                        const path = parseQuotedString(raw_path) orelse {
                            return self.fail(.syntaxError, tag_start, "invalid path in '{% include \"...\" %}'");
                        };
                        try includesList.append(a, path);
                        try outNodes.append(a, .{
                            .include = .{ .templatePath = path, .startByte = tag_start, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "set")) {
                        const remainder = std.mem.trim(u8, tag_content[3..], " \t\r\n");
                        if (std.mem.indexOfScalar(u8, remainder, '=')) |eq| {
                            const name = std.mem.trim(u8, remainder[0..eq], " \t\r\n");
                            const value_expr = std.mem.trim(u8, remainder[eq + 1 ..], " \t\r\n");
                            if (name.len == 0 or value_expr.len == 0) {
                                return self.fail(.syntaxError, tag_start, "invalid set syntax, expected '{% set name = value %}'");
                            }
                            try outNodes.append(a, .{
                                .set = .{ .name = name, .valueExpr = value_expr, .startByte = tag_start, .line = loc.line, .col = loc.col },
                            });
                        } else {
                            if (remainder.len == 0) {
                                return self.fail(.syntaxError, tag_start, "invalid set syntax, expected '{% set name = value %}' or '{% set name %}...{% endset %}'");
                            }
                            var setBody = std.ArrayList(TemplateNode).empty;
                            try self.parseTokenNodes(a, tokens, cursor, &setBody, blocksList, includesList, macrosList, extendsPath, "endset", inLoop, strip_leading);
                            if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endset")) {
                                return self.fail(.unclosed_block, tag_start, "unclosed {% set %}, expected {% endset %}");
                            }
                            trimSliceTail(setBody.items);
                            if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                            cursor.* += 1;
                            try outNodes.append(a, .{
                                .setBlock = .{ .name = remainder, .bodyNodes = try setBody.toOwnedSlice(a), .startByte = tag_start, .line = loc.line, .col = loc.col },
                            });
                        }
                    } else if (std.mem.eql(u8, tag_cmd, "call")) {
                        const sig = std.mem.trim(u8, tag_content[4..], " \t\r\n");
                        const parsed = parseCallSig(a, sig) catch {
                            return self.fail(.syntaxError, tag_start, "invalid call syntax, expected '{% call name(args) %}'");
                        };
                        var callBody = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &callBody, blocksList, includesList, macrosList, extendsPath, "endcall", inLoop, strip_leading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endcall")) {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% call %}, expected {% endcall %}");
                        }
                        trimSliceTail(callBody.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                        cursor.* += 1;
                        try outNodes.append(a, .{
                            .call = .{ .name = parsed.name, .args = parsed.args, .bodyNodes = try callBody.toOwnedSlice(a), .startByte = tag_start, .line = loc.line, .col = loc.col },
                        });
                    } else if (std.mem.eql(u8, tag_cmd, "macro")) {
                        const sig = std.mem.trim(u8, tag_content[5..], " \t\r\n");
                        const parsed = parseMacroSignature(a, sig) catch {
                            return self.fail(.syntaxError, tag_start, "invalid macro signature, expected '{% macro name(args) %}'");
                        };
                        var bodyNodes = std.ArrayList(TemplateNode).empty;
                        try self.parseTokenNodes(a, tokens, cursor, &bodyNodes, blocksList, includesList, macrosList, extendsPath, "endmacro", inLoop, strip_leading);
                        if (!std.mem.eql(u8, self.peekDirectiveCmd(tokens, cursor.*), "endmacro")) {
                            return self.fail(.unclosed_block, tag_start, "unclosed {% macro %}, expected {% endmacro %}");
                        }
                        trimSliceTail(bodyNodes.items);
                        if (stripDashControl(self.source[tokens[cursor.*].start + 2 .. tokens[cursor.*].end - 2]).right) strip_leading.* = true;
                        cursor.* += 1;
                        const def = MacroDef{
                            .name = parsed.name,
                            .params = parsed.params,
                            .bodyNodes = try bodyNodes.toOwnedSlice(a),
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        };
                        try macrosList.append(a, def);
                        try outNodes.append(a, .{ .macroDef = def });
                    } else if (std.mem.eql(u8, tag_cmd, "break")) {
                        if (!inLoop) return self.fail(.unexpectedToken, tag_start, "{% break %} outside of a loop");
                        try outNodes.append(a, .{ .breakLoop = .{ .startByte = tag_start, .line = loc.line, .col = loc.col } });
                    } else if (std.mem.eql(u8, tag_cmd, "continue")) {
                        if (!inLoop) return self.fail(.unexpectedToken, tag_start, "{% continue %} outside of a loop");
                        try outNodes.append(a, .{ .continueLoop = .{ .startByte = tag_start, .line = loc.line, .col = loc.col } });
                    } else if (std.mem.eql(u8, tag_cmd, "endfor") or std.mem.eql(u8, tag_cmd, "endblock") or std.mem.eql(u8, tag_cmd, "endmacro") or std.mem.eql(u8, tag_cmd, "endcall") or std.mem.eql(u8, tag_cmd, "endset") or std.mem.eql(u8, tag_cmd, "endraw")) {
                        return self.fail(.unexpectedToken, tag_start, "unexpected end tag without matching block");
                    } else {
                        return self.fail(.unexpectedToken, tag_start, "unknown template directive");
                    }
                },
            }
        }
    }

    fn fail(self: *Parser, kind: err_mod.TemplateErrorKind, offset: usize, message: []const u8) TemplateError {
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
            .unclosed_block => TemplateError.UnclosedBlock,
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
            const next_open = std.mem.indexOfPos(u8, self.source, self.pos, "{");
            if (next_open == null) {
                // Remainder is plain text
                const text = self.source[self.pos..];
                if (text.len > 0) {
                    try outNodes.append(a, .{ .text = text });
                }
                self.pos = self.source.len;
                break;
            }

            const openIdx = next_open.?;
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
                const expr_start = self.pos;
                const close_idx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "}}") orelse {
                    return self.fail(.unclosedExpression, expr_start, "unclosed expression, expected '}}'");
                };
                const raw_expr = std.mem.trim(u8, self.source[openIdx + 2 .. close_idx], " \t\r\n");
                const loc = lineColFromOffset(self.source, expr_start);
                try outNodes.append(a, .{
                    .expression = .{
                        .expr = raw_expr,
                        .startByte = expr_start,
                        .line = loc.line,
                        .col = loc.col,
                    },
                });
                self.pos = close_idx + 2;
            } else if (second == '#') {
                // Comment: {# ... #}
                const close_idx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "#}") orelse {
                    return self.fail(.syntaxError, openIdx, "unclosed comment, expected '#}'");
                };
                self.pos = close_idx + 2;
            } else if (second == '%') {
                // Directive: {% ... %}
                const tag_start = self.pos;
                const close_idx = std.mem.indexOfPos(u8, self.source, openIdx + 2, "%}") orelse {
                    return self.fail(.syntaxError, tag_start, "unclosed directive, expected '%}'");
                };

                const tag_content = std.mem.trim(u8, self.source[openIdx + 2 .. close_idx], " \t\r\n");
                var tag_it = std.mem.tokenizeAny(u8, tag_content, " \t\r\n");
                const tag_cmd = tag_it.next() orelse "";

                // Check if this matches stopTag
                if (stopTag) |target| {
                    if (std.mem.eql(u8, tag_cmd, target) or
                        (std.mem.eql(u8, target, "endif_or_else") and (std.mem.eql(u8, tag_cmd, "else") or std.mem.eql(u8, tag_cmd, "endif"))))
                    {
                        // Stop before consuming this tag; parent will consume
                        return;
                    }
                }

                self.pos = close_idx + 2;
                const loc = lineColFromOffset(self.source, tag_start);

                if (std.mem.eql(u8, tag_cmd, "if")) {
                    const condition = std.mem.trim(u8, tag_content[2..], " \t\r\n");
                    var thenNodes = std.ArrayList(TemplateNode).empty;
                    var elseNodes = std.ArrayList(TemplateNode).empty;

                    try self.parseNodes(a, &thenNodes, blocksList, includesList, extendsPath, "endif_or_else");

                    if (self.pos < self.source.len) {
                        const next_dir_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% else %} or {% endif %}");
                        };
                        const next_dir = std.mem.trim(u8, self.source[self.pos + 2 .. next_dir_close], " \t\r\n");
                        if (std.mem.startsWith(u8, next_dir, "else")) {
                            self.pos = next_dir_close + 2;
                            try self.parseNodes(a, &elseNodes, blocksList, includesList, extendsPath, "endif");
                            if (self.pos < self.source.len) {
                                const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                                    return self.fail(.unclosed_block, tag_start, "expected {% endif %}");
                                };
                                self.pos = end_close + 2;
                            }
                        } else if (std.mem.startsWith(u8, next_dir, "endif")) {
                            self.pos = next_dir_close + 2;
                        }
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% if %}, expected {% endif %}");
                    }

                    try outNodes.append(a, .{
                        .ifBlock = .{
                            .condition = condition,
                            .thenNodes = try thenNodes.toOwnedSlice(a),
                            .elifBranches = &.{},
                            .elseNodes = try elseNodes.toOwnedSlice(a),
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "for")) {
                    // Syntax: {% for item in collection %}
                    const remainder = std.mem.trim(u8, tag_content[3..], " \t\r\n");
                    const inPos = std.mem.indexOf(u8, remainder, " in ") orelse {
                        return self.fail(.syntaxError, tag_start, "invalid for loop syntax, expected '{% for item in items %}'");
                    };
                    const itemVar = std.mem.trim(u8, remainder[0..inPos], " \t\r\n");
                    const coll_expr = std.mem.trim(u8, remainder[inPos + 4 ..], " \t\r\n");

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocksList, includesList, extendsPath, "endfor");

                    if (self.pos < self.source.len) {
                        const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% endfor %}");
                        };
                        self.pos = end_close + 2;
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% for %}, expected {% endfor %}");
                    }

                    try outNodes.append(a, .{
                        .forLoop = .{
                            .itemVar = itemVar,
                            .collectionExpr = coll_expr,
                            .bodyNodes = try bodyNodes.toOwnedSlice(a),
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "block")) {
                    const block_name = std.mem.trim(u8, tag_content[5..], " \t\r\n");
                    if (block_name.len == 0) {
                        return self.fail(.syntaxError, tag_start, "expected block name in '{% block name %}'");
                    }

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocksList, includesList, extendsPath, "endblock");

                    if (self.pos < self.source.len) {
                        const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% endblock %}");
                        };
                        self.pos = end_close + 2;
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% block %}, expected {% endblock %}");
                    }

                    const owned_body = try bodyNodes.toOwnedSlice(a);
                    try blocksList.append(a, .{
                        .name = block_name,
                        .nodes = owned_body,
                    });

                    try outNodes.append(a, .{
                        .block = .{
                            .name = block_name,
                            .bodyNodes = owned_body,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "extends")) {
                    const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                    const path = parseQuotedString(raw_path) orelse {
                        return self.fail(.syntaxError, tag_start, "invalid path in '{% extends \"...\" %}'");
                    };
                    extendsPath.* = path;
                    try outNodes.append(a, .{
                        .extends = .{
                            .parentPath = path,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "include")) {
                    const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                    const path = parseQuotedString(raw_path) orelse {
                        return self.fail(.syntaxError, tag_start, "invalid path in '{% include \"...\" %}'");
                    };
                    try includesList.append(a, path);
                    try outNodes.append(a, .{
                        .include = .{
                            .templatePath = path,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else {
                    return self.fail(.unexpectedToken, tag_start, "unknown template directive");
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
    var found_text = false;
    var found_expr = false;
    var found_dir = false;
    var found_comment = false;
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, tree.rootNode());
    while (stack.pop()) |cur| {
        const t = cur.nodeType();
        if (std.mem.eql(u8, t, "text")) found_text = true;
        if (std.mem.eql(u8, t, "expression")) {
            found_expr = true;
            try testing.expectEqualStrings("{{ name }}", cur.text());
        }
        if (std.mem.eql(u8, t, "directive")) found_dir = true;
        if (std.mem.eql(u8, t, "comment")) {
            found_comment = true;
            try testing.expectEqualStrings("{# note #}", cur.text());
        }
        var i: u32 = cur.childCount();
        while (i > 0) {
            i -= 1;
            if (cur.child(i)) |c| try stack.append(alloc, c);
        }
    }
    try testing.expect(found_text and found_expr and found_dir and found_comment);
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

    var expr_start: ?usize = null;
    for (ast.nodes) |n| {
        if (n == .expression) expr_start = n.expression.startByte;
    }
    try testing.expect(expr_start != null);
    try testing.expectEqual(std.mem.indexOf(u8, src, "{{").?, expr_start.?);
}
