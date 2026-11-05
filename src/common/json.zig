//! JSON support shared by the REST and GraphQL layers.
//!
//! Three concerns live here and nowhere else:
//!
//! 1. **Media types.** [`isJsonMediaType`] accepts every registered and
//!    de-facto JSON media type, not just `application/json`: structured
//!    syntax suffixes (`problem+json`, `vnd.api+json`, `ld+json`, …),
//!    vendor/personal/experimental trees (`vnd.`, `prs.`, `x.`), the
//!    newline-delimited families (`ndjson`, `jsonl`, `json-seq`), `json5`,
//!    legacy `text/json` / `application/x-json`, and `application/csp-report`.
//!    Parameters (`; charset=utf-8`) and casing never matter.
//!
//! 2. **Arbitrary keys.** [`Object`] helpers read keys that are not valid Zig
//!    identifiers (`user-name`, `@context`, `Content-Type`, `123user`)
//!    directly, because JSON keys are arbitrary strings and are preserved
//!    exactly as received.
//!
//! 3. **Explicit key mapping.** [`decodeNamed`] / [`encodeNamed`] take a
//!    comptime rename map and map Zig fields onto any JSON key:
//!
//!    ```zig
//!    const User = struct { user_name: []const u8, context: []const u8 };
//!    const names = .{ .user_name = "user-name", .context = "@context" };
//!    const user = try httpx.json.decodeNamed(User, arena, body, names);
//!    const wire = try httpx.json.encodeNamed(allocator, user, names);
//!    ```
//!
//!    Unmapped fields keep their Zig name, optional fields accept `null` and
//!    absence, and unknown JSON keys are always ignored so a producer can add
//!    fields without breaking consumers.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;
pub const Array = std.json.Array;

/// Canonical request/response media type used when nothing else is asked for.
pub const applicationJson = "application/json";
/// Canonical value, including the charset parameter every JSON body implies.
pub const applicationJsonUtf8 = "application/json; charset=utf-8";

/// Formats that carry JSON without a `json` token in the subtype.
const plainFormats = [_][]const u8{"csp-report"};

/// Normalizes a `Content-Type` value: parameters dropped, surrounding
/// whitespace trimmed, and the rest lowercased into `buf`. Returns `""` when
/// the value does not fit or is empty.
pub fn normalize(buf: []u8, contentType: []const u8) []const u8 {
    const raw = contentType[0..(std.mem.indexOfScalar(u8, contentType, ';') orelse contentType.len)];
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return "";
    return std.ascii.lowerString(buf, trimmed);
}

/// True for every JSON media type. Detection is rule-based, not a snapshot of
/// the registry, so new vendor types work without a table update:
///
/// * `<anything>+json` — the structured-syntax suffix (`problem+json`,
///   `merge-patch+json`, `vnd.api+json`, `hal+json`, `ld+json`, `geo+json`,
///   `jrd+json`, `webpush-options+json`, `graphql-response+json`, and the
///   `prs.` / `x.` trees).
/// * `json` as the subtype, with an optional vendor or transport prefix
///   (`x-`, `nd`) and an optional version or delimiter suffix
///   (`json5`, `jsonl`, `json-seq`).
/// * `csp-report`, which is JSON without a `json` token.
///
/// Parameters (`; charset=utf-8`) and casing never matter. Lookalikes such as
/// `application/jsonx` are rejected.
pub fn isJsonMediaType(contentType: []const u8) bool {
    var buf: [96]u8 = undefined;
    const mt = normalize(&buf, contentType);
    if (mt.len == 0) return false;

    const slash = std.mem.indexOfScalar(u8, mt, '/') orelse return false;
    if (slash == 0 or slash + 1 >= mt.len) return false;
    const sub = mt[slash + 1 ..];

    if (std.mem.endsWith(u8, sub, "+json")) return true;
    for (plainFormats) |known| {
        if (std.mem.eql(u8, sub, known)) return true;
    }

    const rest = if (std.mem.startsWith(u8, sub, "x-")) sub[2..] else sub;
    const idx = std.mem.indexOf(u8, rest, "json") orelse return false;
    const prefix = rest[0..idx];
    const suffix = rest[idx + 4 ..];
    if (!(prefix.len == 0 or std.mem.eql(u8, prefix, "nd"))) return false;
    if (suffix.len == 0) return true;
    return switch (suffix[0]) {
        '0'...'9', '-', '_', '.' => true,
        'l' => suffix.len == 1,
        else => false,
    };
}

