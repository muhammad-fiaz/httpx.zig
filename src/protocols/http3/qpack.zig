// QPACK - QUIC header compression (RFC 9204).
// Modeled on nghttp3_qpack. Implements:
//   * Static table lookup (99 entries)
//   * Instruction encoding/decoding:
//       - Indexed field line (S=1, 6-bit prefix)
//       - Literal field line without name reference (S+R, 3-bit prefix)
//   * Required insert count in section prefix
//
// Full dynamic table with streams is layered at connection level.

const std = @import("std");
const Allocator = std.mem.Allocator;
const varint = @import("../quic/varint.zig");
const huff = @import("../common/huffman.zig");

pub const Error = error{
    InvalidIndex,
    InvalidInstruction,
    TableCapacityExceeded,
    OutOfMemory,
    BufferTooSmall,
};

pub const ENTRY_OVERHEAD: usize = 32;

fn take(data: []const u8, offset: *usize, length: u64) Error![]const u8 {
    const n = std.math.cast(usize, length) orelse return Error.InvalidInstruction;
    if (offset.* > data.len or n > data.len - offset.*) return Error.InvalidInstruction;
    const result = data[offset.*..][0..n];
    offset.* += n;
    return result;
}

fn readString(allocator: Allocator, data: []const u8, offset: *usize) Error![]u8 {
    if (offset.* >= data.len) return Error.InvalidInstruction;
    const huffman_encoded = data[offset.*] & 0x80 != 0;
    const length = try decodeInt(data, offset, 7);
    const encoded = try take(data, offset, length);
    if (!huffman_encoded) return allocator.dupe(u8, encoded) catch return Error.OutOfMemory;

    const doubled = std.math.mul(usize, encoded.len, 2) catch return Error.OutOfMemory;
    const capacity = std.math.add(usize, doubled, 1) catch return Error.OutOfMemory;
    const decoded = allocator.alloc(u8, capacity) catch return Error.OutOfMemory;
    errdefer allocator.free(decoded);
    const n = huff.decode(decoded, encoded) catch return Error.InvalidInstruction;
    return allocator.realloc(decoded, n) catch return Error.OutOfMemory;
}

pub const StaticEntry = struct { name: []const u8, value: []const u8 };

/// QPACK static table (RFC 9204 Appendix A) - first entries shown; full list encoded.
pub const STATIC_TABLE_SIZE = 99;

fn se(name: []const u8, value: []const u8) StaticEntry {
    return .{ .name = name, .value = value };
}

