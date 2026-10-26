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

// Static table (RFC 7541 Appendix A) — indices are 1-based on the wire.

pub const StaticEntry = struct { name: []const u8, value: []const u8 };

pub const staticTable = [_]StaticEntry{
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

pub const STATIC_TABLE_SIZE = staticTable.len;

fn checkedEntrySize(nameLen: usize, valueLen: usize) ?usize {
    const withOverhead = std.math.add(usize, ENTRY_OVERHEAD, nameLen) catch return null;
    return std.math.add(usize, withOverhead, valueLen) catch return null;
}

fn entrySize(name: []const u8, value: []const u8) ?usize {
    return checkedEntrySize(name.len, value.len);
}

// Dynamic table (shared mechanics for encoder and decoder sides)

/// Ring of entries, newest first (index 0 = most recently inserted),
/// matching the wire's relative-index direction.
const DynTable = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    size: usize = 0,
    maxSize: usize = DEFAULT_TABLE_SIZE,

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

    fn evictFor(self: *DynTable, incoming: ?usize) void {
        while ((incoming == null or self.size > self.maxSize or incoming.? > self.maxSize - self.size) and self.entries.items.len > 0) {
            const old = self.entries.pop() orelse break;
            self.size -= entrySize(old.name, old.value) orelse unreachable;
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
    }

    /// Inserts newest-first. An entry larger than maxSize is dropped
    /// after emptying (per RFC it empties the table but is not stored).
    fn insert(self: *DynTable, name: []const u8, value: []const u8) !void {
        const size = entrySize(name, value);
        self.evictFor(size);
        const entry_bytes = size orelse return;
        if (entry_bytes > self.maxSize) return; // emptied, not stored
        const ownedName = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(ownedName);
        const ownedValue = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(ownedValue);
        try self.entries.insert(self.allocator, 0, .{ .name = ownedName, .value = ownedValue });
        self.size += entry_bytes;
    }

    fn setMaxSize(self: *DynTable, newMax: usize) void {
        self.maxSize = newMax;
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
    protocolMaxSize: usize = DEFAULT_TABLE_SIZE,
    /// Smallest size the peer advertised since the last header block.
    /// The first table size update of the next block must not exceed it
    /// (RFC 7541 Section 4.2).
    pendingMinSize: ?usize = null,
    /// Set when the peer shrinks below the current maximum: the next block
    /// MUST open with a table size update (RFC 7541 Section 4.2).
    requireSizeUpdate: bool = false,
    maxHeaderList: usize = 0xFFFFFFFF,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator, .dyn = DynTable.init(allocator) };
    }

    pub fn deinit(self: *Decoder) void {
        self.dyn.deinit();
    }

    /// Applies our advertised SETTINGS_HEADER_TABLE_SIZE.
    pub fn setProtocolMaxSize(self: *Decoder, sz: usize) void {
        self.protocolMaxSize = sz;
        if (self.dyn.maxSize > sz) {
            self.dyn.setMaxSize(sz);
            self.requireSizeUpdate = true;
            // A shrink obliges the encoder to signal a size update; the
            // smallest advertised value bounds the first one.
            self.pendingMinSize = @min(self.pendingMinSize orelse sz, sz);
        }
    }

    fn lookup(self: *Decoder, index: u64) Error!HeaderField {
        if (index == 0) return Error.InvalidIndex;
        if (index <= STATIC_TABLE_SIZE) {
            const e = staticTable[@intCast(index - 1)];
            return .{ .name = e.name, .value = e.value };
        }
        const rel: usize = @intCast(index - STATIC_TABLE_SIZE - 1);
        const e = self.dyn.get(rel) orelse return Error.InvalidIndex;
        return .{ .name = e.name, .value = e.value };
    }

    const StringResult = struct { data: []u8, owned: bool };

    fn readString(self: *Decoder, data: []const u8, offset: *usize) Error!StringResult {
        if (offset.* >= data.len) return Error.Truncated;
        const huffmanBit = data[offset.*] & 0x80 != 0;
        const len = try pint.decode(data, offset, 7);
        const rawLen = std.math.cast(usize, len) orelse return Error.HeaderTooLarge;
        if (offset.* > data.len or rawLen > data.len - offset.*) return Error.Truncated;
        const raw = data[offset.*..][0..rawLen];
        offset.* += rawLen;
        if (!huffmanBit) {
            return .{ .data = @constCast(raw), .owned = false };
        }
        const cap = huff.maxDecodedLen(rawLen);
        const buf = try self.allocator.alloc(u8, cap);
        const n = huff.decode(buf, raw) catch |e| {
            self.allocator.free(buf);
            return switch (e) {
                error.InvalidHuffmanCode => Error.InvalidHuffmanCode,
                error.BufferTooSmall => Error.HeaderTooLarge,
            };
        };
        // Return an exact allocation. Keeping a shortened slice of the
        // over-sized buffer would make the eventual free() size mismatch;
        // on realloc failure, duplicate and release the original.
        const exact = self.allocator.realloc(buf, n) catch blk: {
            const copy = self.allocator.dupe(u8, buf[0..n]) catch {
                self.allocator.free(buf);
                return Error.OutOfMemory;
            };
            self.allocator.free(buf);
            break :blk copy;
        };
        return .{ .data = exact, .owned = true };
    }

    fn freeString(self: *Decoder, s: StringResult) void {
        if (s.owned) self.allocator.free(s.data);
    }

    pub const Result = struct {
        fields: []HeaderField,
        /// Total decompressed list size for SETTINGS_MAX_HEADER_LIST_SIZE checks.
        totalSize: usize,
        /// The decoded list exceeded the configured budget. Decoding still
        /// completed so the dynamic table stays synchronized with the peer.
        tooLarge: bool = false,
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
        var tooLarge = false;
        var offset: usize = 0;
        var atStart = true;

        while (offset < block.len) {
            const b = block[offset];

            if (b & 0x80 != 0) {
                // 1xxxxxxx: indexed header field.
                const idx = try pint.decode(block, &offset, 7);
                const f = try self.lookup(idx);
                total = addSize(total, f) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    try appendOwned(&list, self.allocator, f);
                } else {
                    tooLarge = true;
                }
                atStart = false;
            } else if (b & 0xC0 == 0x40) {
                // 01xxxxxx: literal WITH incremental indexing.
                const idx = try pint.decode(block, &offset, 6);
                const f = try self.readLiteral(block, &offset, idx);
                defer {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
                self.dyn.insert(f.name, f.value) catch return Error.OutOfMemory;
                total = addSize(total, f) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    try appendDup(&list, self.allocator, f);
                } else {
                    tooLarge = true;
                }
                atStart = false;
            } else if (b & 0xE0 == 0x20) {
                // 001xxxxx: dynamic table size update.
                if (!atStart) return Error.UnexpectedTableSizeUpdate;
                const sz = try pint.decode(block, &offset, 5);
                // The first update of a block is bounded by the smallest
                // size the peer advertised; later ones by the final one.
                const limit = self.pendingMinSize orelse self.protocolMaxSize;
                if (sz > limit) return Error.InvalidTableSize;
                self.dyn.setMaxSize(@intCast(sz));
                self.requireSizeUpdate = false;
                self.pendingMinSize = null;
            } else {
                // 0000xxxx / 0001xxxx: literal without indexing / never indexed.
                const idx = try pint.decode(block, &offset, 4);
                const f = try self.readLiteral(block, &offset, idx);
                defer {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
                total = addSize(total, f) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    try appendDup(&list, self.allocator, f);
                } else {
                    tooLarge = true;
                }
                atStart = false;
            }
        }

        if (self.requireSizeUpdate) return Error.UnexpectedTableSizeUpdate;

        return .{
            .fields = try list.toOwnedSlice(self.allocator),
            .totalSize = total,
            .tooLarge = tooLarge,
        };
    }

    fn addSize(total: usize, f: HeaderField) !usize {
        return std.math.add(usize, total, ENTRY_OVERHEAD + f.name.len + f.value.len);
    }

    fn readLiteral(self: *Decoder, block: []const u8, offset: *usize, nameIndex: u64) Error!HeaderField {
        const nameRes = if (nameIndex == 0)
            try self.readString(block, offset)
        else blk: {
            const nf = try self.lookup(nameIndex);
            break :blk StringResult{ .data = @constCast(nf.name), .owned = false };
        };
        defer if (nameIndex == 0) self.freeString(nameRes);

        const valRes = try self.readString(block, offset);
        defer self.freeString(valRes);

        const ownedName = try self.allocator.dupe(u8, nameRes.data);
        errdefer self.allocator.free(ownedName);
        const ownedValue = try self.allocator.dupe(u8, valRes.data);
        return .{ .name = ownedName, .value = ownedValue };
    }
};

