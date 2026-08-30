//! HPACK — HTTP/2 header compression (RFC 7541).
//!
//! Complete implementation: static table, dynamic table with eviction and
//! size updates, all four representations (indexed, literal with/without
//! incremental indexing, never indexed), Huffman coding both directions,
//! and strict decoder validation. Shared primitives come from
//! protocols/common/{integer,huffman}.zig so QPACK reuses the same code.
//!
//! Decoder rules enforced:
//!   * dynamic table size updates only at block start
//!   * update value <= protocol maximum -> else COMPRESSION error
//!   * index 0 invalid; out-of-range indices invalid
//!   * truncated blocks invalid

const std = @import("std");
const Allocator = std.mem.Allocator;
const pint = @import("../common/integer.zig");
const huff = @import("../common/huffman.zig");

pub const Error = pint.Error || huff.Error || error{
    InvalidIndex,
    InvalidTableSize,
    UnexpectedTableSizeUpdate,
    BlockTooLarge,
    HeaderTooLarge,
    OutOfMemory,
};

pub const DEFAULT_TABLE_SIZE: usize = 4096;
/// Per-entry size overhead (RFC 7541 Section 4.1).
pub const ENTRY_OVERHEAD: usize = 32;
/// Hard cap on a single name/value length (DoS bound, mirrors nghttp2).
pub const MAX_STRING_LEN: usize = 65536;

// Static table (RFC 7541 Appendix A) — indices are 1-based on the wire.

pub const StaticEntry = struct { name: []const u8, value: []const u8 };

pub const static_table = [_]StaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

pub const STATIC_TABLE_SIZE = static_table.len;

fn entrySize(name: []const u8, value: []const u8) usize {
    return ENTRY_OVERHEAD + name.len + value.len;
}

// Dynamic table (shared mechanics for encoder and decoder sides)

/// Ring of entries, newest first (index 0 = most recently inserted),
/// matching the wire's relative-index direction.
const DynTable = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    size: usize = 0,
    max_size: usize = DEFAULT_TABLE_SIZE,

    const Entry = struct {
        name: []u8,
        value: []u8,
    };

    fn init(allocator: Allocator) DynTable {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DynTable) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.entries.deinit(self.allocator);
    }

    fn evictFor(self: *DynTable, incoming: usize) void {
        while (self.size + incoming > self.max_size and self.entries.items.len > 0) {
            const old = self.entries.pop() orelse break;
            self.size -= entrySize(old.name, old.value);
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
    }

    /// Inserts newest-first. An entry larger than max_size is dropped
    /// after emptying (per RFC it empties the table but is not stored).
    fn insert(self: *DynTable, name: []const u8, value: []const u8) !void {
        self.evictFor(entrySize(name, value));
        if (entrySize(name, value) > self.max_size) return; // emptied, not stored
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.entries.insert(self.allocator, 0, .{ .name = owned_name, .value = owned_value });
        self.size += entrySize(name, value);
    }

    fn setMaxSize(self: *DynTable, new_max: usize) void {
        self.max_size = new_max;
        self.evictFor(0);
    }

    fn get(self: *const DynTable, rel: usize) ?StaticEntry {
        if (rel >= self.entries.items.len) return null;
        return .{ .name = self.entries.items[rel].name, .value = self.entries.items[rel].value };
    }
};

// Decoder

pub const HeaderField = struct { name: []const u8, value: []const u8 };

