//! Template value and context abstraction.
//!
//! Provides a clean, flexible, comptime-friendly value system supporting
//! primitives, optionals, structs, slices, arrays, lists, maps, and explicit raw HTML.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Explicit wrapper for trusted HTML that should bypass auto-escaping.
pub const RawHtml = struct {
    content: []const u8,
};

/// Constructs an explicit trusted HTML value.
pub fn raw(content: []const u8) RawHtml {
    return .{ .content = content };
}

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

const parser_mod = @import("parser.zig");

/// Tagged union representing dynamic values inside template evaluation.
/// `.missing` marks an unresolvable lookup (distinct from explicit null):
/// it renders empty, is falsy, and drives `is defined` tests plus the
/// `default` filter. Strict mode turns it into a render error at output.
/// `.macro` holds a first-class macro reference (e.g. `caller` in call
/// blocks); it renders empty and is truthy.
pub const Value = union(enum) {
    nullVal: void,
    missing: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    rawHtml: []const u8,
    list: []const Value,
    map: []const Entry,
    macro: parser_mod.MacroDef,

    /// Returns whether this value evaluates to true in conditional contexts.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nullVal => false,
            .missing => false,
            .macro => true,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0 and !std.math.isNan(f),
            .string => |s| s.len > 0,
            .rawHtml => |h| h.len > 0,
            .list => |l| l.len > 0,
            .map => |m| m.len > 0,
        };
    }

    /// Looks up a direct property or nested dot-path (e.g. "user.profile.name").
    pub fn lookup(self: Value, path: []const u8) ?Value {
        var current = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            current = switch (current) {
                .map => |entries| blk: {
                    var found: ?Value = null;
                    for (entries) |e| {
                        if (std.mem.eql(u8, e.key, part)) {
                            found = e.value;
                            break;
                        }
                    }
                    break :blk found orelse return null;
                },
                .list => |items| blk: {
                    const idx = std.fmt.parseInt(usize, part, 10) catch return null;
                    if (idx < items.len) {
                        break :blk items[idx];
                    }
                    return null;
                },
                else => return null,
            };
        }
        return current;
    }

    /// Checks equality with another Value (for `{% if a == b %}`).
    pub fn equals(self: Value, other: Value) bool {
        switch (self) {
            .nullVal => return other == .nullVal,
            .missing => return other == .missing,
            .boolean => |b| return if (other == .boolean) b == other.boolean else false,
            .integer => |i| {
                return switch (other) {
                    .integer => |oi| i == oi,
                    .float => |of| @as(f64, @floatFromInt(i)) == of,
                    else => false,
                };
            },
            .float => |f| {
                return switch (other) {
                    .float => |of| f == of,
                    .integer => |oi| f == @as(f64, @floatFromInt(oi)),
                    else => false,
                };
            },
            .string => |s| {
                return switch (other) {
                    .string => |os| std.mem.eql(u8, s, os),
                    .rawHtml => |oh| std.mem.eql(u8, s, oh),
                    else => false,
                };
            },
            .rawHtml => |h| {
                return switch (other) {
                    .rawHtml => |oh| std.mem.eql(u8, h, oh),
                    .string => |os| std.mem.eql(u8, h, os),
                    else => false,
                };
            },
            .list => return false,
            .map => return false,
            .macro => return false,
        }
    }

    /// Converts an arbitrary Zig value into a template `Value`.
    pub fn from(allocator: Allocator, val: anytype) Allocator.Error!Value {
        const T = @TypeOf(val);

        if (T == Value) {
            return val;
        }
        if (T == RawHtml) {
            return .{ .rawHtml = val.content };
        }
        if (T == void or T == @TypeOf(null)) {
            return .nullVal;
        }

        const info = @typeInfo(T);
        switch (info) {
            .optional => {
                if (val) |unwrapped| {
                    return try from(allocator, unwrapped);
                }
                return .nullVal;
            },
            .bool => return .{ .boolean = val },
            .int => return .{ .integer = @intCast(val) },
            .comptime_int => return .{ .integer = @intCast(val) },
            .float => return .{ .float = @floatCast(val) },
            .comptime_float => return .{ .float = @floatCast(val) },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .slice => {
                        if (ptr.child == u8) {
                            return .{ .string = try allocator.dupe(u8, val) };
                        } else {
                            const list = try allocator.alloc(Value, val.len);
                            for (val, 0..) |item, i| {
                                list[i] = try from(allocator, item);
                            }
                            return .{ .list = list };
                        }
                    },
                    .one => {
                        if (@typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                            return .{ .string = try allocator.dupe(u8, val) };
                        }
                        return try from(allocator, val.*);
                    },
                    else => return .nullVal,
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    return .{ .string = try allocator.dupe(u8, &val) };
                } else {
                    const list = try allocator.alloc(Value, val.len);
                    for (val, 0..) |item, i| {
                        list[i] = try from(allocator, item);
                    }
                    return .{ .list = list };
                }
            },
            .@"struct" => |st| {
                const fields = st.fields;
                const entries = try allocator.alloc(Entry, fields.len);
                inline for (fields, 0..) |field, i| {
                    const field_val = @field(val, field.name);
                    entries[i] = .{
                        .key = field.name,
                        .value = try from(allocator, field_val),
                    };
                }
                return .{ .map = entries };
            },
            .null => return .nullVal,
            else => return .nullVal,
        }
    }
};

