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
const contextMod = @import("context.zig");
const parserMod = @import("parser.zig");
const errMod = @import("error.zig");
const clockMod = @import("../../common/clock.zig");

pub const Value = contextMod.Value;
pub const Context = contextMod.Context;
pub const TemplateAst = parserMod.TemplateAst;
pub const TemplateNode = parserMod.TemplateNode;
pub const BlockInfo = parserMod.BlockInfo;
pub const TemplateError = errMod.TemplateError;

/// Minimal provider interface used by renderer to retrieve ASTs for includes and parent templates.
pub const TemplateProvider = struct {
    ptr: *const anyopaque,
    getAstFn: *const fn (ptr: *const anyopaque, name: []const u8) ?*const TemplateAst,
    /// Optional sink for per-node source locations (error diagnostics).
    /// Defaults to null so existing providers keep compiling.
    reportLocFn: ?*const fn (ptr: *const anyopaque, line: usize, col: usize, startByte: usize) void = null,

    pub fn getAst(self: TemplateProvider, name: []const u8) ?*const TemplateAst {
        return self.getAstFn(self.ptr, name);
    }

    pub fn reportLoc(self: TemplateProvider, line: usize, col: usize, startByte: usize) void {
        if (self.reportLocFn) |f| f(self.ptr, line, col, startByte);
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
    /// Default HTML autoescaping for `{{ }}` output (overridable per
    /// region with `{% autoescape %}`).
    autoescapeDefault: bool = true,
    /// Cap on rendered output bytes per render (DoS guard).
    maxOutputBytes: usize = 64 << 20,
    /// Cap on nested macro/call depth (recursion guard).
    maxMacroDepth: usize = 64,
    /// Cap on `range()` sequence length (memory guard).
    maxRangeItems: usize = 1 << 20,
};

/// Writer wrapper enforcing RenderOptions.maxOutputBytes.
pub const LimitWriter = struct {
    inner: *std.ArrayList(u8),
    allocator: Allocator,
    remaining: usize,

    pub fn writeAll(self: *LimitWriter, bytes: []const u8) !void {
        if (bytes.len > self.remaining) return TemplateError.SizeLimitExceeded;
        self.remaining -= bytes.len;
        try self.inner.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *LimitWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.writeAll(formatted);
    }
};

/// Counts bytes into any writer while enforcing a cap. Used to wrap
/// caller-provided writers so `maxOutputBytes` holds for every sink.
pub fn CountingWriter(comptime W: type) type {
    return struct {
        inner: W,
        remaining: usize,

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.remaining) return TemplateError.SizeLimitExceeded;
            self.remaining -= bytes.len;
            try self.inner.writeAll(bytes);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            // Formatting needs an allocator; fall back to a bounded stack
            // buffer (outputs larger than this are pathological).
            var buf: [4096]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt, args) catch return TemplateError.SizeLimitExceeded;
            try self.writeAll(s);
        }
    };
}

pub const GlobalKwarg = struct {
    name: []const u8,
    value: Value,
};

pub const GlobalFn = *const fn (userData: ?*const anyopaque, allocator: Allocator, args: []const Value, kwargs: []const GlobalKwarg) anyerror!Value;

pub const GlobalEntry = struct {
    func: GlobalFn,
    userData: ?*const anyopaque = null,
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

pub const FilterFn = *const fn (allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) anyerror!Value;

pub const FilterKwarg = struct {
    name: []const u8,
    value: Value,
};

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

fn filterUpper(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = s };
}

fn filterLower(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s) |*c| c.* = std.ascii.toLower(c.*);
    return .{ .string = s };
}

fn filterTrim(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    return .{ .string = try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")) };
}

fn filterCapitalize(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    for (s, 0..) |*c, i| c.* = if (i == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    return .{ .string = s };
}

fn filterTitle(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    var newWord = true;
    for (s) |*c| {
        if (std.ascii.isWhitespace(c.*)) {
            newWord = true;
        } else if (newWord) {
            c.* = std.ascii.toUpper(c.*);
            newWord = false;
        } else {
            c.* = std.ascii.toLower(c.*);
        }
    }
    return .{ .string = s };
}

fn filterEscape(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    // Already-safe markup passes through unescaped (Jinja Markup semantics);
    // use `forceescape` to escape even safe values.
    if (value == .rawHtml) return value;
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

fn filterSafe(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    return .{ .rawHtml = s };
}

fn filterDefault(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const useBool = boolFilterParam(args, kwargs, 1, "boolean", args.len > 1 and args[1] == .boolean and args[1].boolean);
    const isMissing = value == .nullVal or value == .missing or (useBool and !value.isTruthy());
    if (!isMissing) return value;
    if (args.len > 0) return args[0];
    return .{ .string = try allocator.dupe(u8, "") };
}

fn filterLength(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
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

fn filterJoin(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const sep = if (args.len > 0) try filterStringValue(allocator, args[0]) else try allocator.dupe(u8, "");
    defer allocator.free(sep);
    var attrName: ?[]const u8 = null;
    if (args.len > 1) {
        attrName = switch (args[1]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "attribute")) |v| {
        attrName = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    }
    if (value != .list) return .{ .string = try filterStringValue(allocator, value) };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value.list, 0..) |item, i| {
        if (i > 0) try out.appendSlice(allocator, sep);
        const v = if (attrName) |a| lookupPathValue(item, a) else item;
        if (attrName != null and v == .missing) return error.RenderError;
        const s = try filterStringValue(allocator, v);
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterFirst(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    _ = allocator;
    return switch (value) {
        .list => |l| if (l.len > 0) l[0] else .nullVal,
        .string => |s| if (s.len > 0) .{ .string = s[0..1] } else .nullVal,
        else => .nullVal,
    };
}

fn filterLast(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    _ = allocator;
    return switch (value) {
        .list => |l| if (l.len > 0) l[l.len - 1] else .nullVal,
        .string => |s| if (s.len > 0) .{ .string = s[s.len - 1 ..] } else .nullVal,
        else => .nullVal,
    };
}

fn filterReplace(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
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

fn filterTruncate(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const n: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "length", 255);
        break :blk if (raw < 0) 0 else @intCast(raw);
    };
    const killwords = boolFilterParam(args, kwargs, 1, "killwords", false);
    var endBuf: ?[]u8 = null;
    defer if (endBuf) |e| allocator.free(e);
    const end: []const u8 = blk: {
        if (filterKwarg(kwargs, "end")) |v| {
            endBuf = try filterStringValue(allocator, v);
            break :blk endBuf.?;
        }
        if (args.len > 2) {
            endBuf = try filterStringValue(allocator, args[2]);
            break :blk endBuf.?;
        }
        break :blk "...";
    };
    const leeway: usize = blk: {
        const raw = intFilterParam(args, kwargs, 3, "leeway", 5);
        break :blk if (raw < 0) 0 else @intCast(raw);
    };
    const s = try filterStringValue(allocator, value);
    if (s.len <= n + leeway) return .{ .string = s };
    defer allocator.free(s);
    var cut: []const u8 = s[0..n];
    if (!killwords) {
        if (std.mem.lastIndexOfAny(u8, cut, " \t\r\n")) |sp| {
            cut = std.mem.trimEnd(u8, cut[0..sp], " \t\r\n");
        }
    } else {
        cut = std.mem.trimEnd(u8, cut, " \t\r\n");
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, cut);
    try out.appendSlice(allocator, end);
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterStriptags(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var inTag = false;
    for (s) |c| {
        if (inTag) {
            if (c == '>') inTag = false;
        } else if (c == '<') {
            inTag = true;
        } else {
            try out.append(allocator, c);
        }
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterInt(_: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const fallback: i64 = if (args.len > 0) filterIntValue(args[0], 0) else if (filterKwarg(kwargs, "default")) |v| filterIntValue(v, 0) else 0;
    const base: u8 = blk: {
        const raw = intFilterParam(args, kwargs, 1, "base", 10);
        // Base 0 requests prefix auto-detection (0x/0o/0b); anything
        // outside 0..36 falls back to decimal.
        if (raw < 0 or raw == 1 or raw > 36) break :blk 10;
        break :blk @intCast(raw);
    };
    return .{ .integer = switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |b| if (b) 1 else 0,
        .string => |s| parseIntBase(std.mem.trim(u8, s, " \t\r\n"), base) catch fallback,
        else => fallback,
    } };
}

fn parseIntBase(s: []const u8, base: u8) !i64 {
    var text = s;
    var neg = false;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        neg = text[0] == '-';
        text = text[1..];
    }
    var b = base;
    if (b == 0) {
        b = 10;
        if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
            b = 16;
            text = text[2..];
        } else if (std.mem.startsWith(u8, text, "0o") or std.mem.startsWith(u8, text, "0O")) {
            b = 8;
            text = text[2..];
        } else if (std.mem.startsWith(u8, text, "0b") or std.mem.startsWith(u8, text, "0B")) {
            b = 2;
            text = text[2..];
        }
    }
    const mag = std.fmt.parseInt(i64, text, b) catch return error.InvalidCharacter;
    return if (neg) -mag else mag;
}

fn filterFloat(_: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const fallback: f64 = if (args.len > 0) switch (args[0]) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    } else if (filterKwarg(kwargs, "default")) |v| switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    } else 0.0;
    return .{ .float = switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch fallback,
        else => fallback,
    } };
}

fn filterString(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    return .{ .string = try filterStringValue(allocator, value) };
}

fn filterAbs(_: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    return switch (value) {
        .integer => |i| .{ .integer = if (i < 0) -i else i },
        .float => |f| .{ .float = @abs(f) },
        else => value,
    };
}

fn filterRound(_: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
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

fn filterSort(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    var attrName: ?[]const u8 = null;
    if (args.len > 0) {
        attrName = switch (args[0]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "attribute")) |v| {
        attrName = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    }
    const reverse = boolFilterParam(args, kwargs, 1, "reverse", false);
    const caseSensitive = boolFilterParam(args, kwargs, 2, "case_sensitive", false);
    if (value != .list) return value;
    const out = try allocator.dupe(Value, value.list);
    errdefer allocator.free(out);
    if (attrName) |a| {
        for (out) |item| {
            if (lookupPathValue(item, a) == .missing) return error.RenderError;
        }
        const Ctx = struct {
            attr: []const u8,
            caseSensitive: bool,
        };
        const cx = Ctx{ .attr = a, .caseSensitive = caseSensitive };
        std.mem.sort(Value, out, cx, struct {
            fn less(c: Ctx, x: Value, y: Value) bool {
                return orderValues(lookupPathValue(x, c.attr), lookupPathValue(y, c.attr), c.caseSensitive) == .lt;
            }
        }.less);
    } else {
        var allInt = true;
        var allString = true;
        for (out) |item| {
            if (item != .integer) allInt = false;
            if (item != .string) allString = false;
        }
        if (allInt) {
            std.mem.sort(Value, out, {}, struct {
                fn less(_: void, a: Value, b: Value) bool {
                    return a.integer < b.integer;
                }
            }.less);
        } else {
            const cx = caseSensitive;
            std.mem.sort(Value, out, cx, struct {
                fn less(sensitive: bool, a: Value, b: Value) bool {
                    return orderValues(a, b, sensitive) == .lt;
                }
            }.less);
        }
    }
    if (reverse) std.mem.reverse(Value, out);
    return .{ .list = out };
}

fn filterReverse(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    _ = args;
    if (value != .list) return value;
    const out = try allocator.dupe(Value, value.list);
    errdefer allocator.free(out);
    std.mem.reverse(Value, out);
    return .{ .list = out };
}

// ---------- extended filter helpers ----------

fn filterKwarg(kwargs: []const FilterKwarg, name: []const u8) ?Value {
    for (kwargs) |kw| {
        if (std.mem.eql(u8, kw.name, name)) return kw.value;
    }
    return null;
}

fn filterIntValue(v: Value, default: i64) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |b| if (b) 1 else 0,
        else => default,
    };
}

fn intFilterParam(args: []const Value, kwargs: []const FilterKwarg, ai: usize, kname: []const u8, default: i64) i64 {
    if (filterKwarg(kwargs, kname)) |v| return filterIntValue(v, default);
    if (ai < args.len) return filterIntValue(args[ai], default);
    return default;
}

fn boolFilterParam(args: []const Value, kwargs: []const FilterKwarg, ai: usize, kname: []const u8, default: bool) bool {
    if (filterKwarg(kwargs, kname)) |v| return v.isTruthy();
    if (ai < args.len) return args[ai].isTruthy();
    return default;
}

fn strFilterParam(allocator: Allocator, args: []const Value, kwargs: []const FilterKwarg, ai: usize, kname: []const u8) !?[]u8 {
    if (filterKwarg(kwargs, kname)) |v| return try filterStringValue(allocator, v);
    if (ai < args.len) return try filterStringValue(allocator, args[ai]);
    return null;
}

/// Dotted attribute lookup used by `attr`, `map`, `selectattr` and friends.
/// Traverses maps by key and lists by integer index; anything
/// unresolvable yields `.missing` (empty output, or an error in strict mode).
fn lookupPathValue(value: Value, dotted: []const u8) Value {
    var cur = value;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        cur = switch (cur) {
            .map => |entries| blk: {
                var found: ?Value = null;
                for (entries) |e| {
                    if (std.mem.eql(u8, e.key, part)) {
                        found = e.value;
                        break;
                    }
                }
                break :blk found orelse return .missing;
            },
            .list => |items| blk: {
                const idx = std.fmt.parseInt(usize, part, 10) catch return .missing;
                break :blk if (idx < items.len) items[idx] else .missing;
            },
            else => return .missing,
        };
    }
    return cur;
}

fn appendUtf8Chars(list: *std.ArrayList(Value), allocator: Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + n, s.len);
        try list.append(allocator, .{ .string = s[i..end] });
        i = end;
    }
}