fn appendDup(list: *std.ArrayList(HeaderField), gpa: Allocator, f: HeaderField) Error!void {
    const name = gpa.dupe(u8, f.name) catch return Error.OutOfMemory;
    errdefer gpa.free(name);
    const value = gpa.dupe(u8, f.value) catch return Error.OutOfMemory;
    errdefer gpa.free(value);
    list.append(gpa, .{ .name = name, .value = value }) catch return Error.OutOfMemory;
}

fn appendOwned(list: *std.ArrayList(HeaderField), gpa: Allocator, f: HeaderField) Error!void {
    try appendDup(list, gpa, f);
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
    /// Final size to signal at the next block start.
    pendingSizeUpdate: ?usize = null,
    /// Smallest size requested since the last block. RFC 7541 Section 4.2
    /// requires signaling the minimum first when a shrink/grow pair lands
    /// between two header blocks.
    pendingMinSize: ?usize = null,

    /// Volatile per-request values that are poor dynamic-table candidates.
    const noIndexNames = [_][]const u8{
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
        if (self.dyn.maxSize != sz) {
            self.pendingSizeUpdate = sz;
            self.pendingMinSize = @min(self.pendingMinSize orelse sz, sz);
        }
        self.dyn.setMaxSize(sz);
    }

    fn findNameIndex(self: *const Encoder, name: []const u8) struct { idx: u64, inDyn: bool } {
        for (staticTable, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return .{ .idx = i + 1, .inDyn = false };
        }
        // Dynamic indices are relative to the newest entry and start
        // AFTER the whole static table.
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name))
                return .{ .idx = STATIC_TABLE_SIZE + 1 + i, .inDyn = true };
        }
        return .{ .idx = 0, .inDyn = false };
    }

    fn findFullIndex(self: *const Encoder, name: []const u8, value: []const u8) ?u64 {
        for (staticTable, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value)) return i + 1;
        }
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value))
                return STATIC_TABLE_SIZE + 1 + i;
        }
        return null;
    }

    fn shouldIndex(name: []const u8) bool {
        for (noIndexNames) |n| {
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
        nameIn: []const u8,
        value: []const u8,
        indexing: Indexing,
        forceLiteral: bool,
    ) !void {
        if (self.pendingSizeUpdate) |sz| {
            const min = self.pendingMinSize orelse sz;
            self.pendingSizeUpdate = null;
            self.pendingMinSize = null;
            var tmp: [10]u8 = undefined;
            if (min < sz) {
                const n = try pint.encode(tmp[0..], 5, 0x20, min);
                try out.appendSlice(self.allocator, tmp[0..n]);
            }
            const n = try pint.encode(tmp[0..], 5, 0x20, sz);
            try out.appendSlice(self.allocator, tmp[0..n]);
        }

        const name = try lowerBuf(self.allocator, nameIn);
        defer self.allocator.free(name);

        var ib: [10]u8 = undefined;

        if (!forceLiteral) {
            if (self.findFullIndex(name, value)) |full| {
                const n = try pint.encode(ib[0..], 7, 0x80, full);
                try out.appendSlice(self.allocator, ib[0..n]);
                return;
            }
        }

        const nameRef = self.findNameIndex(name);

        switch (indexing) {
            .incremental => {
                if (!shouldIndex(name)) {
                    const op: u8 = 0x00;
                    if (nameRef.idx != 0 and !forceLiteral) {
                        const n = try pint.encode(ib[0..], 4, op, nameRef.idx);
                        try out.appendSlice(self.allocator, ib[0..n]);
                    } else {
                        try out.append(self.allocator, op);
                        try emitString(out, self.allocator, name);
                    }
                    try emitString(out, self.allocator, value);
                } else {
                    try self.dyn.insert(name, value);
                    const op: u8 = 0x40;
                    if (nameRef.idx != 0 and !forceLiteral) {
                        const n = try pint.encode(ib[0..], 6, op, nameRef.idx);
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
                if (nameRef.idx != 0 and !forceLiteral) {
                    const n = try pint.encode(ib[0..], 4, op, nameRef.idx);
                    try out.appendSlice(self.allocator, ib[0..n]);
                } else {
                    try out.append(self.allocator, op);
                    try emitString(out, self.allocator, name);
                }
                try emitString(out, self.allocator, value);
            },
            .never => {
                const op: u8 = 0x10;
                if (nameRef.idx != 0 and !forceLiteral) {
                    const n = try pint.encode(ib[0..], 4, op, nameRef.idx);
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
        var nameBuf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nameBuf, "header-{d}", .{i});
        try enc.encode(&block, name, "some-value-data", .incremental, false);
    }
    try std.testing.expect(enc.dyn.size <= 200);
}
test "decode RFC 7541 C.3.1 first request without Huffman" {
    // 8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d
    const block = [_]u8{
        0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x',
        'a',  'm',  'p',  'l',  'e',  '.', 'c', 'o', 'm',
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
    try std.testing.expectEqual(@as(usize, 4), res.fields.len);
    try std.testing.expectEqualStrings(":method", res.fields[0].name);
    try std.testing.expectEqualStrings("GET", res.fields[0].value);
    try std.testing.expectEqualStrings(":scheme", res.fields[1].name);
    try std.testing.expectEqualStrings("http", res.fields[1].value);
    try std.testing.expectEqualStrings(":path", res.fields[2].name);
    try std.testing.expectEqualStrings("/", res.fields[2].value);
    try std.testing.expectEqualStrings(":authority", res.fields[3].name);
    try std.testing.expectEqualStrings("www.example.com", res.fields[3].value);
}

test "decode RFC 7541 C.4.1 first request with Huffman coding" {
    // 8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff
    const block = [_]u8{
        0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a,
        0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
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
    try std.testing.expectEqual(@as(usize, 4), res.fields.len);
    try std.testing.expectEqualStrings(":method", res.fields[0].name);
    try std.testing.expectEqualStrings("GET", res.fields[0].value);
    try std.testing.expectEqualStrings(":scheme", res.fields[1].name);
    try std.testing.expectEqualStrings("http", res.fields[1].value);
    try std.testing.expectEqualStrings(":path", res.fields[2].name);
    try std.testing.expectEqualStrings("/", res.fields[2].value);
    try std.testing.expectEqualStrings(":authority", res.fields[3].name);
    try std.testing.expectEqualStrings("www.example.com", res.fields[3].value);
}

test "decode a response with a never-indexed literal (RFC 7541 Section 6.2.3)" {
    // :status: 302 (indexed name), cache-control: private (indexed name),
    // date: Mon, 21 Oct 2013 20:13:21 GMT (indexed name) and a
    // never-indexed literal with a new name.
    const block = [_]u8{
        0x48, 0x03, '3',  '0', '2',
        0x58, 0x07, 'p',  'r', 'i',
        'v',  'a',  't',  'e', 0x61,
        0x1d, 'M',  'o',  'n', ',',
        ' ',  '2',  '1',  ' ', 'O',
        'c',  't',  ' ',  '2', '0',
        '1',  '3',  ' ',  '2', '0',
        ':',  '1',  '3',  ':', '2',
        '1',  ' ',  'G',  'M', 'T',
        0x10, 0x0a, 'c',  'u', 's',
        't',  'o',  'm',  '-', 'k',
        'e',  'y',  0x0c, 'c', 'u',
        's',  't',  'o',  'm', '-',
        'v',  'a',  'l',  'u', 'e',
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
    try std.testing.expectEqual(@as(usize, 4), res.fields.len);
    try std.testing.expectEqualStrings(":status", res.fields[0].name);
    try std.testing.expectEqualStrings("302", res.fields[0].value);
    try std.testing.expectEqualStrings("cache-control", res.fields[1].name);
    try std.testing.expectEqualStrings("private", res.fields[1].value);
    try std.testing.expectEqualStrings("date", res.fields[2].name);
    try std.testing.expectEqualStrings("Mon, 21 Oct 2013 20:13:21 GMT", res.fields[2].value);
    try std.testing.expectEqualStrings("custom-key", res.fields[3].name);
    try std.testing.expectEqualStrings("custom-value", res.fields[3].value);
    // Only the never-indexed literal must stay out of the dynamic table.
    try std.testing.expectEqual(@as(usize, 3), d.dyn.entries.items.len);
}

test "dynamic table size arithmetic is checked at usize boundaries" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?usize, null), checkedEntrySize(std.math.maxInt(usize), 0));
    try std.testing.expectEqual(@as(?usize, null), checkedEntrySize(0, std.math.maxInt(usize)));

    var dyn = DynTable.init(a);
    defer dyn.deinit();
    try dyn.entries.append(a, .{
        .name = try a.dupe(u8, "x"),
        .value = try a.dupe(u8, "y"),
    });
    // This models a legal table close to the maximum representable size on a
    // 32-bit target. Adding the incoming size would wrap and skip eviction.
    dyn.maxSize = std.math.maxInt(usize);
    dyn.size = std.math.maxInt(usize) - 4;
    dyn.evictFor(10);
    try std.testing.expectEqual(@as(usize, 0), dyn.entries.items.len);
}

test "encoder emits a dynamic table size update when the peer shrinks it" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.applySettingsSize(100);

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try enc.encode(&block, "x-test", "1", .incremental, false);

    // The 5-bit prefix marks a dynamic table size update.
    try std.testing.expectEqual(@as(u8, 0x20), block.items[0] & 0xE0);
    var off: usize = 0;
    const size = try pint.decode(block.items, &off, 5);
    try std.testing.expectEqual(@as(u64, 100), size);
}

test "encoder signals the smallest table size before the final one" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    // Shrink then grow between two header blocks: the minimum must be
    // signalled first (RFC 7541 Section 4.2).
    enc.applySettingsSize(100);
    enc.applySettingsSize(4096);

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try enc.encode(&block, "x-test", "1", .incremental, false);

    var off: usize = 0;
    const first = try pint.decode(block.items, &off, 5);
    const second = try pint.decode(block.items, &off, 5);
    try std.testing.expectEqual(@as(u64, 100), first);
    try std.testing.expectEqual(@as(u64, 4096), second);
}

test "never-indexed literals decode but stay out of the dynamic table" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    // 0x10 = literal header field never indexed, new name.
    const block = [_]u8{ 0x10, 0x03, 'a', 'b', 'c', 0x03, 'x', 'y', 'z' };
    const res = try d.decode(&block);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 1), res.fields.len);
    try std.testing.expectEqualStrings("abc", res.fields[0].name);
    try std.testing.expectEqualStrings("xyz", res.fields[0].value);
    try std.testing.expectEqual(@as(usize, 0), d.dyn.entries.items.len);
}

