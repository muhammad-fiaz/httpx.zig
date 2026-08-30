//! CSS selector engine for the httpx DOM tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const Tree = dom.Tree;
const NO_NODE = dom.NO_NODE;

const AttrOp = enum { present, eq, prefix, suffix, contains, word };

const AttrSel = struct {
    name: []const u8,
    op: AttrOp = .present,
    value: []const u8 = "",
};

const PseudoKind = enum {
    first_child,
    last_child,
    nth_child,
    not,
    none,
};

const Pseudo = struct {
    kind: PseudoKind = .none,
    nth_n: i32 = 0,
    nth_of: i32 = 0,
};

const Simple = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    attrs: []const AttrSel = &.{},
    pseudo: Pseudo = .{},
    not_sel: ?*const Compound = null,
};

const Compound = struct {
    parts: []const Simple,
};

const Combinator = enum { descendant, child, adjacent, sibling };

const Sequence = struct {
    compounds: []const Compound,
    combinators: []const Combinator,
};

pub const ParsedSelector = struct {
    arena: std.heap.ArenaAllocator,
    sequences: []const Sequence,

    pub fn deinit(self: *ParsedSelector) void {
        self.arena.deinit();
    }
};

pub const SelectorError = error{
    OutOfMemory,
    InvalidSelector,
};

pub fn parseSelector(allocator: Allocator, sel: []const u8) SelectorError!ParsedSelector {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const al = arena.allocator();
    const sequences = try parseSelectorList(al, std.mem.trim(u8, sel, " \t\r\n"));
    return .{ .arena = arena, .sequences = sequences };
}