pub const Decoder = struct {
    allocator: Allocator,
    dyn: DynTable,
    /// Upper bound from SETTINGS_HEADER_TABLE_SIZE the peer may not exceed.
    protocol_max_size: usize = DEFAULT_TABLE_SIZE,
    /// Set when peer shrinks below current max: next block MUST open with
    /// a table size update (RFC 7541 Section 4.2 via nghttp2 behavior).
    require_size_update: bool = false,
    max_header_list: usize = 0xFFFFFFFF,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator, .dyn = DynTable.init(allocator) };
    }

    pub fn deinit(self: *Decoder) void {
        self.dyn.deinit();
    }

    /// Applies our advertised SETTINGS_HEADER_TABLE_SIZE.
    pub fn setProtocolMaxSize(self: *Decoder, sz: usize) void {
        self.protocol_max_size = sz;
        if (self.dyn.max_size > sz) {
            self.dyn.setMaxSize(sz);
            self.require_size_update = true;
        }
    }

    fn lookup(self: *Decoder, index: u64) Error!HeaderField {
        if (index == 0) return Error.InvalidIndex;
        if (index <= STATIC_TABLE_SIZE) {
            const e = static_table[@intCast(index - 1)];
            return .{ .name = e.name, .value = e.value };
        }
        const rel: usize = @intCast(index - STATIC_TABLE_SIZE - 1);
        const e = self.dyn.get(rel) orelse return Error.InvalidIndex;
        return .{ .name = e.name, .value = e.value };
    }

    const StringResult = struct { data: []u8, owned: bool };

    fn readString(self: *Decoder, data: []const u8, offset: *usize) Error!StringResult {
        if (offset.* >= data.len) return Error.Truncated;
        const huffman_bit = data[offset.*] & 0x80 != 0;
        const len = try pint.decode(data, offset, 7);
        if (len > MAX_STRING_LEN) return Error.HeaderTooLarge;
        const raw_len = std.math.cast(usize, len) orelse return Error.HeaderTooLarge;
        if (offset.* > data.len or raw_len > data.len - offset.*) return Error.Truncated;
        const raw = data[offset.*..][0..raw_len];
        offset.* += raw_len;
        if (!huffman_bit) {
            return .{ .data = @constCast(raw), .owned = false };
        }
        const cap = huff.maxEncodedLen(@intCast(len));
        const buf = try self.allocator.alloc(u8, cap);
        errdefer self.allocator.free(buf);
        const n = huff.decode(buf, raw) catch |e| switch (e) {
            error.InvalidHuffmanCode => return Error.InvalidHuffmanCode,
            error.BufferTooSmall => return Error.HeaderTooLarge,
        };
        // Shrink to exact size (allocators tolerate smaller realloc).
        const exact = self.allocator.realloc(buf[0..cap], n) catch buf[0..n];
        return .{ .data = exact, .owned = true };
    }

    fn freeString(self: *Decoder, s: StringResult) void {
        if (s.owned) self.allocator.free(s.data);
    }

    pub const Result = struct {
        fields: []HeaderField,
        /// Total decompressed list size for SETTINGS_MAX_HEADER_LIST_SIZE checks.
        total_size: usize,
    };

    /// Decodes one complete header block fragment chain (already assembled).
    pub fn decode(self: *Decoder, block: []const u8) Error!Result {
        var list = std.ArrayList(HeaderField).empty;
        errdefer {
            for (list.items) |f| {
                self.allocator.free(f.name);
                self.allocator.free(f.value);
            }
            list.deinit(self.allocator);
        }

        var total: usize = 0;
        var offset: usize = 0;
        var at_start = true;

        while (offset < block.len) {
            const b = block[offset];

            if (b & 0x80 != 0) {
                // 1xxxxxxx: indexed header field.
                const idx = try pint.decode(block, &offset, 7);
                const f = try self.lookup(idx);
                try appendOwned(&list, self.allocator, f);
                total = std.math.add(usize, total, ENTRY_OVERHEAD + f.name.len + f.value.len) catch return Error.HeaderTooLarge;
                at_start = false;
            } else if (b & 0xC0 == 0x40) {
                // 01xxxxxx: literal WITH incremental indexing.
                const idx = try pint.decode(block, &offset, 6);
                const f = try self.readLiteral(block, &offset, idx);
                defer {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
                self.dyn.insert(f.name, f.value) catch return Error.OutOfMemory;
                try appendDup(&list, self.allocator, f);
                total = std.math.add(usize, total, ENTRY_OVERHEAD + f.name.len + f.value.len) catch return Error.HeaderTooLarge;
                at_start = false;
            } else if (b & 0xE0 == 0x20) {
                // 001xxxxx: dynamic table size update.
                if (!at_start) return Error.UnexpectedTableSizeUpdate;
                const sz = try pint.decode(block, &offset, 5);
                if (sz > self.protocol_max_size) return Error.InvalidTableSize;
                self.dyn.setMaxSize(@intCast(sz));
                self.require_size_update = false;
            } else {
                // 0000xxxx / 0001xxxx: literal without indexing / never indexed.
                const idx = try pint.decode(block, &offset, 4);
                const f = try self.readLiteral(block, &offset, idx);
                defer {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
                try appendDup(&list, self.allocator, f);
                total = std.math.add(usize, total, ENTRY_OVERHEAD + f.name.len + f.value.len) catch return Error.HeaderTooLarge;
                at_start = false;
            }
            if (total > self.max_header_list) return Error.HeaderTooLarge;
        }

        if (self.require_size_update) return Error.UnexpectedTableSizeUpdate;

        return .{
            .fields = try list.toOwnedSlice(self.allocator),
            .total_size = total,
        };
    }

    fn readLiteral(self: *Decoder, block: []const u8, offset: *usize, name_index: u64) Error!HeaderField {
        const name_res = if (name_index == 0)
            try self.readString(block, offset)
        else blk: {
            const nf = try self.lookup(name_index);
            break :blk StringResult{ .data = @constCast(nf.name), .owned = false };
        };
        defer if (name_index == 0) self.freeString(name_res);

        const val_res = try self.readString(block, offset);
        defer self.freeString(val_res);

        const owned_name = try self.allocator.dupe(u8, name_res.data);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, val_res.data);
        return .{ .name = owned_name, .value = owned_value };
    }
};

