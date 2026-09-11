//! Template renderer.
//!
//! Evaluates compiled template ASTs against Context values, supporting:
//!   - Secure auto-escaping of HTML characters (&, <, >, ", ')
//!   - Raw trusted HTML bypass via RawHtml/Value.rawHtml
//!   - Dot-path variable lookups and basic conditional expressions
//!   - Template inheritance ({% extends %}, {% block %}) with block overrides
//!   - Reusable includes ({% include %}) with recursion and cycle detection
//!   - Loops ({% for %}) with loop metadata (index, first, last, length)
//!   - Direct streaming to any Zig writer

const std = @import("std");
const Allocator = std.mem.Allocator;
const context_mod = @import("context.zig");
const parser_mod = @import("parser.zig");
const err_mod = @import("error.zig");

pub const Value = context_mod.Value;
pub const Context = context_mod.Context;
pub const TemplateAst = parser_mod.TemplateAst;
pub const TemplateNode = parser_mod.TemplateNode;
pub const BlockInfo = parser_mod.BlockInfo;
pub const TemplateError = err_mod.TemplateError;

/// Minimal provider interface used by renderer to retrieve ASTs for includes and parent templates.
pub const TemplateProvider = struct {
    ptr: *const anyopaque,
    getAstFn: *const fn (ptr: *const anyopaque, name: []const u8) ?*const TemplateAst,

    pub fn getAst(self: TemplateProvider, name: []const u8) ?*const TemplateAst {
        return self.getAstFn(self.ptr, name);
    }
};

/// Writes string content escaping HTML special characters: &, <, >, ", '
pub fn writeEscaped(writer: anytype, text: []const u8) !void {
    var last: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (replacement) |escaped| {
            if (i > last) {
                try writer.writeAll(text[last..i]);
            }
            try writer.writeAll(escaped);
            last = i + 1;
        }
    }
    if (last < text.len) {
        try writer.writeAll(text[last..]);
    }
}

pub const RenderOptions = struct {
    maxIncludeDepth: usize = 32,
    maxInheritanceDepth: usize = 16,
    /// When true, rendering an undefined value is an error instead of empty.
    strictUndefined: bool = false,
};

pub const GlobalKwarg = struct {
    name: []const u8,
    value: Value,
};

pub const GlobalFn = *const fn (user_data: ?*const anyopaque, allocator: Allocator, args: []const Value, kwargs: []const GlobalKwarg) anyerror!Value;

pub const GlobalEntry = struct {
    func: GlobalFn,
    user_data: ?*const anyopaque = null,
};

pub const GlobalMap = struct {
    map: std.StringHashMap(GlobalEntry),

    pub fn init(allocator: Allocator) GlobalMap {
        return .{ .map = std.StringHashMap(GlobalEntry).init(allocator) };
    }

    pub fn deinit(self: *GlobalMap) void {
        self.map.deinit();
    }
};

pub const InheritChain = struct {
    buf: [16][]const u8 = undefined,
    len: usize = 0,
};

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,

    pub fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.list.appendSlice(self.allocator, formatted);
    }
};

pub const Flow = enum { normal, broken, continued };

pub const FilterFn = *const fn (allocator: Allocator, value: Value, args: []const Value) anyerror!Value;

pub const FilterRegistry = struct {
    map: std.StringHashMap(FilterFn),

    pub fn init(allocator: Allocator) FilterRegistry {
        return .{ .map = std.StringHashMap(FilterFn).init(allocator) };
    }

    pub fn deinit(self: *FilterRegistry) void {
        self.map.deinit();
    }

    pub fn register(self: *FilterRegistry, name: []const u8, func: FilterFn) !void {
        try self.map.put(name, func);
    }

    pub fn lookup(self: *const FilterRegistry, name: []const u8) ?FilterFn {
        if (self.map.get(name)) |f| return f;
        return builtinFilter(name);
    }
};

fn filterStringValue(allocator: Allocator, value: Value) ![]u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .rawHtml => |h| try allocator.dupe(u8, h),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .nullVal => try allocator.dupe(u8, ""),
        .missing => try allocator.dupe(u8, ""),
        .macro => try allocator.dupe(u8, ""),
        .list, .map => try allocator.dupe(u8, ""),
    };
}

fn filterUpper(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = s };
}

fn filterLower(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s) |*c| c.* = std.ascii.toLower(c.*);
    return .{ .string = s };
}

fn filterTrim(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    return .{ .string = try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")) };
}

fn filterCapitalize(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s, 0..) |*c, i| c.* = if (i == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    return .{ .string = s };
}

fn filterTitle(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    var new_word = true;
    for (s) |*c| {
        if (std.ascii.isWhitespace(c.*)) {
            new_word = true;
        } else if (new_word) {
            c.* = std.ascii.toUpper(c.*);
            new_word = false;
        } else {
            c.* = std.ascii.toLower(c.*);
        }
    }
    return .{ .string = s };
}

fn filterEscape(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        const rep: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (rep) |r| try out.appendSlice(allocator, r) else try out.append(allocator, c);
    }
    return .{ .rawHtml = try out.toOwnedSlice(allocator) };
}

fn filterSafe(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    return .{ .rawHtml = s };
}

fn filterDefault(allocator: Allocator, value: Value, args: []const Value) !Value {
    const use_bool = args.len > 1 and args[1] == .boolean and args[1].boolean;
    const is_missing = value == .nullVal or value == .missing or (use_bool and !value.isTruthy());
    if (!is_missing) return value;
    if (args.len > 0) return args[0];
    return .{ .string = try allocator.dupe(u8, "") };
}

fn filterLength(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    _ = allocator;
    return .{ .integer = switch (value) {
        .string => |s| @intCast(s.len),
        .rawHtml => |h| @intCast(h.len),
        .list => |l| @intCast(l.len),
        .map => |m| @intCast(m.len),
        else => 0,
    } };
}