pub const static_table = [_]StaticEntry{
    se(":authority", ""), // 0
    se(":path", "/"), // 1
    se("age", "0"), // 2
    se("content-disposition", ""), // 3
    se("content-length", "0"), // 4
    se("cookie", ""), // 5
    se("date", ""), // 6
    se("etag", ""), // 7
    se("if-modified-since", ""), // 8
    se("if-none-match", ""), // 9
    se("last-modified", ""), // 10
    se("link", ""), // 11
    se("location", ""), // 12
    se("referer", ""), // 13
    se("set-cookie", ""), // 14
    se(":method", "CONNECT"), // 15
    se(":method", "DELETE"), // 16
    se(":method", "GET"), // 17
    se(":method", "HEAD"), // 18
    se(":method", "OPTIONS"), // 19
    se(":method", "POST"), // 20
    se(":method", "PUT"), // 21
    se(":scheme", "http"), // 22
    se(":scheme", "https"), // 23
    se(":status", "103"), // 24
    se(":status", "200"), // 25
    se(":status", "304"), // 26
    se(":status", "404"), // 27
    se(":status", "503"), // 28
    se("accept", "*/*"), // 29
    se("accept", "application/dns-message"), // 30
    se("accept-encoding", "gzip, deflate, br"), // 31
    se("accept-ranges", "bytes"), // 32
    se("access-control-allow-headers", "cache-control"), // 33
    se("access-control-allow-headers", "content-type"), // 34
    se("access-control-allow-origin", "*"), // 35
    se("cache-control", "max-age=0"), // 36
    se("cache-control", "max-age=2592000"), // 37
    se("cache-control", "max-age=604800"), // 38
    se("cache-control", "no-cache"), // 39
    se("cache-control", "no-store"), // 40
    se("cache-control", "public, max-age=31536000"), // 41
    se("content-encoding", "br"), // 42
    se("content-encoding", "gzip"), // 43
    se("content-type", "application/dns-message"), // 44
    se("content-type", "application/javascript"), // 45
    se("content-type", "application/json"), // 46
    se("content-type", "application/x-www-form-urlencoded"), // 47
    se("content-type", "image/gif"), // 48
    se("content-type", "image/jpeg"), // 49
    se("content-type", "image/png"), // 50
    se("content-type", "text/css"), // 51
    se("content-type", "text/html; charset=utf-8"), // 52
    se("content-type", "text/plain"), // 53
    se("content-type", "text/plain;charset=utf-8"), // 54
    se("range", "bytes=0-"), // 55
    se("strict-transport-security", "max-age=31536000"), // 56
    se("strict-transport-security", "max-age=31536000; includesubdomains"), // 57
    se("strict-transport-security", "max-age=31536000; includesubdomains; preload"), // 58
    se("vary", "accept-encoding"), // 59
    se("vary", "origin"), // 60
    se("x-content-type-options", "nosniff"), // 61
    se("x-xss-protection", "1; mode=block"), // 62
    se(":status", "100"), // 63
    se(":status", "204"), // 64
    se(":status", "206"), // 65
    se(":status", "302"), // 66
    se(":status", "400"), // 67
    se(":status", "403"), // 68
    se(":status", "421"), // 69
    se(":status", "425"), // 70
    se(":status", "500"), // 71
    se("accept-language", ""), // 72
    se("access-control-allow-credentials", "FALSE"), // 73
    se("access-control-allow-credentials", "TRUE"), // 74
    se("access-control-allow-headers", "*"), // 75
    se("access-control-allow-methods", "get"), // 76
    se("access-control-allow-methods", "get, post, options"), // 77
    se("access-control-allow-methods", "options"), // 78
    se("access-control-expose-headers", "content-length"), // 79
    se("access-control-request-headers", "content-type"), // 80
    se("access-control-request-method", "get"), // 81
    se("access-control-request-method", "post"), // 82
    se("alt-svc", "clear"), // 83
    se("authorization", ""), // 84
    se("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"), // 85
    se("early-data", "1"), // 86
    se("expect-ct", ""), // 87
    se("forwarded", ""), // 88
    se("if-range", ""), // 89
    se("origin", ""), // 90
    se("purpose", "prefetch"), // 91
    se("server", ""), // 92
    se("timing-allow-origin", "*"), // 93
    se("upgrade-insecure-requests", "1"), // 94
    se("user-agent", ""), // 95
    se("x-forwarded-for", ""), // 96
    se("x-frame-options", "deny"), // 97
    se("x-frame-options", "sameorigin"), // 98
};

// Integer primitives shared with HPACK-style prefixes

pub fn encodeInt(buf: []u8, prefix_bits: u4, value: u64) Error!usize {
    if (buf.len < 1) return Error.BufferTooSmall;
    const max_prefix: u64 = (@as(u64, 1) << prefix_bits) - 1;
    buf[0] = 0;

    if (value < max_prefix) {
        buf[0] |= @intCast(value);
        return 1;
    }
    buf[0] |= @intCast(max_prefix);
    var remaining = value - max_prefix;
    var pos: usize = 1;
    while (remaining >= 128) {
        if (pos >= buf.len) return Error.BufferTooSmall;
        buf[pos] = @intCast((remaining % 128) + 128);
        remaining /= 128;
        pos += 1;
    }
    if (pos >= buf.len) return Error.BufferTooSmall;
    buf[pos] = @intCast(remaining);
    return pos + 1;
}

