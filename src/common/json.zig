//! JSON support shared by the REST and GraphQL layers.
//!
//! Three concerns live here and nowhere else:
//!
//! 1. **Media types.** [`classifyMediaType`] validates Content-Type syntax and
//!    distinguishes JSON documents, JSON5, line-delimited JSON, and JSON text
//!    sequences. [`isJsonMediaType`] is intentionally limited to document
//!    formats that Zig's standard JSON parser can consume as a single value.
//!
//! 2. **Arbitrary keys.** [`Object`] helpers read keys that are not valid Zig
//!    identifiers (`user-name`, `@context`, `Content-Type`, `123user`)
//!    directly, because JSON keys are arbitrary strings and are preserved
//!    exactly as received.
//!
//! 3. **Exact struct typing.** [`decode`] and [`encode`] use the Zig field
//!    names verbatim. Any JSON key is representable as a struct field through
//!    Zig's quoted identifiers, so no key-mapping layer is needed:
//!
//!    ```zig
//!    const User = struct {
//!        @"user-name": []const u8,
//!        @"@context": []const u8,
//!        @"123user": []const u8,
//!    };
//!    const user = try httpx.json.decode(User, arena, body);
//!    const wire = try httpx.json.encode(allocator, user);
//!    ```
//!
//!    Optional fields accept `null` and absence, fields with Zig defaults are
//!    optional on input, and unknown JSON keys are ignored so a producer can
//!    add fields without breaking consumers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mediaType = @import("mediaType.zig");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;
pub const Array = std.json.Array;

/// Canonical request/response media type used when nothing else is asked for.
pub const applicationJson = mediaType.applicationJson;
/// Canonical value, including the charset parameter every JSON body implies.
pub const applicationJsonUtf8 = mediaType.applicationJsonUtf8;

pub const MediaKind = enum { document, json5, lineDelimited, sequence, unsupported };

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn validParameters(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        if (i == value.len or value[i] != ';') return false;
        i += 1;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        const name_start = i;
        while (i < value.len and isTokenChar(value[i])) : (i += 1) {}
        if (i == name_start) return false;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        if (i == value.len or value[i] != '=') return false;
        i += 1;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        if (i == value.len) return false;
        if (value[i] == '"') {
            i += 1;
            var closed = false;
            while (i < value.len) : (i += 1) {
                const c = value[i];
                if (c == '"') {
                    i += 1;
                    closed = true;
                    break;
                }
                if (c == '\\') {
                    i += 1;
                    if (i == value.len or value[i] < 0x20 or value[i] == 0x7f) return false;
                } else if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
            }
            if (!closed) return false;
        } else {
            const start = i;
            while (i < value.len and isTokenChar(value[i])) : (i += 1) {}
            if (i == start) return false;
        }
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) : (i += 1) {}
        if (i < value.len and value[i] != ';') return false;
    }
    return true;
}

/// Normalizes a syntactically valid `Content-Type` to its lowercased
/// type/subtype. Invalid type tokens or parameters return `""`.
pub fn normalize(buf: []u8, contentType: []const u8) []const u8 {
    const value = std.mem.trim(u8, contentType, " \t");
    var i: usize = 0;
    while (i < value.len and value[i] != ';') : (i += 1) {}
    const media = std.mem.trimEnd(u8, value[0..i], " \t");
    if (media.len == 0 or media.len > buf.len or !validParameters(value[i..])) return "";
    const slash = std.mem.indexOfScalar(u8, media, '/') orelse return "";
    if (slash == 0 or slash + 1 >= media.len or std.mem.indexOfScalar(u8, media[slash + 1 ..], '/') != null) return "";
    for (media, 0..) |c, index| {
        if (index == slash) continue;
        if (!isTokenChar(c)) return "";
    }
    return std.ascii.lowerString(buf, media);
}