fn filterJoin(allocator: Allocator, value: Value, args: []const Value) !Value {
    const sep = if (args.len > 0) try filterStringValue(allocator, args[0]) else try allocator.dupe(u8, "");
    defer allocator.free(sep);
    if (value != .list) return .{ .string = try filterStringValue(allocator, value) };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value.list, 0..) |item, i| {
        if (i > 0) try out.appendSlice(allocator, sep);
        const s = try filterStringValue(allocator, item);
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterFirst(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    _ = allocator;
    return switch (value) {
        .list => |l| if (l.len > 0) l[0] else .nullVal,
        .string => |s| if (s.len > 0) .{ .string = s[0..1] } else .nullVal,
        else => .nullVal,
    };
}

fn filterLast(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    _ = allocator;
    return switch (value) {
        .list => |l| if (l.len > 0) l[l.len - 1] else .nullVal,
        .string => |s| if (s.len > 0) .{ .string = s[s.len - 1 ..] } else .nullVal,
        else => .nullVal,
    };
}

fn filterReplace(allocator: Allocator, value: Value, args: []const Value) !Value {
    if (args.len < 2) return value;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    const old = try filterStringValue(allocator, args[0]);
    defer allocator.free(old);
    const new = try filterStringValue(allocator, args[1]);
    defer allocator.free(new);
    if (old.len == 0) return .{ .string = try allocator.dupe(u8, s) };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var rest = s;
    while (std.mem.indexOf(u8, rest, old)) |idx| {
        try out.appendSlice(allocator, rest[0..idx]);
        try out.appendSlice(allocator, new);
        rest = rest[idx + old.len ..];
    }
    try out.appendSlice(allocator, rest);
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterTruncate(allocator: Allocator, value: Value, args: []const Value) !Value {
    var n: usize = 255;
    if (args.len > 0) {
        n = switch (args[0]) {
            .integer => |i| if (i < 0) 0 else @intCast(i),
            .float => |f| if (f < 0) 0 else @intFromFloat(f),
            else => 255,
        };
    }
    const s = try filterStringValue(allocator, value);
    if (s.len <= n) return .{ .string = s };
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, s[0..n]);
    try out.appendSlice(allocator, "...");
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterStriptags(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    for (s) |c| {
        if (in_tag) {
            if (c == '>') in_tag = false;
        } else if (c == '<') {
            in_tag = true;
        } else {
            try out.append(allocator, c);
        }
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterInt(_: Allocator, value: Value, args: []const Value) !Value {
    const fallback: i64 = if (args.len > 0) switch (args[0]) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    } else 0;
    return .{ .integer = switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |b| if (b) 1 else 0,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch fallback,
        else => fallback,
    } };
}

fn filterFloat(_: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    return .{ .float = switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch 0.0,
        else => 0.0,
    } };
}

fn filterString(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    return .{ .string = try filterStringValue(allocator, value) };
}

fn filterAbs(_: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    return switch (value) {
        .integer => |i| .{ .integer = if (i < 0) -i else i },
        .float => |f| .{ .float = @abs(f) },
        else => value,
    };
}

fn filterRound(_: Allocator, value: Value, args: []const Value) !Value {
    var prec: i32 = 0;
    if (args.len > 0) {
        prec = switch (args[0]) {
            .integer => |i| @intCast(@max(i, 0)),
            .float => |f| @intFromFloat(@max(f, 0)),
            else => 0,
        };
    }
    const f: f64 = switch (value) {
        .float => |x| x,
        .integer => |i| @floatFromInt(i),
        else => return value,
    };
    const factor = std.math.pow(f64, 10.0, @floatFromInt(prec));
    return .{ .float = @round(f * factor) / factor };
}

fn filterSort(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    if (value != .list) return value;
    const out = try allocator.dupe(Value, value.list);
    errdefer allocator.free(out);
    var all_int = true;
    var all_string = true;
    for (out) |item| {
        if (item != .integer) all_int = false;
        if (item != .string) all_string = false;
    }
    if (all_int) {
        std.mem.sort(Value, out, {}, struct {
            fn less(_: void, a: Value, b: Value) bool {
                return a.integer < b.integer;
            }
        }.less);
    } else if (all_string) {
        std.mem.sort(Value, out, {}, struct {
            fn less(_: void, a: Value, b: Value) bool {
                return std.mem.order(u8, a.string, b.string) == .lt;
            }
        }.less);
    } else {
        std.mem.sort(Value, out, {}, struct {
            fn less(_: void, a: Value, b: Value) bool {
                const sa: []const u8 = switch (a) {
                    .string => |s| s,
                    .integer => "",
                    else => "",
                };
                const sb: []const u8 = switch (b) {
                    .string => |s| s,
                    .integer => "",
                    else => "",
                };
                if (a == .integer and b == .integer) return a.integer < b.integer;
                return std.mem.order(u8, sa, sb) == .lt;
            }
        }.less);
    }
    return .{ .list = out };
}

fn filterReverse(allocator: Allocator, value: Value, args: []const Value) !Value {
    _ = args;
    if (value != .list) return value;
    const out = try allocator.dupe(Value, value.list);
    errdefer allocator.free(out);
    std.mem.reverse(Value, out);
    return .{ .list = out };
}

pub fn builtinFilter(name: []const u8) ?FilterFn {
    if (std.mem.eql(u8, name, "upper")) return filterUpper;
    if (std.mem.eql(u8, name, "lower")) return filterLower;
    if (std.mem.eql(u8, name, "trim")) return filterTrim;
    if (std.mem.eql(u8, name, "capitalize")) return filterCapitalize;
    if (std.mem.eql(u8, name, "title")) return filterTitle;
    if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "e")) return filterEscape;
    if (std.mem.eql(u8, name, "safe")) return filterSafe;
    if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "d")) return filterDefault;
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "count")) return filterLength;
    if (std.mem.eql(u8, name, "join")) return filterJoin;
    if (std.mem.eql(u8, name, "sort")) return filterSort;
    if (std.mem.eql(u8, name, "reverse")) return filterReverse;
    if (std.mem.eql(u8, name, "first")) return filterFirst;
    if (std.mem.eql(u8, name, "last")) return filterLast;
    if (std.mem.eql(u8, name, "replace")) return filterReplace;
    if (std.mem.eql(u8, name, "truncate")) return filterTruncate;
    if (std.mem.eql(u8, name, "striptags")) return filterStriptags;
    if (std.mem.eql(u8, name, "int")) return filterInt;
    if (std.mem.eql(u8, name, "float")) return filterFloat;
    if (std.mem.eql(u8, name, "string")) return filterString;
    if (std.mem.eql(u8, name, "abs")) return filterAbs;
    if (std.mem.eql(u8, name, "round")) return filterRound;
    return null;
}

const MacroTable = struct {
    map: std.StringHashMap(parser_mod.MacroDef),

    fn init(allocator: Allocator) MacroTable {
        return .{ .map = std.StringHashMap(parser_mod.MacroDef).init(allocator) };
    }

    fn deinit(self: *MacroTable) void {
        self.map.deinit();
    }

    fn addIfAbsent(self: *MacroTable, def: parser_mod.MacroDef) !void {
        if (!self.map.contains(def.name)) try self.map.put(def.name, def);
    }

    fn get(self: *const MacroTable, name: []const u8) ?parser_mod.MacroDef {
        return self.map.get(name);
    }
};

const RenderState = struct {
    provider: ?TemplateProvider,
    blockOverrides: []const BlockInfo,
    includeStack: []const []const u8,
    inheritanceDepth: *usize,
    inheritChain: *InheritChain,
    macros: *MacroTable,
    filters: ?*const FilterRegistry,
    globals: ?*const GlobalMap,
    scope: *context_mod.Scope,
    superNodes: ?[]const TemplateNode = null,
    strict: bool = false,
    alloc: Allocator,
    root: Value,
};