fn appendPercentEncoded(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/' or c == ':';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(allocator, &[_]u8{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, &[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn writeJsonValue(out: *std.ArrayList(u8), allocator: Allocator, v: Value, indent: ?usize, level: usize) anyerror!void {
    switch (v) {
        .nullVal, .missing, .macro => try out.appendSlice(allocator, "null"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
        .float => |f| {
            if (!std.math.isFinite(f)) {
                try out.appendSlice(allocator, "null");
            } else {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            }
        },
        .string => |s| try appendJsonString(out, allocator, s),
        .rawHtml => |h| try appendJsonString(out, allocator, h),
        .list => |items| {
            if (items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (indent) |pad| {
                    try out.append(allocator, '\n');
                    var k: usize = 0;
                    while (k < (level + 1) * pad) : (k += 1) try out.append(allocator, ' ');
                }
                try writeJsonValue(out, allocator, item, indent, level + 1);
                if (i + 1 < items.len) {
                    try out.append(allocator, ',');
                    if (indent == null) try out.append(allocator, ' ');
                }
            }
            if (indent) |pad| {
                try out.append(allocator, '\n');
                var k: usize = 0;
                while (k < level * pad) : (k += 1) try out.append(allocator, ' ');
            }
            try out.append(allocator, ']');
        },
        .map => |entries| {
            if (entries.len == 0) {
                try out.appendSlice(allocator, "{}");
                return;
            }
            try out.append(allocator, '{');
            for (entries, 0..) |e, i| {
                if (indent) |pad| {
                    try out.append(allocator, '\n');
                    var k: usize = 0;
                    while (k < (level + 1) * pad) : (k += 1) try out.append(allocator, ' ');
                }
                try appendJsonString(out, allocator, e.key);
                try out.append(allocator, ':');
                try out.append(allocator, ' ');
                try writeJsonValue(out, allocator, e.value, indent, level + 1);
                if (i + 1 < entries.len) {
                    try out.append(allocator, ',');
                    if (indent == null) try out.append(allocator, ' ');
                }
            }
            if (indent) |pad| {
                try out.append(allocator, '\n');
                var k: usize = 0;
                while (k < level * pad) : (k += 1) try out.append(allocator, ' ');
            }
            try out.append(allocator, '}');
        },
    }
}

fn appendPprint(out: *std.ArrayList(u8), allocator: Allocator, v: Value, verbose: bool) anyerror!void {
    switch (v) {
        .nullVal => try out.appendSlice(allocator, "None"),
        .missing => try out.appendSlice(allocator, "Undefined"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "True" else "False"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
        .string => |s| {
            try out.append(allocator, '\'');
            for (s) |c| {
                if (c == '\'') try out.appendSlice(allocator, "\\'") else try out.append(allocator, c);
            }
            try out.append(allocator, '\'');
        },
        .rawHtml => |h| {
            if (verbose) try out.appendSlice(allocator, "Markup(");
            try out.append(allocator, '\'');
            try out.appendSlice(allocator, h);
            try out.append(allocator, '\'');
            if (verbose) try out.append(allocator, ')');
        },
        .list => |items| {
            try out.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try appendPprint(out, allocator, item, verbose);
            }
            try out.append(allocator, ']');
        },
        .map => |entries| {
            try out.append(allocator, '{');
            for (entries, 0..) |e, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.append(allocator, '\'');
                try out.appendSlice(allocator, e.key);
                try out.appendSlice(allocator, "': ");
                try appendPprint(out, allocator, e.value, verbose);
            }
            try out.append(allocator, '}');
        },
        .macro => |m| {
            const s = try std.fmt.allocPrint(allocator, "<Macro '{s}'>", .{m.name});
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
    }
}

/// Case-aware value ordering shared by `sort`, `max`, `min` and `dictsort`.
fn orderValues(a: Value, b: Value, caseSensitive: bool) std.math.Order {
    if (a == .string and b == .string and !caseSensitive) {
        if (std.ascii.eqlIgnoreCase(a.string, b.string)) return .eq;
        var i: usize = 0;
        while (i < a.string.len and i < b.string.len) : (i += 1) {
            const ca = std.ascii.toLower(a.string[i]);
            const cb = std.ascii.toLower(b.string[i]);
            if (ca != cb) return if (ca < cb) .lt else .gt;
        }
        return std.math.order(a.string.len, b.string.len);
    }
    return compareOrder(a, b);
}

fn filterAttr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = allocator;
    var name: ?[]const u8 = null;
    if (args.len > 0) {
        name = switch (args[0]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "name")) |v| {
        name = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else return error.RenderError;
    return lookupPathValue(value, name.?);
}

fn filterBatch(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .list) return error.RenderError;
    const n: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "linecount", -1);
        if (raw <= 0) return error.RenderError;
        break :blk @intCast(raw);
    };
    const hasFill = args.len > 1 or filterKwarg(kwargs, "fill_with") != null;
    const fill: Value = if (args.len > 1) args[1] else if (filterKwarg(kwargs, "fill_with")) |v| v else .nullVal;
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.list.len) {
        var row = std.ArrayList(Value).empty;
        errdefer row.deinit(allocator);
        var k: usize = 0;
        while (k < n and i < value.list.len) : ({
            k += 1;
            i += 1;
        }) try row.append(allocator, value.list[i]);
        if (hasFill) {
            while (k < n) : (k += 1) try row.append(allocator, fill);
        }
        try out.append(allocator, .{ .list = try row.toOwnedSlice(allocator) });
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterSliceBatch(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .list) return error.RenderError;
    const n: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "slices", -1);
        if (raw <= 0) return error.RenderError;
        break :blk @intCast(raw);
    };
    const hasFill = args.len > 1 or filterKwarg(kwargs, "fill_with") != null;
    const fill: Value = if (args.len > 1) args[1] else if (filterKwarg(kwargs, "fill_with")) |v| v else .nullVal;
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    const total = value.list.len;
    var col: usize = 0;
    while (col < n) : (col += 1) {
        var column = std.ArrayList(Value).empty;
        errdefer column.deinit(allocator);
        var idx = col;
        var filled = false;
        while (idx < total) : (idx += n) {
            try column.append(allocator, value.list[idx]);
            filled = true;
        }
        if (!filled and hasFill) try column.append(allocator, fill);
        if (filled or hasFill) try out.append(allocator, .{ .list = try column.toOwnedSlice(allocator) });
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterCenter(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const width: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "width", 80);
        break :blk if (raw < 0) 0 else @intCast(raw);
    };
    const s = try filterStringValue(allocator, value);
    if (s.len >= width) return .{ .string = s };
    const pad = width - s.len;
    const left = pad / 2;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < left) : (i += 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, s);
    allocator.free(s);
    while (out.items.len < width) try out.append(allocator, ' ');
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterDictsort(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .map) return error.RenderError;
    const caseSensitive = boolFilterParam(args, kwargs, 0, "case_sensitive", false);
    var byKey = true;
    if (filterKwarg(kwargs, "by")) |v| {
        byKey = switch (v) {
            .string => |s| !std.mem.eql(u8, s, "value"),
            else => true,
        };
    } else if (args.len > 1) {
        byKey = switch (args[1]) {
            .string => |s| !std.mem.eql(u8, s, "value"),
            else => true,
        };
    }
    const reverse = boolFilterParam(args, kwargs, 2, "reverse", false);
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    for (value.map) |e| {
        const pair = try allocator.alloc(Value, 2);
        errdefer allocator.free(pair);
        pair[0] = .{ .string = e.key };
        pair[1] = e.value;
        try out.append(allocator, .{ .list = pair });
    }
    const Ctx = struct {
        byKey: bool,
        caseSensitive: bool,
    };
    const cx = Ctx{ .byKey = byKey, .caseSensitive = caseSensitive };
    std.mem.sort(Value, out.items, cx, struct {
        fn less(c: Ctx, a: Value, b: Value) bool {
            const ka = if (c.byKey) a.list[0] else a.list[1];
            const kb = if (c.byKey) b.list[0] else b.list[1];
            return orderValues(ka, kb, c.caseSensitive) == .lt;
        }
    }.less);
    if (reverse) std.mem.reverse(Value, out.items);
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterFilesizeformat(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const bytes: i64 = switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return error.RenderError,
    };
    const binary = boolFilterParam(args, kwargs, 0, "binary", false);
    const mag = if (bytes < 0) -bytes else bytes;
    if (mag < 1024) {
        return .{ .string = try std.fmt.allocPrint(allocator, "{d} Bytes", .{bytes}) };
    }
    const units: []const []const u8 = if (binary) &.{ "KiB", "MiB", "GiB", "TiB", "PiB" } else &.{ "kB", "MB", "GB", "TB", "PB" };
    var f: f64 = @as(f64, @floatFromInt(mag)) / 1024.0;
    var ui: usize = 0;
    while (f >= 1024.0 and ui + 1 < units.len) {
        f /= 1024.0;
        ui += 1;
    }
    const sign: []const u8 = if (bytes < 0) "-" else "";
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}{d:.1} {s}", .{ sign, f, units[ui] }) };
}

fn filterForceescape(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = args;
    _ = kwargs;
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

fn padFormatted(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8, width: usize, left: bool, zero: bool) !void {
    if (s.len >= width) {
        try out.appendSlice(allocator, s);
        return;
    }
    const pad = width - s.len;
    if (left) {
        try out.appendSlice(allocator, s);
        var i: usize = 0;
        while (i < pad) : (i += 1) try out.append(allocator, ' ');
        return;
    }
    const padChar: u8 = if (zero) '0' else ' ';
    var start: usize = 0;
    if (zero and (s.len > 0) and (s[0] == '-' or s[0] == '+' or s[0] == ' ')) {
        try out.append(allocator, s[0]);
        start = 1;
    }
    var i: usize = 0;
    while (i < pad) : (i += 1) try out.append(allocator, padChar);
    try out.appendSlice(allocator, s[start..]);
}

fn filterFormat(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = kwargs;
    const fmt = try filterStringValue(allocator, value);
    defer allocator.free(fmt);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var ai: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try out.append(allocator, '%');
            i += 1;
            continue;
        }
        var left = false;
        var plus = false;
        var space = false;
        var zero = false;
        while (i < fmt.len) {
            switch (fmt[i]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '0' => zero = true,
                '#' => {},
                else => break,
            }
            i += 1;
        }
        var width: usize = 0;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = width * 10 + @as(usize, @intCast(fmt[i] - '0'));
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            prec = 0;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) prec.? = prec.? * 10 + @as(usize, @intCast(fmt[i] - '0'));
        }
        if (i >= fmt.len) return error.RenderError;
        const spec = fmt[i];
        i += 1;
        if (ai >= args.len) return error.RenderError;
        const arg = args[ai];
        ai += 1;
        switch (spec) {
            's' => {
                const s = try filterStringValue(allocator, arg);
                defer allocator.free(s);
                const cut = if (prec) |p| s[0..@min(p, s.len)] else s;
                try padFormatted(&out, allocator, cut, width, left, false);
            },
            'd', 'i', 'u' => {
                const v: i64 = switch (arg) {
                    .integer => |x| x,
                    .float => |x| @intFromFloat(x),
                    .boolean => |b| if (b) 1 else 0,
                    .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch return error.RenderError,
                    else => return error.RenderError,
                };
                var num: [32]u8 = undefined;
                var body: []const u8 = undefined;
                if (spec == 'u') {
                    body = std.fmt.bufPrint(&num, "{d}", .{@as(u64, @bitCast(v))}) catch return error.RenderError;
                } else if (v < 0) {
                    const mag: u64 = if (v == std.math.minInt(i64)) @as(u64, 0x8000000000000000) else @intCast(-v);
                    const m = std.fmt.bufPrint(&num, "-{d}", .{mag}) catch return error.RenderError;
                    body = m;
                } else {
                    const sign: []const u8 = if (plus) "+" else if (space) " " else "";
                    const m = std.fmt.bufPrint(&num, "{s}{d}", .{ sign, v }) catch return error.RenderError;
                    body = m;
                }
                try padFormatted(&out, allocator, body, width, left, zero);
            },
            'f', 'F' => {
                const f: f64 = switch (arg) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    .boolean => |b| if (b) 1.0 else 0.0,
                    else => return error.RenderError,
                };
                const p = prec orelse 6;
                const pow10 = std.math.pow(f64, 10.0, @floatFromInt(p));
                const neg = f < 0;
                const af = @abs(f);
                var num: [64]u8 = undefined;
                var body: []const u8 = undefined;
                if (!std.math.isFinite(f) or af >= 1e18) {
                    body = std.fmt.bufPrint(&num, "{d}", .{f}) catch return error.RenderError;
                } else if (p == 0) {
                    const w: u64 = @intFromFloat(@trunc(af));
                    if (neg) {
                        body = std.fmt.bufPrint(&num, "-{d}", .{w}) catch return error.RenderError;
                    } else {
                        const sign: []const u8 = if (plus) "+" else if (space) " " else "";
                        body = std.fmt.bufPrint(&num, "{s}{d}", .{ sign, w }) catch return error.RenderError;
                    }
                } else {
                    const scaled = @round(af * pow10);
                    const whole: u64 = @intFromFloat(@trunc(scaled / pow10));
                    const frac: u64 = @intFromFloat(scaled - @as(f64, @floatFromInt(whole)) * pow10);
                    var fracBuf: [32]u8 = undefined;
                    const fs = std.fmt.bufPrint(&fracBuf, "{d}", .{frac}) catch return error.RenderError;
                    var padBuf: [64]u8 = undefined;
                    var pi: usize = 0;
                    while (pi + fs.len < p) : (pi += 1) padBuf[pi] = '0';
                    @memcpy(padBuf[pi .. pi + fs.len], fs);
                    if (neg) {
                        body = std.fmt.bufPrint(&num, "-{d}.{s}", .{ whole, padBuf[0 .. pi + fs.len] }) catch return error.RenderError;
                    } else {
                        const sign: []const u8 = if (plus) "+" else if (space) " " else "";
                        body = std.fmt.bufPrint(&num, "{s}{d}.{s}", .{ sign, whole, padBuf[0 .. pi + fs.len] }) catch return error.RenderError;
                    }
                }
                if (spec == 'F') {
                    var up: [64]u8 = undefined;
                    @memcpy(up[0..body.len], body);
                    for (up[0..body.len]) |*ch| ch.* = std.ascii.toUpper(ch.*);
                    body = up[0..body.len];
                }
                try padFormatted(&out, allocator, body, width, left, zero);
            },
            'e', 'E' => {
                if (prec != null) return error.RenderError;
                const f: f64 = switch (arg) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => return error.RenderError,
                };
                const s = try std.fmt.allocPrint(allocator, "{e}", .{f});
                defer allocator.free(s);
                if (spec == 'E') {
                    for (s) |*ch| ch.* = std.ascii.toUpper(ch.*);
                }
                try padFormatted(&out, allocator, s, width, left, false);
            },
            'x', 'X', 'o' => {
                const v: i64 = switch (arg) {
                    .integer => |x| x,
                    .boolean => |b| if (b) 1 else 0,
                    else => return error.RenderError,
                };
                var num: [32]u8 = undefined;
                var body: []const u8 = undefined;
                if (v < 0) {
                    const mag: u64 = if (v == std.math.minInt(i64)) @as(u64, 0x8000000000000000) else @intCast(-v);
                    const m = std.fmt.bufPrint(&num, "-{x}", .{mag}) catch return error.RenderError;
                    body = m;
                } else if (spec == 'x') {
                    body = std.fmt.bufPrint(&num, "{x}", .{@as(u64, @bitCast(v))}) catch return error.RenderError;
                } else if (spec == 'X') {
                    body = std.fmt.bufPrint(&num, "{X}", .{@as(u64, @bitCast(v))}) catch return error.RenderError;
                } else {
                    body = std.fmt.bufPrint(&num, "{o}", .{@as(u64, @bitCast(v))}) catch return error.RenderError;
                }
                try padFormatted(&out, allocator, body, width, left, zero);
            },
            'c' => {
                if (arg == .integer) {
                    const cp: u21 = std.math.cast(u21, arg.integer) orelse return error.RenderError;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch return error.RenderError;
                    try padFormatted(&out, allocator, enc[0..n], width, left, false);
                } else {
                    const s = try filterStringValue(allocator, arg);
                    defer allocator.free(s);
                    if (s.len == 0) return error.RenderError;
                    try padFormatted(&out, allocator, s[0..1], width, left, false);
                }
            },
            else => return error.RenderError,
        }
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterGroupby(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .list) return error.RenderError;
    const attrName: []const u8 = blk: {
        if (args.len > 0) {
            break :blk switch (args[0]) {
                .string => |s| s,
                .rawHtml => |h| h,
                else => return error.RenderError,
            };
        }
        if (filterKwarg(kwargs, "attribute")) |v| {
            break :blk switch (v) {
                .string => |s| s,
                .rawHtml => |h| h,
                else => return error.RenderError,
            };
        }
        return error.RenderError;
    };
    const caseSensitive = boolFilterParam(args, kwargs, 2, "case_sensitive", false);
    const hasDefault = args.len > 1 or filterKwarg(kwargs, "default") != null;
    const default: Value = if (args.len > 1) args[1] else if (filterKwarg(kwargs, "default")) |v| v else .nullVal;
    var groupKeys = std.ArrayList(Value).empty;
    defer groupKeys.deinit(allocator);
    var members = std.ArrayList(std.ArrayList(Value)).empty;
    errdefer {
        for (members.items) |*m| m.deinit(allocator);
        members.deinit(allocator);
    }
    for (value.list) |item| {
        var key = lookupPathValue(item, attrName);
        if (key == .missing) {
            if (!hasDefault) return error.RenderError;
            key = default;
        }
        var found: ?usize = null;
        for (groupKeys.items, 0..) |gk, gi| {
            if (key == .string and gk == .string and !caseSensitive) {
                if (std.ascii.eqlIgnoreCase(gk.string, key.string)) {
                    found = gi;
                    break;
                }
            } else if (key.equals(gk)) {
                found = gi;
                break;
            }
        }
        if (found) |fi| {
            try members.items[fi].append(allocator, item);
        } else {
            var mem = std.ArrayList(Value).empty;
            errdefer mem.deinit(allocator);
            try mem.append(allocator, item);
            errdefer members.deinit(allocator);
            try members.append(allocator, mem);
            errdefer _ = members.pop();
            try groupKeys.append(allocator, key);
        }
    }
    var groups = std.ArrayList(Value).empty;
    errdefer groups.deinit(allocator);
    for (groupKeys.items, 0..) |key, gi| {
        const entries = try allocator.alloc(contextMod.Entry, 2);
        errdefer allocator.free(entries);
        entries[0] = .{ .key = "grouper", .value = key };
        entries[1] = .{ .key = "list", .value = .{ .list = try members.items[gi].toOwnedSlice(allocator) } };
        try groups.append(allocator, .{ .map = entries });
    }
    for (members.items) |*m| m.deinit(allocator);
    members.deinit(allocator);
    return .{ .list = try groups.toOwnedSlice(allocator) };
}

