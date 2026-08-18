//! JSON Utilities for httpx.zig
//!
//! Provides JSON handling utilities for HTTP message bodies:
//!
//! - Type-safe parsing using Zig's std.json
//! - Dynamic JSON value wrapper for runtime inspection
//! - Dynamic JSON building with JsonBuilder
//! - Common JSON operations for APIs
//!
//! ## Quick Start
//!
//! ```zig
//! // Typed parsing
//! const user = try httpx.json.parse(User, allocator, data);
//! defer user.deinit();
//!
//! // Dynamic parsing
//! var val = try httpx.json.parseValue(allocator, data);
//! defer val.deinit();
//! const name = try val.getString("name");
//!
//! // Building JSON
//! var builder = httpx.json.JsonBuilder.init(allocator);
//! defer builder.deinit();
//! try builder.beginObject();
//! try builder.key("ok");
//! try builder.boolean(true);
//! try builder.endObject();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_writer = @import("../io/list_writer.zig");

fn stringifyJsonAlloc(allocator: Allocator, value: anytype, options: std.json.Stringify.Options) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, options);
}

/// JSON utility functions.
pub const Json = struct {
    /// Parses a JSON string into the specified type.
    /// The caller must call `deinit()` on the returned `std.json.Parsed(T)`.
    pub fn parse(comptime T: type, allocator: Allocator, data: []const u8) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, data, .{});
    }

    /// Parses a JSON string into the specified type with options.
    pub fn parseWithOptions(comptime T: type, allocator: Allocator, data: []const u8, options: std.json.ParseOptions) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, data, options);
    }

    /// Zero-copy parse: strings borrow from the input buffer.
    /// The input `data` must outlive the returned value.
    /// Caller must free with `allocator.destroy(result)` or use an arena.
    pub fn parseBorrowed(comptime T: type, allocator: Allocator, data: []const u8) !T {
        return std.json.parseFromSliceLeaky(T, allocator, data, .{});
    }

    /// Zero-copy parse with options: strings borrow from the input buffer.
    pub fn parseBorrowedWithOptions(comptime T: type, allocator: Allocator, data: []const u8, options: std.json.ParseOptions) !T {
        return std.json.parseFromSliceLeaky(T, allocator, data, options);
    }

    /// Parses JSON into a dynamic Value tree.
    /// The caller must call `deinit()` on the returned `ParsedJson`.
    pub fn parseValue(allocator: Allocator, data: []const u8) !ParsedJson {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        return .{ .arena = parsed.arena, .value = JsonValue{ .inner = parsed.value, .allocator = allocator } };
    }

    /// Parses JSON into a dynamic Value tree with options.
    pub fn parseValueWithOptions(allocator: Allocator, data: []const u8, options: std.json.ParseOptions) !ParsedJson {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, options);
        return .{ .arena = parsed.arena, .value = JsonValue{ .inner = parsed.value, .allocator = allocator } };
    }

    /// Serializes a value to a JSON string.
    pub fn stringify(allocator: Allocator, value: anytype) ![]u8 {
        return stringifyJsonAlloc(allocator, value, .{});
    }

    /// Serializes a value to a JSON string with pretty formatting.
    pub fn stringifyPretty(allocator: Allocator, value: anytype) ![]u8 {
        return stringifyJsonAlloc(allocator, value, .{ .whitespace = .indent_2 });
    }

    /// Validates that a string is valid JSON.
    pub fn validate(allocator: Allocator, data: []const u8) bool {
        return std.json.validate(allocator, data) catch false;
    }
};