/// Parses a JSON document into a dynamically typed value. The returned value
/// borrows `arena`; keys stay exactly as written in the document.
pub fn parse(arena: Allocator, source: []const u8) DecodeError!Value {
    const parsed = std.json.parseFromSlice(Value, arena, source, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    return parsed.value;
}

pub const DecodeError = Allocator.Error || error{
    InvalidJson,
    UnexpectedToken,
    MissingField,
    InvalidValue,
    UnsupportedType,
};

/// JSON key for a Zig field. `names` is a comptime rename map such as
/// `.{ .user_name = "user-name", .context = "@context" }`; fields absent from
/// the map keep their Zig name.
pub fn keyFor(comptime names: anytype, comptime field: []const u8) []const u8 {
    if (@typeInfo(@TypeOf(names)) == .@"struct" and @hasField(@TypeOf(names), field)) {
        return @field(names, field);
    }
    return field;
}

/// True when `names` maps at least one field, used to pick the fast path.
pub fn hasNames(comptime names: anytype) bool {
    return @typeInfo(@TypeOf(names)) == .@"struct" and @typeInfo(@TypeOf(names)).@"struct".field_names.len > 0;
}

/// Decodes a JSON document into `T` using Zig field names.
pub fn decode(comptime T: type, arena: Allocator, source: []const u8) DecodeError!T {
    return decodeNamed(T, arena, source, .{});
}

/// Decodes a JSON document into `T`, mapping fields through `names`.
pub fn decodeNamed(comptime T: type, arena: Allocator, source: []const u8, comptime names: anytype) DecodeError!T {
    const value = try parse(arena, source);
    return fromValue(T, arena, value, names);
}

/// Converts an already-parsed JSON value into `T`, mapping fields through `names`.
pub fn fromValue(comptime T: type, arena: Allocator, value: Value, comptime names: anytype) DecodeError!T {
    if (T == Value) return value;
    return switch (@typeInfo(T)) {
        .bool => switch (value) {
            .bool => |b| b,
            else => error.UnexpectedToken,
        },
        .int => switch (value) {
            .integer => |i| std.math.cast(T, i) orelse error.InvalidValue,
            .number_string => |s| std.fmt.parseInt(T, s, 10) catch error.InvalidValue,
            else => error.UnexpectedToken,
        },
        .float => switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .number_string => |s| std.fmt.parseFloat(T, s) catch error.InvalidValue,
            else => error.UnexpectedToken,
        },
        .optional => |opt| if (value == .null) null else try fromValue(opt.child, arena, value, names),
        .@"enum" => |en| blk: {
            _ = en;
            const text = switch (value) {
                .string => |s| s,
                else => return error.UnexpectedToken,
            };
            break :blk std.meta.stringToEnum(T, text) orelse error.InvalidValue;
        },
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) return error.UnsupportedType;
            if (ptr.child == u8) {
                break :blk switch (value) {
                    .string => |s| s,
                    .null => "",
                    else => error.UnexpectedToken,
                };
            }
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.UnexpectedToken,
            };
            const out = try arena.alloc(ptr.child, items.len);
            for (items, 0..) |item, i| out[i] = try fromValue(ptr.child, arena, item, names);
            break :blk out;
        },
        .array => |arr| blk: {
            if (arr.child == u8) return error.UnsupportedType;
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.UnexpectedToken,
            };
            if (items.len != arr.len) return error.InvalidValue;
            var out: T = undefined;
            for (items, 0..) |item, i| out[i] = try fromValue(arr.child, arena, item, names);
            break :blk out;
        },
        .@"struct" => |st| blk: {
            const obj = switch (value) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            var out: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |fname, FType, fattrs| {
                const key = comptime keyFor(names, fname);
                if (obj.get(key)) |fieldValue| {
                    @field(out, fname) = try fromValue(FType, arena, fieldValue, names);
                } else if (comptime @typeInfo(FType) == .optional) {
                    @field(out, fname) = null;
                } else if (fattrs.default_value_ptr != null) {
                    const defaultValue: *const FType = @ptrCast(@alignCast(fattrs.default_value_ptr.?));
                    @field(out, fname) = defaultValue.*;
                } else {
                    return error.MissingField;
                }
            }
            break :blk out;
        },
        else => error.UnsupportedType,
    };
}