pub const Renderer = struct {
    options: RenderOptions = .{},
    filters: ?*const FilterRegistry = null,
    globals: ?*const GlobalMap = null,

    /// Renders a template AST directly to any writer.
    pub fn render(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
    ) !void {
        try self.renderWithFilters(ast, ctx, provider, writer, self.filters, self.globals);
    }

    /// Renders with explicit filter registry (custom filters overlay builtins).
    pub fn renderWithFilters(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
        filters: ?*const FilterRegistry,
        globals: ?*const GlobalMap,
    ) !void {
        var depth: usize = 0;
        var chain = InheritChain{};
        var scope = context_mod.Scope{};
        const arena_alloc = @constCast(&ctx.arena).allocator();
        defer scope.deinit(arena_alloc);
        var macros = MacroTable.init(ctx.arena.child_allocator);
        defer macros.deinit();
        for (ast.macros) |m| try macros.addIfAbsent(m);
        const state = RenderState{
            .provider = provider,
            .blockOverrides = ast.blocks,
            .includeStack = &[0][]const u8{},
            .inheritanceDepth = &depth,
            .inheritChain = &chain,
            .macros = &macros,
            .filters = filters,
            .globals = globals,
            .scope = &scope,
            .strict = self.options.strictUndefined,
            .alloc = arena_alloc,
            .root = ctx.root,
        };
        _ = try self.renderInternal(ast, ctx, state, writer);
    }

    /// Renders a template AST to an allocated string.
    pub fn renderToString(
        self: Renderer,
        allocator: Allocator,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
    ) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);
        var lw = ListWriter{ .list = &list, .allocator = allocator };
        try self.render(ast, ctx, provider, &lw);
        return try list.toOwnedSlice(allocator);
    }

    fn renderInternal(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *const Context,
        state: RenderState,
        writer: anytype,
    ) anyerror!Flow {
        if (ast.extendsPath) |parentPath| {
            for (state.inheritChain.buf[0..state.inheritChain.len]) |seen| {
                if (std.mem.eql(u8, seen, parentPath)) return TemplateError.CircularInheritance;
            }
            if (state.inheritChain.len >= state.inheritChain.buf.len) return TemplateError.DepthLimitExceeded;
            state.inheritChain.buf[state.inheritChain.len] = parentPath;
            state.inheritChain.len += 1;
            defer state.inheritChain.len -= 1;
            state.inheritanceDepth.* += 1;
            if (state.inheritanceDepth.* > self.options.maxInheritanceDepth) {
                return TemplateError.DepthLimitExceeded;
            }

            const p = state.provider orelse return TemplateError.TemplateNotFound;
            const parent_ast = p.getAst(parentPath) orelse return TemplateError.TemplateNotFound;

            var combined_blocks = std.ArrayList(BlockInfo).empty;
            defer combined_blocks.deinit(ctx.arena.child_allocator);

            for (ast.blocks) |b| {
                try combined_blocks.append(ctx.arena.child_allocator, b);
            }
            for (state.blockOverrides) |b| {
                var found = false;
                for (ast.blocks) |existing| {
                    if (std.mem.eql(u8, existing.name, b.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try combined_blocks.append(ctx.arena.child_allocator, b);
                }
            }
            for (parent_ast.macros) |m| try state.macros.addIfAbsent(m);

            var next = state;
            next.blockOverrides = combined_blocks.items;
            return self.renderInternal(parent_ast, ctx, next, writer);
        }

        for (ast.macros) |m| try state.macros.addIfAbsent(m);
        return self.renderNodes(ast.nodes, ctx, state, writer);
    }

    fn renderNodes(
        self: Renderer,
        nodes: []const TemplateNode,
        ctx: *const Context,
        state: RenderState,
        writer: anytype,
    ) anyerror!Flow {
        for (nodes) |node| {
            switch (node) {
                .text => |txt| {
                    try writer.writeAll(txt);
                },
                .expression => |expr_info| {
                    try self.renderExpression(expr_info.expr, ctx, state, writer);
                },
                .ifBlock => |if_info| {
                    const cond_val = try self.evalExpr(ctx, state, if_info.condition);
                    if (cond_val.isTruthy()) {
                        const f = try self.renderNodes(if_info.thenNodes, ctx, state, writer);
                        if (f != .normal) return f;
                    } else {
                        var taken = false;
                        for (if_info.elifBranches) |branch| {
                            const bv = try self.evalExpr(ctx, state, branch.condition);
                            if (bv.isTruthy()) {
                                const f = try self.renderNodes(branch.bodyNodes, ctx, state, writer);
                                if (f != .normal) return f;
                                taken = true;
                                break;
                            }
                        }
                        if (!taken and if_info.elseNodes.len > 0) {
                            const f = try self.renderNodes(if_info.elseNodes, ctx, state, writer);
                            if (f != .normal) return f;
                        }
                    }
                },
                .forLoop => |forInfo| {
                    const f = try self.renderForLoop(forInfo, ctx, state, writer);
                    if (f != .normal) return f;
                },
                .set => |set_info| {
                    const val = try self.evalExpr(ctx, state, set_info.valueExpr);
                    try state.scope.set(state.alloc, set_info.name, val);
                },
                .setBlock => |set_info| {
                    var list = std.ArrayList(u8).empty;
                    defer list.deinit(state.alloc);
                    var lw = ListWriter{ .list = &list, .allocator = state.alloc };
                    _ = try self.renderNodes(set_info.bodyNodes, ctx, state, &lw);
                    try state.scope.set(state.alloc, set_info.name, .{ .rawHtml = try list.toOwnedSlice(state.alloc) });
                },
                .call => |call_info| {
                    var args = std.ArrayList(Value).empty;
                    defer args.deinit(state.alloc);
                    var kwargs = std.ArrayList(CallKwarg).empty;
                    defer kwargs.deinit(state.alloc);
                    for (call_info.args) |a| {
                        const v = try self.evalExpr(ctx, state, a.value);
                        if (a.name) |nm| {
                            try kwargs.append(state.alloc, .{ .name = nm, .value = v });
                        } else {
                            try args.append(state.alloc, v);
                        }
                    }
                    var body_list = std.ArrayList(u8).empty;
                    defer body_list.deinit(state.alloc);
                    var body_lw = ListWriter{ .list = &body_list, .allocator = state.alloc };
                    _ = try self.renderNodes(call_info.bodyNodes, ctx, state, &body_lw);
                    const body_text = try body_list.toOwnedSlice(state.alloc);
                    const caller_nodes = try state.alloc.alloc(TemplateNode, 1);
                    caller_nodes[0] = .{ .text = body_text };
                    var call_scope = context_mod.Scope{ .parent = state.scope };
                    defer call_scope.deinit(state.alloc);
                    try call_scope.set(state.alloc, "caller", .{ .macro = .{
                        .name = "caller",
                        .params = &.{},
                        .bodyNodes = caller_nodes,
                        .startByte = call_info.startByte,
                        .line = call_info.line,
                        .col = call_info.col,
                    } });
                    var call_state = state;
                    call_state.scope = &call_scope;
                    const callee_def = state.macros.get(call_info.name) orelse return TemplateError.UnknownVariable;
                    const out = try self.renderMacroWithScope(ctx, call_state, callee_def, args.items, kwargs.items, &call_scope);
                    // Call-block output is statement-level markup like includes.
                    switch (out) {
                        .string => |s| try writer.writeAll(s),
                        .rawHtml => |h| try writer.writeAll(h),
                        else => try writeValue(out, writer),
                    }
                },
                .macroDef => |def| {
                    try state.macros.addIfAbsent(def);
                },
                .breakLoop => {
                    return .broken;
                },
                .continueLoop => {
                    return .continued;
                },
                .block => |block_info| {
                    var block_to_render = block_info.bodyNodes;
                    var super_nodes: ?[]const TemplateNode = null;
                    for (state.blockOverrides) |ov| {
                        if (std.mem.eql(u8, ov.name, block_info.name)) {
                            block_to_render = ov.nodes;
                            super_nodes = block_info.bodyNodes;
                            break;
                        }
                    }
                    var next = state;
                    next.superNodes = super_nodes;
                    const f = try self.renderNodes(block_to_render, ctx, next, writer);
                    if (f != .normal) return f;
                },
                .extends => {},
                .include => |inc_info| {
                    if (state.includeStack.len >= self.options.maxIncludeDepth) {
                        return TemplateError.DepthLimitExceeded;
                    }
                    for (state.includeStack) |item| {
                        if (std.mem.eql(u8, item, inc_info.templatePath)) {
                            return TemplateError.CircularInclude;
                        }
                    }

                    const p = state.provider orelse return TemplateError.TemplateNotFound;
                    const inc_ast = p.getAst(inc_info.templatePath) orelse return TemplateError.TemplateNotFound;
                    for (inc_ast.macros) |m| try state.macros.addIfAbsent(m);

                    const new_stack = try ctx.arena.child_allocator.alloc([]const u8, state.includeStack.len + 1);
                    defer ctx.arena.child_allocator.free(new_stack);
                    @memcpy(new_stack[0..state.includeStack.len], state.includeStack);
                    new_stack[state.includeStack.len] = inc_info.templatePath;

                    var next = state;
                    next.blockOverrides = &[_]BlockInfo{};
                    next.includeStack = new_stack;
                    const f = try self.renderInternal(inc_ast, ctx, next, writer);
                    if (f != .normal) return f;
                },
            }
        }
        return .normal;
    }

    fn writeValue(val: Value, writer: anytype) !void {
        switch (val) {
            .nullVal => {},
            .missing => {},
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writeEscaped(writer, s),
            .rawHtml => |h| try writer.writeAll(h),
            .list => {},
            .map => {},
            .macro => {},
        }
    }

    fn renderExpression(self: Renderer, expr: []const u8, ctx: *const Context, state: RenderState, writer: anytype) !void {
        const trimmed = std.mem.trim(u8, expr, " \t\r\n");
        if (trimmed.len == 0) return;
        const val = try self.evalExpr(ctx, state, trimmed);
        if (val == .missing and state.strict) return TemplateError.UnknownVariable;
        try writeValue(val, writer);
    }

    fn lookupFilter(self: Renderer, state: RenderState, name: []const u8) ?FilterFn {
        if (state.filters) |reg| {
            if (reg.lookup(name)) |f| return f;
        }
        _ = self;
        return builtinFilter(name);
    }

    fn resolveName(self: Renderer, ctx: *const Context, state: RenderState, name: []const u8) Value {
        _ = self;
        _ = ctx;
        if (state.scope.getLocal(name)) |v| return v;
        return state.root.lookup(name) orelse .missing;
    }

    fn lookupAttr(self: Renderer, base: Value, name: []const u8) Value {
        _ = self;
        return switch (base) {
            .map => |entries| blk: {
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, name)) break :blk e.value;
                }
                break :blk .missing;
            },
            else => .missing,
        };
    }

    fn lookupIndex(self: Renderer, base: Value, idx: Value) Value {
        _ = self;
        switch (base) {
            .list => |items| {
                const i: usize = switch (idx) {
                    .integer => |v| if (v < 0) return .missing else @intCast(v),
                    else => return .missing,
                };
                if (i < items.len) return items[i];
                return .missing;
            },
            .map => |entries| {
                if (idx != .string) return .missing;
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, idx.string)) return e.value;
                }
                return .missing;
            },
            .string => |s| {
                const i: usize = switch (idx) {
                    .integer => |v| if (v < 0) return .missing else @intCast(v),
                    else => return .missing,
                };
                if (i < s.len) return .{ .string = s[i .. i + 1] };
                return .missing;
            },
            else => return .missing,
        }
    }

    const CallKwarg = struct {
        name: []const u8,
        value: Value,
    };

    const ExprParser = struct {
        src: []const u8,
        pos: usize = 0,
        renderer: *const Renderer,
        ctx: *const Context,
        state: RenderState,

        fn eof(self: *ExprParser) bool {
            self.skipWs();
            return self.pos >= self.src.len;
        }

        fn skipWs(self: *ExprParser) void {
            while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\r' or self.src[self.pos] == '\n')) : (self.pos += 1) {}
        }

        fn peekWord(self: *ExprParser) []const u8 {
            self.skipWs();
            var i = self.pos;
            while (i < self.src.len and (std.ascii.isAlphanumeric(self.src[i]) or self.src[i] == '_')) : (i += 1) {}
            return self.src[self.pos..i];
        }

        fn eatWord(self: *ExprParser, word: []const u8) bool {
            const w = self.peekWord();
            if (!std.mem.eql(u8, w, word)) return false;
            const after = self.pos + w.len;
            if (after < self.src.len and (std.ascii.isAlphanumeric(self.src[after]) or self.src[after] == '_')) return false;
            self.pos = after;
            return true;
        }

        fn eatOp(self: *ExprParser, op: []const u8) bool {
            self.skipWs();
            if (self.pos + op.len > self.src.len) return false;
            if (!std.mem.eql(u8, self.src[self.pos .. self.pos + op.len], op)) return false;
            self.pos += op.len;
            return true;
        }

        fn parseFull(self: *ExprParser) anyerror!Value {
            return self.parseTernary();
        }

        fn parseTernary(self: *ExprParser) anyerror!Value {
            const first = try self.parseOr();
            if (self.eatWord("if")) {
                const cond = try self.parseOr();
                if (!self.eatWord("else")) return error.RenderError;
                const alt = try self.parseTernary();
                return if (cond.isTruthy()) first else alt;
            }
            return first;
        }

        fn parseOr(self: *ExprParser) anyerror!Value {
            var left = try self.parseAnd();
            while (self.eatWord("or")) {
                const right = try self.parseAnd();
                left = if (left.isTruthy()) left else right;
            }
            return left;
        }

        fn parseAnd(self: *ExprParser) anyerror!Value {
            var left = try self.parseNot();
            while (self.eatWord("and")) {
                const right = try self.parseNot();
                left = if (!left.isTruthy()) left else right;
            }
            return left;
        }

        fn parseNot(self: *ExprParser) anyerror!Value {
            self.skipWs();
            const save = self.pos;
            if (self.eatWord("not")) {
                const inner = try self.parseNot();
                return .{ .boolean = !inner.isTruthy() };
            }
            self.pos = save;
            return self.parseIs();
        }

        fn parseIs(self: *ExprParser) anyerror!Value {
            const left = try self.parseComparison();
            const save = self.pos;
            if (!self.eatWord("is")) {
                self.pos = save;
                return left;
            }
            const negated = self.eatWord("not");
            const test_name = self.parseName() orelse return error.RenderError;
            const result = try self.evalTest(left, test_name);
            return .{ .boolean = if (negated) !result else result };
        }

        fn evalTest(self: *ExprParser, value: Value, name: []const u8) !bool {
            _ = self;
            if (std.mem.eql(u8, name, "defined")) return value != .missing;
            if (std.mem.eql(u8, name, "undefined")) return value == .missing;
            if (std.mem.eql(u8, name, "none")) return value == .nullVal;
            if (std.mem.eql(u8, name, "string")) return value == .string or value == .rawHtml;
            if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float;
            if (std.mem.eql(u8, name, "boolean")) return value == .boolean;
            if (std.mem.eql(u8, name, "sequence")) return value == .list;
            if (std.mem.eql(u8, name, "mapping")) return value == .map;
            if (std.mem.eql(u8, name, "callable")) return value == .macro;
            return error.RenderError;
        }

        fn parseComparison(self: *ExprParser) anyerror!Value {
            const left = try self.parseConcat();
            if (self.eatOp("==")) {
                const right = try self.parseConcat();
                return .{ .boolean = left.equals(right) };
            }
            if (self.eatOp("!=")) {
                const right = try self.parseConcat();
                return .{ .boolean = !left.equals(right) };
            }
            if (self.eatOp(">=")) {
                const right = try self.parseConcat();
                const o = compareOrder(left, right);
                return .{ .boolean = o == .gt or o == .eq };
            }
            if (self.eatOp("<=")) {
                const right = try self.parseConcat();
                const o = compareOrder(left, right);
                return .{ .boolean = o == .lt or o == .eq };
            }
            if (self.eatOp(">")) {
                const right = try self.parseConcat();
                return .{ .boolean = compareOrder(left, right) == .gt };
            }
            if (self.eatOp("<")) {
                const right = try self.parseConcat();
                return .{ .boolean = compareOrder(left, right) == .lt };
            }
            {
                const save = self.pos;
                const negated = self.eatWord("not");
                if (self.eatWord("in")) {
                    const right = try self.parseConcat();
                    const found = valueContains(left, right);
                    return .{ .boolean = if (negated) !found else found };
                }
                self.pos = save;
            }
            {
                const save = self.pos;
                if (self.eatWord("in")) {
                    const right = try self.parseConcat();
                    return .{ .boolean = valueContains(left, right) };
                }
                self.pos = save;
            }
            return left;
        }

        fn parseConcat(self: *ExprParser) anyerror!Value {
            var left = try self.parseAdditive();
            while (self.eatOp("~")) {
                const right = try self.parseAdditive();
                const ls = try filterStringValue(self.state.alloc, left);
                defer self.state.alloc.free(ls);
                const rs = try filterStringValue(self.state.alloc, right);
                defer self.state.alloc.free(rs);
                left = .{ .string = try std.fmt.allocPrint(self.state.alloc, "{s}{s}", .{ ls, rs }) };
            }
            return left;
        }

        fn parseAdditive(self: *ExprParser) anyerror!Value {
            var left = try self.parseMul();
            while (true) {
                if (self.eatOp("+")) {
                    const right = try self.parseMul();
                    left = try numericBinop(left, right, .add);
                } else if (self.eatOp("-")) {
                    const right = try self.parseMul();
                    left = try numericBinop(left, right, .sub);
                } else break;
            }
            return left;
        }

        fn parseMul(self: *ExprParser) anyerror!Value {
            var left = try self.parseUnary();
            while (true) {
                if (self.eatOp("//")) {
                    const right = try self.parseUnary();
                    left = try numericBinop(left, right, .floorDiv);
                } else if (self.eatOp("*")) {
                    const right = try self.parseUnary();
                    if (left == .string and right == .integer and right.integer >= 0) {
                        var out = std.ArrayList(u8).empty;
                        errdefer out.deinit(self.state.alloc);
                        var k: i64 = 0;
                        while (k < right.integer) : (k += 1) try out.appendSlice(self.state.alloc, left.string);
                        left = .{ .string = try out.toOwnedSlice(self.state.alloc) };
                    } else {
                        left = try numericBinop(left, right, .mul);
                    }
                } else if (self.eatOp("/")) {
                    const right = try self.parseUnary();
                    left = try numericBinop(left, right, .div);
                } else if (self.eatOp("%")) {
                    const right = try self.parseUnary();
                    left = try numericBinop(left, right, .mod);
                } else break;
            }
            return left;
        }

        fn parseUnary(self: *ExprParser) anyerror!Value {
            if (self.eatOp("-")) {
                const inner = try self.parseUnary();
                return switch (inner) {
                    .integer => |i| .{ .integer = -i },
                    .float => |f| .{ .float = -f },
                    else => .{ .integer = 0 },
                };
            }
            if (self.eatOp("+")) return self.parseUnary();
            return self.parseFilter();
        }

        fn parseFilter(self: *ExprParser) anyerror!Value {
            var val = try self.parsePostfix();
            while (self.eatOp("|")) {
                const fname = self.parseName() orelse return error.RenderError;
                var args = std.ArrayList(Value).empty;
                defer args.deinit(self.state.alloc);
                if (self.eatOp("(")) {
                    try self.parseCallArgs(&args);
                    if (!self.eatOp(")")) return error.RenderError;
                }
                const func = self.renderer.lookupFilter(self.state, fname) orelse return error.RenderError;
                val = try func(self.state.alloc, val, args.items);
            }
            return val;
        }

        fn parsePostfix(self: *ExprParser) anyerror!Value {
            self.skipWs();
            const save = self.pos;
            if (self.parseName()) |nm| {
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == '(') {
                    self.pos += 1;
                    var args = std.ArrayList(Value).empty;
                    defer args.deinit(self.state.alloc);
                    var kwargs = std.ArrayList(CallKwarg).empty;
                    defer kwargs.deinit(self.state.alloc);
                    try self.parseCallArgsFull(&args, &kwargs);
                    if (!self.eatOp(")")) return error.RenderError;
                    var val = try self.renderer.evalCallNamed(self.ctx, self.state, nm, args.items, kwargs.items);
                    while (true) {
                        self.skipWs();
                        if (self.pos < self.src.len and self.src[self.pos] == '.') {
                            self.pos += 1;
                            const attr = self.parseName() orelse return error.RenderError;
                            val = self.renderer.lookupAttr(val, attr);
                            continue;
                        }
                        if (self.pos < self.src.len and self.src[self.pos] == '[') {
                            self.pos += 1;
                            const idx = try self.parseTernary();
                            self.skipWs();
                            if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.RenderError;
                            self.pos += 1;
                            val = self.renderer.lookupIndex(val, idx);
                            continue;
                        }
                        break;
                    }
                    return val;
                }
                self.pos = save;
            }
            var val = try self.parsePrimary();
            while (true) {
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == '.') {
                    self.pos += 1;
                    const name = self.parseName() orelse return error.RenderError;
                    val = self.renderer.lookupAttr(val, name);
                    continue;
                }
                if (self.pos < self.src.len and self.src[self.pos] == '[') {
                    self.pos += 1;
                    const idx = try self.parseTernary();
                    self.skipWs();
                    if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.RenderError;
                    self.pos += 1;
                    val = self.renderer.lookupIndex(val, idx);
                    continue;
                }
                break;
            }
            return val;
        }

        fn parsePrimary(self: *ExprParser) anyerror!Value {
            self.skipWs();
            if (self.pos >= self.src.len) return error.RenderError;
            const c = self.src[self.pos];
            if (c == '(') {
                self.pos += 1;
                const v = try self.parseTernary();
                self.skipWs();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.RenderError;
                self.pos += 1;
                return v;
            }
            if (c == '[') {
                self.pos += 1;
                var items = std.ArrayList(Value).empty;
                errdefer items.deinit(self.state.alloc);
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ']') {
                    self.pos += 1;
                    return .{ .list = try items.toOwnedSlice(self.state.alloc) };
                }
                while (true) {
                    try items.append(self.state.alloc, try self.parseTernary());
                    self.skipWs();
                    if (self.pos < self.src.len and self.src[self.pos] == ',') {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                self.skipWs();
                if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.RenderError;
                self.pos += 1;
                return .{ .list = try items.toOwnedSlice(self.state.alloc) };
            }
            if (c == '{') {
                self.pos += 1;
                var entries = std.ArrayList(context_mod.Entry).empty;
                errdefer entries.deinit(self.state.alloc);
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == '}') {
                    self.pos += 1;
                    return .{ .map = try entries.toOwnedSlice(self.state.alloc) };
                }
                while (true) {
                    const key = try self.parseTernary();
                    self.skipWs();
                    if (self.pos >= self.src.len or self.src[self.pos] != ':') return error.RenderError;
                    self.pos += 1;
                    const kval = try self.parseTernary();
                    const key_str = try filterStringValue(self.state.alloc, key);
                    try entries.append(self.state.alloc, .{ .key = key_str, .value = kval });
                    self.skipWs();
                    if (self.pos < self.src.len and self.src[self.pos] == ',') {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                self.skipWs();
                if (self.pos >= self.src.len or self.src[self.pos] != '}') return error.RenderError;
                self.pos += 1;
                return .{ .map = try entries.toOwnedSlice(self.state.alloc) };
            }
            if (c == '"' or c == '\'') {
                return .{ .string = try self.parseStringLiteral() };
            }
            if (std.ascii.isDigit(c) or (c == '.' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
                return self.parseNumber();
            }
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const w = self.peekWord();
                if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "True")) {
                    self.pos += w.len;
                    return .{ .boolean = true };
                }
                if (std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "False")) {
                    self.pos += w.len;
                    return .{ .boolean = false };
                }
                if (std.mem.eql(u8, w, "none") or std.mem.eql(u8, w, "None") or std.mem.eql(u8, w, "null")) {
                    self.pos += w.len;
                    return .nullVal;
                }
                self.pos += w.len;
                return self.renderer.resolveName(self.ctx, self.state, w);
            }
            return error.RenderError;
        }

        fn parseName(self: *ExprParser) ?[]const u8 {
            self.skipWs();
            const start = self.pos;
            if (start < self.src.len and (std.ascii.isAlphabetic(self.src[start]) or self.src[start] == '_')) {
                self.pos += 1;
                while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
                return self.src[start..self.pos];
            }
            return null;
        }

        fn parseStringLiteral(self: *ExprParser) ![]const u8 {
            const quote = self.src[self.pos];
            self.pos += 1;
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(self.state.alloc);
            while (self.pos < self.src.len) {
                const ch = self.src[self.pos];
                if (ch == quote) {
                    self.pos += 1;
                    return out.toOwnedSlice(self.state.alloc);
                }
                if (ch == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 1;
                    const e = self.src[self.pos];
                    try out.append(self.state.alloc, switch (e) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '0' => 0,
                        else => e,
                    });
                    self.pos += 1;
                    continue;
                }
                try out.append(self.state.alloc, ch);
                self.pos += 1;
            }
            return error.RenderError;
        }

        fn parseNumber(self: *ExprParser) !Value {
            const start = self.pos;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            var is_float = false;
            if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            }
            if (!is_float) {
                return .{ .integer = std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch return error.RenderError };
            }
            return .{ .float = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return error.RenderError };
        }

        fn parseCallArgs(self: *ExprParser, args: *std.ArrayList(Value)) !void {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') return;
            while (true) {
                try args.append(self.state.alloc, try self.parseTernary());
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }
                break;
            }
        }

        fn parseCallArgsFull(self: *ExprParser, args: *std.ArrayList(Value), kwargs: *std.ArrayList(CallKwarg)) !void {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') return;
            while (true) {
                const save = self.pos;
                if (self.parseName()) |nm| {
                    const after_name = self.pos;
                    _ = after_name;
                    self.skipWs();
                    if (self.pos < self.src.len and self.src[self.pos] == '=' and (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != '=')) {
                        self.pos += 1;
                        const v = try self.parseTernary();
                        try kwargs.append(self.state.alloc, .{ .name = nm, .value = v });
                        self.skipWs();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        }
                        break;
                    }
                    self.pos = save;
                }
                try args.append(self.state.alloc, try self.parseTernary());
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }
                break;
            }
        }
    };

    fn compareOrder(a: Value, b: Value) std.math.Order {
        const af: ?f64 = switch (a) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        const bf: ?f64 = switch (b) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        if (af != null and bf != null) return std.math.order(af.?, bf.?);
        if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
        if (a == .boolean and b == .boolean) {
            if (a.boolean == b.boolean) return .eq;
            return if (!a.boolean) .lt else .gt;
        }
        return .eq;
    }

    fn valueContains(needle: Value, haystack: Value) bool {
        switch (haystack) {
            .list => |items| {
                for (items) |item| {
                    if (needle.equals(item)) return true;
                }
                return false;
            },
            .string => |h| {
                if (needle != .string) return false;
                return std.mem.indexOf(u8, h, needle.string) != null;
            },
            .map => |entries| {
                if (needle != .string) return false;
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, needle.string)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    const NumOp = enum { add, sub, mul, div, floorDiv, mod };

    fn numericBinop(left: Value, right: Value, op: NumOp) !Value {
        const lf: ?f64 = switch (left) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        const rf: ?f64 = switch (right) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        if (lf == null or rf == null) return .nullVal;
        const both_int = left == .integer and right == .integer;
        switch (op) {
            .add => {
                if (both_int) return .{ .integer = left.integer +% right.integer };
                return .{ .float = lf.? + rf.? };
            },
            .sub => {
                if (both_int) return .{ .integer = left.integer -% right.integer };
                return .{ .float = lf.? - rf.? };
            },
            .mul => {
                if (both_int) return .{ .integer = left.integer *% right.integer };
                return .{ .float = lf.? * rf.? };
            },
            .div => {
                if (rf.? == 0) return .nullVal;
                return .{ .float = lf.? / rf.? };
            },
            .floorDiv => {
                if (rf.? == 0) return .nullVal;
                return .{ .integer = @intFromFloat(@floor(lf.? / rf.?)) };
            },
            .mod => {
                if (both_int) {
                    if (right.integer == 0) return .nullVal;
                    return .{ .integer = @mod(left.integer, right.integer) };
                }
                if (rf.? == 0) return .nullVal;
                return .{ .float = @mod(lf.?, rf.?) };
            },
        }
    }

    fn evalCallNamed(self: Renderer, ctx: *const Context, state: RenderState, name: []const u8, args: []const Value, kwargs: []const CallKwarg) anyerror!Value {
        if (std.mem.eql(u8, name, "super")) {
            const nodes = state.superNodes orelse return .nullVal;
            if (args.len != 0 or kwargs.len != 0) return error.RenderError;
            var list = std.ArrayList(u8).empty;
            defer list.deinit(state.alloc);
            var lw = ListWriter{ .list = &list, .allocator = state.alloc };
            _ = try self.renderNodes(nodes, ctx, state, &lw);
            return .{ .rawHtml = try list.toOwnedSlice(state.alloc) };
        }
        if (state.scope.getLocal(name)) |v| {
            if (v == .macro) return self.renderMacro(ctx, state, v.macro, args, kwargs);
        }
        if (state.macros.get(name)) |def| {
            return self.renderMacro(ctx, state, def, args, kwargs);
        }
        if (state.globals) |globals| {
            if (globals.map.get(name)) |entry| {
                var gkwargs = std.ArrayList(GlobalKwarg).empty;
                defer gkwargs.deinit(state.alloc);
                for (kwargs) |kw| try gkwargs.append(state.alloc, .{ .name = kw.name, .value = kw.value });
                return entry.func(entry.user_data, state.alloc, args, gkwargs.items);
            }
        }
        if (std.mem.eql(u8, name, "range")) {
            var start: i64 = 0;
            var stop: i64 = 0;
            var step: i64 = 1;
            if (args.len == 1) {
                stop = switch (args[0]) {
                    .integer => |i| i,
                    else => return .nullVal,
                };
            } else if (args.len >= 2) {
                start = switch (args[0]) {
                    .integer => |i| i,
                    else => return .nullVal,
                };
                stop = switch (args[1]) {
                    .integer => |i| i,
                    else => return .nullVal,
                };
                if (args.len >= 3) {
                    step = switch (args[2]) {
                        .integer => |i| i,
                        else => return .nullVal,
                    };
                }
            } else return .nullVal;
            if (step == 0) return .nullVal;
            var out = std.ArrayList(Value).empty;
            errdefer out.deinit(state.alloc);
            var i = start;
            while (if (step > 0) i < stop else i > stop) : (i += step) {
                try out.append(state.alloc, .{ .integer = i });
            }
            return .{ .list = try out.toOwnedSlice(state.alloc) };
        }
        return .nullVal;
    }

    fn renderMacro(self: Renderer, ctx: *const Context, state: RenderState, def: parser_mod.MacroDef, args: []const Value, kwargs: []const CallKwarg) anyerror!Value {
        return self.renderMacroWithScope(ctx, state, def, args, kwargs, null);
    }

    fn renderMacroWithScope(self: Renderer, ctx: *const Context, state: RenderState, def: parser_mod.MacroDef, args: []const Value, kwargs: []const CallKwarg, parent_scope: ?*context_mod.Scope) anyerror!Value {
        var macro_scope = context_mod.Scope{ .parent = parent_scope };
        defer macro_scope.deinit(state.alloc);
        for (def.params, 0..) |param, i| {
            if (i < args.len) {
                try macro_scope.set(state.alloc, param.name, args[i]);
            } else {
                var bound: ?Value = null;
                for (kwargs) |kw| {
                    if (std.mem.eql(u8, kw.name, param.name)) {
                        bound = kw.value;
                        break;
                    }
                }
                if (bound) |v| {
                    try macro_scope.set(state.alloc, param.name, v);
                } else if (param.default) |d| {
                    const trimmed = std.mem.trim(u8, d, " \t\r\n");
                    if (trimmed.len == 0) {
                        try macro_scope.set(state.alloc, param.name, .nullVal);
                    } else {
                        const dv = try self.evalExpr(ctx, state, trimmed);
                        try macro_scope.set(state.alloc, param.name, dv);
                    }
                } else {
                    try macro_scope.set(state.alloc, param.name, .nullVal);
                }
            }
        }
        var next = state;
        next.scope = &macro_scope;
        var list = std.ArrayList(u8).empty;
        defer list.deinit(state.alloc);
        var lw = ListWriter{ .list = &list, .allocator = state.alloc };
        _ = try self.renderNodes(def.bodyNodes, ctx, next, &lw);
        return .{ .string = try list.toOwnedSlice(state.alloc) };
    }

    fn evalExpr(self: Renderer, ctx: *const Context, state: RenderState, text: []const u8) anyerror!Value {
        var p = ExprParser{ .src = text, .renderer = &self, .ctx = ctx, .state = state };
        const v = try p.parseFull();
        if (!p.eof()) return error.RenderError;
        if (v == .missing and state.strict) return TemplateError.UnknownVariable;
        return v;
    }

    fn renderForLoop(
        self: Renderer,
        forInfo: anytype,
        ctx: *const Context,
        state: RenderState,
        writer: anytype,
    ) anyerror!Flow {
        const coll_val = try self.evalExpr(ctx, state, forInfo.collectionExpr);
        const list = switch (coll_val) {
            .list => |l| l,
            else => {
                if (forInfo.elseNodes.len > 0) {
                    return self.renderNodes(forInfo.elseNodes, ctx, state, writer);
                }
                return .normal;
            },
        };
        if (list.len == 0 and forInfo.elseNodes.len > 0) {
            return self.renderNodes(forInfo.elseNodes, ctx, state, writer);
        }

        var loop_scope = context_mod.Scope{ .parent = state.scope };
        defer loop_scope.deinit(state.alloc);
        var loop_state = state;
        loop_state.scope = &loop_scope;

        for (list, 0..) |item, i| {
            var iter_scope = context_mod.Scope{ .parent = &loop_scope };
            defer iter_scope.deinit(state.alloc);
            if (forInfo.itemVar2) |second| {
                if (item == .list and item.list.len >= 2) {
                    try iter_scope.set(state.alloc, forInfo.itemVar, item.list[0]);
                    try iter_scope.set(state.alloc, second, item.list[1]);
                } else {
                    try iter_scope.set(state.alloc, forInfo.itemVar, .nullVal);
                    try iter_scope.set(state.alloc, second, .nullVal);
                }
            } else {
                try iter_scope.set(state.alloc, forInfo.itemVar, item);
            }
            const loop_meta = try state.alloc.alloc(context_mod.Entry, 7);
            loop_meta[0] = .{ .key = "index", .value = .{ .integer = @intCast(i + 1) } };
            loop_meta[1] = .{ .key = "index0", .value = .{ .integer = @intCast(i) } };
            loop_meta[2] = .{ .key = "first", .value = .{ .boolean = (i == 0) } };
            loop_meta[3] = .{ .key = "last", .value = .{ .boolean = (i + 1 == list.len) } };
            loop_meta[4] = .{ .key = "length", .value = .{ .integer = @intCast(list.len) } };
            loop_meta[5] = .{ .key = "revindex", .value = .{ .integer = @intCast(list.len - i) } };
            loop_meta[6] = .{ .key = "revindex0", .value = .{ .integer = @intCast(list.len - 1 - i) } };
            try iter_scope.set(state.alloc, "loop", .{ .map = loop_meta });

            var iter_state = loop_state;
            iter_state.scope = &iter_scope;
            const f = try self.renderNodes(forInfo.bodyNodes, ctx, iter_state, writer);
            if (f == .broken) break;
            if (f == .continued) continue;
        }
        return .normal;
    }
};

test "Renderer escapes HTML and supports raw HTML" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = "<title>{{ title }}</title><body>{{ safeBody }}</body>";
    var parser = parser_mod.Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var ctx = try Context.init(alloc, .{
        .title = "<script>alert('xss')</script> & \"more\"",
        .safeBody = context_mod.raw("<b>Trusted Content</b>"),
    });
    defer ctx.deinit();

    const renderer = Renderer{};
    const output = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(output);

    const expected = "<title>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; &amp; &quot;more&quot;</title><body><b>Trusted Content</b></body>";
    try testing.expectEqualStrings(expected, output);
}