fn filterIndent(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const width: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "width", 4);
        break :blk if (raw < 0) 0 else @intCast(raw);
    };
    const first = boolFilterParam(args, kwargs, 1, "first", false);
    const blank = boolFilterParam(args, kwargs, 2, "blank", false);
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx > 0) try out.append(allocator, '\n');
        if ((idx > 0 or first) and (line.len > 0 or blank)) {
            var k: usize = 0;
            while (k < width) : (k += 1) try out.append(allocator, ' ');
        }
        try out.appendSlice(allocator, line);
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterList(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = args;
    _ = kwargs;
    switch (value) {
        .list => return value,
        .string => |s| {
            var out = std.ArrayList(Value).empty;
            errdefer out.deinit(allocator);
            try appendUtf8Chars(&out, allocator, s);
            return .{ .list = try out.toOwnedSlice(allocator) };
        },
        .rawHtml => |h| {
            var out = std.ArrayList(Value).empty;
            errdefer out.deinit(allocator);
            try appendUtf8Chars(&out, allocator, h);
            return .{ .list = try out.toOwnedSlice(allocator) };
        },
        .map => |entries| {
            var out = std.ArrayList(Value).empty;
            errdefer out.deinit(allocator);
            for (entries) |e| try out.append(allocator, .{ .string = e.key });
            return .{ .list = try out.toOwnedSlice(allocator) };
        },
        else => return error.RenderError,
    }
}

