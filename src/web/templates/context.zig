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

/// Tagged union representing dynamic values inside template evaluation.
pub const Value = union(enum) {
    null_val: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    raw_html: []const u8,
    list: []const Value,
    map: []const Entry,

    /// Returns whether this value evaluates to true in conditional contexts.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null_val => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0 and !std.math.isNan(f),
            .string => |s| s.len > 0,
            .raw_html => |h| h.len > 0,
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
            .null_val => return other == .null_val,
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
                    .raw_html => |oh| std.mem.eql(u8, s, oh),
                    else => false,
                };
            },
            .raw_html => |h| {
                return switch (other) {
                    .raw_html => |oh| std.mem.eql(u8, h, oh),
                    .string => |os| std.mem.eql(u8, h, os),
                    else => false,
                };
            },
            .list => return false,
            .map => return false,
        }
    }

    /// Converts an arbitrary Zig value into a template `Value`.
    pub fn from(allocator: Allocator, val: anytype) Allocator.Error!Value {
        const T = @TypeOf(val);

        if (T == Value) {
            return val;
        }
        if (T == RawHtml) {
            return .{ .raw_html = val.content };
        }
        if (T == void or T == @TypeOf(null)) {
            return .null_val;
        }

        const info = @typeInfo(T);
        switch (info) {
            .optional => {
                if (val) |unwrapped| {
                    return try from(allocator, unwrapped);
                }
                return .null_val;
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
                    else => return .null_val,
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
            .null => return .null_val,
            else => return .null_val,
        }
    }
};

/// Evaluation context holding template scope values and an arena for temporary allocations.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    /// Initializes a context from an arbitrary Zig struct or Value.
    pub fn init(base_allocator: Allocator, data: anytype) !Context {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
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
    const null_v = Value{ .null_val = {} };
    try testing.expect(!null_v.isTruthy());

    // Raw HTML
    const markup = ctx.get("safe_markup");
    try testing.expect(markup != null);
    try testing.expectEqual(Value.raw_html, std.meta.activeTag(markup.?));
}