test "Renderer supports elif chains" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% if a %}A{% elif b %}B{% else %}C{% endif %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    const renderer = Renderer{};
    {
        var ctx = try Context.init(alloc, .{ .a = false, .b = true });
        defer ctx.deinit();
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("B", out);
    }
    {
        var ctx = try Context.init(alloc, .{ .a = false, .b = false });
        defer ctx.deinit();
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("C", out);
    }
}

test "Renderer supports set assignments" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% set greeting = \"hi\" %}{{ greeting }}, {{ greeting ~ \"!\" }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("hi, hi!", out);
}

test "Renderer supports macros with defaults" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% macro input(name, value=\"\") %}<input name=\"{{ name }}\" value=\"{{ value }}\">{% endmacro %}{{ input(\"u\")|safe }}|{{ input(\"p\", \"x\")|safe }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("<input name=\"u\" value=\"\">|<input name=\"p\" value=\"x\">", out);
}

test "Renderer supports filter pipelines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ name|trim|upper }}|{{ missing|default(\"N/A\") }}|{{ items|join(\", \") }}|{{ items|length }}|{{ html|striptags }}|{{ trusted|safe }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{
        .name = "  ada  ",
        .items = [_][]const u8{ "a", "b" },
        .html = "<b>x</b>",
        .trusted = context_mod.raw("<i>y</i>"),
    });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("ADA|N/A|a, b|2|x|<i>y</i>", out);
}