fn filterMapAttr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .list) return error.RenderError;
    const attrName: []const u8 = blk: {
        if (args.len > 0) {
            break :blk switch (args[0]) {
                .string => |s| s,
                .rawHtml => |h| h,
                else => return error.RenderError,
            };
        }
        if (filterKwarg(kwargs, "attribute")) |v| {
            break :blk switch (v) {
                .string => |s| s,
                .rawHtml => |h| h,
                else => return error.RenderError,
            };
        }
        return error.RenderError;
    };
    const hasDefault = args.len > 1 or filterKwarg(kwargs, "default") != null;
    const default: Value = if (args.len > 1) args[1] else if (filterKwarg(kwargs, "default")) |v| v else .missing;
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    for (value.list) |item| {
        const v = lookupPathValue(item, attrName);
        if (v == .missing and !hasDefault) return error.RenderError;
        try out.append(allocator, if (v == .missing) default else v);
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterMaxMin(_: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg, wantMax: bool) !Value {
    if (value != .list or value.list.len == 0) return error.RenderError;
    var attrName: ?[]const u8 = null;
    if (args.len > 0) {
        attrName = switch (args[0]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "attribute")) |v| {
        attrName = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    }
    const caseSensitive = boolFilterParam(args, kwargs, 1, "case_sensitive", false);
    var best = value.list[0];
    var bestKey = if (attrName) |a| lookupPathValue(best, a) else best;
    if (attrName != null and bestKey == .missing) return error.RenderError;
    for (value.list[1..]) |item| {
        const key = if (attrName) |a| lookupPathValue(item, a) else item;
        if (attrName != null and key == .missing) return error.RenderError;
        const o = orderValues(key, bestKey, caseSensitive);
        if ((wantMax and o == .gt) or (!wantMax and o == .lt)) {
            best = item;
            bestKey = key;
        }
    }
    return best;
}

fn filterMax(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterMaxMin(allocator, value, args, kwargs, true);
}

fn filterMin(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterMaxMin(allocator, value, args, kwargs, false);
}

fn filterPprint(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const verbose = boolFilterParam(args, kwargs, 0, "verbose", false);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendPprint(&out, allocator, value, verbose);
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterRandom(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = allocator;
    _ = args;
    _ = kwargs;
    if (value != .list or value.list.len == 0) return error.RenderError;
    var h = std.hash.Wyhash.init(
        @as(u64, @bitCast(clockMod.millisNow())) ^ @as(u64, @intCast(@intFromPtr(value.list.ptr))) ^ @as(u64, @intCast(value.list.len)),
    );
    var n: usize = 0;
    for (value.list) |item| {
        if (n >= 8) break;
        h.update(std.mem.asBytes(&@as(u64, @intFromEnum(item))));
        n += 1;
    }
    var seed = h.final();
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    if (seed == 0) seed = 0x9E3779B97F4A7C15;
    return value.list[seed % value.list.len];
}

fn filterSelectReject(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg, want: bool) !Value {
    _ = kwargs;
    if (value != .list) return error.RenderError;
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    if (args.len == 0) {
        for (value.list) |item| {
            if (item.isTruthy() == want) try out.append(allocator, item);
        }
        return .{ .list = try out.toOwnedSlice(allocator) };
    }
    const testName: []const u8 = switch (args[0]) {
        .string => |s| s,
        .rawHtml => |h| h,
        else => return error.RenderError,
    };
    for (value.list) |item| {
        const r = try testValue(item, testName, args[1..]);
        if (r == want) try out.append(allocator, item);
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterSelect(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterSelectReject(allocator, value, args, kwargs, true);
}

fn filterReject(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterSelectReject(allocator, value, args, kwargs, false);
}

fn filterSelectAttrRejectAttr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg, want: bool) !Value {
    _ = kwargs;
    if (value != .list) return error.RenderError;
    if (args.len < 1) return error.RenderError;
    const attrName: []const u8 = switch (args[0]) {
        .string => |s| s,
        .rawHtml => |h| h,
        else => return error.RenderError,
    };
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    for (value.list) |item| {
        const attr = lookupPathValue(item, attrName);
        var keep: bool = undefined;
        if (args.len < 2) {
            keep = attr.isTruthy();
        } else {
            const testName: []const u8 = switch (args[1]) {
                .string => |s| s,
                .rawHtml => |h| h,
                else => return error.RenderError,
            };
            keep = try testValue(attr, testName, args[2..]);
        }
        if (keep == want) try out.append(allocator, item);
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterSelectattr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterSelectAttrRejectAttr(allocator, value, args, kwargs, true);
}

fn filterRejectattr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    return filterSelectAttrRejectAttr(allocator, value, args, kwargs, false);
}

fn filterSum(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = allocator;
    if (value != .list) return error.RenderError;
    var attrName: ?[]const u8 = null;
    if (args.len > 0) {
        attrName = switch (args[0]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "attribute")) |v| {
        attrName = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    }
    var startFloat: ?f64 = null;
    var startInt: i64 = 0;
    if (args.len > 1) {
        switch (args[1]) {
            .integer => |i| startInt = i,
            .float => |f| startFloat = f,
            else => return error.RenderError,
        }
    } else if (filterKwarg(kwargs, "start")) |v| {
        switch (v) {
            .integer => |i| startInt = i,
            .float => |f| startFloat = f,
            else => return error.RenderError,
        }
    }
    var accInt = startInt;
    var accFloat: f64 = startFloat orelse 0.0;
    var useFloat = startFloat != null;
    for (value.list) |item| {
        const v = if (attrName) |a| lookupPathValue(item, a) else item;
        switch (v) {
            .integer => |i| {
                if (useFloat) {
                    accFloat += @floatFromInt(i);
                } else {
                    accInt +%= i;
                }
            },
            .float => |f| {
                if (!useFloat) {
                    useFloat = true;
                    accFloat = @floatFromInt(accInt);
                }
                accFloat += f;
            },
            else => return error.RenderError,
        }
    }
    if (useFloat) return .{ .float = accFloat };
    return .{ .integer = accInt };
}

fn filterToJson(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    var indent: ?usize = null;
    if (filterKwarg(kwargs, "indent")) |v| {
        const raw = filterIntValue(v, -1);
        if (raw < 0) return error.RenderError;
        indent = @intCast(raw);
    } else if (args.len > 0) {
        const raw = filterIntValue(args[0], -1);
        if (raw < 0) return error.RenderError;
        indent = @intCast(raw);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeJsonValue(&out, allocator, value, indent, 0);
    return .{ .rawHtml = try out.toOwnedSlice(allocator) };
}

fn filterUnique(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .list) return error.RenderError;
    var attrName: ?[]const u8 = null;
    if (args.len > 0) {
        attrName = switch (args[0]) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    } else if (filterKwarg(kwargs, "attribute")) |v| {
        attrName = switch (v) {
            .string => |s| s,
            .rawHtml => |h| h,
            else => return error.RenderError,
        };
    }
    const caseSensitive = boolFilterParam(args, kwargs, 1, "case_sensitive", false);
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(allocator);
    for (value.list) |item| {
        const key = if (attrName) |a| lookupPathValue(item, a) else item;
        var dup = false;
        for (out.items) |seen| {
            const skey = if (attrName) |a| lookupPathValue(seen, a) else seen;
            if (key == .string and skey == .string and !caseSensitive) {
                if (std.ascii.eqlIgnoreCase(key.string, skey.string)) {
                    dup = true;
                    break;
                }
            } else if (key.equals(skey)) {
                dup = true;
                break;
            }
        }
        if (!dup) try out.append(allocator, item);
    }
    return .{ .list = try out.toOwnedSlice(allocator) };
}

fn filterUrlencode(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = args;
    _ = kwargs;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    switch (value) {
        .string => |s| try appendPercentEncoded(&out, allocator, s),
        .rawHtml => |h| try appendPercentEncoded(&out, allocator, h),
        .map => |entries| {
            for (entries, 0..) |e, i| {
                if (i > 0) try out.append(allocator, '&');
                try appendPercentEncoded(&out, allocator, e.key);
                try out.append(allocator, '=');
                const vs = try filterStringValue(allocator, e.value);
                defer allocator.free(vs);
                try appendPercentEncoded(&out, allocator, vs);
            }
        },
        .list => |items| {
            for (items, 0..) |item, i| {
                if (item != .list or item.list.len != 2) return error.RenderError;
                if (i > 0) try out.append(allocator, '&');
                const ks = try filterStringValue(allocator, item.list[0]);
                defer allocator.free(ks);
                const vs = try filterStringValue(allocator, item.list[1]);
                defer allocator.free(vs);
                try appendPercentEncoded(&out, allocator, ks);
                try out.append(allocator, '=');
                try appendPercentEncoded(&out, allocator, vs);
            }
        },
        else => return error.RenderError,
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterWordcount(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    _ = args;
    _ = kwargs;
    _ = allocator;
    const s: []const u8 = switch (value) {
        .string => |x| x,
        .rawHtml => |x| x,
        else => return .{ .integer = 0 },
    };
    var count: i64 = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0B\x0C");
    while (it.next() != null) count += 1;
    return .{ .integer = count };
}

fn filterWordwrap(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    const width: usize = blk: {
        const raw = intFilterParam(args, kwargs, 0, "width", 79);
        break :blk if (raw <= 0) 79 else @intCast(raw);
    };
    const breakLong = boolFilterParam(args, kwargs, 1, "break_long_words", true);
    var wrapStr: []const u8 = "\n";
    var wrapOwned: ?[]u8 = null;
    defer if (wrapOwned) |w| allocator.free(w);
    if (filterKwarg(kwargs, "wrapstring")) |v| {
        wrapOwned = try filterStringValue(allocator, v);
        wrapStr = wrapOwned.?;
    } else if (args.len > 2) {
        wrapOwned = try filterStringValue(allocator, args[2]);
        wrapStr = wrapOwned.?;
    }
    const s = try filterStringValue(allocator, value);
    defer allocator.free(s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var paraIt = std.mem.splitScalar(u8, s, '\n');
    var firstPara = true;
    while (paraIt.next()) |para| {
        if (!firstPara) try out.appendSlice(allocator, wrapStr);
        firstPara = false;
        var lineLen: usize = 0;
        var firstWord = true;
        var wordIt = std.mem.tokenizeAny(u8, para, " \t\r");
        while (wordIt.next()) |word| {
            var w = word;
            while (w.len > 0) {
                const room = if (lineLen == 0) width else if (width > lineLen + 1) width - lineLen - 1 else 0;
                if (w.len <= room or lineLen == 0 and w.len <= width) {
                    if (!firstWord and lineLen > 0) {
                        try out.append(allocator, ' ');
                        lineLen += 1;
                    }
                    try out.appendSlice(allocator, w);
                    lineLen += w.len;
                    firstWord = false;
                    break;
                }
                if (!breakLong or lineLen > 0) {
                    try out.appendSlice(allocator, wrapStr);
                    lineLen = 0;
                    firstWord = true;
                    continue;
                }
                try out.appendSlice(allocator, w[0..width]);
                lineLen = width;
                w = w[width..];
                firstWord = false;
                if (w.len > 0) {
                    try out.appendSlice(allocator, wrapStr);
                    lineLen = 0;
                    firstWord = true;
                }
            }
        }
    }
    return .{ .string = try out.toOwnedSlice(allocator) };
}

fn filterXmlattr(allocator: Allocator, value: Value, args: []const Value, kwargs: []const FilterKwarg) !Value {
    if (value != .map) return error.RenderError;
    const autoescape = boolFilterParam(args, kwargs, 0, "autoescape", true);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value.map) |e| {
        if (e.value == .nullVal or e.value == .missing) continue;
        var badKey = false;
        for (e.key) |c| {
            if (c == '/' or c == '>' or c == '=' or c == ' ' or c == '"' or c == '\'') {
                badKey = true;
                break;
            }
        }
        if (badKey or e.key.len == 0) continue;
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, e.key);
        try out.appendSlice(allocator, "=\"");
        const vs = try filterStringValue(allocator, e.value);
        defer allocator.free(vs);
        if (autoescape) {
            for (vs) |c| {
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
        } else {
            try out.appendSlice(allocator, vs);
        }
        try out.append(allocator, '"');
    }
    // Jinja returns Markup here: attribute markup is already output-safe.
    return .{ .rawHtml = try out.toOwnedSlice(allocator) };
}

/// Shared Jinja test implementation usable from `is` expressions and
/// from the `select`/`reject` filter family.
fn testValue(value: Value, name: []const u8, args: []const Value) !bool {
    if (std.mem.eql(u8, name, "defined")) return value != .missing;
    if (std.mem.eql(u8, name, "undefined")) return value == .missing;
    if (std.mem.eql(u8, name, "none")) return value == .nullVal;
    if (std.mem.eql(u8, name, "true")) return value == .boolean and value.boolean;
    if (std.mem.eql(u8, name, "false")) return value == .boolean and !value.boolean;
    if (std.mem.eql(u8, name, "boolean")) return value == .boolean;
    if (std.mem.eql(u8, name, "integer")) return value == .integer;
    if (std.mem.eql(u8, name, "float")) return value == .float;
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, name, "string")) return value == .string or value == .rawHtml;
    if (std.mem.eql(u8, name, "lower")) {
        const s: []const u8 = switch (value) {
            .string => |x| x,
            .rawHtml => |x| x,
            else => return false,
        };
        var cased = false;
        for (s) |c| {
            if (std.ascii.isLower(c)) {
                cased = true;
            } else if (std.ascii.isUpper(c)) {
                return false;
            }
        }
        return cased;
    }
    if (std.mem.eql(u8, name, "upper")) {
        const s: []const u8 = switch (value) {
            .string => |x| x,
            .rawHtml => |x| x,
            else => return false,
        };
        var cased = false;
        for (s) |c| {
            if (std.ascii.isUpper(c)) {
                cased = true;
            } else if (std.ascii.isLower(c)) {
                return false;
            }
        }
        return cased;
    }
    if (std.mem.eql(u8, name, "sequence")) return value == .list or value == .string or value == .rawHtml;
    if (std.mem.eql(u8, name, "mapping")) return value == .map;
    if (std.mem.eql(u8, name, "iterable")) return value == .list or value == .string or value == .rawHtml or value == .map;
    if (std.mem.eql(u8, name, "callable")) return value == .macro;
    if (std.mem.eql(u8, name, "escaped")) return value == .rawHtml;
    if (std.mem.eql(u8, name, "odd")) return value == .integer and @rem(value.integer, 2) != 0;
    if (std.mem.eql(u8, name, "even")) return value == .integer and @rem(value.integer, 2) == 0;
    if (std.mem.eql(u8, name, "divisibleby")) {
        if (args.len < 1 or value != .integer) return false;
        const n: i64 = switch (args[0]) {
            .integer => |i| i,
            else => return false,
        };
        if (n == 0) return false;
        return @rem(value.integer, n) == 0;
    }
    if (std.mem.eql(u8, name, "eq") or std.mem.eql(u8, name, "equalto") or std.mem.eql(u8, name, "==")) {
        if (args.len < 1) return error.RenderError;
        return value.equals(args[0]);
    }
    if (std.mem.eql(u8, name, "ne") or std.mem.eql(u8, name, "!=")) {
        if (args.len < 1) return error.RenderError;
        return !value.equals(args[0]);
    }
    if (std.mem.eql(u8, name, "lt") or std.mem.eql(u8, name, "<")) {
        if (args.len < 1) return error.RenderError;
        return compareOrder(value, args[0]) == .lt;
    }
    if (std.mem.eql(u8, name, "le") or std.mem.eql(u8, name, "<=")) {
        if (args.len < 1) return error.RenderError;
        const o = compareOrder(value, args[0]);
        return o == .lt or o == .eq;
    }
    if (std.mem.eql(u8, name, "gt") or std.mem.eql(u8, name, ">")) {
        if (args.len < 1) return error.RenderError;
        return compareOrder(value, args[0]) == .gt;
    }
    if (std.mem.eql(u8, name, "ge") or std.mem.eql(u8, name, ">=")) {
        if (args.len < 1) return error.RenderError;
        const o = compareOrder(value, args[0]);
        return o == .gt or o == .eq;
    }
    if (std.mem.eql(u8, name, "sameas")) {
        if (args.len < 1) return error.RenderError;
        const other = args[0];
        if (std.meta.activeTag(value) != std.meta.activeTag(other)) return false;
        return value.equals(other);
    }
    if (std.mem.eql(u8, name, "in")) {
        if (args.len < 1) return error.RenderError;
        return valueContains(value, args[0]);
    }
    return error.RenderError;
}

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
    if (std.mem.eql(u8, name, "attr")) return filterAttr;
    if (std.mem.eql(u8, name, "batch")) return filterBatch;
    if (std.mem.eql(u8, name, "center")) return filterCenter;
    if (std.mem.eql(u8, name, "dictsort")) return filterDictsort;
    if (std.mem.eql(u8, name, "filesizeformat")) return filterFilesizeformat;
    if (std.mem.eql(u8, name, "forceescape")) return filterForceescape;
    if (std.mem.eql(u8, name, "format")) return filterFormat;
    if (std.mem.eql(u8, name, "groupby")) return filterGroupby;
    if (std.mem.eql(u8, name, "indent")) return filterIndent;
    if (std.mem.eql(u8, name, "list")) return filterList;
    if (std.mem.eql(u8, name, "map")) return filterMapAttr;
    if (std.mem.eql(u8, name, "max")) return filterMax;
    if (std.mem.eql(u8, name, "min")) return filterMin;
    if (std.mem.eql(u8, name, "pprint")) return filterPprint;
    if (std.mem.eql(u8, name, "random")) return filterRandom;
    if (std.mem.eql(u8, name, "reject")) return filterReject;
    if (std.mem.eql(u8, name, "rejectattr")) return filterRejectattr;
    if (std.mem.eql(u8, name, "select")) return filterSelect;
    if (std.mem.eql(u8, name, "selectattr")) return filterSelectattr;
    if (std.mem.eql(u8, name, "slice")) return filterSliceBatch;
    if (std.mem.eql(u8, name, "sum")) return filterSum;
    if (std.mem.eql(u8, name, "tojson")) return filterToJson;
    if (std.mem.eql(u8, name, "unique")) return filterUnique;
    if (std.mem.eql(u8, name, "urlencode")) return filterUrlencode;
    if (std.mem.eql(u8, name, "wordcount")) return filterWordcount;
    if (std.mem.eql(u8, name, "wordwrap")) return filterWordwrap;
    if (std.mem.eql(u8, name, "xmlattr")) return filterXmlattr;
    return null;
}

const MacroTable = struct {
    map: std.StringHashMap(parserMod.MacroDef),

    fn init(allocator: Allocator) MacroTable {
        return .{ .map = std.StringHashMap(parserMod.MacroDef).init(allocator) };
    }

    fn deinit(self: *MacroTable) void {
        self.map.deinit();
    }

    fn addIfAbsent(self: *MacroTable, def: parserMod.MacroDef) !void {
        if (!self.map.contains(def.name)) try self.map.put(def.name, def);
    }

    fn get(self: *const MacroTable, name: []const u8) ?parserMod.MacroDef {
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
    scope: *contextMod.Scope,
    /// Remaining same-name block bodies for `super()` to consume, from
    /// most-derived to base (built per block render).
    superChain: []const BlockInfo = &.{},
    /// The base template's own body for the current block: final `super()`
    /// fallback once the chain is exhausted.
    superBase: ?[]const TemplateNode = null,
    strict: bool = false,
    alloc: Allocator,
    root: Value,
    /// False inside `{% autoescape %}` regions when disabled.
    autoescape: bool = true,
    /// True while rendering an isolated macro body: name lookups must not
    /// fall back to the template root (Jinja macro isolation).
    macroIsolated: bool = false,
    /// True while rendering a `without context` include: same root
    /// suppression as macro isolation.
    includeIsolated: bool = false,
    /// Current `{% for %}` nesting depth (drives loop.depth/depth0).
    loopDepth: usize = 0,
    /// Active recursive-loop frame for `loop(...)` calls, if any.
    loopRecurse: ?*const LoopRecurse = null,
    /// Per-render macro call depth (recursion guard).
    macroDepth: usize = 0,
    /// Cap applied to intermediate buffers (set/call/super/macro bodies).
    outputCap: usize = 64 << 20,
    /// Cap on nested macro depth, copied from options at render start.
    maxMacroDepth: usize = 64,
    /// Cap on `range()` length, copied from options at render start.
    maxRangeItems: usize = 1 << 20,
    /// Receives the source location of the node being rendered when an
    /// error aborts the walk (engine surfaces it via lastError).
    errLoc: *?ErrLoc,
};

/// Source location captured for runtime error diagnostics.
pub const ErrLoc = struct {
    line: usize = 1,
    col: usize = 1,
    startByte: usize = 0,
};

/// Recursion frame for `{% for %}...recursive` loops.
pub const LoopRecurse = struct {
    info: *const parserMod.ForLoopInfo,
};

/// Strict boolean evaluation: in strict mode a missing operand is an
/// error (Jinja StrictUndefined semantics); otherwise plain truthiness.
/// `is defined`/`default` paths never produce `.missing` here, so they
/// keep working under strict mode.
fn truthyStrict(state: RenderState, v: Value) !bool {
    if (v == .missing and state.strict) return TemplateError.UnknownVariable;
    return v.isTruthy();
}

pub const Renderer = struct {
    options: RenderOptions = .{},
    filters: ?*const FilterRegistry = null,
    globals: ?*const GlobalMap = null,

    /// Renders a template AST directly to any writer. This is the single
    /// render entry point; custom filters and globals come from the
    /// renderer's own registry pointers. Output is capped at
    /// `options.maxOutputBytes`.
    pub fn render(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *Context,
        provider: ?TemplateProvider,
        writer: anytype,
    ) !void {
        comptime {
            if (@typeInfo(@TypeOf(ctx)).pointer.is_const) {
                @compileError(
                    "Renderer.render must take `*Context`: it mutates ctx.arena " ++
                        "through arenaAlloc below, and a `*const` parameter is emitted " ++
                        "as LLVM `readonly`, which lets callers prove " ++
                        "ctx.arena.state.used_list is still null and fold " ++
                        "`defer ctx.deinit()` away, leaking every arena node " ++
                        "pushed during the render.",
                );
            }
        }
        var depth: usize = 0;
        var chain = InheritChain{};
        var scope = contextMod.Scope{};
        const arenaAlloc = ctx.arena.allocator();
        defer scope.deinit(arenaAlloc);
        var macros = MacroTable.init(ctx.arena.child_allocator);
        defer macros.deinit();
        for (ast.macros) |m| try macros.addIfAbsent(m);
        var errLoc: ?ErrLoc = null;
        var counter = CountingWriter(@TypeOf(writer)){
            .inner = writer,
            .remaining = self.options.maxOutputBytes,
        };
        const state = RenderState{
            .provider = provider,
            // Empty seed: each inheritance level appends its own blocks,
            // preserving the full most-derived-first chain for super().
            .blockOverrides = &.{},
            .includeStack = &[0][]const u8{},
            .inheritanceDepth = &depth,
            .inheritChain = &chain,
            .macros = &macros,
            .filters = self.filters,
            .globals = self.globals,
            .scope = &scope,
            .strict = self.options.strictUndefined,
            .autoescape = self.options.autoescapeDefault,
            .alloc = arenaAlloc,
            .root = ctx.root,
            .outputCap = self.options.maxOutputBytes,
            .maxMacroDepth = self.options.maxMacroDepth,
            .maxRangeItems = self.options.maxRangeItems,
            .errLoc = &errLoc,
        };
        _ = try self.renderInternal(ast, ctx, state, &counter);
    }

    /// Renders a template AST to an allocated string.
    pub fn renderToString(
        self: Renderer,
        allocator: Allocator,
        ast: *const TemplateAst,
        ctx: *Context,
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
            const parentAst = p.getAst(parentPath) orelse return TemplateError.TemplateNotFound;

            // Full most-derived-first chain: descendant overrides keep
            // their order (no name dedup — intermediate same-name bodies
            // are needed for chained super() calls).
            var combinedBlocks = std.ArrayList(BlockInfo).empty;
            defer combinedBlocks.deinit(ctx.arena.child_allocator);

            for (state.blockOverrides) |b| {
                try combinedBlocks.append(ctx.arena.child_allocator, b);
            }
            for (ast.blocks) |b| {
                try combinedBlocks.append(ctx.arena.child_allocator, b);
            }
            for (parentAst.macros) |m| try state.macros.addIfAbsent(m);

            var next = state;
            next.blockOverrides = combinedBlocks.items;
            return self.renderInternal(parentAst, ctx, next, writer);
        }

        for (ast.macros) |m| try state.macros.addIfAbsent(m);
        return self.renderNodes(ast.nodes, ctx, state, writer);
    }

    fn noteLoc(state: RenderState, line: usize, col: usize, startByte: usize) void {
        state.errLoc.* = .{ .line = line, .col = col, .startByte = startByte };
        if (state.provider) |p| p.reportLoc(line, col, startByte);
    }

    /// Resolves a macro callee by plain or dotted name (`ns.wrap`) through
    /// the scope chain, imported namespaces and the macro table.
    fn resolveCallee(state: RenderState, name: []const u8) ?parserMod.MacroDef {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const head = name[0..dot];
            const rest = name[dot + 1 ..];
            const base = state.scope.getLocal(head) orelse return null;
            if (base != .map) return null;
            for (base.map) |e| {
                if (std.mem.eql(u8, e.key, rest) and e.value == .macro) return e.value.macro;
            }
            return null;
        }
        if (state.scope.getLocal(name)) |v| {
            if (v == .macro) return v.macro;
        }
        return state.macros.get(name);
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
                .expression => |exprInfo| {
                    noteLoc(state, exprInfo.line, exprInfo.col, exprInfo.startByte);
                    try self.renderExpression(exprInfo.expr, ctx, state, writer);
                },
                .ifBlock => |ifInfo| {
                    noteLoc(state, ifInfo.line, ifInfo.col, ifInfo.startByte);
                    const condVal = try self.evalExpr(ctx, state, ifInfo.condition);
                    if (try truthyStrict(state, condVal)) {
                        const f = try self.renderNodes(ifInfo.thenNodes, ctx, state, writer);
                        if (f != .normal) return f;
                    } else {
                        var taken = false;
                        for (ifInfo.elifBranches) |branch| {
                            const bv = try self.evalExpr(ctx, state, branch.condition);
                            if (try truthyStrict(state, bv)) {
                                const f = try self.renderNodes(branch.bodyNodes, ctx, state, writer);
                                if (f != .normal) return f;
                                taken = true;
                                break;
                            }
                        }
                        if (!taken and ifInfo.elseNodes.len > 0) {
                            const f = try self.renderNodes(ifInfo.elseNodes, ctx, state, writer);
                            if (f != .normal) return f;
                        }
                    }
                },
                .forLoop => |forInfo| {
                    const f = try self.renderForLoop(&forInfo, ctx, state, writer);
                    if (f != .normal) return f;
                },
                .set => |setInfo| {
                    noteLoc(state, setInfo.line, setInfo.col, setInfo.startByte);
                    // `{% set a, b = ... %}` unpacks a tuple/list pairwise.
                    if (std.mem.indexOfScalar(u8, setInfo.name, ',') != null) {
                        const parts = try parserMod.splitTopLevel(state.alloc, setInfo.name);
                        defer state.alloc.free(parts);
                        const wrapped = try std.fmt.allocPrint(state.alloc, "({s})", .{setInfo.valueExpr});
                        defer state.alloc.free(wrapped);
                        const val = try self.evalExpr(ctx, state, wrapped);
                        if (val != .list) return TemplateError.TypeMismatch;
                        for (parts, 0..) |pname, pi| {
                            const pv: Value = if (pi < val.list.len) val.list[pi] else .nullVal;
                            try state.scope.set(state.alloc, pname, pv);
                        }
                    } else {
                        const val = try self.evalExpr(ctx, state, setInfo.valueExpr);
                        try state.scope.set(state.alloc, setInfo.name, val);
                    }
                },
                .setBlock => |setInfo| {
                    noteLoc(state, setInfo.line, setInfo.col, setInfo.startByte);
                    var list = std.ArrayList(u8).empty;
                    defer list.deinit(state.alloc);
                    var lw = ListWriter{ .list = &list, .allocator = state.alloc };
                    var counter = CountingWriter(*ListWriter){ .inner = &lw, .remaining = state.outputCap };
                    _ = try self.renderNodes(setInfo.bodyNodes, ctx, state, &counter);
                    try state.scope.set(state.alloc, setInfo.name, .{ .rawHtml = try list.toOwnedSlice(state.alloc) });
                },
                .call => |callInfo| {
                    noteLoc(state, callInfo.line, callInfo.col, callInfo.startByte);
                    var args = std.ArrayList(Value).empty;
                    defer args.deinit(state.alloc);
                    var kwargs = std.ArrayList(CallKwarg).empty;
                    defer kwargs.deinit(state.alloc);
                    for (callInfo.args) |a| {
                        const v = try self.evalExpr(ctx, state, a.value);
                        if (a.name) |nm| {
                            try kwargs.append(state.alloc, .{ .name = nm, .value = v });
                        } else {
                            try args.append(state.alloc, v);
                        }
                    }
                    // Caller parameters declared via `{% call(item) %}` become
                    // the caller pseudo-macro's signature; the body always
                    // renders in the caller's scope (with template context).
                    // NOTE: the body is intentionally NOT pre-rendered here:
                    // it renders lazily at each `caller()` invocation so
                    // caller parameters (and caller ambient state) are bound.
                    const callerParamDefs = try state.alloc.alloc(parserMod.MacroParam, callInfo.callerParams.len);
                    for (callInfo.callerParams, 0..) |pname, pi| callerParamDefs[pi] = .{ .name = pname };
                    var callScope = contextMod.Scope{ .parent = state.scope };
                    defer callScope.deinit(state.alloc);
                    try callScope.set(state.alloc, "caller", .{ .macro = .{
                        .name = "caller",
                        .params = callerParamDefs,
                        .bodyNodes = callInfo.bodyNodes,
                        .withContext = true,
                        .startByte = callInfo.startByte,
                        .line = callInfo.line,
                        .col = callInfo.col,
                    } });
                    var callState = state;
                    callState.scope = &callScope;
                    const calleeDef = resolveCallee(state, callInfo.name) orelse return TemplateError.UnknownVariable;
                    const out = try self.renderMacroWithScope(ctx, callState, calleeDef, args.items, kwargs.items, &callScope);
                    // Call-block output is statement-level markup like includes.
                    switch (out) {
                        .string => |s| try writer.writeAll(s),
                        .rawHtml => |h| try writer.writeAll(h),
                        else => try writeValue(out, writer, state.autoescape),
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
                .block => |blockInfo| {
                    noteLoc(state, blockInfo.line, blockInfo.col, blockInfo.startByte);
                    // Same-name override chain for this block, most-derived
                    // first; the base body is the final super() fallback.
                    var chain = std.ArrayList(BlockInfo).empty;
                    defer chain.deinit(state.alloc);
                    for (state.blockOverrides) |ov| {
                        if (std.mem.eql(u8, ov.name, blockInfo.name)) {
                            try chain.append(state.alloc, ov);
                        }
                    }
                    var next = state;
                    if (chain.items.len > 0) {
                        next.superChain = chain.items[1..];
                        next.superBase = blockInfo.bodyNodes;
                        const f = try self.renderNodes(chain.items[0].nodes, ctx, next, writer);
                        if (f != .normal) return f;
                    } else {
                        next.superChain = &.{};
                        next.superBase = null;
                        const f = try self.renderNodes(blockInfo.bodyNodes, ctx, next, writer);
                        if (f != .normal) return f;
                    }
                },
                .extends => {},
                .include => |incInfo| {
                    noteLoc(state, incInfo.line, incInfo.col, incInfo.startByte);
                    if (state.includeStack.len >= self.options.maxIncludeDepth) {
                        return TemplateError.DepthLimitExceeded;
                    }
                    const incPath: []const u8 = if (incInfo.pathIsExpr) blk: {
                        const pv = try self.evalExpr(ctx, state, incInfo.templatePath);
                        break :blk switch (pv) {
                            .string => |s| s,
                            .rawHtml => |h| h,
                            else => return TemplateError.TypeMismatch,
                        };
                    } else incInfo.templatePath;
                    for (state.includeStack) |item| {
                        if (std.mem.eql(u8, item, incPath)) {
                            return TemplateError.CircularInclude;
                        }
                    }

                    const p = state.provider orelse return TemplateError.TemplateNotFound;
                    if (p.getAst(incPath)) |incAst| {
                        for (incAst.macros) |m| try state.macros.addIfAbsent(m);

                        const newStack = try ctx.arena.child_allocator.alloc([]const u8, state.includeStack.len + 1);
                        defer ctx.arena.child_allocator.free(newStack);
                        @memcpy(newStack[0..state.includeStack.len], state.includeStack);
                        newStack[state.includeStack.len] = incPath;

                        var next = state;
                        next.blockOverrides = &[_]BlockInfo{};
                        next.includeStack = newStack;
                        // A `without context` include renders in a fresh,
                        // parentless scope. The scope must outlive the
                        // renderInternal call below (it is not a temporary).
                        var freshScope = contextMod.Scope{};
                        defer freshScope.deinit(state.alloc);
                        // Only `without context` changes visibility: the flag
                        // otherwise inherits the current region (an include
                        // inside an isolated macro stays isolated).
                        if (incInfo.withContext) |with| {
                            if (!with) {
                                next.scope = &freshScope;
                                next.includeIsolated = true;
                            }
                        }
                        const f = try self.renderInternal(incAst, ctx, next, writer);
                        if (f != .normal) return f;
                    } else if (!incInfo.ignoreMissing) {
                        return TemplateError.TemplateNotFound;
                    }
                    // Missing template with `ignore missing`: emit nothing and
                    // continue with the following nodes.
                },
                .importAs => |impInfo| {
                    noteLoc(state, impInfo.line, impInfo.col, impInfo.startByte);
                    const p = state.provider orelse return TemplateError.TemplateNotFound;
                    const targetAst = p.getAst(impInfo.templatePath) orelse return TemplateError.TemplateNotFound;
                    var entries = std.ArrayList(contextMod.Entry).empty;
                    errdefer entries.deinit(state.alloc);
                    for (targetAst.macros) |m| {
                        var owned = m;
                        owned.withContext = impInfo.withContext;
                        try state.macros.addIfAbsent(owned);
                        try entries.append(state.alloc, .{ .key = m.name, .value = .{ .macro = owned } });
                    }
                    try state.scope.set(state.alloc, impInfo.alias, .{ .map = try entries.toOwnedSlice(state.alloc) });
                },
                .fromImport => |impInfo| {
                    noteLoc(state, impInfo.line, impInfo.col, impInfo.startByte);
                    const p = state.provider orelse return TemplateError.TemplateNotFound;
                    const targetAst = p.getAst(impInfo.templatePath) orelse return TemplateError.TemplateNotFound;
                    for (impInfo.names) |named| {
                        var found: ?parserMod.MacroDef = null;
                        for (targetAst.macros) |m| {
                            if (std.mem.eql(u8, m.name, named.name)) {
                                found = m;
                                break;
                            }
                        }
                        var def = found orelse return TemplateError.UnknownVariable;
                        def.withContext = impInfo.withContext;
                        try state.macros.addIfAbsent(def);
                        try state.scope.set(state.alloc, named.alias orelse named.name, .{ .macro = def });
                    }
                },
                .filterBlock => |filterInfo| {
                    noteLoc(state, filterInfo.line, filterInfo.col, filterInfo.startByte);
                    var list = std.ArrayList(u8).empty;
                    defer list.deinit(state.alloc);
                    var lw = ListWriter{ .list = &list, .allocator = state.alloc };
                    var counter = CountingWriter(*ListWriter){ .inner = &lw, .remaining = state.outputCap };
                    _ = try self.renderNodes(filterInfo.bodyNodes, ctx, state, &counter);
                    const bodyText = try list.toOwnedSlice(state.alloc);
                    var sub = ExprParser{ .src = filterInfo.filterExpr, .renderer = &self, .ctx = ctx, .state = state };
                    const filtered = try sub.parseFilterSpec(.{ .string = bodyText });
                    if (!sub.eof()) return TemplateError.SyntaxError;
                    switch (filtered) {
                        .string => |s| try writer.writeAll(s),
                        .rawHtml => |h| try writer.writeAll(h),
                        else => try writeValue(filtered, writer, state.autoescape),
                    }
                },
                .withBlock => |withInfo| {
                    noteLoc(state, withInfo.line, withInfo.col, withInfo.startByte);
                    var childScope = contextMod.Scope{ .parent = state.scope };
                    defer childScope.deinit(state.alloc);
                    for (withInfo.assigns) |a| {
                        const v = try self.evalExpr(ctx, state, a.value);
                        try childScope.set(state.alloc, a.name.?, v);
                    }
                    var next = state;
                    next.scope = &childScope;
                    const f = try self.renderNodes(withInfo.bodyNodes, ctx, next, writer);
                    if (f != .normal) return f;
                },
                .autoescapeBlock => |aeInfo| {
                    noteLoc(state, aeInfo.line, aeInfo.col, aeInfo.startByte);
                    var next = state;
                    next.autoescape = aeInfo.enabled;
                    const f = try self.renderNodes(aeInfo.bodyNodes, ctx, next, writer);
                    if (f != .normal) return f;
                },
            }
        }
        return .normal;
    }

    fn writeValue(val: Value, writer: anytype, autoescape: bool) !void {
        switch (val) {
            .nullVal => {},
            .missing => {},
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| if (autoescape) try writeEscaped(writer, s) else try writer.writeAll(s),
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
        try writeValue(val, writer, state.autoescape);
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
        // Isolated macro bodies and `without context` includes cannot see
        // template data; macros imported `with context` (and caller
        // blocks) may.
        if (state.macroIsolated or state.includeIsolated) return .missing;
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
                return if (try truthyStrict(self.state, cond)) first else alt;
            }
            return first;
        }

        fn parseOr(self: *ExprParser) anyerror!Value {
            var left = try self.parseAnd();
            while (self.eatWord("or")) {
                const right = try self.parseAnd();
                left = if (try truthyStrict(self.state, left)) left else right;
            }
            return left;
        }

        fn parseAnd(self: *ExprParser) anyerror!Value {
            var left = try self.parseNot();
            while (self.eatWord("and")) {
                const right = try self.parseNot();
                left = if (!(try truthyStrict(self.state, left))) left else right;
            }
            return left;
        }

        fn parseNot(self: *ExprParser) anyerror!Value {
            self.skipWs();
            const save = self.pos;
            if (self.eatWord("not")) {
                const inner = try self.parseNot();
                return .{ .boolean = !(try truthyStrict(self.state, inner)) };
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
            const testName = self.parseName() orelse return error.RenderError;
            // Tests may take call arguments: `is divisibleby(3)`, `is in(items)`.
            var testArgs = std.ArrayList(Value).empty;
            defer testArgs.deinit(self.state.alloc);
            if (self.eatOp("(")) {
                self.skipWs();
                if (!(self.pos < self.src.len and self.src[self.pos] == ')')) {
                    while (true) {
                        try testArgs.append(self.state.alloc, try self.parseTernary());
                        self.skipWs();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        }
                        break;
                    }
                }
                self.skipWs();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.RenderError;
                self.pos += 1;
            }
            const result = try self.evalTestWithArgs(left, testName, testArgs.items);
            return .{ .boolean = if (negated) !result else result };
        }

        fn evalTest(self: *ExprParser, value: Value, name: []const u8) !bool {
            return self.evalTestWithArgs(value, name, &.{});
        }

        fn evalTestWithArgs(self: *ExprParser, value: Value, name: []const u8, args: []const Value) !bool {
            _ = self;
            return testValue(value, name, args);
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
                    // A second `*` belongs to `**`, which parsePow owns;
                    // back up and let the pow level handle it.
                    if (self.pos < self.src.len and self.src[self.pos] == '*') {
                        self.pos -= 1;
                        break;
                    }
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
            return self.parsePow();
        }

        /// Exponentiation: right-associative and binding tighter than
        /// unary sign (Python/Jinja semantics: `-2**2 == -4`,
        /// `2**3**2 == 512`). The left operand excludes unary signs;
        /// the right operand allows them (`2**-2 == 0.5`).
        fn parsePow(self: *ExprParser) anyerror!Value {
            const left = try self.parseFilter();
            if (!self.eatOp("**")) return left;
            const right = try self.parseUnary();
            return try numericBinop(left, right, .pow);
        }

        fn parseFilter(self: *ExprParser) anyerror!Value {
            const val = try self.parsePostfix();
            return self.parseFilterChain(val);
        }

        /// Applies a `|name(args, key=value)...` chain to an initial value.
        /// Shared by expression filters and `{% filter %}` blocks.
        fn parseFilterChain(self: *ExprParser, initial: Value) anyerror!Value {
            var val = initial;
            while (self.eatOp("|")) {
                val = try self.applyOneFilter(val);
            }
            return val;
        }

        /// Parses a filter specification (`name(args)` plus `|...` chains)
        /// as used by `{% filter %}` blocks.
        fn parseFilterSpec(self: *ExprParser, initial: Value) anyerror!Value {
            var val = try self.applyOneFilter(initial);
            while (self.eatOp("|")) {
                val = try self.applyOneFilter(val);
            }
            return val;
        }

        fn applyOneFilter(self: *ExprParser, val: Value) anyerror!Value {
            const fname = self.parseName() orelse return error.RenderError;
            var args = std.ArrayList(Value).empty;
            defer args.deinit(self.state.alloc);
            var kwargs = std.ArrayList(FilterKwarg).empty;
            defer kwargs.deinit(self.state.alloc);
            if (self.eatOp("(")) {
                try self.parseFilterArgs(&args, &kwargs);
                if (!self.eatOp(")")) return error.RenderError;
            }
            const func = self.renderer.lookupFilter(self.state, fname) orelse return error.RenderError;
            return try func(self.state.alloc, val, args.items, kwargs.items);
        }

        fn parseFilterArgs(self: *ExprParser, args: *std.ArrayList(Value), kwargs: *std.ArrayList(FilterKwarg)) !void {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') return;
            while (true) {
                const save = self.pos;
                if (self.parseName()) |nm| {
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
                    const val = try self.renderer.evalCallNamed(self.ctx, self.state, nm, args.items, kwargs.items);
                    return try self.parsePostfixChain(val);
                }
                self.pos = save;
            }
            const val = try self.parsePrimary();
            return try self.parsePostfixChain(val);
        }

        /// Handles `.attr`, `.method(args)`, and `[index]` chains after any
        /// primary value (names, calls, literals, groupings).
        fn parsePostfixChain(self: *ExprParser, initial: Value) anyerror!Value {
            var val = initial;
            while (true) {
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == '.') {
                    self.pos += 1;
                    const attr = self.parseName() orelse return error.RenderError;
                    self.skipWs();
                    if (self.pos < self.src.len and self.src[self.pos] == '(') {
                        self.pos += 1;
                        var args = std.ArrayList(Value).empty;
                        defer args.deinit(self.state.alloc);
                        var kwargs = std.ArrayList(CallKwarg).empty;
                        defer kwargs.deinit(self.state.alloc);
                        try self.parseCallArgsFull(&args, &kwargs);
                        if (!self.eatOp(")")) return error.RenderError;
                        val = try self.renderer.evalMethodCall(self.ctx, self.state, val, attr, args.items, kwargs.items);
                        continue;
                    }
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

        fn parsePrimary(self: *ExprParser) anyerror!Value {
            self.skipWs();
            if (self.pos >= self.src.len) return error.RenderError;
            const c = self.src[self.pos];
            if (c == '(') {
                self.pos += 1;
                self.skipWs();
                // Empty tuple `()`.
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                    return .{ .list = &.{} };
                }
                const first = try self.parseTernary();
                self.skipWs();
                // A top-level comma makes this a tuple literal `(1, 2)`,
                // `(1,)`; otherwise it is a plain grouping `(x)`.
                if (self.pos >= self.src.len or self.src[self.pos] != ',') {
                    if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.RenderError;
                    self.pos += 1;
                    return first;
                }
                var items = std.ArrayList(Value).empty;
                errdefer items.deinit(self.state.alloc);
                try items.append(self.state.alloc, first);
                while (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    self.skipWs();
                    if (self.pos < self.src.len and self.src[self.pos] == ')') break;
                    try items.append(self.state.alloc, try self.parseTernary());
                    self.skipWs();
                }
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.RenderError;
                self.pos += 1;
                return .{ .list = try items.toOwnedSlice(self.state.alloc) };
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
                var entries = std.ArrayList(contextMod.Entry).empty;
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
                    const keyStr = try filterStringValue(self.state.alloc, key);
                    try entries.append(self.state.alloc, .{ .key = keyStr, .value = kval });
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
            var isFloat = false;
            if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                isFloat = true;
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            }
            if (!isFloat) {
                return .{ .integer = std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch return error.RenderError };
            }
            return .{ .float = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return error.RenderError };
        }

        fn parseCallArgsFull(self: *ExprParser, args: *std.ArrayList(Value), kwargs: *std.ArrayList(CallKwarg)) !void {
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == ')') return;
            while (true) {
                const save = self.pos;
                if (self.parseName()) |nm| {
                    const afterName = self.pos;
                    _ = afterName;
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

    const NumOp = enum { add, sub, mul, div, floorDiv, mod, pow };

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
        const bothInt = left == .integer and right == .integer;
        switch (op) {
            .add => {
                if (bothInt) return .{ .integer = left.integer +% right.integer };
                return .{ .float = lf.? + rf.? };
            },
            .sub => {
                if (bothInt) return .{ .integer = left.integer -% right.integer };
                return .{ .float = lf.? - rf.? };
            },
            .mul => {
                if (bothInt) return .{ .integer = left.integer *% right.integer };
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
                if (bothInt) {
                    if (right.integer == 0) return .nullVal;
                    return .{ .integer = @mod(left.integer, right.integer) };
                }
                if (rf.? == 0) return .nullVal;
                return .{ .float = @mod(lf.?, rf.?) };
            },
            .pow => {
                if (bothInt and right.integer >= 0) {
                    var acc: i64 = 1;
                    var base = left.integer;
                    var exp = right.integer;
                    var overflow = false;
                    while (exp > 0) {
                        if (exp & 1 == 1) {
                            const r = @mulWithOverflow(acc, base);
                            acc = r[0];
                            overflow = overflow or r[1] != 0;
                        }
                        exp >>= 1;
                        if (exp > 0) {
                            const r = @mulWithOverflow(base, base);
                            base = r[0];
                            overflow = overflow or r[1] != 0;
                        }
                    }
                    if (!overflow) return .{ .integer = acc };
                }
                return .{ .float = std.math.pow(f64, lf.?, rf.?) };
            },
        }
    }

    fn evalCallNamed(self: Renderer, ctx: *const Context, state: RenderState, name: []const u8, args: []const Value, kwargs: []const CallKwarg) anyerror!Value {
        if (std.mem.eql(u8, name, "super")) {
            if (args.len != 0 or kwargs.len != 0) return error.RenderError;
            var list = std.ArrayList(u8).empty;
            defer list.deinit(state.alloc);
            var lw = ListWriter{ .list = &list, .allocator = state.alloc };
            var counter = CountingWriter(*ListWriter){ .inner = &lw, .remaining = state.outputCap };
            if (state.superChain.len > 0) {
                var next = state;
                next.superChain = state.superChain[1..];
                _ = try self.renderNodes(state.superChain[0].nodes, ctx, next, &counter);
            } else if (state.superBase) |base| {
                var next = state;
                next.superBase = null;
                _ = try self.renderNodes(base, ctx, next, &counter);
            }
            return .{ .rawHtml = try list.toOwnedSlice(state.alloc) };
        }
        // Recursive-loop driver: `loop(seq)` re-renders the enclosing
        // recursive loop body over a new sequence (one level deeper).
        if (std.mem.eql(u8, name, "loop")) {
            const frame = state.loopRecurse orelse return .nullVal;
            if (args.len != 1 or kwargs.len != 0) return error.RenderError;
            if (args[0] != .list) return error.RenderError;
            var items = args[0].list;
            var filtered: ?[]Value = null;
            defer if (filtered) |f| state.alloc.free(f);
            if (frame.info.filterExpr != null) {
                items = try self.filterLoopItems(ctx, state, frame.info, items);
                filtered = @constCast(items);
            }
            var list = std.ArrayList(u8).empty;
            defer list.deinit(state.alloc);
            var lw = ListWriter{ .list = &list, .allocator = state.alloc };
            var counter = CountingWriter(*ListWriter){ .inner = &lw, .remaining = state.outputCap };
            var next = state;
            next.loopDepth = state.loopDepth + 1;
            _ = try self.renderForItems(frame.info, items, ctx, next, &counter);
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
                return entry.func(entry.userData, state.alloc, args, gkwargs.items);
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
            // Memory guard: materializing gigantic ranges would exhaust the arena.
            const est: i64 = if (step > 0) @divFloor(stop - start + step - 1, step) else @divFloor(start - stop - step - 1, -step);
            if (est < 0 or est > @as(i64, @intCast(state.maxRangeItems))) return TemplateError.SizeLimitExceeded;
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

    /// Method calls on values: import-namespace macros (`ns.wrap(...)`)
    /// and builtin map methods (`items()`, `keys()`, `values()`, `get()`).
    fn evalMethodCall(self: Renderer, ctx: *const Context, state: RenderState, base: Value, name: []const u8, args: []const Value, kwargs: []const CallKwarg) anyerror!Value {
        if (base == .map) {
            for (base.map) |e| {
                if (std.mem.eql(u8, e.key, name)) {
                    if (e.value == .macro) {
                        return self.renderMacro(ctx, state, e.value.macro, args, kwargs);
                    }
                    break;
                }
            }
            if (std.mem.eql(u8, name, "items")) {
                if (args.len != 0 or kwargs.len != 0) return error.RenderError;
                var out = std.ArrayList(Value).empty;
                errdefer out.deinit(state.alloc);
                for (base.map) |e| {
                    const pair = try state.alloc.alloc(Value, 2);
                    errdefer state.alloc.free(pair);
                    pair[0] = .{ .string = e.key };
                    pair[1] = e.value;
                    try out.append(state.alloc, .{ .list = pair });
                }
                return .{ .list = try out.toOwnedSlice(state.alloc) };
            }
            if (std.mem.eql(u8, name, "keys")) {
                if (args.len != 0 or kwargs.len != 0) return error.RenderError;
                var out = std.ArrayList(Value).empty;
                errdefer out.deinit(state.alloc);
                for (base.map) |e| try out.append(state.alloc, .{ .string = e.key });
                return .{ .list = try out.toOwnedSlice(state.alloc) };
            }
            if (std.mem.eql(u8, name, "values")) {
                if (args.len != 0 or kwargs.len != 0) return error.RenderError;
                var out = std.ArrayList(Value).empty;
                errdefer out.deinit(state.alloc);
                for (base.map) |e| try out.append(state.alloc, e.value);
                return .{ .list = try out.toOwnedSlice(state.alloc) };
            }
            if (std.mem.eql(u8, name, "get")) {
                if (args.len < 1) return error.RenderError;
                const key: []const u8 = switch (args[0]) {
                    .string => |s| s,
                    .rawHtml => |h| h,
                    else => {
                        if (args.len > 1) return args[1];
                        if (kwargs.len > 0) {
                            var di: usize = 0;
                            while (di < kwargs.len) : (di += 1) {
                                if (std.mem.eql(u8, kwargs[di].name, "default")) return kwargs[di].value;
                            }
                        }
                        return .missing;
                    },
                };
                for (base.map) |e| {
                    if (std.mem.eql(u8, e.key, key)) return e.value;
                }
                if (args.len > 1) return args[1];
                for (kwargs) |kw| {
                    if (std.mem.eql(u8, kw.name, "default")) return kw.value;
                }
                return .missing;
            }
            return error.RenderError;
        }
        return error.RenderError;
    }

    fn renderMacro(self: Renderer, ctx: *const Context, state: RenderState, def: parserMod.MacroDef, args: []const Value, kwargs: []const CallKwarg) anyerror!Value {
        // Macros imported `with context` render with the caller ambient
        // scope chained (full Jinja context); plain macros are isolated.
        const ambient: ?*contextMod.Scope = if (def.withContext) state.scope else null;
        return self.renderMacroWithScope(ctx, state, def, args, kwargs, ambient);
    }

    fn renderMacroWithScope(self: Renderer, ctx: *const Context, state: RenderState, def: parserMod.MacroDef, args: []const Value, kwargs: []const CallKwarg, parentScope: ?*contextMod.Scope) anyerror!Value {
        if (state.macroDepth >= state.maxMacroDepth) return TemplateError.DepthLimitExceeded;
        var macroScope = contextMod.Scope{ .parent = parentScope };
        defer macroScope.deinit(state.alloc);
        // Classify parameters: plain, *args collector, **kwargs collector.
        var plainCount: usize = 0;
        var starIdx: ?usize = null;
        var starStarIdx: ?usize = null;
        for (def.params, 0..) |param, pi| {
            if (param.starStar) {
                if (starStarIdx != null) return TemplateError.TypeMismatch;
                starStarIdx = pi;
            } else if (param.star) {
                if (starIdx != null) return TemplateError.TypeMismatch;
                starIdx = pi;
            } else {
                if (starIdx != null or starStarIdx != null) return TemplateError.TypeMismatch;
                plainCount += 1;
            }
        }
        // Surplus positionals without *args is a call error (Jinja TypeError).
        if (starIdx == null and args.len > plainCount) return TemplateError.TypeMismatch;
        var argPos: usize = 0;
        var usedKw = try state.alloc.alloc(bool, kwargs.len);
        defer state.alloc.free(usedKw);
        @memset(usedKw, false);
        for (def.params) |param| {
            if (param.star) {
                var rest = std.ArrayList(Value).empty;
                errdefer rest.deinit(state.alloc);
                while (argPos < args.len) : (argPos += 1) try rest.append(state.alloc, args[argPos]);
                try macroScope.set(state.alloc, param.name, .{ .list = try rest.toOwnedSlice(state.alloc) });
            } else if (param.starStar) {
                var rest = std.ArrayList(contextMod.Entry).empty;
                errdefer rest.deinit(state.alloc);
                for (kwargs, 0..) |kw, ki| {
                    if (!usedKw[ki]) {
                        try rest.append(state.alloc, .{ .key = kw.name, .value = kw.value });
                        usedKw[ki] = true;
                    }
                }
                try macroScope.set(state.alloc, param.name, .{ .map = try rest.toOwnedSlice(state.alloc) });
            } else if (argPos < args.len and (starIdx == null or argPos < plainCount)) {
                try macroScope.set(state.alloc, param.name, args[argPos]);
                argPos += 1;
            } else {
                var bound: ?Value = null;
                for (kwargs, 0..) |kw, ki| {
                    if (!usedKw[ki] and std.mem.eql(u8, kw.name, param.name)) {
                        bound = kw.value;
                        usedKw[ki] = true;
                        break;
                    }
                }
                if (bound) |v| {
                    try macroScope.set(state.alloc, param.name, v);
                } else if (param.default) |d| {
                    const trimmed = std.mem.trim(u8, d, " \t\r\n");
                    if (trimmed.len == 0) {
                        try macroScope.set(state.alloc, param.name, .nullVal);
                    } else {
                        // Defaults evaluate in the caller context (Jinja).
                        const dv = try self.evalExpr(ctx, state, trimmed);
                        try macroScope.set(state.alloc, param.name, dv);
                    }
                } else {
                    return TemplateError.TypeMismatch;
                }
            }
        }
        // Unknown keywords without **kwargs is a call error.
        if (starStarIdx == null) {
            for (usedKw) |u| {
                if (!u) return TemplateError.TypeMismatch;
            }
        }
        // Jinja always provides varargs/kwargs specials in macro scope.
        const emptyList: []const Value = &.{};
        const emptyMap: []const contextMod.Entry = &.{};
        if (starIdx == null) {
            try macroScope.set(state.alloc, "varargs", .{ .list = emptyList });
        } else if (macroScope.getLocal(def.params[starIdx.?].name)) |sv| {
            try macroScope.set(state.alloc, "varargs", sv);
        } else {
            try macroScope.set(state.alloc, "varargs", .{ .list = emptyList });
        }
        if (starStarIdx == null) {
            try macroScope.set(state.alloc, "kwargs", .{ .map = emptyMap });
        } else if (macroScope.getLocal(def.params[starStarIdx.?].name)) |kv| {
            try macroScope.set(state.alloc, "kwargs", kv);
        } else {
            try macroScope.set(state.alloc, "kwargs", .{ .map = emptyMap });
        }
        var next = state;
        next.scope = &macroScope;
        // Jinja macro isolation: bodies see arguments, globals and (for
        // `with context` imports and caller blocks) the template context —
        // never the ambient scope chain beyond their definition point.
        next.macroIsolated = !def.withContext;
        next.macroDepth = state.macroDepth + 1;
        var list = std.ArrayList(u8).empty;
        defer list.deinit(state.alloc);
        var lw = ListWriter{ .list = &list, .allocator = state.alloc };
        var counter = CountingWriter(*ListWriter){ .inner = &lw, .remaining = state.outputCap };
        _ = try self.renderNodes(def.bodyNodes, ctx, next, &counter);
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
        forInfo: *const parserMod.ForLoopInfo,
        ctx: *const Context,
        state: RenderState,
        writer: anytype,
    ) anyerror!Flow {
        const collVal = try self.evalExpr(ctx, state, forInfo.collectionExpr);
        if (collVal == .missing and state.strict) return TemplateError.UnknownVariable;
        // Coerce the iterable: lists as-is, maps yield keys, strings
        // yield characters (by code point).
        var owned: ?[]Value = null;
        defer if (owned) |o| state.alloc.free(o);
        const list: []const Value = switch (collVal) {
            .list => |l| l,
            .map => |entries| blk: {
                const keys = try state.alloc.alloc(Value, entries.len);
                for (entries, 0..) |e, i| keys[i] = .{ .string = e.key };
                owned = keys;
                break :blk keys;
            },
            .string => |s| blk: {
                var chars = std.ArrayList(Value).empty;
                errdefer chars.deinit(state.alloc);
                try appendUtf8Chars(&chars, state.alloc, s);
                owned = try chars.toOwnedSlice(state.alloc);
                break :blk owned.?;
            },
            .rawHtml => |h| blk: {
                var chars = std.ArrayList(Value).empty;
                errdefer chars.deinit(state.alloc);
                try appendUtf8Chars(&chars, state.alloc, h);
                owned = try chars.toOwnedSlice(state.alloc);
                break :blk owned.?;
            },
            else => {
                if (forInfo.elseNodes.len > 0) {
                    return self.renderNodes(forInfo.elseNodes, ctx, state, writer);
                }
                return .normal;
            },
        };
        var filtered: ?[]Value = null;
        defer if (filtered) |f| state.alloc.free(f);
        var items = list;
        if (forInfo.filterExpr != null) {
            items = try self.filterLoopItems(ctx, state, forInfo, list);
            filtered = @constCast(items);
        }
        if (items.len == 0 and forInfo.elseNodes.len > 0) {
            return self.renderNodes(forInfo.elseNodes, ctx, state, writer);
        }

        var loopState = state;
        loopState.loopDepth = state.loopDepth + 1;
        if (forInfo.recursive) {
            var frame = LoopRecurse{ .info = forInfo };
            const saved = loopState.loopRecurse;
            loopState.loopRecurse = &frame;
            defer loopState.loopRecurse = saved;
            return self.renderForItems(forInfo, items, ctx, loopState, writer);
        }
        return self.renderForItems(forInfo, items, ctx, loopState, writer);
    }

    /// Applies a `{% for %}` if-filter: keeps items whose filter expression
    /// is truthy when evaluated with the loop variables bound.
    fn filterLoopItems(
        self: Renderer,
        ctx: *const Context,
        state: RenderState,
        forInfo: *const parserMod.ForLoopInfo,
        list: []const Value,
    ) anyerror![]Value {
        const fexpr = forInfo.filterExpr orelse return @constCast(list);
        var out = std.ArrayList(Value).empty;
        errdefer out.deinit(state.alloc);
        for (list) |item| {
            var tmpScope = contextMod.Scope{ .parent = state.scope };
            defer tmpScope.deinit(state.alloc);
            try self.bindLoopVars(forInfo, item, &tmpScope, state.alloc);
            var tmpState = state;
            tmpState.scope = &tmpScope;
            const fv = try self.evalExpr(ctx, tmpState, fexpr);
            if (try truthyStrict(tmpState, fv)) try out.append(state.alloc, item);
        }
        return out.toOwnedSlice(state.alloc);
    }

    /// Binds loop target variables for one item (a single variable binds
    /// the whole item; multiple variables unpack list items pairwise,
    /// with missing positions becoming null).
    fn bindLoopVars(
        self: Renderer,
        forInfo: *const parserMod.ForLoopInfo,
        item: Value,
        scope: *contextMod.Scope,
        allocator: Allocator,
    ) !void {
        _ = self;
        if (forInfo.itemVars.len == 1) {
            try scope.set(allocator, forInfo.itemVars[0], item);
            return;
        }
        for (forInfo.itemVars, 0..) |vname, vi| {
            const v: Value = if (item == .list and vi < item.list.len) item.list[vi] else .nullVal;
            try scope.set(allocator, vname, v);
        }
    }

    fn renderForItems(
        self: Renderer,
        forInfo: *const parserMod.ForLoopInfo,
        items: []const Value,
        ctx: *const Context,
        state: RenderState,
        writer: anytype,
    ) anyerror!Flow {
        var loopScope = contextMod.Scope{ .parent = state.scope };
        defer loopScope.deinit(state.alloc);
        var loopState = state;
        loopState.scope = &loopScope;

        for (items, 0..) |item, i| {
            var iterScope = contextMod.Scope{ .parent = &loopScope };
            defer iterScope.deinit(state.alloc);
            try self.bindLoopVars(forInfo, item, &iterScope, state.alloc);
            const loopMeta = try state.alloc.alloc(contextMod.Entry, 9);
            loopMeta[0] = .{ .key = "index", .value = .{ .integer = @intCast(i + 1) } };
            loopMeta[1] = .{ .key = "index0", .value = .{ .integer = @intCast(i) } };
            loopMeta[2] = .{ .key = "first", .value = .{ .boolean = (i == 0) } };
            loopMeta[3] = .{ .key = "last", .value = .{ .boolean = (i + 1 == items.len) } };
            loopMeta[4] = .{ .key = "length", .value = .{ .integer = @intCast(items.len) } };
            loopMeta[5] = .{ .key = "revindex", .value = .{ .integer = @intCast(items.len - i) } };
            loopMeta[6] = .{ .key = "revindex0", .value = .{ .integer = @intCast(items.len - 1 - i) } };
            loopMeta[7] = .{ .key = "depth", .value = .{ .integer = @intCast(state.loopDepth) } };
            loopMeta[8] = .{ .key = "depth0", .value = .{ .integer = @intCast(if (state.loopDepth > 0) state.loopDepth - 1 else 0) } };
            try iterScope.set(state.alloc, "loop", .{ .map = loopMeta });

            var iterState = loopState;
            iterState.scope = &iterScope;
            const f = try self.renderNodes(forInfo.bodyNodes, ctx, iterState, writer);
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
    var parser = parserMod.Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var ctx = try Context.init(alloc, .{
        .title = "<script>alert('xss')</script> & \"more\"",
        .safeBody = contextMod.raw("<b>Trusted Content</b>"),
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{
        .name = "  ada  ",
        .items = [_][]const u8{ "a", "b" },
        .html = "<b>x</b>",
        .trusted = contextMod.raw("<i>y</i>"),
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
        fn f(a: Allocator, v: Value, args: []const Value, kwargs: []const FilterKwarg) anyerror!Value {
            _ = args;
            _ = kwargs;
            const s = try filterStringValue(a, v);
            defer a.free(s);
            return .{ .string = try std.fmt.allocPrint(a, "{s}!", .{s}) };
        }
    }.f;
    var reg = FilterRegistry.init(alloc);
    defer reg.deinit();
    try reg.register("shout", shout);
    const src = "{{ name|shout }}";
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var baseParser = parserMod.Parser.init(alloc, "base.html", "<title>{% block t %}Base{% endblock %}</title>{% block c %}Body{% endblock %}");
    var baseAst = try baseParser.parse();
    defer baseAst.deinit();
    var midParser = parserMod.Parser.init(alloc, "mid.html", "{% extends \"base.html\" %}{% block t %}Mid-{{ super() }}{% endblock %}");
    var midAst = try midParser.parse();
    defer midAst.deinit();
    var pageParser = parserMod.Parser.init(alloc, "page.html", "{% extends \"mid.html\" %}{% block c %}Page{% endblock %}");
    var pageAst = try pageParser.parse();
    defer pageAst.deinit();
    const Provider = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?*const TemplateAst {
            const asts: *const struct { base: *const TemplateAst, mid: *const TemplateAst } = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, name, "base.html")) return asts.base;
            if (std.mem.eql(u8, name, "mid.html")) return asts.mid;
            return null;
        }
    };
    const pair = .{ .base = &baseAst, .mid = &midAst };
    const provider = TemplateProvider{ .ptr = &pair, .getAstFn = Provider.get };
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &pageAst, &ctx, provider);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<title>Mid-Base</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Page") != null);
}

test "Renderer detects inheritance cycles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var aParser = parserMod.Parser.init(alloc, "a.html", "{% extends \"b.html\" %}A");
    var aAst = try aParser.parse();
    defer aAst.deinit();
    var bParser = parserMod.Parser.init(alloc, "b.html", "{% extends \"a.html\" %}B");
    var bAst = try bParser.parse();
    defer bAst.deinit();
    const Provider = struct {
        fn get(ptr: *const anyopaque, name: []const u8) ?*const TemplateAst {
            const asts: *const struct { a: *const TemplateAst, b: *const TemplateAst } = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, name, "a.html")) return asts.a;
            if (std.mem.eql(u8, name, "b.html")) return asts.b;
            return null;
        }
    };
    const pair = .{ .a = &aAst, .b = &bAst };
    const provider = TemplateProvider{ .ptr = &pair, .getAstFn = Provider.get };
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const res = renderer.renderToString(alloc, &aAst, &ctx, provider);
    try testing.expectError(error.CircularInheritance, res);
}

test "Renderer strict mode rejects undefined output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ missing }}";
    var parser = parserMod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const strictRenderer = Renderer{ .options = .{ .strictUndefined = true } };
    try testing.expectError(error.UnknownVariable, strictRenderer.renderToString(alloc, &ast, &ctx, null));
    const laxRenderer = Renderer{};
    const out = try laxRenderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("", out);
}

test "Renderer supports sort and reverse filters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{{ items|sort|join(\",\") }}|{{ items|reverse|join(\",\") }}";
    var parser = parserMod.Parser.init(alloc, "t.html", src);
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
    var srcList = std.ArrayList(u8).empty;
    defer srcList.deinit(alloc);
    try srcList.appendSlice(alloc, "{% for i in items %}");
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        try srcList.appendSlice(alloc, "<p>{{ i }}:{{ loop.index }}</p>{% if i %}<b>x</b>{% endif %}");
    }
    try srcList.appendSlice(alloc, "{% endfor %}");
    const src = srcList.items;

    var items = std.ArrayList(Value).empty;
    defer items.deinit(alloc);
    var j: i64 = 0;
    while (j < 50) : (j += 1) try items.append(alloc, .{ .integer = j });

    var parser = parserMod.Parser.init(alloc, "big.html", src);
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
        var parser = parserMod.Parser.init(alloc, "fuzz.html", src);
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

    var parser = parserMod.Parser.init(alloc, "test.html", src);
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