pub fn decodeInt(data: []const u8, offset: *usize, prefix_bits: u4) Error!u64 {
    if (offset.* >= data.len) return Error.InvalidInstruction;
    const max_prefix: u64 = (@as(u64, 1) << prefix_bits) - 1;
    var value: u64 = data[offset.*] & @as(u8, @intCast(max_prefix));
    offset.* += 1;
    if (value < max_prefix) return value;

    var shift: u6 = 0;
    var terminated = false;
    while (offset.* < data.len) {
        const b = data[offset.*];
        offset.* += 1;
        if (shift >= 63 and (b & 0x7F) > 1) return Error.InvalidInstruction;
        const contribution = @as(u64, b & 0x7F) << shift;
        value = std.math.add(u64, value, contribution) catch return Error.InvalidInstruction;
        if (b & 0x80 == 0) {
            terminated = true;
            break;
        }
        shift += 7;
        if (shift > 63) return Error.InvalidInstruction;
    }
    if (!terminated) return Error.InvalidInstruction;
    return value;
}

// Dynamic table entry (RFC 9204 Section 2.3.2).

pub const DynEntry = struct {
    name: []const u8,
    value: []const u8,
    /// Total size = name.len + value.len + ENTRY_OVERHEAD (32).
    total_size: usize,
};

pub const DynTable = struct {
    entries: std.ArrayList(DynEntry),
    max_size: usize,
    current_size: usize = 0,
    /// Absolute index of the oldest retained dynamic entry.
    base_index: u64 = STATIC_TABLE_SIZE,
    /// Absolute index assigned to the next insertion.
    next_index: u64 = STATIC_TABLE_SIZE,

    pub fn init(_: Allocator, max_size: usize) DynTable {
        return .{
            .entries = std.ArrayList(DynEntry).empty,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *DynTable, allocator: Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        self.entries.deinit(allocator);
    }

    /// Inserts a new entry, evicting oldest entries to stay within max_size.
    pub fn insert(self: *DynTable, allocator: Allocator, name: []const u8, value: []const u8) !u64 {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);

        const total = std.math.add(usize, std.math.add(usize, name.len, value.len) catch return Error.OutOfMemory, ENTRY_OVERHEAD) catch return Error.OutOfMemory;
        if (total > self.max_size) return Error.TableCapacityExceeded;
        const index = self.next_index;

        // Evict from oldest (index = STATIC_TABLE_SIZE) until room.
        while (self.current_size + total > self.max_size and self.entries.items.len > 0) {
            const old = self.entries.orderedRemove(0);
            self.current_size -%= old.total_size;
            self.base_index = std.math.add(u64, self.base_index, 1) catch return Error.OutOfMemory;
            allocator.free(old.name);
            allocator.free(old.value);
        }

        try self.entries.append(allocator, .{
            .name = owned_name,
            .value = owned_value,
            .total_size = total,
        });
        self.current_size += total;
        self.next_index = std.math.add(u64, self.next_index, 1) catch return Error.OutOfMemory;
        return @intCast(index);
    }

    /// Resolves a QPACK absolute index to a name+value pair.
    pub fn resolve(self: *const DynTable, absolute_index: u64) ?struct { name: []const u8, value: []const u8 } {
        if (absolute_index < STATIC_TABLE_SIZE) {
            const e = static_table[@intCast(absolute_index)];
            return .{ .name = e.name, .value = e.value };
        }
        if (absolute_index < self.base_index) return null;
        const dyn_idx = absolute_index - self.base_index;
        if (dyn_idx >= self.entries.items.len) return null;
        const e = self.entries.items[@intCast(dyn_idx)];
        return .{ .name = e.name, .value = e.value };
    }
};

// Encoder