test "Renderer evaluates rich expressions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ price * qty }}|{{ user.age >= 18 }}|{{ user[\"name\"] }}|{{ items[0] }}|{{ a and b }}|{{ x if ok else \"fallback\" }}|{{ 7 // 2 }}|{{ 7 % 3 }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{
        .price = @as(i32, 3),
        .qty = @as(i32, 4),
        .user = .{ .age = @as(i32, 20), .name = "Al" },
        .items = [_][]const u8{"z"},
        .a = true,
        .b = "yes",
        .ok = false,
        .x = "X",
    });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("12|true|Al|z|yes|fallback|3|1", out);
}

test "Renderer supports break and continue" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% for i in items %}{% if i == \"b\" %}{% break %}{% endif %}{{ i }}{% endfor %}|{% for i in items %}{% if i == \"a\" %}{% continue %}{% endif %}{{ i }}{% endfor %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .items = [_][]const u8{ "a", "b", "c" } });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("a|bc", out);
}

test "Renderer supports whitespace control" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "a  \n  {%- if ok -%}  \n  x  \n  {%- endif -%}  \n  b";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .ok = true });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("axb", out);
}

test "Renderer custom filter registration" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const shout = struct {
        fn f(a: Allocator, v: Value, args: []const Value) anyerror!Value {
            _ = args;
            const s = try filterStringValue(a, v);
            defer a.free(s);
            return .{ .string = try std.fmt.allocPrint(a, "{s}!", .{s}) };
        }
    }.f;
    var reg = FilterRegistry.init(alloc);
    defer reg.deinit();
    try reg.register("shout", shout);
    const src = "{{ name|shout }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .name = "hi" });
    defer ctx.deinit();
    const renderer = Renderer{ .filters = &reg };
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("hi!", out);
}