/// Mutable lexical scope overlay for `{% set %}`, loop variables, and
/// macro arguments. Scopes chain via `parent`; rendering threads a single
/// current scope through the AST walk. Storage lives in the Context arena.
pub const Scope = struct {
    parent: ?*Scope = null,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Scope, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn getLocal(self: *const Scope, key: []const u8) ?Value {
        var s: ?*const Scope = self;
        while (s) |sc| {
            for (sc.entries.items) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.value;
            }
            s = sc.parent;
        }
        return null;
    }

    pub fn set(self: *Scope, allocator: Allocator, key: []const u8, value: Value) !void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        try self.entries.append(allocator, .{ .key = key, .value = value });
    }
};

/// Evaluation context holding template scope values and an arena for temporary allocations.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    /// Initializes a context from an arbitrary Zig struct or Value.
    pub fn init(baseAllocator: Allocator, data: anytype) !Context {
        var arena = std.heap.ArenaAllocator.init(baseAllocator);
        errdefer arena.deinit();

        const root_val = try Value.from(arena.allocator(), data);
        return .{
            .arena = arena,
            .root = root_val,
        };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    /// Looks up a variable or nested path (e.g. "user.profile.name") from the context.
    pub fn get(self: Context, path: []const u8) ?Value {
        return self.root.lookup(path);
    }

    /// Scope-aware lookup: the first path segment resolves through the scope
    /// chain (shadowing root), remaining segments traverse the found value.
    /// A null scope falls back to plain root lookup.
    pub fn resolve(self: Context, scope: ?*const Scope, path: []const u8) ?Value {
        const sc = scope orelse return self.get(path);
        var it = std.mem.splitScalar(u8, path, '.');
        const first = it.next() orelse return null;
        if (first.len == 0) return self.get(path);
        const base = sc.getLocal(first) orelse return self.get(path);
        var current = base;
        while (it.next()) |part| {
            if (part.len == 0) continue;
            current = switch (current) {
                .map => |entries| blk: {
                    var found: ?Value = null;
                    for (entries) |e| {
                        if (std.mem.eql(u8, e.key, part)) {
                            found = e.value;
                            break;
                        }
                    }
                    break :blk found orelse return null;
                },
                .list => |items| blk: {
                    const idx = std.fmt.parseInt(usize, part, 10) catch return null;
                    if (idx < items.len) break :blk items[idx];
                    return null;
                },
                else => return null,
            };
        }
        return current;
    }
};

test "Value and Context basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, .{
        .title = "HTTPX",
        .count = @as(i32, 42),
        .enabled = true,
        .user = .{
            .name = "Muhammad",
            .role = "admin",
        },
        .tags = [_][]const u8{ "zig", "web", "templates" },
        .safe_markup = raw("<b>bold</b>"),
    });
    defer ctx.deinit();

    // Direct lookup
    const title = ctx.get("title");
    try testing.expect(title != null);
    try testing.expectEqualStrings("HTTPX", title.?.string);

    // Nested struct lookup
    const user_name = ctx.get("user.name");
    try testing.expect(user_name != null);
    try testing.expectEqualStrings("Muhammad", user_name.?.string);

    // Array index lookup
    const tag1 = ctx.get("tags.1");
    try testing.expect(tag1 != null);
    try testing.expectEqualStrings("web", tag1.?.string);

    // Truthiness
    try testing.expect(ctx.get("enabled").?.isTruthy());
    try testing.expect(ctx.get("count").?.isTruthy());
    const null_v = Value{ .nullVal = {} };
    try testing.expect(!null_v.isTruthy());

    // Raw HTML
    const markup = ctx.get("safe_markup");
    try testing.expect(markup != null);
    try testing.expectEqual(Value.rawHtml, std.meta.activeTag(markup.?));
}