/// Parsed dynamic JSON. Wraps std.json.Parsed(Value) with ergonomic methods.
pub const ParsedJson = struct {
    arena: *std.heap.ArenaAllocator,
    value: JsonValue,

    pub fn deinit(self: ParsedJson) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// Dynamic JSON value wrapper around std.json.Value.
/// Provides ergonomic accessors for runtime JSON inspection.
pub const JsonValue = struct {
    inner: std.json.Value,
    allocator: Allocator,

    const Self = @This();

    /// Type tag for inspecting the value type.
    pub const Tag = enum {
        null,
        bool,
        integer,
        float,
        number_string,
        string,
        array,
        object,
    };

    /// Returns the type tag of this value.
    pub fn tag(self: Self) Tag {
        return switch (self.inner) {
            .null => .null,
            .bool => .bool,
            .integer => .integer,
            .float => .float,
            .number_string => .number_string,
            .string => .string,
            .array => .array,
            .object => .object,
        };
    }

    // --- Type checks ---

    pub fn isNull(self: Self) bool {
        return self.inner == .null;
    }

    pub fn isObject(self: Self) bool {
        return self.inner == .object;
    }

    pub fn isArray(self: Self) bool {
        return self.inner == .array;
    }

    pub fn isString(self: Self) bool {
        return self.inner == .string;
    }

    pub fn isNumber(self: Self) bool {
        return self.inner == .integer or self.inner == .float or self.inner == .number_string;
    }

    pub fn isBool(self: Self) bool {
        return self.inner == .bool;
    }

    // --- Value accessors ---

    /// Returns the boolean value. Returns error.NullValue if null, error.TypeMismatch if not boolean.
    pub fn getBoolValue(self: Self) !bool {
        return switch (self.inner) {
            .bool => |v| v,
            .null => error.NullValue,
            else => error.TypeMismatch,
        };
    }

    /// Returns the integer value. Returns error.TypeMismatch if not an integer.
    pub fn integer(self: Self) !i64 {
        return switch (self.inner) {
            .integer => |v| v,
            .float => |v| @intFromFloat(v),
            .null => error.NullValue,
            else => error.TypeMismatch,
        };
    }

    /// Returns the integer value cast to the requested integer type.
    pub fn int(self: Self, comptime T: type) !T {
        const val = try self.integer();
        return @intCast(val);
    }

    /// Returns the float value. Returns error.TypeMismatch if not a number.
    pub fn float(self: Self) !f64 {
        return switch (self.inner) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            .number_string => std.fmt.parseFloat(f64, self.inner.number_string) catch error.InvalidNumber,
            .null => error.NullValue,
            else => error.TypeMismatch,
        };
    }

    /// Returns the string value. Returns error.TypeMismatch if not a string.
    pub fn string(self: Self) ![]const u8 {
        return switch (self.inner) {
            .string => |v| v,
            .null => error.NullValue,
            else => error.TypeMismatch,
        };
    }

    // --- Object operations ---

    /// Returns a child value by key from an object. Returns null if key not found.
    pub fn get(self: Self, key: []const u8) ?JsonValue {
        if (self.inner != .object) return null;
        const val = self.inner.object.get(key) orelse return null;
        return .{ .inner = val, .allocator = self.allocator };
    }

    /// Returns a child value by key, or error.KeyNotFound if missing.
    pub fn getField(self: Self, key: []const u8) !JsonValue {
        return self.get(key) orelse error.KeyNotFound;
    }

    /// Returns the string value of a field.
    pub fn getString(self: Self, key: []const u8) ![]const u8 {
        const field = try self.getField(key);
        return field.string();
    }

    /// Returns the string value of a field, or null if missing or null.
    pub fn getStringOrNull(self: Self, key: []const u8) ?[]const u8 {
        const field = self.get(key) orelse return null;
        return switch (field.inner) {
            .string => |v| v,
            .null => null,
            else => null,
        };
    }

    /// Returns the integer value of a field.
    pub fn getInt(self: Self, key: []const u8) !i64 {
        const field = try self.getField(key);
        return field.integer();
    }

    /// Returns the integer value of a field as a specific type.
    pub fn getIntAs(self: Self, key: []const u8, comptime T: type) !T {
        const val = try self.getInt(key);
        return @intCast(val);
    }

    /// Returns the integer value of a field, or null if missing or null.
    pub fn getIntOrNull(self: Self, key: []const u8) ?i64 {
        const field = self.get(key) orelse return null;
        return switch (field.inner) {
            .integer => |v| v,
            .float => |v| @intFromFloat(v),
            .null => null,
            else => null,
        };
    }

    /// Returns the float value of a field.
    pub fn getFloat(self: Self, key: []const u8) !f64 {
        const field = try self.getField(key);
        return field.float();
    }

    /// Returns the boolean value of a field.
    pub fn getBool(self: Self, key: []const u8) !bool {
        const field = try self.getField(key);
        return field.getBoolValue();
    }

    /// Returns the boolean value of a field, or null if missing.
    pub fn getBoolOrNull(self: Self, key: []const u8) ?bool {
        const field = self.get(key) orelse return null;
        return switch (field.inner) {
            .bool => |v| v,
            .null => null,
            else => null,
        };
    }

    /// Returns a nested value by path (e.g., &.{"user", "address", "city"}).
    pub fn getPath(self: Self, path: []const []const u8) ?JsonValue {
        var current = self;
        for (path) |key| {
            current = current.get(key) orelse return null;
        }
        return current;
    }

    /// Returns a nested value by path, or error.KeyNotFound if any key is missing.
    pub fn getFieldPath(self: Self, path: []const []const u8) !JsonValue {
        return self.getPath(path) orelse error.KeyNotFound;
    }

    /// Checks if a key exists in an object.
    pub fn has(self: Self, key: []const u8) bool {
        if (self.inner != .object) return false;
        return self.inner.object.contains(key);
    }

    /// Checks if a nested path exists.
    pub fn hasPath(self: Self, path: []const []const u8) bool {
        return self.getPath(path) != null;
    }

    // --- Array operations ---

    /// Returns the length of an array.
    pub fn len(self: Self) !usize {
        return switch (self.inner) {
            .array => |v| v.items.len,
            .string => |v| v.len,
            else => error.TypeMismatch,
        };
    }

    /// Returns an item at index from an array.
    pub fn at(self: Self, index: usize) !JsonValue {
        if (self.inner != .array) return error.TypeMismatch;
        if (index >= self.inner.array.items.len) return error.IndexOutOfBounds;
        return .{ .inner = self.inner.array.items[index], .allocator = self.allocator };
    }

    // --- Set / modify ---

    /// Sets a field on an object.
    pub fn set(self: *Self, key: []const u8, value: std.json.Value) !void {
        if (self.inner != .object) return error.TypeMismatch;
        var obj = self.inner.object;
        try obj.put(self.allocator, key, value);
        self.inner = .{ .object = obj };
    }

    /// Sets a string field.
    pub fn setString(self: *Self, key: []const u8, value: []const u8) !void {
        try self.set(key, .{ .string = value });
    }

    /// Sets an integer field.
    pub fn setInt(self: *Self, key: []const u8, value: i64) !void {
        try self.set(key, .{ .integer = value });
    }

    /// Sets a boolean field.
    pub fn setBool(self: *Self, key: []const u8, value: bool) !void {
        try self.set(key, .{ .bool = value });
    }

    /// Sets a null field.
    pub fn setNull(self: *Self, key: []const u8) !void {
        try self.set(key, .null);
    }

    /// Sets a field at a nested path, creating intermediate objects as needed.
    pub fn setPath(self: *Self, path: []const []const u8, value: std.json.Value) !void {
        if (path.len == 0) return error.EmptyPath;
        var current = self;
        for (path[0 .. path.len - 1]) |key| {
            if (current.inner != .object) return error.TypeMismatch;
            const child_val = current.get(key) orelse blk: {
                var obj = current.inner.object;
                try obj.put(self.allocator, key, .{ .object = .init(self.allocator) });
                current.inner = .{ .object = obj };
                break :blk .{ .inner = current.inner.object.get(key).?, .allocator = self.allocator };
            };
            if (child_val.inner != .object) {
                var obj = current.inner.object;
                try obj.put(self.allocator, key, .{ .object = .init(self.allocator) });
                current.inner = .{ .object = obj };
            }
            current = child_val;
        }
        try current.set(path[path.len - 1], value);
    }

    /// Removes a field from an object. Returns true if the field existed.
    pub fn remove(self: *Self, key: []const u8) bool {
        if (self.inner != .object) return false;
        var obj = self.inner.object;
        const result = obj.swapRemove(key);
        self.inner = .{ .object = obj };
        return result;
    }

    // --- Iteration ---

    /// Returns an iterator over object entries.
    pub fn objectIterator(self: Self) ObjectIterator {
        if (self.inner != .object) return .{ .keys = &.{}, .values = &.{}, .index = 0, .active = false, .allocator = self.allocator };
        const obj = self.inner.object;
        return .{
            .keys = obj.entries.items(.key),
            .values = obj.entries.items(.value),
            .index = 0,
            .active = true,
            .allocator = self.allocator,
        };
    }

    /// Returns an iterator over array items.
    pub fn arrayIterator(self: Self) ArrayIterator {
        if (self.inner != .array) return .{ .items = &.{}, .index = 0 };
        return .{ .items = self.inner.array.items, .index = 0 };
    }

    // --- Stringify ---

    /// Serializes this value to an allocated JSON string.
    pub fn stringifyAlloc(self: Self, allocator: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.inner, .{});
    }

    /// Serializes this value to a pretty-printed JSON string.
    pub fn stringifyAllocPretty(self: Self, allocator: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.inner, .{ .whitespace = .indent_2 });
    }

    // --- Type conversion ---

    /// Converts this dynamic value to a typed struct using std.json.
    /// The caller must call `deinit()` on the returned `std.json.Parsed(T)`.
    pub fn to(self: Self, comptime T: type) !std.json.Parsed(T) {
        const json_str = try self.stringifyAlloc(self.allocator);
        defer self.allocator.free(json_str);
        return std.json.parseFromSlice(T, self.allocator, json_str, .{});
    }

    /// Creates a JsonValue from any Zig value (struct, int, string, etc.).
    /// The caller owns the returned value and must ensure the allocator outlives it.
    pub fn from(allocator: Allocator, value: anytype) !Self {
        const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(json_str);
        // Use leaky parse to avoid creating an arena that would be lost.
        // The allocator passed here is responsible for freeing the parsed value.
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json_str, .{});
        return .{ .inner = parsed, .allocator = allocator };
    }
};