test "Renderer supports is-tests" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% if u is defined %}D{% endif %}{% if m is undefined %}U{% endif %}{% if n is none %}N{% endif %}{% if s is string %}S{% endif %}{% if i is number %}I{% endif %}{% if l is sequence %}Q{% endif %}{% if d is mapping %}M{% endif %}{% if x is not defined %}ND{% endif %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .u = 1, .n = null, .s = "a", .i = 2, .l = [_]i32{1}, .d = .{ .k = 1 } });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("DUNSIQMND", out);
}

test "Renderer supports for-else and revindex" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% for i in items %}{{ loop.revindex }}{% else %}empty{% endfor %}|{% for i in missing %}{{ i }}{% else %}none{% endfor %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .items = [_][]const u8{ "a", "b" } });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("21|none", out);
}

test "Renderer supports destructuring" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% for k, v in pairs %}{{ k }}={{ v }};{% endfor %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .pairs = [_][2][]const u8{ .{ "a", "1" }, .{ "b", "2" } } });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("a=1;b=2;", out);
}

test "Renderer supports set blocks and raw blocks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% set card %}<b>{{ v }}</b>{% endset %}{{ card }}{% raw %}{{ not evaluated }}{% endraw %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .v = "X" });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("<b>X</b>{{ not evaluated }}", out);
}