pub const Encoder = struct {
    allocator: Allocator,
    dyn: ?DynTable = null,

    pub fn init(allocator: Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    /// Releases the optional dynamic table and all strings owned by it.
    pub fn deinit(self: *Encoder) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
    }

    pub fn setMaxTableCapacity(self: *Encoder, capacity: usize) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        if (capacity != 0) {
            self.dyn = DynTable.init(self.allocator, capacity);
        }
    }

    /// Encodes a header as literal-without-name-reference on the instruction stream.
    /// S flag cleared (never index). R bit reserved.
    pub fn encodeField(
        self: *Encoder,
        out: *std.ArrayList(u8),
        name: []const u8,
        value: []const u8,
    ) !void {
        // Try static table match first
        if (self.encodeStaticMatch(out, name, value)) {
            return;
        }

        // Try dynamic table match (name only), then literal with name ref
        if (self.dyn) |*dt| {
            const base = STATIC_TABLE_SIZE;
            var i: usize = dt.entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = dt.entries.items[i];
                if (std.mem.eql(u8, e.name, name)) {
                    // Literal with dynamic name reference
                    const absolute_idx = base + i;
                    var ib: [10]u8 = undefined;
                    const n = try encodeInt(&ib, 4, absolute_idx);
                    ib[0] |= 0x40; // 01, N=0, S=0
                    try out.appendSlice(self.allocator, ib[0..n]);
                    // Value as literal
                    var vn: [10]u8 = undefined;
                    const vlen = try encodeInt(&vn, 7, value.len);
                    try out.appendSlice(self.allocator, vn[0..vlen]);
                    try out.appendSlice(self.allocator, value);
                    return;
                }
            }
        }

        // No match: literal without name reference
        try out.append(self.allocator, 0x00);

        var ib: [10]u8 = undefined;
        var n = try encodeInt(&ib, 7, name.len);
        try out.appendSlice(self.allocator, ib[0..n]);
        try out.appendSlice(self.allocator, name);

        n = try encodeInt(&ib, 7, value.len);
        try out.appendSlice(self.allocator, ib[0..n]);
        try out.appendSlice(self.allocator, value);
    }

    /// Attempts to encode using a static table indexed match.
    fn encodeStaticMatch(self: *Encoder, out: *std.ArrayList(u8), name: []const u8, value: []const u8) bool {
        for (static_table, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                self.encodeIndexedStatic(out, @intCast(i)) catch return false;
                return true;
            }
        }
        return false;
    }

    /// Encodes a static-table indexed field (S=1, 6-bit prefix).
    pub fn encodeIndexedStatic(self: *Encoder, out: *std.ArrayList(u8), index: u64) !void {
        var ib: [10]u8 = undefined;
        const n = try encodeInt(&ib, 6, index);
        ib[0] |= 0xC0; // S=1 + 6-bit prefix tag
        try out.appendSlice(self.allocator, ib[0..n]);
    }

    /// Encodes a dynamic-table indexed field.
    pub fn encodeIndexedDynamic(self: *Encoder, out: *std.ArrayList(u8), absolute_index: u64) !void {
        const base = STATIC_TABLE_SIZE;
        if (absolute_index < base) {
            return try self.encodeIndexedStatic(out, absolute_index);
        }
        var ib: [10]u8 = undefined;
        const n = try encodeInt(&ib, 4, absolute_index);
        ib[0] |= 0xC0; // S=1 + 4-bit prefix
        try out.appendSlice(self.allocator, ib[0..n]);
    }
};

// Decoder

pub const FieldLine = struct {
    name: []const u8,
    value: []const u8,
    allocated: bool = false,
};