/// Iterator over JSON object entries.
pub const ObjectIterator = struct {
    keys: []const []const u8,
    values: []const std.json.Value,
    index: usize,
    active: bool,
    allocator: Allocator,

    pub fn next(self: *ObjectIterator) ?struct { key: []const u8, value: JsonValue } {
        if (!self.active) return null;
        while (self.index < self.keys.len) {
            const idx = self.index;
            self.index += 1;
            return .{
                .key = self.keys[idx],
                .value = .{ .inner = self.values[idx], .allocator = self.allocator },
            };
        }
        return null;
    }
};

/// Iterator over JSON array items.
pub const ArrayIterator = struct {
    items: []const std.json.Value,
    index: usize,

    pub fn next(self: *ArrayIterator) ?JsonValue {
        if (self.index >= self.items.len) return null;
        const item = self.items[self.index];
        self.index += 1;
        return .{ .inner = item, .allocator = undefined };
    }
};

/// Check if a Content-Type header indicates JSON.
/// Handles: application/json, application/vnd.api+json, application/json; charset=utf-8, etc.
pub fn isJsonContentType(content_type: []const u8) bool {
    const ct = std.mem.trim(u8, content_type, " \t");
    if (ct.len < "application/json".len) return false;
    if (std.ascii.startsWithIgnoreCase(ct, "application/json")) {
        if (ct.len == "application/json".len) return true;
        const next = ct["application/json".len];
        return next == ';' or next == ' ';
    }
    if (std.mem.indexOf(u8, ct, "+json")) |_| {
        return std.ascii.startsWithIgnoreCase(ct, "application/");
    }
    return false;
}