test "Renderer supports call blocks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% macro wrap(cls) %}<div class=\"{{ cls }}\">{{ caller() }}</div>{% endmacro %}{% call wrap(\"box\") %}Hi{% endcall %}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("<div class=\"box\">Hi</div>", out);
}

test "Renderer supports super and nested inheritance" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var base_parser = parser_mod.Parser.init(alloc, "base.html", "<title>{% block t %}Base{% endblock %}</title>{% block c %}Body{% endblock %}");
    var base_ast = try base_parser.parse();
    defer base_ast.deinit();
    var mid_parser = parser_mod.Parser.init(alloc, "mid.html", "{% extends \"base.html\" %}{% block t %}Mid-{{ super() }}{% endblock %}");
    var mid_ast = try mid_parser.parse();
    defer mid_ast.deinit();
    var page_parser = parser_mod.Parser.init(alloc, "page.html", "{% extends \"mid.html\" %}{% block c %}Page{% endblock %}");
    var page_ast = try page_parser.parse();
    defer page_ast.deinit();
    const Provider = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?*const TemplateAst {
            const asts: *const struct { base: *const TemplateAst, mid: *const TemplateAst } = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, name, "base.html")) return asts.base;
            if (std.mem.eql(u8, name, "mid.html")) return asts.mid;
            return null;
        }
    };
    const pair = .{ .base = &base_ast, .mid = &mid_ast };
    const provider = TemplateProvider{ .ptr = &pair, .getAstFn = Provider.get };
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &page_ast, &ctx, provider);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<title>Mid-Base</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Page") != null);
}