test "Renderer evaluates power operator and tuples" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{{ 2**3 }}", .want = "8" },
        .{ .src = "{{ 2**3**2 }}", .want = "512" },
        .{ .src = "{{ -2**2 }}", .want = "-4" },
        .{ .src = "{{ 2*3**2 }}", .want = "18" },
        .{ .src = "{{ 10-2**3 }}", .want = "2" },
        .{ .src = "{{ (1, 2)[1] }}", .want = "2" },
        .{ .src = "{{ (1, 2)|length }}", .want = "2" },
        .{ .src = "{{ ()|length }}", .want = "0" },
        .{ .src = "{{ (-2)**2 }}", .want = "4" },
        .{ .src = "{{ -(2**2) }}", .want = "-4" },
        .{ .src = "{{ 0-2**2 }}", .want = "-4" },
        .{ .src = "{{ 3**2 }}", .want = "9" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{{ 2**-2 }}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("0.25", out);
    }
}

test "Renderer supports extended Jinja filters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const users = [_]Value{
        .{ .map = &[_]contextMod.Entry{
            .{ .key = "name", .value = .{ .string = "ann" } },
            .{ .key = "age", .value = .{ .integer = 30 } },
            .{ .key = "active", .value = .{ .boolean = true } },
            .{ .key = "city", .value = .{ .string = "x" } },
        } },
        .{ .map = &[_]contextMod.Entry{
            .{ .key = "name", .value = .{ .string = "bob" } },
            .{ .key = "age", .value = .{ .integer = 17 } },
            .{ .key = "active", .value = .{ .boolean = false } },
            .{ .key = "city", .value = .{ .string = "y" } },
        } },
        .{ .map = &[_]contextMod.Entry{
            .{ .key = "name", .value = .{ .string = "cid" } },
            .{ .key = "age", .value = .{ .integer = 25 } },
            .{ .key = "active", .value = .{ .boolean = true } },
            .{ .key = "city", .value = .{ .string = "x" } },
        } },
    };
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{{ u|attr(\"name\") }}", .want = "Al" },
        .{ .src = "{{ [1,2,3,4,5]|batch(2)|length }}", .want = "3" },
        .{ .src = "{{ [1,2,3,4,5]|batch(2)|first|join(\",\") }}", .want = "1,2" },
        .{ .src = "{{ [1,2,3]|batch(2, 0)|last|join(\",\") }}", .want = "3,0" },
        .{ .src = "{{ \"ab\"|center(5) }}", .want = " ab  " },
        .{ .src = "{{ d|dictsort|map(\"0\")|join(\",\") }}", .want = "a,b" },
        .{ .src = "{{ d|dictsort(by=\"value\")|map(\"1\")|join(\",\") }}", .want = "1,2" },
        .{ .src = "{{ 512|filesizeformat }}", .want = "512 Bytes" },
        .{ .src = "{{ 2048|filesizeformat }}", .want = "2.0 kB" },
        .{ .src = "{{ 2048|filesizeformat(true) }}", .want = "2.0 KiB" },
        .{ .src = "{{ s|forceescape }}", .want = "&lt;b&gt;" },
        .{ .src = "{{ s|escape }}", .want = "<b>" },
        .{ .src = "{{ \"%s=%d\"|format(\"a\", 1) }}", .want = "a=1" },
        .{ .src = "{{ \"%05.2f\"|format(3.14159) }}", .want = "03.14" },
        .{ .src = "{{ \"%x\"|format(255) }}", .want = "ff" },
        .{ .src = "{{ \"%c\"|format(65) }}", .want = "A" },
        .{ .src = "{{ \"100%%\"|format }}", .want = "100%" },
        .{ .src = "{{ users|groupby(\"city\")|length }}", .want = "2" },
        .{ .src = "{{ (users|groupby(\"city\")|first).grouper }}", .want = "x" },
        .{ .src = "{{ (users|groupby(\"city\")|first).list|length }}", .want = "2" },
        .{ .src = "{{ \"a\\nb\"|indent(2) }}", .want = "a\n  b" },
        .{ .src = "{{ \"a\\nb\"|indent(2, true) }}", .want = "  a\n  b" },
        .{ .src = "{{ \"abc\"|list|length }}", .want = "3" },
        .{ .src = "{{ users|map(\"name\")|join(\",\") }}", .want = "ann,bob,cid" },
        .{ .src = "{{ [3,1,2]|max }}", .want = "3" },
        .{ .src = "{{ [3,1,2]|min }}", .want = "1" },
        .{ .src = "{{ (users|max(\"age\")).name }}", .want = "ann" },
        .{ .src = "{{ (users|min(\"age\")).name }}", .want = "bob" },
        .{ .src = "{{ [1, \"a\"]|pprint }}", .want = "[1, &#39;a&#39;]" },
        .{ .src = "{{ [7]|random }}", .want = "7" },
        .{ .src = "{{ [1,2,3,4]|select(\"odd\")|join(\",\") }}", .want = "1,3" },
        .{ .src = "{{ [1,2,3]|reject(\"==\", 2)|join(\",\") }}", .want = "1,3" },
        .{ .src = "{{ [0, 1, \"\"]|select|join(\",\") }}", .want = "1" },
        .{ .src = "{{ users|selectattr(\"active\")|length }}", .want = "2" },
        .{ .src = "{{ users|selectattr(\"age\", \">\", 18)|length }}", .want = "2" },
        .{ .src = "{{ users|rejectattr(\"active\")|length }}", .want = "1" },
        .{ .src = "{{ [1,2,3,4,5]|slice(2)|length }}", .want = "2" },
        .{ .src = "{{ [1,2,3,4,5]|slice(2)|first|join(\",\") }}", .want = "1,3,5" },
        .{ .src = "{{ [1,2,3]|sum }}", .want = "6" },
        .{ .src = "{{ users|sum(\"age\") }}", .want = "72" },
        .{ .src = "{{ [1]|sum(start=10) }}", .want = "11" },
        .{ .src = "{{ m|tojson }}", .want = "{\"a\": 1}" },
        .{ .src = "{{ \"<b>\"|tojson }}", .want = "\"<b>\"" },
        .{ .src = "{{ [1,2,1,3]|unique|join(\",\") }}", .want = "1,2,3" },
        .{ .src = "{{ [\"a\",\"A\",\"b\"]|unique|join(\",\") }}", .want = "a,b" },
        .{ .src = "{{ \"a b\"|urlencode }}", .want = "a%20b" },
        .{ .src = "{{ m2|urlencode }}", .want = "a=b%20c" },
        .{ .src = "{{ \"hello cruel world\"|wordcount }}", .want = "3" },
        .{ .src = "{{ \"aa bb cc\"|wordwrap(4) }}", .want = "aa\nbb\ncc" },
        .{ .src = "{{ xm|xmlattr }}", .want = " a=\"1\" b=\"&lt;x&gt;\"" },
        .{ .src = "{{ users|sort(attribute=\"age\")|map(\"name\")|join(\",\") }}", .want = "bob,cid,ann" },
        .{ .src = "{{ [1,2]|sort(reverse=true)|join(\",\") }}", .want = "2,1" },
        .{ .src = "{{ users|join(\", \", \"name\") }}", .want = "ann, bob, cid" },
        .{ .src = "{{ \"hello world foo\"|truncate(8, true, \"!\") }}", .want = "hello wo!" },
        .{ .src = "{{ \"hello\"|truncate(4) }}", .want = "hello" },
        .{ .src = "{{ \"ff\"|int(0, 16) }}", .want = "255" },
        .{ .src = "{{ \"0x10\"|int(0, 0) }}", .want = "16" },
        .{ .src = "{{ [3,1,2]|sort|join(\",\") }}", .want = "1,2,3" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{
            .u = .{ .name = "Al" },
            .d = .{ .b = @as(i32, 1), .a = @as(i32, 2) },
            .s = contextMod.raw("<b>"),
            .users = users,
            .m = .{ .a = @as(i32, 1) },
            .m2 = .{ .a = "b c" },
            .xm = .{ .a = @as(i32, 1), .b = "<x>" },
        });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("FILTER MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
}

test "Renderer supports extended is-tests" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{% if x is true %}T{% endif %}", .want = "T" },
        .{ .src = "{% if x is false %}T{% else %}F{% endif %}", .want = "F" },
        .{ .src = "{% if n is integer %}T{% endif %}", .want = "T" },
        .{ .src = "{% if f is float %}T{% endif %}", .want = "T" },
        .{ .src = "{% if l is iterable %}T{% endif %}", .want = "T" },
        .{ .src = "{% if s is iterable %}T{% endif %}", .want = "T" },
        .{ .src = "{% if n is iterable %}T{% else %}F{% endif %}", .want = "F" },
        .{ .src = "{% if n is sameas(1) %}T{% endif %}", .want = "T" },
        .{ .src = "{% if s is escaped %}T{% endif %}", .want = "T" },
        .{ .src = "{% if n is in([1,2]) %}T{% endif %}", .want = "T" },
        .{ .src = "{% if n is not in([1,2]) %}T{% else %}F{% endif %}", .want = "F" },
        .{ .src = "{% if n is odd %}T{% endif %}", .want = "T" },
        .{ .src = "{% if n is even %}T{% else %}F{% endif %}", .want = "F" },
        .{ .src = "{% if n is divisibleby(3) %}T{% else %}F{% endif %}", .want = "F" },
        .{ .src = "{% if m is divisibleby(2) %}T{% endif %}", .want = "T" },
        .{ .src = "{% if s is eq(\"a\") %}T{% endif %}", .want = "T" },
        .{ .src = "{% if s is lower %}T{% endif %}", .want = "T" },
        .{ .src = "{% if u is upper %}T{% endif %}", .want = "T" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{
            .x = true,
            .n = @as(i32, 1),
            .m = @as(i32, 4),
            .f = @as(f64, 1.5),
            .l = [_]i32{1},
            .s = contextMod.raw("a"),
            .u = "AB",
        });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("TEST MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
}

/// Test-only partial template descriptor.
const Partial = struct { name: []const u8, src: []const u8 };

/// Test-only multi-template provider: maps names to pre-parsed ASTs.
const MapProvider = struct {
    map: std.StringHashMap(*const TemplateAst),
    fn get(ptr: *const anyopaque, name: []const u8) ?*const TemplateAst {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return self.map.get(name);
    }
    fn provider(self: *const @This()) TemplateProvider {
        return .{ .ptr = self, .getAstFn = get };
    }
};

/// Renders `mainSrc` with `partials` available for include/import/extends.
/// Sources are comptime-known; ASTs are freed before return.
fn renderWithPartials(
    alloc: Allocator,
    mainSrc: []const u8,
    data: anytype,
    partials: []const Partial,
) ![]u8 {
    var asts = std.ArrayList(TemplateAst).empty;
    defer {
        for (asts.items) |*a| a.deinit();
        asts.deinit(alloc);
    }
    try asts.ensureTotalCapacity(alloc, partials.len);
    var map = std.StringHashMap(*const TemplateAst).init(alloc);
    defer map.deinit();
    for (partials) |p| {
        var parser = parserMod.Parser.init(alloc, p.name, p.src);
        const ast = try parser.parse();
        try asts.append(alloc, ast);
        try map.put(p.name, &asts.items[asts.items.len - 1]);
    }
    var mainParser = parserMod.Parser.init(alloc, "main.html", mainSrc);
    var mainAst = try mainParser.parse();
    defer mainAst.deinit();
    var ctx = try Context.init(alloc, data);
    defer ctx.deinit();
    const mp = MapProvider{ .map = map };
    const renderer = Renderer{};
    return renderer.renderToString(alloc, &mainAst, &ctx, mp.provider());
}

test "Renderer supports import as namespace with caller isolation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const out = try renderWithPartials(alloc, "{% import \"m.html\" as m %}{{ m.hi(\"Al\") }}", .{}, &.{
        .{ .name = "m.html", .src = "{% macro hi(n) %}Hi {{ n }}{% endmacro %}" },
    });
    defer alloc.free(out);
    try testing.expectEqualStrings("Hi Al", out);
}

test "Renderer import with and without context" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const partials = [_]Partial{
        .{ .name = "m.html", .src = "{% macro show() %}[{{ v }}]{% endmacro %}" },
    };
    {
        const out = try renderWithPartials(alloc, "{% import \"m.html\" as m %}{{ m.show() }}", .{ .v = "V" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[]", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% import \"m.html\" as m with context %}{{ m.show() }}", .{ .v = "V" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[V]", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% from \"m.html\" import show with context %}{{ show() }}", .{ .v = "W" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[W]", out);
    }
}

test "Renderer supports from-import with alias" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const out = try renderWithPartials(alloc, "{% from \"m.html\" import hi as greet %}{{ greet(\"Bo\") }}", .{}, &.{
        .{ .name = "m.html", .src = "{% macro hi(n) %}Hi {{ n }}{% endmacro %}{% macro bye(n) %}Bye{% endmacro %}" },
    });
    defer alloc.free(out);
    try testing.expectEqualStrings("Hi Bo", out);
}

test "Renderer reports import errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Missing template.
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% import \"nope.html\" as m %}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        const mp = MapProvider{ .map = std.StringHashMap(*const TemplateAst).init(alloc) };
        var m = mp;
        defer m.map.deinit();
        try testing.expectError(error.TemplateNotFound, renderer.renderToString(alloc, &ast, &ctx, m.provider()));
    }
    // Missing macro name.
    {
        const out = renderWithPartials(alloc, "{% from \"m.html\" import nosuch %}{{ nosuch() }}", .{}, &.{
            .{ .name = "m.html", .src = "{% macro hi() %}Hi{% endmacro %}" },
        });
        try testing.expectError(error.UnknownVariable, out);
    }
}

test "Renderer include ignore missing and context flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const partials = [_]Partial{
        .{ .name = "p.html", .src = "[{{ v }}]" },
    };
    {
        const out = try renderWithPartials(alloc, "a{% include \"nope.html\" ignore missing %}b", .{}, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("ab", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% include \"p.html\" %}", .{ .v = "V" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[V]", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% include \"p.html\" without context %}", .{ .v = "V" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[]", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% include \"p.html\" with context %}", .{ .v = "W" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[W]", out);
    }
    {
        const out = try renderWithPartials(alloc, "{% include name %}", .{ .name = "p.html", .v = "E" }, &partials);
        defer alloc.free(out);
        try testing.expectEqualStrings("[E]", out);
    }
}

test "Renderer supports filter apply with and blocks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{% filter upper %}hi{% endfilter %}", .want = "HI" },
        .{ .src = "{% apply upper %}hi{% endapply %}", .want = "HI" },
        .{ .src = "{% filter truncate(3) %}hello world{% endfilter %}", .want = "hel..." },
        .{ .src = "{% filter upper|lower %}Hi{% endfilter %}", .want = "hi" },
        .{ .src = "{% with a=1, b=2 %}{{ a }}{{ b }}{% endwith %}", .want = "12" },
        .{ .src = "{% with a=1 %}{{ a }}{% endwith %}{{ a }}", .want = "1" },
        .{ .src = "{% autoescape false %}{{ h }}{% endautoescape %}{{ h }}", .want = "<b>&lt;b&gt;" },
        .{ .src = "{% autoescape true %}{{ h }}{% endautoescape %}", .want = "&lt;b&gt;" },
        .{ .src = "{% filter upper %}a{% filter lower %}B{% endfilter %}c{% endfilter %}", .want = "ABC" },
        .{ .src = "{{ (1,)|length }}", .want = "1" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .h = "<b>" });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("BLOCK MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
}

test "Renderer supports for-if filters and collection kinds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{% for x in items if x > 1 %}{{ x }}{% endfor %}", .want = "23" },
        .{ .src = "{% for x in items if x > 1 %}{{ loop.length }}{% endfor %}", .want = "22" },
        .{ .src = "{% for x in items if x > 9 %}{{ x }}{% else %}none{% endfor %}", .want = "none" },
        .{ .src = "{% for k in d %}{{ k }};{% endfor %}", .want = "a;b;" },
        .{ .src = "{% for c in \"ab\" %}{{ c }}{% endfor %}", .want = "ab" },
        .{ .src = "{% for k, v in d.items() %}{{ k }}={{ v }};{% endfor %}", .want = "a=1;b=2;" },
        .{ .src = "{% for a, b, c in rows %}{{ a }}{{ b }}{{ c }};{% endfor %}", .want = "123;" },
        .{ .src = "{% for x in nest %}{{ loop.depth }}{% endfor %}", .want = "1" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{
            .items = [_]i32{ 1, 2, 3 },
            .d = .{ .a = @as(i32, 1), .b = @as(i32, 2) },
            .rows = [_][3]i32{.{ 1, 2, 3 }},
            .nest = [_]i32{7},
        });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("LOOP MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
    // Nested depth values.
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% for a in x %}{{ loop.depth }}:{{ loop.depth0 }}:{% for b in y %}{{ loop.depth }}:{{ loop.depth0 }};{% endfor %}{% endfor %}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .x = [_]i32{1}, .y = [_]i32{2} });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("1:0:2:1;", out);
    }
    // Destructuring with parens.
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% for (k, v) in pairs %}{{ k }}={{ v }};{% endfor %}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .pairs = [_][2][]const u8{.{ "a", "1" }} });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("a=1;", out);
    }
}