pub const Decoder = struct {
    allocator: Allocator,
    dyn: ?DynTable = null,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    /// Releases the optional dynamic table and all strings owned by it.
    pub fn deinit(self: *Decoder) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
    }

    pub fn setMaxTableCapacity(self: *Decoder, capacity: usize) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        if (capacity != 0) {
            self.dyn = DynTable.init(self.allocator, capacity);
        }
    }

    /// Decodes an encoded field section into field lines.
    pub fn decodeSection(self: *Decoder, data: []const u8) Error![]FieldLine {
        var results = std.ArrayList(FieldLine).empty;
        errdefer results.deinit(self.allocator);
        var offset: usize = 0;

        while (offset < data.len) {
            const first = data[offset];

            if (first & 0x80 != 0) {
                // S=1: indexed field line
                const idx = try decodeInt(data, &offset, 6);
                if (self.dyn) |*dt| {
                    if (dt.resolve(idx)) |res| {
                        try results.append(self.allocator, .{ .name = res.name, .value = res.value, .allocated = false });
                    } else {
                        return Error.InvalidIndex;
                    }
                } else {
                    if (idx >= STATIC_TABLE_SIZE) return Error.InvalidIndex;
                    const e = static_table[@intCast(idx)];
                    try results.append(self.allocator, .{ .name = e.name, .value = e.value, .allocated = false });
                }
            } else if (first & 0xF0 == 0x20 or first & 0xF0 == 0x30) {
                // Dynamic table size update (RFC 9204 Section 4.3.1)
                _ = try decodeInt(data, &offset, 4);
                // Size updates are acknowledged by the decoder; no-op here.
            } else if (first & 0xD0 == 0x50) {
                // Literal field line with a static-table name reference.
                const idx = try decodeInt(data, &offset, 4);
                if (self.dyn) |*dt| {
                    if (dt.resolve(idx)) |res| {
                        const name = try self.allocator.dupe(u8, res.name);
                        const value = readString(self.allocator, data, &offset) catch |e| {
                            self.allocator.free(name);
                            return e;
                        };
                        appendOwnedField(&results, self.allocator, name, value) catch |e| {
                            self.allocator.free(name);
                            self.allocator.free(value);
                            return e;
                        };
                    } else {
                        if (idx >= STATIC_TABLE_SIZE) return Error.InvalidIndex;
                        const name = try self.allocator.dupe(u8, static_table[@intCast(idx)].name);
                        const value = readString(self.allocator, data, &offset) catch |e| {
                            self.allocator.free(name);
                            return e;
                        };
                        appendOwnedField(&results, self.allocator, name, value) catch |e| {
                            self.allocator.free(name);
                            self.allocator.free(value);
                            return e;
                        };
                    }
                } else {
                    if (idx >= STATIC_TABLE_SIZE) return Error.InvalidIndex;
                    const name = try self.allocator.dupe(u8, static_table[@intCast(idx)].name);
                    const value = readString(self.allocator, data, &offset) catch |e| {
                        self.allocator.free(name);
                        return e;
                    };
                    appendOwnedField(&results, self.allocator, name, value) catch |e| {
                        self.allocator.free(name);
                        self.allocator.free(value);
                        return e;
                    };
                }
            } else if (first & 0xC0 == 0x40) {
                // Literal with dynamic-table name reference
                const idx = try decodeInt(data, &offset, 4);
                if (self.dyn) |*dt| {
                    if (dt.resolve(idx)) |res| {
                        const name = try self.allocator.dupe(u8, res.name);
                        const value = readString(self.allocator, data, &offset) catch |e| {
                            self.allocator.free(name);
                            return e;
                        };
                        appendOwnedField(&results, self.allocator, name, value) catch |e| {
                            self.allocator.free(name);
                            self.allocator.free(value);
                            return e;
                        };
                    } else {
                        return Error.InvalidIndex;
                    }
                } else {
                    return Error.InvalidInstruction;
                }
            } else {
                // Fallback: literal without name reference
                offset += 1;
                const name = try readString(self.allocator, data, &offset);
                const value = readString(self.allocator, data, &offset) catch |e| {
                    self.allocator.free(name);
                    return e;
                };
                appendOwnedField(&results, self.allocator, name, value) catch |e| {
                    self.allocator.free(name);
                    self.allocator.free(value);
                    return e;
                };
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Decodes a complete QPACK encoded field section, including its prefix.
    pub fn decodeSectionWithPrefix(self: *Decoder, data: []const u8) Error![]FieldLine {
        var offset: usize = 0;
        const required_insert_count = try decodeInt(data, &offset, 8);
        if (required_insert_count != 0 and self.dyn == null) return Error.InvalidInstruction;

        if (offset >= data.len) return Error.InvalidInstruction;
        const sign_and_delta = data[offset];
        const delta_base = try decodeInt(data, &offset, 7);
        if (sign_and_delta & 0x80 != 0 and delta_base != 0) return Error.InvalidInstruction;
        return self.decodeSection(data[offset..]);
    }

    pub fn freeFields(self: *Decoder, fields: []FieldLine) void {
        for (fields) |f| {
            if (f.allocated) {
                self.allocator.free(f.name);
                self.allocator.free(f.value);
            }
        }
        self.allocator.free(fields);
    }
};

fn appendOwnedField(
    results: *std.ArrayList(FieldLine),
    allocator: Allocator,
    name: []u8,
    value: []u8,
) !void {
    try results.append(allocator, .{ .name = name, .value = value, .allocated = true });
}

// Tests

test "qpack integer roundtrip" {
    var buf: [16]u8 = undefined;
    const vals = [_]u64{ 0, 62, 63, 127, 128, 255 };
    for (vals) |v| {
        const n = try encodeInt(&buf, 6, v);
        var off: usize = 0;
        const d = try decodeInt(buf[0..n], &off, 6);
        try std.testing.expectEqual(v, d);
    }
}

test "static table known entries" {
    try std.testing.expectEqualStrings(":method", static_table[17].name);
    try std.testing.expectEqualStrings("GET", static_table[17].value);
    try std.testing.expectEqualStrings(":status", static_table[25].name);
    try std.testing.expectEqualStrings("200", static_table[25].value);
}

test "encoder indexed static then decoder reads it" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);

    try enc.encodeIndexedStatic(&block, 17); // :method GET
    try enc.encodeIndexedStatic(&block, 25); // :status 200

    var dec = Decoder.init(a);
    const fields = try dec.decodeSection(block.items);
    defer dec.freeFields(fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
    try std.testing.expectEqualStrings("GET", fields[0].value);
}

test "qpack static name reference decodes without consuming a name" {
    const a = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);

    var len_buf: [10]u8 = undefined;
    const index_bytes = try encodeInt(&len_buf, 4, 17);
    len_buf[0] |= 0x50; // 01, N=0, S=1
    try block.appendSlice(a, len_buf[0..index_bytes]);
    const n = try encodeInt(&len_buf, 7, 4);
    try block.appendSlice(a, len_buf[0..n]);
    try block.appendSlice(a, "POST");

    var dec = Decoder.init(a);
    const fields = try dec.decodeSection(block.items);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
    try std.testing.expectEqualStrings("POST", fields[0].value);
}