test "Renderer detects inheritance cycles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var a_parser = parser_mod.Parser.init(alloc, "a.html", "{% extends \"b.html\" %}A");
    var a_ast = try a_parser.parse();
    defer a_ast.deinit();
    var b_parser = parser_mod.Parser.init(alloc, "b.html", "{% extends \"a.html\" %}B");
    var b_ast = try b_parser.parse();
    defer b_ast.deinit();
    const Provider = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?*const TemplateAst {
            const asts: *const struct { a: *const TemplateAst, b: *const TemplateAst } = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, name, "a.html")) return asts.a;
            if (std.mem.eql(u8, name, "b.html")) return asts.b;
            return null;
        }
    };
    const pair = .{ .a = &a_ast, .b = &b_ast };
    const provider = TemplateProvider{ .ptr = &pair, .getAstFn = Provider.get };
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const res = renderer.renderToString(alloc, &a_ast, &ctx, provider);
    try testing.expectError(error.CircularInheritance, res);
}

test "Renderer strict mode rejects undefined output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ missing }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const strict_renderer = Renderer{ .options = .{ .strictUndefined = true } };
    try testing.expectError(error.UnknownVariable, strict_renderer.renderToString(alloc, &ast, &ctx, null));
    const lax_renderer = Renderer{};
    const out = try lax_renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("", out);
}

test "Renderer supports sort and reverse filters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ items|sort|join(\",\") }}|{{ items|reverse|join(\",\") }}";
    var parser = parser_mod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .items = [_][]const u8{ "b", "a", "c" } });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("a,b,c|c,a,b", out);
}

test "Renderer handles large templates without reparsing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var src_list = std.ArrayList(u8).empty;
    defer src_list.deinit(alloc);
    try src_list.appendSlice(alloc, "{% for i in items %}");
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        try src_list.appendSlice(alloc, "<p>{{ i }}:{{ loop.index }}</p>{% if i %}<b>x</b>{% endif %}");
    }
    try src_list.appendSlice(alloc, "{% endfor %}");
    const src = src_list.items;

    var items = std.ArrayList(Value).empty;
    defer items.deinit(alloc);
    var j: i64 = 0;
    while (j < 50) : (j += 1) try items.append(alloc, .{ .integer = j });

    var parser = parser_mod.Parser.init(alloc, "big.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{ .items = items.items });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expect(out.len > 100000);
    try testing.expect(std.mem.indexOf(u8, out, "<p>49:50</p>") != null);
}

test "Renderer fuzzes invalid expressions without crashing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const evil = [_][]const u8{
        "{{ unknown_filter_xyz(1) }}",
        "{{ missing.deep.path }}",
        "{{ 1 + }}",
        "{{ (2 }}",
        "{{ x|nosuchfilter }}",
        "{% if %}x{% endif %}",
        "{{ range(1,2,0) }}",
        "{{ [1,2] + 1 }}",
        "{{ {} }}",
        "{{ {\"a\": 1} }}",
    };
    for (evil) |src| {
        var parser = parser_mod.Parser.init(alloc, "fuzz.html", src);
        if (parser.parse()) |ast| {
            var mut = ast;
            defer mut.deinit();
            var ctx = try Context.init(alloc, .{});
            defer ctx.deinit();
            const renderer = Renderer{};
            if (renderer.renderToString(alloc, &mut, &ctx, null)) |out| {
                alloc.free(out);
            } else |_| {}
        } else |_| {}
    }
}

test "Renderer evaluates conditionals and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\{% if user %}
        \\Hello {{ user.name }}!
        \\{% endif %}
        \\Items:
        \\{% for item in items %}
        \\{{ loop.index }}: {{ item }}
        \\{% endfor %}
    ;

    var parser = parser_mod.Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var ctx = try Context.init(alloc, .{
        .user = .{ .name = "Muhammad" },
        .items = [_][]const u8{ "apple", "banana" },
    });
    defer ctx.deinit();

    const renderer = Renderer{};
    const output = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "Hello Muhammad!") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1: apple") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2: banana") != null);
}