test "Renderer supports recursive loops" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const src = "{% for n in tree recursive %}{{ n.v }}{% if n.kids %}[{{ loop(n.kids) }}]{% endif %}{% endfor %}";
    var parser = parserMod.Parser.init(alloc, "t.html", src);
    var ast = try parser.parse();
    defer ast.deinit();
    const leaf = [_]Value{.{ .map = &[_]contextMod.Entry{
        .{ .key = "v", .value = .{ .string = "leaf" } },
    } }};
    const root = [_]Value{.{ .map = &[_]contextMod.Entry{
        .{ .key = "v", .value = .{ .string = "root" } },
        .{ .key = "kids", .value = .{ .list = &leaf } },
    } }};
    var ctx = try Context.init(alloc, .{ .tree = root });
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("root[leaf]", out);
}

test "Renderer supports set tuple assignment" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{% set a, b = 1, 2 %}{{ a }}{{ b }}", .want = "12" },
        .{ .src = "{% set a, b = pair %}{{ a }}{{ b }}", .want = "xy" },
        .{ .src = "{% set a, b = (1, 2) %}{{ a }}{{ b }}", .want = "12" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .pair = [_][]const u8{ "x", "y" } });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "Renderer supports macro star args and validation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{% macro m(a, *rest) %}{{ a }}:{{ rest|join(\",\") }}{% endmacro %}{{ m(1, 2, 3) }}", .want = "1:2,3" },
        .{ .src = "{% macro m(*r) %}{{ r|length }}{% endmacro %}{{ m(1, 2, 3) }}", .want = "3" },
        .{ .src = "{% macro m(**kw) %}{{ kw|length }}{% endmacro %}{{ m(a=1, b=2) }}", .want = "2" },
        .{ .src = "{% macro m(a) %}{{ varargs|length }}{% endmacro %}{{ m(1) }}", .want = "0" },
        .{ .src = "{% macro outer() %}{% macro inner() %}in{% endmacro %}{{ inner() }}{% endmacro %}{{ outer() }}", .want = "in" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("MACRO MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
    // Surplus positionals without *args, unknown kwargs, and missing
    // required params are call errors.
    const bad = [_][]const u8{
        "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}",
        "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(b=1) }}",
        "{% macro m(a, b) %}{{ a }}{% endmacro %}{{ m(1) }}",
    };
    for (bad) |src| {
        var parser = parserMod.Parser.init(alloc, "t.html", src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        try testing.expectError(error.TypeMismatch, renderer.renderToString(alloc, &ast, &ctx, null));
    }
}

test "Renderer isolates plain macros from template context" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Same-template macros cannot see template data (Jinja default).
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% macro m() %}[{{ v }}]{% endmacro %}{{ m() }}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .v = "V" });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("[]", out);
    }
    // Assignments inside a macro stay macro-local.
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% macro m() %}{% set x = 1 %}{{ x }}{% endmacro %}{{ m() }}[{{ x }}]");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("1[]", out);
    }
}