test "Json.validate" {
    const allocator = std.testing.allocator;
    try std.testing.expect(Json.validate(allocator, "{\"ok\": true}"));
    try std.testing.expect(!Json.validate(allocator, "{\"ok\": true"));
}

test "Json.parseValue" {
    const allocator = std.testing.allocator;
    const data =
        \\{"name":"test","age":42,"active":true,"tags":["a","b"],"address":{"city":"NYC"}}
    ;
    var parsed = try Json.parseValue(allocator, data);
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root.isObject());
    try std.testing.expectEqualStrings("test", try root.getString("name"));
    try std.testing.expectEqual(@as(i64, 42), try root.getInt("age"));
    try std.testing.expect(try root.getBool("active"));
    try std.testing.expect(root.has("name"));
    try std.testing.expect(!root.has("email"));

    const tags = try root.getField("tags");
    try std.testing.expect(tags.isArray());
    try std.testing.expectEqual(@as(usize, 2), try tags.len());

    const addr = try root.getField("address");
    try std.testing.expectEqualStrings("NYC", try addr.getString("city"));
}

test "JsonValue path navigation" {
    const allocator = std.testing.allocator;
    var parsed = try Json.parseValue(allocator, "{\"a\":{\"b\":{\"c\":123}}}");
    defer parsed.deinit();

    const val = try parsed.value.getFieldPath(&.{ "a", "b", "c" });
    try std.testing.expectEqual(@as(i64, 123), try val.integer());

    try std.testing.expect(parsed.value.hasPath(&.{ "a", "b" }));
    try std.testing.expect(!parsed.value.hasPath(&.{ "a", "x" }));
}