fn appendOwned(list: *std.ArrayList(HeaderField), gpa: Allocator, f: HeaderField) Error!void {
    const name = gpa.dupe(u8, f.name) catch return Error.OutOfMemory;
    errdefer gpa.free(name);
    try list.append(gpa, .{
        .name = name,
        .value = try gpa.dupe(u8, f.value),
    });
}

fn appendDup(list: *std.ArrayList(HeaderField), gpa: Allocator, f: HeaderField) Error!void {
    const name = gpa.dupe(u8, f.name) catch return Error.OutOfMemory;
    errdefer gpa.free(name);
    try list.append(gpa, .{
        .name = name,
        .value = try gpa.dupe(u8, f.value),
    });
}

// Encoder

pub const Indexing = enum {
    /// 01xxxxxx — stored in dynamic table.
    incremental,
    /// 0000xxxx — not stored.
    without,
    /// 0001xxxx — never indexed (sensitive).
    never,
};

pub const Encoder = struct {
    allocator: Allocator,
    dyn: DynTable,
    pending_size_update: ?usize = null,

    /// Names that nghttp2 avoids indexing (volatile per-request values).
    const no_index_names = [_][]const u8{
        ":path",             "age",           "content-length", "etag",
        "if-modified-since", "if-none-match", "location",       "set-cookie",
    };

    pub fn init(allocator: Allocator) Encoder {
        return .{ .allocator = allocator, .dyn = DynTable.init(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.dyn.deinit();
    }

    /// Applies negotiated SETTINGS_HEADER_TABLE_SIZE (emits an update at
    /// next encode when changed).
    pub fn applySettingsSize(self: *Encoder, sz: usize) void {
        if (self.dyn.max_size != sz) {
            self.pending_size_update = sz;
        }
        self.dyn.setMaxSize(sz);
    }

    fn findNameIndex(self: *const Encoder, name: []const u8) struct { idx: u64, in_dyn: bool } {
        for (static_table, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return .{ .idx = i + 1, .in_dyn = false };
        }
        // Dynamic indices are relative to the newest entry and start
        // AFTER the whole static table.
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name))
                return .{ .idx = STATIC_TABLE_SIZE + 1 + i, .in_dyn = true };
        }
        return .{ .idx = 0, .in_dyn = false };
    }

    fn findFullIndex(self: *const Encoder, name: []const u8, value: []const u8) ?u64 {
        for (static_table, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value)) return i + 1;
        }
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value))
                return STATIC_TABLE_SIZE + 1 + i;
        }
        return null;
    }

    fn shouldIndex(name: []const u8) bool {
        for (no_index_names) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) return false;
        }
        return true;
    }

    fn emitString(out: *std.ArrayList(u8), gpa: Allocator, data: []const u8) !void {
        if (data.len > 0) {
            const compressed = try gpa.alloc(u8, huff.maxEncodedLen(data.len));
            defer gpa.free(compressed);
            if (huff.encode(compressed, data)) |n| {
                if (n < data.len) {
                    // Huffman flag bit set + length of encoded form.
                    var tmp: [10]u8 = undefined;
                    const nn = try pint.encode(tmp[0..], 7, 0x80, n);
                    try out.appendSlice(gpa, tmp[0..nn]);
                    try out.appendSlice(gpa, compressed[0..n]);
                    return;
                }
            } else |_| {
                // Fall through to raw encoding.
            }
        }
        var tmp: [10]u8 = undefined;
        const n = try pint.encode(tmp[0..], 7, 0x00, data.len);
        try out.appendSlice(gpa, tmp[0..n]);
        try out.appendSlice(gpa, data);
    }

    /// Encodes one header field into `out`.
    pub fn encode(
        self: *Encoder,
        out: *std.ArrayList(u8),
        name_in: []const u8,
        value: []const u8,
        indexing: Indexing,
        force_literal: bool,
    ) !void {
        if (self.pending_size_update) |sz| {
            self.pending_size_update = null;
            var tmp: [10]u8 = undefined;
            const n = try pint.encode(tmp[0..], 5, 0x20, sz);
            try out.appendSlice(self.allocator, tmp[0..n]);
        }

        const name = lowerBuf(self.allocator, name_in) catch name_in;
        defer if (name.ptr != name_in.ptr) self.allocator.free(name);

        var ib: [10]u8 = undefined;

        if (!force_literal) {
            if (self.findFullIndex(name, value)) |full| {
                const n = try pint.encode(ib[0..], 7, 0x80, full);
                try out.appendSlice(self.allocator, ib[0..n]);
                return;
            }
        }

        const name_ref = self.findNameIndex(name);

        switch (indexing) {
            .incremental => {
                if (!shouldIndex(name)) {
                    const op: u8 = 0x00;
                    if (name_ref.idx != 0 and !force_literal) {
                        const n = try pint.encode(ib[0..], 4, op, name_ref.idx);
                        try out.appendSlice(self.allocator, ib[0..n]);
                    } else {
                        try out.append(self.allocator, op);
                        try emitString(out, self.allocator, name);
                    }
                    try emitString(out, self.allocator, value);
                } else {
                    try self.dyn.insert(name, value);
                    const op: u8 = 0x40;
                    if (name_ref.idx != 0 and !force_literal) {
                        const n = try pint.encode(ib[0..], 6, op, name_ref.idx);
                        try out.appendSlice(self.allocator, ib[0..n]);
                    } else {
                        try out.append(self.allocator, op);
                        try emitString(out, self.allocator, name);
                    }
                    try emitString(out, self.allocator, value);
                }
            },
            .without => {
                const op: u8 = 0x00;
                if (name_ref.idx != 0 and !force_literal) {
                    const n = try pint.encode(ib[0..], 4, op, name_ref.idx);
                    try out.appendSlice(self.allocator, ib[0..n]);
                } else {
                    try out.append(self.allocator, op);
                    try emitString(out, self.allocator, name);
                }
                try emitString(out, self.allocator, value);
            },
            .never => {
                const op: u8 = 0x10;
                if (name_ref.idx != 0 and !force_literal) {
                    const n = try pint.encode(ib[0..], 4, op, name_ref.idx);
                    try out.appendSlice(self.allocator, ib[0..n]);
                } else {
                    try out.append(self.allocator, op);
                    try emitString(out, self.allocator, name);
                }
                try emitString(out, self.allocator, value);
            },
        }
    }
};

