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

/// Stack scratch size used to Huffman-decode short header strings.
const huffman_stack_size = 512;

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

/// The static entries that share one header name.
///
/// The static table lists the entries of a name consecutively, so a name
/// resolves to a contiguous run of entries: the first one is used for a
/// name-only reference, and the run is scanned for a name+value match.
const StaticNameGroup = struct {
    /// 1-based wire index of the first entry carrying the name.
    first: u32,
    /// Number of consecutive entries carrying the name.
    count: u32,
};

/// Compile-time index from a header name to its static-table entries.
/// Replaces a linear scan over the 61-entry table on every lookup.
const staticNameMap = std.StaticStringMap(StaticNameGroup).initComptime(blk: {
    var list: [STATIC_TABLE_SIZE]struct { []const u8, StaticNameGroup } = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < staticTable.len) {
        const name = staticTable[i].name;
        var j = i + 1;
        while (j < staticTable.len and std.mem.eql(u8, staticTable[j].name, name)) j += 1;
        list[n] = .{ name, .{ .first = @intCast(i + 1), .count = @intCast(j - i) } };
        n += 1;
        i = j;
    }
    break :blk list[0..n];
});

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

    /// Name and value live back-to-back in a single allocation, so an
    /// insert costs one allocator round-trip instead of two.
    const Entry = struct {
        buf: []u8,
        /// Byte length of the name inside `buf`.
        name_len: usize,

        pub fn nameOf(e: Entry) []const u8 {
            return e.buf[0..e.name_len];
        }

        pub fn valueOf(e: Entry) []const u8 {
            return e.buf[e.name_len..];
        }
    };

    fn init(allocator: Allocator) DynTable {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DynTable) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.buf);
        }
        self.entries.deinit(self.allocator);
    }

    fn evictFor(self: *DynTable, incoming: ?usize) void {
        while ((incoming == null or self.size > self.maxSize or incoming.? > self.maxSize - self.size) and self.entries.items.len > 0) {
            const old = self.entries.pop() orelse break;
            self.size -= entrySize(old.nameOf(), old.valueOf()) orelse unreachable;
            self.allocator.free(old.buf);
        }
    }

    /// Inserts newest-first. An entry larger than maxSize is dropped
    /// after emptying (per RFC it empties the table but is not stored).
    fn insert(self: *DynTable, name: []const u8, value: []const u8) !void {
        const size = entrySize(name, value);
        self.evictFor(size);
        const entry_bytes = size orelse return;
        if (entry_bytes > self.maxSize) return; // emptied, not stored
        const buf = try self.allocator.alloc(u8, name.len + value.len);
        errdefer self.allocator.free(buf);
        @memcpy(buf[0..name.len], name);
        @memcpy(buf[name.len..], value);
        try self.entries.insert(self.allocator, 0, .{ .buf = buf, .name_len = name.len });
        self.size += entry_bytes;
    }

    fn setMaxSize(self: *DynTable, newMax: usize) void {
        self.maxSize = newMax;
        self.evictFor(0);
    }

    fn get(self: *const DynTable, rel: usize) ?StaticEntry {
        if (rel >= self.entries.items.len) return null;
        const e = self.entries.items[rel];
        return .{ .name = e.nameOf(), .value = e.valueOf() };
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

    /// Decoded name and value of a literal header field. Each part is
    /// either owned (Huffman-decoded) or borrowed from the block or the
    /// header tables.
    const Literal = struct { name: StringResult, value: StringResult };

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
        // Short strings decode on the stack and are copied out at their
        // exact size, so the result can be freed with a plain free().
        if (cap <= huffman_stack_size) {
            var stack: [huffman_stack_size]u8 = undefined;
            const n = huff.decode(stack[0..cap], raw) catch |e| return switch (e) {
                error.InvalidHuffmanCode => Error.InvalidHuffmanCode,
                error.BufferTooSmall => Error.HeaderTooLarge,
            };
            const exact = self.allocator.dupe(u8, stack[0..n]) catch return Error.OutOfMemory;
            return .{ .data = exact, .owned = true };
        }
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
                total = addSize(total, f.name, f.value) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    // The table entry stays owned by the table: copy it.
                    try appendCopy(&list, self.allocator, f);
                } else {
                    tooLarge = true;
                }
                atStart = false;
            } else if (b & 0xC0 == 0x40) {
                // 01xxxxxx: literal WITH incremental indexing.
                const idx = try pint.decode(block, &offset, 6);
                var lit = try self.readLiteral(block, &offset, idx);
                defer {
                    self.freeString(lit.name);
                    self.freeString(lit.value);
                }
                // The dynamic table keeps its own copy (RFC 7541 Section 2.3.2).
                self.dyn.insert(lit.name.data, lit.value.data) catch return Error.OutOfMemory;
                total = addSize(total, lit.name.data, lit.value.data) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    try self.appendLiteral(&list, &lit);
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
                var lit = try self.readLiteral(block, &offset, idx);
                defer {
                    self.freeString(lit.name);
                    self.freeString(lit.value);
                }
                total = addSize(total, lit.name.data, lit.value.data) catch blk: {
                    tooLarge = true;
                    break :blk std.math.maxInt(usize);
                };
                if (!tooLarge and total <= self.maxHeaderList) {
                    try self.appendLiteral(&list, &lit);
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

    /// Appends a literal field, taking ownership of the decoded strings.
    /// Borrowed strings (static/dynamic table entries) are copied;
    /// Huffman-decoded ones are adopted as they are.
    fn appendLiteral(self: *Decoder, list: *std.ArrayList(HeaderField), lit: *Literal) Error!void {
        const name_owned = !lit.name.owned;
        const value_owned = !lit.value.owned;
        const name = if (name_owned)
            self.allocator.dupe(u8, lit.name.data) catch return Error.OutOfMemory
        else
            lit.name.data;
        const value = if (value_owned)
            self.allocator.dupe(u8, lit.value.data) catch {
                if (name_owned) self.allocator.free(name);
                return Error.OutOfMemory;
            }
        else
            lit.value.data;
        list.append(self.allocator, .{ .name = name, .value = value }) catch {
            if (name_owned) self.allocator.free(name);
            if (value_owned) self.allocator.free(value);
            return Error.OutOfMemory;
        };
        // Ownership moved into the list: the caller must not free them.
        lit.name.owned = false;
        lit.value.owned = false;
    }

    fn addSize(total: usize, name: []const u8, value: []const u8) !usize {
        return std.math.add(usize, total, ENTRY_OVERHEAD + name.len + value.len);
    }

    /// Reads a literal header field. The name may be borrowed from the
    /// header tables; the value is borrowed from the block unless it was
    /// Huffman-decoded. The caller owns the returned parts.
    fn readLiteral(self: *Decoder, block: []const u8, offset: *usize, nameIndex: u64) Error!Literal {
        const name = if (nameIndex == 0)
            try self.readString(block, offset)
        else blk: {
            const nf = try self.lookup(nameIndex);
            break :blk StringResult{ .data = @constCast(nf.name), .owned = false };
        };
        errdefer self.freeString(name);
        const value = try self.readString(block, offset);
        return .{ .name = name, .value = value };
    }
};

/// Appends a copy of `f` to the list; both strings are freshly owned.
fn appendCopy(list: *std.ArrayList(HeaderField), gpa: Allocator, f: HeaderField) Error!void {
    const name = gpa.dupe(u8, f.name) catch return Error.OutOfMemory;
    const value = gpa.dupe(u8, f.value) catch {
        gpa.free(name);
        return Error.OutOfMemory;
    };
    list.append(gpa, .{ .name = name, .value = value }) catch {
        gpa.free(name);
        gpa.free(value);
        return Error.OutOfMemory;
    };
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
        // Static table: constant-time lookup through the compile-time map.
        if (staticNameMap.get(name)) |group| {
            return .{ .idx = group.first, .inDyn = false };
        }
        // Dynamic indices are relative to the newest entry and start
        // AFTER the whole static table.
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.nameOf(), name))
                return .{ .idx = STATIC_TABLE_SIZE + 1 + i, .inDyn = true };
        }
        return .{ .idx = 0, .inDyn = false };
    }

    fn findFullIndex(self: *const Encoder, name: []const u8, value: []const u8) ?u64 {
        // Only the static entries sharing this name can match, and they
        // are consecutive, so the scan stays tiny.
        if (staticNameMap.get(name)) |group| {
            var i: usize = group.first - 1;
            const end = i + group.count;
            while (i < end) : (i += 1) {
                const e = staticTable[i];
                if (std.mem.eql(u8, e.value, value)) return i + 1;
            }
        }
        for (self.dyn.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.nameOf(), name) and std.mem.eql(u8, e.valueOf(), value))
                return STATIC_TABLE_SIZE + 1 + i;
        }
        return null;
    }

    /// `name` is already lowercased, so the comparison is exact.
    fn shouldIndex(name: []const u8) bool {
        for (noIndexNames) |n| {
            if (std.mem.eql(u8, n, name)) return false;
        }
        return true;
    }

    /// Emits a string literal (RFC 7541 Section 5.2).
    ///
    /// The Huffman-encoded length is known up front, so the payload is
    /// written straight into the output buffer: no scratch allocation
    /// and no 5x over-sized temporary.
    fn emitString(out: *std.ArrayList(u8), gpa: Allocator, data: []const u8) !void {
        const hlen = huff.encodedLen(data);
        if (hlen < data.len) {
            // Huffman flag bit set + length of the encoded form.
            var tmp: [10]u8 = undefined;
            const nn = try pint.encode(tmp[0..], 7, 0x80, hlen);
            try out.ensureUnusedCapacity(gpa, nn + hlen);
            const base = out.items.len;
            const cap = out.unusedCapacitySlice();
            @memcpy(cap[0..nn], tmp[0..nn]);
            if (huff.encode(cap[nn..][0..hlen], data)) |n| {
                out.items.len = base + nn + n;
                return;
            } else |_| {
                // `hlen` is the exact encoded length, so this cannot
                // happen; fall back to the raw literal below.
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

        var name_stack: [name_stack_size]u8 = undefined;
        const lowered = try lowerName(self.allocator, nameIn, &name_stack);
        defer lowered.deinit(self.allocator);
        const name = lowered.bytes;

        var ib: [10]u8 = undefined;

        // A sensitive field marked `never` MUST NOT use an indexed
        // representation even when name+value happen to already be in the
        // static or dynamic table: reusing the index defeats the "never
        // indexed" guarantee for intermediaries (RFC 7541 Section 6.2.3).
        if (!forceLiteral and indexing != .never) {
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

/// Stack scratch for the lowercased header name. HTTP/2 field names are
/// short, so the common case never touches the heap.
const name_stack_size = 64;

/// A lowercased header name, either in the caller's stack buffer or in
/// a heap allocation for unusually long names.
const LoweredName = struct {
    bytes: []const u8,
    owned: bool,

    fn deinit(self: LoweredName, gpa: Allocator) void {
        if (self.owned) gpa.free(self.bytes);
    }
};

fn lowerName(gpa: Allocator, name: []const u8, stack: []u8) !LoweredName {
    if (name.len <= stack.len) {
        return .{ .bytes = std.ascii.lowerString(stack, name)[0..name.len], .owned = false };
    }
    const owned = try gpa.alloc(u8, name.len);
    errdefer gpa.free(owned);
    _ = std.ascii.lowerString(owned, name);
    return .{ .bytes = owned, .owned = true };
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
        .buf = try a.dupe(u8, "xy"),
        .name_len = 1,
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

test "never-indexed encoding never emits an indexed representation" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();

    // First store the secret with incremental indexing so a full match exists.
    var first = std.ArrayList(u8).empty;
    defer first.deinit(a);
    try enc.encode(&first, "authorization", "Bearer secret", .incremental, false);
    try std.testing.expect(enc.dyn.entries.items.len != 0);

    // Re-encoding it as sensitive must stay literal-never-indexed, not 0x80|idx.
    var second = std.ArrayList(u8).empty;
    defer second.deinit(a);
    try enc.encode(&second, "authorization", "Bearer secret", .never, false);
    try std.testing.expect(second.items.len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), second.items[0] & 0xF0);

    var dec = Decoder.init(a);
    defer dec.deinit();
    // Feed the first block so the decoder's table matches, then decode the
    // sensitive block and verify both value and that the table is unchanged.
    const r1 = try dec.decode(first.items);
    defer {
        for (r1.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(r1.fields);
    }
    const tableLen = dec.dyn.entries.items.len;
    const r2 = try dec.decode(second.items);
    defer {
        for (r2.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(r2.fields);
    }
    try std.testing.expectEqualStrings("authorization", r2.fields[0].name);
    try std.testing.expectEqualStrings("Bearer secret", r2.fields[0].value);
    try std.testing.expectEqual(tableLen, dec.dyn.entries.items.len);
}

test "static table lookups resolve the documented indices" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();

    // ":method GET" is static entry 2, ":status 200" is entry 8.
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try enc.encode(&block, ":method", "GET", .without, false);
    try std.testing.expectEqual(@as(u8, 0x82), block.items[0]);

    block.clearRetainingCapacity();
    try enc.encode(&block, ":status", "200", .without, false);
    try std.testing.expectEqual(@as(u8, 0x88), block.items[0]);

    // ":path /index.html" is static entry 5 and shares its name with
    // ":path /" (entry 4).
    block.clearRetainingCapacity();
    try enc.encode(&block, ":path", "/index.html", .without, false);
    try std.testing.expectEqual(@as(u8, 0x85), block.items[0]);
    try std.testing.expectEqual(@as(usize, 1), block.items.len);

    // A name that is in the table but whose value is not falls back to a
    // literal that references the *first* entry with that name (":path").
    block.clearRetainingCapacity();
    try enc.encode(&block, ":path", "/other", .without, false);
    try std.testing.expectEqual(@as(u8, 0x04), block.items[0] & 0x0F);
    try std.testing.expectEqual(@as(u8, 0x00), block.items[0] & 0xF0);

    // A name that is not in the static table falls back to a literal.
    block.clearRetainingCapacity();
    try enc.encode(&block, "x-not-in-static", "v", .without, false);
    try std.testing.expectEqual(@as(u8, 0x00), block.items[0] & 0xF0);
}

test "encoder emits huffman-coded literals when they are shorter" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    var dec = Decoder.init(a);
    defer dec.deinit();

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    // A long, highly compressible value must be Huffman coded.
    try enc.encode(&block, "x-compressible", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .without, false);

    // Literal without indexing (0x00) with a new name.
    try std.testing.expectEqual(@as(u8, 0x00), block.items[0]);

    var off: usize = 1;
    const nameLen = try pint.decode(block.items, &off, 7);
    // The name is not in the static table, so it is Huffman coded too.
    try std.testing.expect(block.items[off - 1] & 0x80 != 0);
    off += @intCast(nameLen);
    // The value string carries the Huffman flag in bit 7 of its length
    // octet: the raw value is 32 bytes, the coded one is much shorter.
    try std.testing.expect(block.items[off] & 0x80 != 0);
    const valueLen = try pint.decode(block.items, &off, 7);
    try std.testing.expect(valueLen < 32);

    const res = try dec.decode(block.items);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 1), res.fields.len);
    try std.testing.expectEqualStrings("x-compressible", res.fields[0].name);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", res.fields[0].value);
}

test "huffman-coded literals decode through the shared codec" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();

    var name_buf: [16]u8 = undefined;
    const name_len = try huff.encode(&name_buf, "abc");
    var value_buf: [16]u8 = undefined;
    const value_len = try huff.encode(&value_buf, "xyz");

    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try block.append(a, 0x10); // never indexed
    try block.append(a, 0x80 | @as(u8, @intCast(name_len)));
    try block.appendSlice(a, name_buf[0..name_len]);
    try block.append(a, 0x80 | @as(u8, @intCast(value_len)));
    try block.appendSlice(a, value_buf[0..value_len]);

    const res = try d.decode(block.items);
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