test "JsonValue set and remove" {
    const allocator = std.testing.allocator;
    var parsed = try Json.parseValue(allocator, "{\"x\":1}");
    defer parsed.deinit();

    try parsed.value.setString("y", "hello");
    try std.testing.expectEqualStrings("hello", try parsed.value.getString("y"));

    try parsed.value.setInt("z", 99);
    try std.testing.expectEqual(@as(i64, 99), try parsed.value.getInt("z"));

    try std.testing.expect(parsed.value.remove("x"));
    try std.testing.expect(!parsed.value.has("x"));
}

test "JsonValue iteration" {
    const allocator = std.testing.allocator;
    var parsed = try Json.parseValue(allocator, "{\"a\":1,\"b\":2}");
    defer parsed.deinit();

    var count: usize = 0;
    var it = parsed.value.objectIterator();
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "isJsonContentType" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("application/json "));
    try std.testing.expect(isJsonContentType("APPLICATION/JSON"));
    try std.testing.expect(isJsonContentType("application/vnd.api+json"));
    try std.testing.expect(isJsonContentType(" application/json"));
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType("application/xml"));
    try std.testing.expect(!isJsonContentType(""));
}

/// Dynamic JSON builder for constructing JSON objects.
pub const JsonBuilder = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8) = .empty,
    depth: usize = 0,
    needs_comma: bool = false,

    const Self = @This();

    /// Creates a new JSON builder.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Releases builder resources.
    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Starts a JSON object.
    pub fn beginObject(self: *Self) !void {
        try self.maybeComma();
        try self.buffer.append(self.allocator, '{');
        self.depth += 1;
        self.needs_comma = false;
    }

    /// Ends the current JSON object.
    pub fn endObject(self: *Self) !void {
        try self.buffer.append(self.allocator, '}');
        self.depth -= 1;
        self.needs_comma = true;
    }

    /// Starts a JSON array.
    pub fn beginArray(self: *Self) !void {
        try self.maybeComma();
        try self.buffer.append(self.allocator, '[');
        self.depth += 1;
        self.needs_comma = false;
    }

    /// Ends the current JSON array.
    pub fn endArray(self: *Self) !void {
        try self.buffer.append(self.allocator, ']');
        self.depth -= 1;
        self.needs_comma = true;
    }

    /// Writes an object key.
    pub fn key(self: *Self, name: []const u8) !void {
        try self.maybeComma();
        try self.writeString(name);
        try self.buffer.append(self.allocator, ':');
        self.needs_comma = false;
    }

    /// Writes a string value.
    pub fn string(self: *Self, value: []const u8) !void {
        try self.maybeComma();
        try self.writeString(value);
        self.needs_comma = true;
    }

    /// Writes an integer value.
    pub fn number(self: *Self, value: anytype) !void {
        try self.maybeComma();
        const writer = list_writer.init(self.allocator, &self.buffer);
        try writer.print("{d}", .{value});
        self.needs_comma = true;
    }

    /// Writes a boolean value.
    pub fn boolean(self: *Self, value: bool) !void {
        try self.maybeComma();
        const str = if (value) "true" else "false";
        try self.buffer.appendSlice(self.allocator, str);
        self.needs_comma = true;
    }

    /// Writes a null value.
    pub fn nullValue(self: *Self) !void {
        try self.maybeComma();
        try self.buffer.appendSlice(self.allocator, "null");
        self.needs_comma = true;
    }

    /// Writes a float value.
    pub fn float(self: *Self, value: f64) !void {
        try self.maybeComma();
        if (std.math.isNan(value)) {
            try self.buffer.appendSlice(self.allocator, "null");
        } else if (std.math.isInf(value)) {
            try self.buffer.appendSlice(self.allocator, if (value > 0) "1e999" else "-1e999");
        } else {
            const writer = list_writer.init(self.allocator, &self.buffer);
            try writer.print("{d}", .{value});
        }
        self.needs_comma = true;
    }

    /// Writes a raw JSON fragment (already-encoded value).
    pub fn raw(self: *Self, fragment: []const u8) !void {
        try self.maybeComma();
        try self.buffer.appendSlice(self.allocator, fragment);
        self.needs_comma = true;
    }

    /// Returns the built JSON string.
    pub fn toSlice(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// Returns ownership of the JSON string.
    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn maybeComma(self: *Self) !void {
        if (self.needs_comma) {
            try self.buffer.append(self.allocator, ',');
        }
    }

    fn writeString(self: *Self, str: []const u8) !void {
        try self.buffer.append(self.allocator, '"');
        for (str) |c| {
            switch (c) {
                '"' => try self.buffer.appendSlice(self.allocator, "\\\""),
                '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buffer.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buffer.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buffer.appendSlice(self.allocator, "\\t"),
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0b, 0x0c, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f => |cc| {
                    var buf: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{cc}) catch unreachable;
                    try self.buffer.appendSlice(self.allocator, s);
                },
                else => try self.buffer.append(self.allocator, c),
            }
        }
        try self.buffer.append(self.allocator, '"');
    }
};