pub fn selectAll(
    allocator: Allocator,
    tree: *const Tree,
    root_idx: u32,
    sel: *const ParsedSelector,
) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var w = try tree.walk(allocator, root_idx);
    defer w.deinit();
    while (w.next()) |idx| {
        if (matchesSelector(tree, idx, sel)) {
            try out.append(allocator, idx);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn selectFirst(
    allocator: Allocator,
    tree: *const Tree,
    root_idx: u32,
    sel: *const ParsedSelector,
) !?u32 {
    var w = try tree.walk(allocator, root_idx);
    defer w.deinit();
    while (w.next()) |idx| {
        if (matchesSelector(tree, idx, sel)) return idx;
    }
    return null;
}

pub fn matchesSelector(tree: *const Tree, node_idx: u32, sel: *const ParsedSelector) bool {
    for (sel.sequences) |seq| {
        if (matchesSequence(tree, node_idx, &seq)) return true;
    }
    return false;
}

fn matchesSequence(tree: *const Tree, node_idx: u32, seq: *const Sequence) bool {
    if (seq.compounds.len == 0) return false;
    const last_cmp = &seq.compounds[seq.compounds.len - 1];
    if (!matchesCompound(tree, node_idx, last_cmp)) return false;
    if (seq.compounds.len == 1) return true;

    var current = node_idx;
    var ci: usize = seq.compounds.len - 1;
    while (ci > 0) {
        const comb = seq.combinators[ci - 1];
        const cmp = &seq.compounds[ci - 1];
        switch (comb) {
            .descendant => {
                var ancestor = tree.get(current).parent;
                var found = false;
                while (ancestor != NO_NODE) {
                    if (matchesCompound(tree, ancestor, cmp)) {
                        found = true;
                        current = ancestor;
                        break;
                    }
                    ancestor = tree.get(ancestor).parent;
                }
                if (!found) return false;
            },
            .child => {
                const par = tree.get(current).parent;
                if (par == NO_NODE or !matchesCompound(tree, par, cmp)) return false;
                current = par;
            },
            .adjacent => {
                const sib = tree.get(current).prev_sibling;
                if (sib == NO_NODE) return false;
                var s = sib;
                while (s != NO_NODE and tree.get(s).kind == .text) s = tree.get(s).prev_sibling;
                if (s == NO_NODE or !matchesCompound(tree, s, cmp)) return false;
                current = s;
            },
            .sibling => {
                var s = tree.get(current).prev_sibling;
                var found = false;
                while (s != NO_NODE) {
                    if (tree.get(s).kind != .text and matchesCompound(tree, s, cmp)) {
                        found = true;
                        current = s;
                        break;
                    }
                    s = tree.get(s).prev_sibling;
                }
                if (!found) return false;
            },
        }
        ci -= 1;
    }
    return true;
}

fn matchesCompound(tree: *const Tree, node_idx: u32, cmp: *const Compound) bool {
    for (cmp.parts) |*simple| {
        if (!matchesSimple(tree, node_idx, simple)) return false;
    }
    return true;
}

fn matchesSimple(tree: *const Tree, node_idx: u32, s: *const Simple) bool {
    const node = tree.get(node_idx);
    if (node.kind != .element) return false;

    if (s.tag) |t| {
        if (!std.ascii.eqlIgnoreCase(node.tag, t)) return false;
    }
    if (s.id) |id| {
        const node_id = node.attr("id") orelse return false;
        if (!std.mem.eql(u8, node_id, id)) return false;
    }
    for (s.classes) |cls| {
        if (!node.hasClass(cls)) return false;
    }
    for (s.attrs) |asel| {
        if (!matchesAttr(node, &asel)) return false;
    }
    if (!matchesPseudo(tree, node_idx, &s.pseudo)) return false;
    if (s.not_sel) |not_cmp| {
        if (matchesCompound(tree, node_idx, not_cmp)) return false;
    }
    return true;
}

fn matchesAttr(node: *const dom.Node, asel: *const AttrSel) bool {
    const val = node.attr(asel.name);
    switch (asel.op) {
        .present => return val != null,
        .eq => return val != null and std.mem.eql(u8, val.?, asel.value),
        .prefix => return val != null and std.mem.startsWith(u8, val.?, asel.value),
        .suffix => return val != null and std.mem.endsWith(u8, val.?, asel.value),
        .contains => return val != null and std.mem.indexOf(u8, val.?, asel.value) != null,
        .word => {
            const v = val orelse return false;
            var it = std.mem.splitAny(u8, v, " \t");
            while (it.next()) |tok| if (std.mem.eql(u8, tok, asel.value)) return true;
            return false;
        },
    }
}

fn matchesPseudo(tree: *const Tree, node_idx: u32, p: *const Pseudo) bool {
    switch (p.kind) {
        .none => return true,
        .first_child => {
            const par = tree.get(node_idx).parent;
            if (par == NO_NODE) return false;
            var s = tree.get(par).first_child;
            while (s != NO_NODE and tree.get(s).kind == .text) s = tree.get(s).next_sibling;
            return s == node_idx;
        },
        .last_child => {
            const par = tree.get(node_idx).parent;
            if (par == NO_NODE) return false;
            var s = tree.get(par).last_child;
            while (s != NO_NODE and tree.get(s).kind == .text) s = tree.get(s).prev_sibling;
            return s == node_idx;
        },
        .nth_child => {
            const par = tree.get(node_idx).parent;
            if (par == NO_NODE) return false;
            var pos: i32 = 0;
            var s = tree.get(par).first_child;
            while (s != NO_NODE) {
                if (tree.get(s).kind == .element) {
                    pos += 1;
                    if (s == node_idx) break;
                }
                s = tree.get(s).next_sibling;
            }
            if (p.nth_n == 0) return pos == p.nth_of;
            return p.nth_n > 0 and (pos - p.nth_of) >= 0 and @mod((pos - p.nth_of), p.nth_n) == 0;
        },
        .not => return true,
    }
}

fn parseSelectorList(al: Allocator, src: []const u8) SelectorError![]const Sequence {
    var seqs: std.ArrayList(Sequence) = .empty;
    var parts = std.mem.splitScalar(u8, src, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const seq = try parseSequence(al, trimmed);
        try seqs.append(al, seq);
    }
    return seqs.toOwnedSlice(al);
}

fn parseSequence(al: Allocator, src: []const u8) SelectorError!Sequence {
    var compounds: std.ArrayList(Compound) = .empty;
    var combs: std.ArrayList(Combinator) = .empty;

    var i: usize = 0;
    while (i < src.len) {
        const ws_start = i;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
        const had_ws = i > ws_start;

        if (i >= src.len) break;

        var comb: ?Combinator = null;
        switch (src[i]) {
            '>' => {
                comb = .child;
                i += 1;
                while (i < src.len and src[i] == ' ') : (i += 1) {}
            },
            '+' => {
                comb = .adjacent;
                i += 1;
                while (i < src.len and src[i] == ' ') : (i += 1) {}
            },
            '~' => {
                comb = .sibling;
                i += 1;
                while (i < src.len and src[i] == ' ') : (i += 1) {}
            },
            else => {
                if (had_ws and compounds.items.len > 0) comb = .descendant;
            },
        }

        if (comb) |c| {
            try combs.append(al, c);
        }

        const cmp = try parseCompound(al, src, &i);
        try compounds.append(al, cmp);
    }

    return .{
        .compounds = try compounds.toOwnedSlice(al),
        .combinators = try combs.toOwnedSlice(al),
    };
}

fn parseCompound(al: Allocator, src: []const u8, pos: *usize) SelectorError!Compound {
    var parts: std.ArrayList(Simple) = .empty;
    var simple = Simple{};
    var classes: std.ArrayList([]const u8) = .empty;
    var attrs: std.ArrayList(AttrSel) = .empty;

    while (pos.* < src.len) {
        const c = src[pos.*];
        if (c == ' ' or c == '\t' or c == '>' or c == '+' or c == '~' or c == ',') break;

        if (c == '*') {
            pos.* += 1;
        } else if (c == '#') {
            pos.* += 1;
            const start = pos.*;
            while (pos.* < src.len and isSelectorIdent(src[pos.*])) : (pos.* += 1) {}
            simple.id = src[start..pos.*];
        } else if (c == '.') {
            pos.* += 1;
            const start = pos.*;
            while (pos.* < src.len and isSelectorIdent(src[pos.*])) : (pos.* += 1) {}
            try classes.append(al, src[start..pos.*]);
        } else if (c == '[') {
            pos.* += 1;
            const asel = try parseAttrSel(src, pos);
            try attrs.append(al, asel);
        } else if (c == ':') {
            pos.* += 1;
            if (pos.* < src.len and src[pos.*] == ':') pos.* += 1;
            const pseudo = try parsePseudo(al, src, pos, &simple);
            simple.pseudo = pseudo;
        } else if (std.ascii.isAlphabetic(c) or c == '_' or c == '-') {
            const start = pos.*;
            while (pos.* < src.len and isSelectorIdent(src[pos.*])) : (pos.* += 1) {}
            simple.tag = src[start..pos.*];
        } else {
            pos.* += 1;
        }
    }

    simple.classes = try classes.toOwnedSlice(al);
    simple.attrs = try attrs.toOwnedSlice(al);
    try parts.append(al, simple);
    return .{ .parts = try parts.toOwnedSlice(al) };
}

fn parseAttrSel(src: []const u8, pos: *usize) SelectorError!AttrSel {
    while (pos.* < src.len and src[pos.*] == ' ') : (pos.* += 1) {}
    const name_start = pos.*;
    while (pos.* < src.len and src[pos.*] != ']' and src[pos.*] != '=' and
        src[pos.*] != '^' and src[pos.*] != '$' and src[pos.*] != '*' and
        src[pos.*] != '~' and src[pos.*] != ' ') : (pos.* += 1)
    {}
    const name = src[name_start..pos.*];
    while (pos.* < src.len and src[pos.*] == ' ') : (pos.* += 1) {}

    if (pos.* >= src.len or src[pos.*] == ']') {
        if (pos.* < src.len) pos.* += 1;
        return .{ .name = name, .op = .present };
    }

    var op: AttrOp = .eq;
    if (pos.* + 1 < src.len and src[pos.* + 1] == '=') {
        switch (src[pos.*]) {
            '^' => {
                op = .prefix;
                pos.* += 1;
            },
            '$' => {
                op = .suffix;
                pos.* += 1;
            },
            '*' => {
                op = .contains;
                pos.* += 1;
            },
            '~' => {
                op = .word;
                pos.* += 1;
            },
            else => {},
        }
    }
    if (pos.* < src.len and src[pos.*] == '=') pos.* += 1;

    while (pos.* < src.len and src[pos.*] == ' ') : (pos.* += 1) {}

    var value: []const u8 = "";
    if (pos.* < src.len and (src[pos.*] == '"' or src[pos.*] == '\'')) {
        const q = src[pos.*];
        pos.* += 1;
        const vstart = pos.*;
        while (pos.* < src.len and src[pos.*] != q) : (pos.* += 1) {}
        value = src[vstart..pos.*];
        if (pos.* < src.len) pos.* += 1;
    } else {
        const vstart = pos.*;
        while (pos.* < src.len and src[pos.*] != ']' and src[pos.*] != ' ') : (pos.* += 1) {}
        value = src[vstart..pos.*];
    }

    while (pos.* < src.len and src[pos.*] != ']') : (pos.* += 1) {}
    if (pos.* < src.len) pos.* += 1;

    return .{ .name = name, .op = op, .value = value };
}

fn parsePseudo(al: Allocator, src: []const u8, pos: *usize, simple: *Simple) SelectorError!Pseudo {
    const start = pos.*;
    while (pos.* < src.len and src[pos.*] != '(' and !isSelectorStop(src[pos.*])) : (pos.* += 1) {}
    const name = src[start..pos.*];

    if (std.ascii.eqlIgnoreCase(name, "first-child")) return .{ .kind = .first_child };
    if (std.ascii.eqlIgnoreCase(name, "last-child")) return .{ .kind = .last_child };
    if (std.ascii.eqlIgnoreCase(name, "nth-child")) {
        if (pos.* < src.len and src[pos.*] == '(') {
            pos.* += 1;
            const nstart = pos.*;
            while (pos.* < src.len and src[pos.*] != ')') : (pos.* += 1) {}
            const nstr = std.mem.trim(u8, src[nstart..pos.*], " ");
            if (pos.* < src.len) pos.* += 1;
            if (std.fmt.parseInt(i32, nstr, 10)) |n| {
                return .{ .kind = .nth_child, .nth_n = 0, .nth_of = n };
            } else |_| {}
        }
        return .{ .kind = .nth_child, .nth_n = 1, .nth_of = 0 };
    }
    if (std.ascii.eqlIgnoreCase(name, "not")) {
        if (pos.* < src.len and src[pos.*] == '(') {
            pos.* += 1;
            const nstart = pos.*;
            var depth: usize = 1;
            while (pos.* < src.len and depth > 0) : (pos.* += 1) {
                if (src[pos.*] == '(') depth += 1;
                if (src[pos.*] == ')') depth -= 1;
            }
            const inner = src[nstart .. pos.* - 1];
            const not_cmp = try al.create(Compound);
            var inner_pos: usize = 0;
            not_cmp.* = try parseCompound(al, inner, &inner_pos);
            simple.not_sel = not_cmp;
        }
        return .{ .kind = .not };
    }
    return .{ .kind = .none };
}

fn isSelectorIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isSelectorStop(c: u8) bool {
    return c == ' ' or c == '\t' or c == ',' or c == '>' or c == '+' or c == '~';
}