test "truncated blocks and invalid indices are rejected" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();

    // Indexed field 0 is invalid.
    try std.testing.expectError(Error.InvalidIndex, d.decode(&[_]u8{0x80}));
    // A literal whose string length runs past the block is truncated.
    try std.testing.expectError(Error.Truncated, d.decode(&[_]u8{ 0x40, 0x05, 'a' }));
    // An index beyond the dynamic table is invalid.
    try std.testing.expectError(Error.InvalidIndex, d.decode(&[_]u8{0xfe}));
}

test "the header list budget is enforced while decoding" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    d.maxHeaderList = 32;
    const block = [_]u8{
        0x40, 0x0a, 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y',
        0x0d, 'c',  'u', 's', 't', 'o', 'm', '-', 'h', 'e', 'a', 'd',
        'e',  'r',
    };
    const res = try d.decode(&block);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expect(res.tooLarge);
    try std.testing.expectEqual(@as(usize, 0), res.fields.len);
    // The oversized entry was still inserted; skipping it would desync
    // the connection-wide dynamic table.
    try std.testing.expectEqual(@as(usize, 1), d.dyn.entries.items.len);
}

test "an oversized field still populates the dynamic table for later blocks" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    d.maxHeaderList = 32;
    const first = [_]u8{
        0x40, 0x0a, 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y',
        0x0d, 'c',  'u', 's', 't', 'o', 'm', '-', 'h', 'e', 'a', 'd',
        'e',  'r',
    };
    const r1 = try d.decode(&first);
    a.free(r1.fields);
    try std.testing.expect(r1.tooLarge);

    d.maxHeaderList = 100;
    const r2 = try d.decode(&[_]u8{0xBE});
    defer {
        for (r2.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(r2.fields);
    }
    try std.testing.expect(!r2.tooLarge);
    try std.testing.expectEqual(@as(usize, 1), r2.fields.len);
    try std.testing.expectEqualStrings("custom-key", r2.fields[0].name);
    try std.testing.expectEqualStrings("custom-header", r2.fields[0].value);
}