test "JsonBuilder object" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginObject();
    try builder.key("name");
    try builder.string("test");
    try builder.key("count");
    try builder.number(42);
    try builder.endObject();

    const result = builder.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"count\":42") != null);
}

test "JsonBuilder array" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginArray();
    try builder.number(1);
    try builder.number(2);
    try builder.number(3);
    try builder.endArray();

    try std.testing.expectEqualStrings("[1,2,3]", builder.toSlice());
}

test "JsonBuilder nested" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginObject();
    try builder.key("items");
    try builder.beginArray();
    try builder.beginObject();
    try builder.key("id");
    try builder.number(1);
    try builder.endObject();
    try builder.endArray();
    try builder.endObject();

    const result = builder.toSlice();
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"items\":[{\"id\":1}]}"));
}

test "JsonBuilder boolean and null" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginObject();
    try builder.key("active");
    try builder.boolean(true);
    try builder.key("deleted");
    try builder.boolean(false);
    try builder.key("data");
    try builder.nullValue();
    try builder.endObject();

    const result = builder.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"active\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"data\":null") != null);
}

test "JsonBuilder string escaping" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginObject();
    try builder.key("text");
    try builder.string("line1\nline2\ttab");
    try builder.endObject();

    const result = builder.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\t") != null);
}

test "JsonBuilder float and raw" {
    const allocator = std.testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.beginObject();
    try builder.key("pi");
    try builder.float(3.14);
    try builder.key("raw_json");
    try builder.raw("{\"nested\":true}");
    try builder.endObject();

    const result = builder.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"pi\":3.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"raw_json\":{\"nested\":true}") != null);
}