test "qpack complete field section consumes zero dynamic prefix" {
    const a = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try block.appendSlice(a, "\x00\x00"); // Required Insert Count=0, Delta Base=0

    var enc = Encoder.init(a);
    try enc.encodeIndexedStatic(&block, 17);

    var dec = Decoder.init(a);
    const fields = try dec.decodeSectionWithPrefix(block.items);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
}

test "qpack dynamic name references fail closed" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    try std.testing.expectError(Error.InvalidInstruction, dec.decodeSection("\x41"));
}

test "qpack dynamic indexes remain monotonic across eviction" {
    const a = std.testing.allocator;
    var table = DynTable.init(a, 40);
    defer table.deinit(a);

    const first = try table.insert(a, "a", "1");
    const second = try table.insert(a, "b", "2");
    try std.testing.expectEqual(@as(u64, STATIC_TABLE_SIZE), first);
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expect(table.resolve(first) == null);
    const current = table.resolve(second) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", current.name);
}

test "qpack rejects entries larger than dynamic capacity" {
    const a = std.testing.allocator;
    var table = DynTable.init(a, 40);
    defer table.deinit(a);
    try std.testing.expectError(Error.TableCapacityExceeded, table.insert(a, "oversized-name", "oversized-value"));
    try std.testing.expectEqual(@as(usize, 0), table.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.current_size);
}

test "qpack huffman literal decodes through shared codec" {
    const a = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try block.append(a, 0x00); // literal without name reference

    var encoded: [64]u8 = undefined;
    const name_len = try huff.encode(encoded[0..], ":path");
    var len_buf: [10]u8 = undefined;
    var n = try encodeInt(&len_buf, 7, name_len);
    len_buf[0] |= 0x80;
    try block.appendSlice(a, len_buf[0..n]);
    try block.appendSlice(a, encoded[0..name_len]);

    const value_len = try huff.encode(encoded[0..], "/");
    n = try encodeInt(&len_buf, 7, value_len);
    len_buf[0] |= 0x80;
    try block.appendSlice(a, len_buf[0..n]);
    try block.appendSlice(a, encoded[0..value_len]);

    var dec = Decoder.init(a);
    const fields = try dec.decodeSection(block.items);
    defer dec.freeFields(fields);
    try std.testing.expectEqualStrings(":path", fields[0].name);
    try std.testing.expectEqualStrings("/", fields[0].value);
}