fn lowerBuf(gpa: Allocator, name: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

// Tests

test "integer roundtrip via shared primitive" {
    var buf: [16]u8 = undefined;
    inline for ([_]u3{ 4, 5, 6, 7 }) |p| {
        for ([_]u64{ 0, 14, 15, 16, 127, 128 }) |v| {
            const n = try pint.encode(&buf, p, 0, v);
            var off: usize = 0;
            try std.testing.expectEqual(v, try pint.decode(buf[0..n], &off, p));
        }
    }
}

test "decode RFC 7541 C.2.1 literal with incremental indexing (custom-key)" {
    // Encoded: 400c 31322d33342078202d206f6e65 ... actually use the spec hex
    const block = [_]u8{
        0x40, 0x0a, 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y',
        0x0d, 'c',  'u', 's', 't', 'o', 'm', '-', 'h', 'e', 'a', 'd',
        'e',  'r',
    };
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    const res = try d.decode(&block);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 1), res.fields.len);
    try std.testing.expectEqualStrings("custom-key", res.fields[0].name);
    try std.testing.expectEqualStrings("custom-header", res.fields[0].value);
    // Entry inserted into dynamic table at index 62.
    try std.testing.expect(d.dyn.entries.items.len == 1);
}

test "decode indexed static field (C.1.2 :path /)" {
    const block = [_]u8{0x84}; // index 4 => :path /
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    const res = try d.decode(&block);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqualStrings(":path", res.fields[0].name);
    try std.testing.expectEqualStrings("/", res.fields[0].value);
}