/// True for a valid single-document JSON media type, including structured
/// syntax suffixes and legacy aliases. Formats requiring a different parser
/// are available through `classifyMediaType` but intentionally return false.
pub fn classifyMediaType(contentType: []const u8) MediaKind {
    var buf: [96]u8 = undefined;
    const mt = normalize(&buf, contentType);
    if (mt.len == 0) return .unsupported;

    const slash = std.mem.indexOfScalar(u8, mt, '/') orelse return .unsupported;
    if (slash == 0 or slash + 1 >= mt.len) return .unsupported;
    const sub = mt[slash + 1 ..];

    if (std.mem.eql(u8, mt, "application/json") or std.mem.eql(u8, mt, "text/json") or
        std.mem.eql(u8, mt, "application/x-json") or std.mem.eql(u8, mt, "application/csp-report") or
        std.mem.endsWith(u8, sub, "+json")) return .document;
    if (std.mem.eql(u8, mt, "application/json5") or std.mem.eql(u8, mt, "text/json5")) return .json5;
    if (std.mem.eql(u8, mt, "application/jsonl") or std.mem.eql(u8, mt, "application/ndjson") or
        std.mem.eql(u8, mt, "application/x-ndjson") or std.mem.eql(u8, mt, "text/ndjson")) return .lineDelimited;
    if (std.mem.eql(u8, mt, "application/json-seq") or std.mem.eql(u8, mt, "text/json-seq")) return .sequence;
    return .unsupported;
}