/// Converts any Zig value into a JSON value, mapping fields through `names`.
pub fn toValue(comptime T: type, arena: Allocator, value: T, comptime names: anytype) DecodeError!Value {
    if (T == Value) return value;
    return switch (@typeInfo(T)) {
        .null => .null,
        .bool => .{ .bool = value },
        .int, .comptime_int => .{ .integer = std.math.cast(i64, value) orelse return error.InvalidValue },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .@"enum" => .{ .string = @tagName(value) },
        .optional => if (value) |inner| try toValue(@TypeOf(inner), arena, inner, names) else .null,
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) return error.UnsupportedType;
            if (ptr.child == u8) break :blk .{ .string = value };
            var out: Array = .init(arena);
            for (value) |item| try out.append(try toValue(ptr.child, arena, item, names));
            break :blk .{ .array = out };
        },
        .array => |arr| blk: {
            if (arr.child == u8) break :blk .{ .string = value[0..] };
            var out: Array = .init(arena);
            for (value) |item| try out.append(try toValue(arr.child, arena, item, names));
            break :blk .{ .array = out };
        },
        .@"struct" => |st| blk: {
            var out: Object = .empty;
            inline for (st.field_names) |fname| {
                const key = comptime keyFor(names, fname);
                try out.put(arena, key, try toValue(@TypeOf(@field(value, fname)), arena, @field(value, fname), names));
            }
            break :blk .{ .object = out };
        },
        else => error.UnsupportedType,
    };
}

/// Serializes any Zig value to compact JSON, mapping fields through `names`.
pub fn encodeNamed(allocator: Allocator, value: anytype, comptime names: anytype) DecodeError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const dynamic = try toValue(@TypeOf(value), arena.allocator(), value, names);
    return std.json.Stringify.valueAlloc(allocator, dynamic, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Looks up a key exactly as received, including keys that are not valid Zig
/// identifiers (`user-name`, `@context`, `Content-Type`, `123user`).
pub fn get(object: *const Object, key: []const u8) ?Value {
    return object.get(key);
}

/// Case-insensitive lookup, useful for header-style keys (`Content-Type`).
pub fn getIgnoreCase(object: *const Object, key: []const u8) ?Value {
    for (object.keys(), 0..) |candidate, i| {
        if (std.ascii.eqlIgnoreCase(candidate, key)) return object.values()[i];
    }
    return null;
}

pub fn getString(object: *const Object, key: []const u8) ?[]const u8 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .integer, .float, .number_string, .bool => null,
        else => null,
    };
}