test "huffman-coded literals decode (C.4.1 www.example.com)" {
    // Literal-with-incremental-indexing, Huffman name+value.
    const spec = [_]u8{
        0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab,
        0x90, 0xf4, 0xff,
    };
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    const res = try d.decode(&spec);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqualStrings(":authority", res.fields[0].name);
    try std.testing.expectEqualStrings("www.example.com", res.fields[0].value);
}

test "encoder output decodes back (roundtrip incl dynamic reuse)" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    var d = Decoder.init(a);
    defer d.deinit();

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);

    try enc.encode(&block, "content-type", "application/json", .incremental, false);
    try enc.encode(&block, "content-type", "application/json", .incremental, false); // now fully indexed
    try enc.encode(&block, "x-secret-token", "hunter2", .never, false);

    const res = try d.decode(block.items);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 3), res.fields.len);
    try std.testing.expectEqualStrings("content-type", res.fields[0].name);
    try std.testing.expectEqualStrings("application/json", res.fields[0].value);
    try std.testing.expectEqualStrings("application/json", res.fields[1].value);
    try std.testing.expectEqualStrings("x-secret-token", res.fields[2].name);
    try std.testing.expectEqualStrings("hunter2", res.fields[2].value);
    // Dynamic table holds exactly one entry: content-type. The repeat was
    // fully indexed (no re-insert) and the never-indexed field is not stored.
    try std.testing.expectEqual(@as(usize, 1), enc.dyn.entries.items.len);
}

test "table size updates: only at start; oversized rejected" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();

    // Update exceeding protocol max -> error.
    d.setProtocolMaxSize(64);
    const bad = [_]u8{ 0x3F, 0x51 }; // 31 + 81 = 112 > 64
    try std.testing.expectError(Error.InvalidTableSize, d.decode(&bad));

    // Update AFTER a field -> unexpected.
    var d2 = Decoder.init(a);
    defer d2.deinit();
    const mid = [_]u8{ 0x40, 0x01, 'a', 0x01, 'b', 0x20 };
    try std.testing.expectError(Error.UnexpectedTableSizeUpdate, d2.decode(&mid));
}

test "eviction respects max size" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.applySettingsSize(200);

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "header-{d}", .{i});
        try enc.encode(&block, name, "some-value-data", .incremental, false);
    }
    try std.testing.expect(enc.dyn.size <= 200);
}