test "huffman encoded strings decode to the exact bytes" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    // RFC 7541 C.4.1: ":authority: www.example.com" with Huffman coding.
    const block = [_]u8{
        0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab,
        0x90, 0xf4, 0xff,
    };
    const res = try d.decode(&block);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 1), res.fields.len);
    try std.testing.expectEqualStrings(":authority", res.fields[0].name);
    try std.testing.expectEqualStrings("www.example.com", res.fields[0].value);
}

test "nghttp2 reference multi-block sequential deflate and inflate sequence" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    var dec = Decoder.init(a);
    defer dec.deinit();

    const Block = struct {
        fields: []const HeaderField,
    };

    const b1 = [_]HeaderField{
        .{ .name = ":path", .value = "/my-example/index.html" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = "hello", .value = "world" },
    };
    const b2 = [_]HeaderField{
        .{ .name = ":path", .value = "/script.js" },
        .{ .name = ":scheme", .value = "https" },
    };
    const b3 = [_]HeaderField{
        .{ .name = "cookie", .value = "k1=v1" },
        .{ .name = "cookie", .value = "k2=v2" },
        .{ .name = "via", .value = "proxy" },
    };
    const b4 = [_]HeaderField{
        .{ .name = ":path", .value = "/style.css" },
        .{ .name = "cookie", .value = "k1=v1" },
        .{ .name = "cookie", .value = "k1=v1" },
    };
    const b5 = [_]HeaderField{
        .{ .name = ":path", .value = "/style.css" },
        .{ .name = "x-nghttp2", .value = "" },
    };

    const blocks = [_]Block{
        .{ .fields = &b1 },
        .{ .fields = &b2 },
        .{ .fields = &b3 },
        .{ .fields = &b4 },
        .{ .fields = &b5 },
    };

    for (blocks) |b| {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(a);

        for (b.fields) |f| {
            try enc.encode(&out, f.name, f.value, .incremental, false);
        }

        const res = try dec.decode(out.items);
        defer {
            for (res.fields) |f| {
                a.free(f.name);
                a.free(f.value);
            }
            a.free(res.fields);
        }

        try std.testing.expectEqual(b.fields.len, res.fields.len);
        for (b.fields, 0..) |expected, i| {
            try std.testing.expectEqualStrings(expected.name, res.fields[i].name);
            try std.testing.expectEqualStrings(expected.value, res.fields[i].value);
        }
    }
}