test "Renderer include inside isolated macro stays isolated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const out = try renderWithPartials(alloc, "{% macro m() %}{% include \"p.html\" %}{% endmacro %}{{ m() }}", .{ .v = "V" }, &.{
        .{ .name = "p.html", .src = "[{{ v }}]" },
    });
    defer alloc.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "Renderer supports caller parameters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var parser = parserMod.Parser.init(alloc, "t.html", "{% macro wrap() %}<b>{{ caller(\"X\") }}</b>{% endmacro %}{% call(item) wrap() %}{{ item }}!{% endcall %}");
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{};
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("<b>X!</b>", out);
}

test "Renderer supports map methods" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "{{ d.items()|length }}", .want = "2" },
        .{ .src = "{{ d.keys()|join(\",\") }}", .want = "a,b" },
        .{ .src = "{{ d.values()|join(\",\") }}", .want = "1,2" },
        .{ .src = "{{ d.get(\"a\", \"dflt\") }}", .want = "1" },
        .{ .src = "{{ d.get(\"zz\", \"dflt\") }}", .want = "dflt" },
        .{ .src = "{{ d.get(\"zz\") }}", .want = "" },
        .{ .src = "{% for k, v in d.items() %}{{ k }}={{ v }};{% endfor %}", .want = "a=1;b=2;" },
    };
    for (cases) |c| {
        var parser = parserMod.Parser.init(alloc, "t.html", c.src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{ .d = .{ .a = @as(i32, 1), .b = @as(i32, 2) } });
        defer ctx.deinit();
        const renderer = Renderer{};
        const out = try renderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        if (!std.mem.eql(u8, c.want, out)) {
            std.debug.print("METHOD MISMATCH src={s} want={s} got={s}\n", .{ c.src, c.want, out });
        }
        try testing.expectEqualStrings(c.want, out);
    }
}