pub fn isJsonMediaType(contentType: []const u8) bool {
    return classifyMediaType(contentType) == .document;
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

/// Decodes a JSON document into `T` using the exact Zig field names.
pub fn decode(comptime T: type, arena: Allocator, source: []const u8) DecodeError!T {
    const value = try parse(arena, source);
    return decodeValue(T, arena, value);
}

fn decodeValue(comptime T: type, arena: Allocator, value: Value) DecodeError!T {
    if (T == Value) return value;
    // Dynamic containers are returned as-is so callers can keep arbitrary keys.
    if (T == Object) return switch (value) {
        .object => |object| object,
        else => error.UnexpectedToken,
    };
    if (T == Array) return switch (value) {
        .array => |array| array,
        else => error.UnexpectedToken,
    };
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
        .optional => |opt| if (value == .null) null else try decodeValue(opt.child, arena, value),
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
                    else => error.UnexpectedToken,
                };
            }
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.UnexpectedToken,
            };
            const out = try arena.alloc(ptr.child, items.len);
            for (items, 0..) |item, i| out[i] = try decodeValue(ptr.child, arena, item);
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
            for (items, 0..) |item, i| out[i] = try decodeValue(arr.child, arena, item);
            break :blk out;
        },
        .@"struct" => |st| blk: {
            const object = switch (value) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            var out: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |fname, FType, fattrs| {
                // `fname` is the exact Zig field name, including quoted
                // identifiers such as `@"user-name"` or `@"@context"`.
                if (object.get(fname)) |parsed| {
                    @field(out, fname) = try decodeValue(FType, arena, parsed);
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

/// Serializes any Zig value to compact JSON using its exact field names.
pub fn encode(allocator: Allocator, value: anytype) DecodeError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const dynamic = try encodeValueTyped(@TypeOf(value), arena.allocator(), value);
    return std.json.Stringify.valueAlloc(allocator, dynamic, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Encodes any Zig value with `std.json`. Kept as the generic escape hatch for
/// values that do not need the explicit typed conversion used by [`encode`].
pub fn encodeAny(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn encodeValueTyped(comptime T: type, arena: Allocator, value: T) DecodeError!Value {
    if (T == Value) return value;
    if (T == Object) return .{ .object = value };
    if (T == Array) return .{ .array = value };
    return switch (@typeInfo(T)) {
        .null => .null,
        .bool => .{ .bool = value },
        .int, .comptime_int => .{ .integer = std.math.cast(i64, value) orelse return error.InvalidValue },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .@"enum" => .{ .string = @tagName(value) },
        .optional => if (value) |inner| try encodeValueTyped(@TypeOf(inner), arena, inner) else .null,
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) return error.UnsupportedType;
            if (ptr.child == u8) break :blk .{ .string = value };
            var out: Array = .init(arena);
            for (value) |item| try out.append(try encodeValueTyped(ptr.child, arena, item));
            break :blk .{ .array = out };
        },
        .array => |arr| blk: {
            if (arr.child == u8) break :blk .{ .string = value[0..] };
            var out: Array = .init(arena);
            for (value) |item| try out.append(try encodeValueTyped(arr.child, arena, item));
            break :blk .{ .array = out };
        },
        .@"struct" => |st| blk: {
            var out: Object = .empty;
            inline for (st.field_names) |fname| {
                // Exact Zig field name, quoted identifiers included.
                try out.put(arena, fname, try encodeValueTyped(@TypeOf(@field(value, fname)), arena, @field(value, fname)));
            }
            break :blk .{ .object = out };
        },
        else => error.UnsupportedType,
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

test "classifies JSON media types precisely and validates Content-Type syntax" {
    const testing = std.testing;
    const accepted = [_][]const u8{
        "application/json",
        "APPLICATION/JSON; charset=utf-8",
        " text/json ",
        "application/x-json",
        "application/csp-report",
        "application/problem+json",
        "application/vnd.api+json",
        "application/prs.example+json",
        "application/x.example+json",
        "application/not-yet-registered+json; charset=utf-8",
    };
    for (accepted) |ct| try testing.expect(isJsonMediaType(ct));

    try testing.expectEqual(MediaKind.json5, classifyMediaType("application/json5"));
    try testing.expectEqual(MediaKind.lineDelimited, classifyMediaType("application/x-ndjson"));
    try testing.expectEqual(MediaKind.sequence, classifyMediaType("application/json-seq"));
    try testing.expect(!isJsonMediaType("application/json5"));
    try testing.expect(!isJsonMediaType("application/jsonl"));
    try testing.expect(!isJsonMediaType("application/ndjson"));
    try testing.expect(!isJsonMediaType("application/x-ndjson"));
    try testing.expect(!isJsonMediaType("application/json-seq"));

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
        "application/not-json",
        "text/plain-json",
        "application/json/extra",
        "application /json",
        "application/json; charset=",
        "application/json; charset=\"utf-8",
        "application/json; charset=utf-8 garbage",
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
    try testing.expect(getBool(&obj, "HTTP/2").?);

    const encoded = try encode(testing.allocator, obj);
    defer testing.allocator.free(encoded);
    const roundTrip = try parse(arena.allocator(), encoded);
    for ([_][]const u8{ "user-name", "user_name", "user.name", "user name", "user@email", "user/id", "123user", "@context", "$schema", "Content-Type", "X-API-Key", "HTTP/2", "snake_case", "camelCase", "PascalCase" }) |key| {
        try testing.expect(roundTrip.object.contains(key));
    }

    // Case-insensitive helper resolves header-style keys.
    try testing.expect(getIgnoreCase(&obj, "CONTENT-TYPE") != null);
}

test "quoted identifiers decode and encode every arbitrary JSON key" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const User = struct {
        @"user-name": []const u8,
        user_name: []const u8,
        @"user.name": []const u8,
        @"user name": []const u8,
        @"user@email": []const u8,
        @"user/id": u32,
        @"123user": []const u8,
        @"@context": []const u8,
        @"$schema": []const u8,
        @"Content-Type": []const u8,
        @"X-API-Key": []const u8,
        @"HTTP/2": bool,
        snake_case: bool,
        camelCase: bool,
        PascalCase: bool,
    };

    const body =
        \\{
        \\  "user-name": "Fiaz",
        \\  "user_name": "Fiaz",
        \\  "user.name": "Fiaz",
        \\  "user name": "Fiaz",
        \\  "user@email": "fiaz@example.com",
        \\  "user/id": 123,
        \\  "123user": "Fiaz",
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

    const user = try decode(User, arena.allocator(), body);
    try testing.expectEqualStrings("Fiaz", user.@"user-name");
    try testing.expectEqualStrings("Fiaz", user.user_name);
    try testing.expectEqualStrings("Fiaz", user.@"user.name");
    try testing.expectEqualStrings("Fiaz", user.@"user name");
    try testing.expectEqualStrings("fiaz@example.com", user.@"user@email");
    try testing.expectEqual(@as(u32, 123), user.@"user/id");
    try testing.expectEqualStrings("Fiaz", user.@"123user");
    try testing.expectEqualStrings("https://schema.org", user.@"@context");
    try testing.expectEqualStrings("https://example.com/schema", user.@"$schema");
    try testing.expectEqualStrings("application/json", user.@"Content-Type");
    try testing.expectEqualStrings("secret", user.@"X-API-Key");
    try testing.expect(user.@"HTTP/2");
    try testing.expect(user.snake_case);
    try testing.expect(user.camelCase);
    try testing.expect(user.PascalCase);

    // Encoding uses the exact same quoted field names.
    const encoded = try encode(testing.allocator, user);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"user-name\":\"Fiaz\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"user/id\":123") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"@context\":\"https://schema.org\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"HTTP/2\":true") != null);
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

    const encoded = try encode(arena.allocator(), profile);
    const decoded = try decode(Profile, arena.allocator(), encoded);
    try testing.expectEqualStrings("Example User", decoded.name);
    try testing.expectEqual(Role.admin, decoded.role);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(f64, 9.5), decoded.score);
    try testing.expectEqual(@as(usize, 2), decoded.tags.len);
    try testing.expectEqualStrings("Lahore", decoded.address.city);
}