pub fn getInt(object: *const Object, key: []const u8) ?i64 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn getFloat(object: *const Object, key: []const u8) ?f64 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn getBool(object: *const Object, key: []const u8) ?bool {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getObject(object: *const Object, key: []const u8) ?Object {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn getArray(object: *const Object, key: []const u8) ?Array {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

test "accepts JSON media types by rule, not by a fixed list" {
    const testing = std.testing;
    const accepted = [_][]const u8{
        "application/json",
        "APPLICATION/JSON; charset=utf-8",
        " text/json ",
        "application/x-json",
        "application/json5",
        "application/jsonl",
        "application/ndjson",
        "application/x-ndjson",
        "application/json-seq",
        "application/csp-report",
        "application/problem+json",
        "application/vnd.api+json",
        "application/prs.example+json",
        "application/x.example+json",
        "application/not-yet-registered+json; charset=utf-8",
    };
    for (accepted) |ct| try testing.expect(isJsonMediaType(ct));

    const rejected = [_][]const u8{
        "",
        "   ",
        "text/plain",
        "application/xml",
        "application/octet-stream",
        "multipart/form-data; boundary=x",
        "application/x-www-form-urlencoded",
        "application/graphql",
        "text/html; charset=utf-8",
        "application/jsonx",
        "application/jsonx+jsonx",
    };
    for (rejected) |ct| try testing.expect(!isJsonMediaType(ct));
}

test "reads arbitrary JSON keys that are not Zig identifiers" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{
        \\  "user-name": "Example User",
        \\  "user_name": "Example User",
        \\  "user.name": "Example User",
        \\  "user name": "Example User",
        \\  "user@email": "user@example.com",
        \\  "user/id": 123,
        \\  "123user": "Example User",
        \\  "@context": "https://schema.org",
        \\  "$schema": "https://example.com/schema",
        \\  "Content-Type": "application/json",
        \\  "X-API-Key": "secret",
        \\  "HTTP/2": true,
        \\  "snake_case": true,
        \\  "camelCase": true,
        \\  "PascalCase": true
        \\}
    ;
    const parsed = try parse(arena.allocator(), body);
    const obj = parsed.object;

    try testing.expectEqualStrings("Example User", getString(&obj, "user-name").?);
    try testing.expectEqualStrings("Example User", getString(&obj, "user.name").?);
    try testing.expectEqualStrings("Example User", getString(&obj, "user name").?);
    try testing.expectEqualStrings("user@example.com", getString(&obj, "user@email").?);
    try testing.expectEqual(@as(i64, 123), getInt(&obj, "user/id").?);
    try testing.expectEqualStrings("Example User", getString(&obj, "123user").?);
    try testing.expectEqualStrings("https://schema.org", getString(&obj, "@context").?);
    try testing.expectEqualStrings("https://example.com/schema", getString(&obj, "$schema").?);
    try testing.expectEqualStrings("application/json", getString(&obj, "Content-Type").?);
    try testing.expectEqualStrings("secret", getString(&obj, "X-API-Key").?);
    try testing.expectEqual(true, getBool(&obj, "HTTP/2").?);
    try testing.expectEqual(true, getBool(&obj, "snake_case").?);
    try testing.expectEqual(true, getBool(&obj, "camelCase").?);
    try testing.expectEqual(true, getBool(&obj, "PascalCase").?);
    try testing.expectEqualStrings("application/json", getIgnoreCase(&obj, "content-type").?.string);

    // Dynamic object serialization retains arbitrary keys exactly.
    const encoded = try std.json.Stringify.valueAlloc(testing.allocator, parsed, .{});
    defer testing.allocator.free(encoded);
    const roundTrip = try parse(arena.allocator(), encoded);
    for ([_][]const u8{ "user-name", "user_name", "user.name", "user name", "user@email", "user/id", "123user", "@context", "$schema", "Content-Type", "X-API-Key", "HTTP/2", "snake_case", "camelCase", "PascalCase" }) |key| {
        try testing.expect(roundTrip.object.contains(key));
    }

    // Case-insensitive helper resolves header-style keys.
    try testing.expect(getIgnoreCase(&obj, "CONTENT-TYPE") != null);
}

test "decodes and encodes structs through an explicit key map" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const User = struct {
        user_name: []const u8,
        context: []const u8,
        user_id: u32,
        nickname: ?[]const u8 = null,
    };
    const names = .{ .user_name = "user-name", .context = "@context", .user_id = "user/id" };

    const body =
        \\{"user-name":"Example User","@context":"https://schema.org","user/id":7,"extra":true}
    ;
    const user = try decodeNamed(User, arena.allocator(), body, names);
    try testing.expectEqualStrings("Example User", user.user_name);
    try testing.expectEqualStrings("https://schema.org", user.context);
    try testing.expectEqual(@as(u32, 7), user.user_id);
    try testing.expect(user.nickname == null);

    const encoded = try encodeNamed(testing.allocator, user, names);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"user-name\":\"Example User\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"@context\":\"https://schema.org\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"user/id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"nickname\":null") != null);
}

test "missing required fields and wrong tokens are reported" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const User = struct { name: []const u8 };
    try testing.expectError(error.MissingField, decode(User, arena.allocator(), "{}"));
    try testing.expectError(error.UnexpectedToken, decode(User, arena.allocator(), "[]"));
    try testing.expectError(error.InvalidJson, decode(User, arena.allocator(), "{"));
}

test "round-trips nested structures, enums, and slices" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Role = enum { admin, member };
    const Address = struct { city: []const u8, zip: []const u8 };
    const Profile = struct {
        name: []const u8,
        role: Role,
        active: bool,
        score: f64,
        tags: []const []const u8,
        address: Address,
    };

    const profile = Profile{
        .name = "Example User",
        .role = .admin,
        .active = true,
        .score = 9.5,
        .tags = &.{ "one", "two" },
        .address = .{ .city = "Lahore", .zip = "54000" },
    };

    const encoded = try encodeNamed(arena.allocator(), profile, .{});
    const decoded = try decodeNamed(Profile, arena.allocator(), encoded, .{});
    try testing.expectEqualStrings("Example User", decoded.name);
    try testing.expectEqual(Role.admin, decoded.role);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(f64, 9.5), decoded.score);
    try testing.expectEqual(@as(usize, 2), decoded.tags.len);
    try testing.expectEqualStrings("Lahore", decoded.address.city);
}