test "Renderer strict mode covers conditions and iterations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const strictRenderer = Renderer{ .options = .{ .strictUndefined = true } };
    const laxRenderer = Renderer{};
    // Missing in conditions and iterations fails strict, renders lax.
    const errCases = [_][]const u8{
        "{% if nope %}x{% endif %}",
        "{% if nope or false %}x{% endif %}",
        "{% if not nope %}x{% endif %}",
        "{{ nope and true }}",
        "{% for x in nope %}{{ x }}{% endfor %}",
    };
    for (errCases) |src| {
        var parser = parserMod.Parser.init(alloc, "t.html", src);
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.UnknownVariable, strictRenderer.renderToString(alloc, &ast, &ctx, null));
    }
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% if nope %}x{% endif %}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.UnknownVariable, strictRenderer.renderToString(alloc, &ast, &ctx, null));
        const out = try laxRenderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("", out);
    }
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% for x in nope %}{{ x }}{% else %}E{% endfor %}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.UnknownVariable, strictRenderer.renderToString(alloc, &ast, &ctx, null));
        const out = try laxRenderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("E", out);
    }
    // Defined-tests and defaults keep working in strict mode.
    {
        var parser = parserMod.Parser.init(alloc, "t.html", "{% if nope is defined %}D{% else %}U{% endif %}|{{ nope|default(\"ok\") }}|{{ (1, 2)|length }}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        const out = try strictRenderer.renderToString(alloc, &ast, &ctx, null);
        defer alloc.free(out);
        try testing.expectEqualStrings("U|ok|2", out);
    }
}

test "Renderer enforces output macro range caps" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Output cap.
    {
        const tiny = Renderer{ .options = .{ .maxOutputBytes = 10 } };
        var parser = parserMod.Parser.init(alloc, "t.html", "0123456789ABCDEF");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.SizeLimitExceeded, tiny.renderToString(alloc, &ast, &ctx, null));
    }
    // Macro recursion depth.
    {
        const shallow = Renderer{ .options = .{ .maxMacroDepth = 4 } };
        var parser = parserMod.Parser.init(alloc, "t.html", "{% macro m(n) %}{{ m(n) }}{% endmacro %}{{ m(1) }}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.DepthLimitExceeded, shallow.renderToString(alloc, &ast, &ctx, null));
    }
    // Range length cap.
    {
        const small = Renderer{ .options = .{ .maxRangeItems = 8 } };
        var parser = parserMod.Parser.init(alloc, "t.html", "{{ range(100)|length }}");
        var ast = try parser.parse();
        defer ast.deinit();
        var ctx = try Context.init(alloc, .{});
        defer ctx.deinit();
        try testing.expectError(error.SizeLimitExceeded, small.renderToString(alloc, &ast, &ctx, null));
    }
}

test "Renderer supports four-level inheritance with super" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const out = try renderWithPartials(alloc, "{% extends \"page.html\" %}{% block c %}[C:{{ super() }}]{% endblock %}", .{}, &.{
        .{ .name = "base.html", .src = "B:{% block c %}base{% endblock %}" },
        .{ .name = "layout.html", .src = "{% extends \"base.html\" %}{% block c %}L({{ super() }}){% endblock %}" },
        .{ .name = "page.html", .src = "{% extends \"layout.html\" %}{% block c %}P({{ super() }}){% endblock %}" },
    });
    defer alloc.free(out);
    try testing.expectEqualStrings("B:[C:P(L(base))]", out);
}

test "Renderer urlFor-style globals take kwargs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const urlFor = struct {
        fn f(_: ?*const anyopaque, a: Allocator, args: []const Value, kwargs: []const GlobalKwarg) anyerror!Value {
            if (args.len < 1 or args[0] != .string) return .nullVal;
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(a);
            try out.appendSlice(a, "/");
            try out.appendSlice(a, args[0].string);
            for (kwargs) |kw| {
                const vs = try filterStringValue(a, kw.value);
                defer a.free(vs);
                try out.appendSlice(a, "/");
                try out.appendSlice(a, vs);
            }
            return .{ .string = try out.toOwnedSlice(a) };
        }
    }.f;
    var reg = GlobalMap.init(alloc);
    defer reg.deinit();
    try reg.map.put("urlFor", .{ .func = urlFor });
    var parser = parserMod.Parser.init(alloc, "t.html", "{{ urlFor(\"user\", id=7) }}");
    var ast = try parser.parse();
    defer ast.deinit();
    var ctx = try Context.init(alloc, .{});
    defer ctx.deinit();
    const renderer = Renderer{ .globals = &reg };
    const out = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(out);
    try testing.expectEqualStrings("/user/7", out);
}
