//! QPACK - QUIC header compression (RFC 9204).
//!
//! Static table (99 entries), dynamic table with eviction, field-section
//! representations (indexed, name references, literals, post-base), the
//! field-section prefix (Required Insert Count / Delta Base, including
//! blocked sections), encoder-stream instructions (Set Capacity, Insert
//! with Name Reference, Insert with Literal Name, Duplicate) and
//! decoder-stream instructions (Section Acknowledgment, Stream
//! Cancellation, Insert Count Increment).
//!
//! Dynamic-table wire layouts implement RFC 9204 Sections 4.3-4.5
//! (opcodes, T-bit polarity, relative indexes, RIC/Base math).
//! Encoder policy is insert-on-first-use with literal fallback when the
//! table is full or barred; eviction of entries referenced by
//! unacknowledged sections is fenced by `evictBarrier`, which the
//! connection layer advances from decoder-stream acknowledgments.
//!
//! References:
//!   - RFC 9204 — QPACK: Field Compression for HTTP/3
//!   - RFC 9204 Section 2.3.2 — Static Table
//!   - RFC 9204 Section 3.1 — Encoder Instructions
//!   - RFC 9204 Section 3.2.6 — Decoder Instructions

const std = @import("std");
const Allocator = std.mem.Allocator;
const varint = @import("../quic/varint.zig");
const huff = @import("../common/huffman.zig");

pub const Error = error{
    InvalidIndex,
    InvalidInstruction,
    TableCapacityExceeded,
    /// A field section references dynamic entries the decoder has not
    /// received yet (Required Insert Count beyond our insert count).
    /// Not a protocol violation: buffer the section bytes and retry
    /// after feeding more encoder-stream data.
    Blocked,
    /// More bytes are needed to finish the current integer or string.
    /// Instruction-stream readers treat trailing Truncated as "wait
    /// for more bytes"; anywhere else it is malformed input.
    Truncated,
    OutOfMemory,
    BufferTooSmall,
};

pub const ENTRY_OVERHEAD: usize = 32;

/// Resource caps: names are short, values can be large (cookies),
/// large (cookies), sections are bounded by maxFieldSectionSize.
pub const MAX_NAME_LEN: usize = 256;
pub const MAX_VALUE_LEN: usize = 65536;

fn take(data: []const u8, offset: *usize, length: u64) Error![]const u8 {
    const n = std.math.cast(usize, length) orelse return Error.InvalidInstruction;
    if (offset.* > data.len or n > data.len - offset.*) return Error.Truncated;
    const result = data[offset.*..][0..n];
    offset.* += n;
    return result;
}

fn readString(allocator: Allocator, data: []const u8, offset: *usize, maxLen: usize) Error![]u8 {
    if (offset.* >= data.len) return Error.Truncated;
    const huffmanEncoded = data[offset.*] & 0x80 != 0;
    const length = try decodeInt(data, offset, 7);
    if (length > maxLen) return Error.InvalidInstruction;
    const encoded = try take(data, offset, length);
    return decodeStringBytes(allocator, encoded, huffmanEncoded, maxLen);
}

/// Decodes already-framed string bytes (length known, header parsed).
fn decodeStringBytes(allocator: Allocator, encoded: []const u8, huffman: bool, maxLen: usize) Error![]u8 {
    if (!huffman) return allocator.dupe(u8, encoded) catch return Error.OutOfMemory;
    const doubled = std.math.mul(usize, encoded.len, 2) catch return Error.OutOfMemory;
    const capacity = std.math.add(usize, doubled, 1) catch return Error.OutOfMemory;
    const decoded = allocator.alloc(u8, capacity) catch return Error.OutOfMemory;
    errdefer allocator.free(decoded);
    const n = huff.decode(decoded, encoded) catch return Error.InvalidInstruction;
    if (n > maxLen) return Error.InvalidInstruction;
    return allocator.realloc(decoded, n) catch return Error.OutOfMemory;
}

pub const StaticEntry = struct { name: []const u8, value: []const u8 };

/// QPACK static table (RFC 9204 Appendix A) - first entries shown; full list encoded.
pub const STATIC_TABLE_SIZE = 99;

fn se(name: []const u8, value: []const u8) StaticEntry {
    return .{ .name = name, .value = value };
}

pub const staticTable = [_]StaticEntry{
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

pub fn encodeInt(buf: []u8, prefixBits: u4, value: u64) Error!usize {
    if (buf.len < 1) return Error.BufferTooSmall;
    const maxPrefix: u64 = (@as(u64, 1) << prefixBits) - 1;
    buf[0] = 0;

    if (value < maxPrefix) {
        buf[0] |= @intCast(value);
        return 1;
    }
    buf[0] |= @intCast(maxPrefix);
    var remaining = value - maxPrefix;
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

pub fn decodeInt(data: []const u8, offset: *usize, prefixBits: u4) Error!u64 {
    if (offset.* >= data.len) return Error.Truncated;
    const maxPrefix: u64 = (@as(u64, 1) << prefixBits) - 1;
    var value: u64 = data[offset.*] & @as(u8, @intCast(maxPrefix));
    offset.* += 1;
    if (value < maxPrefix) return value;

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
    if (!terminated) return Error.Truncated;
    return value;
}

// Dynamic table entry (RFC 9204 Section 2.3.2).
//
// Dynamic absolute indexes are 0-based and live in their own number
// space: static references (selected by each representation's T bit)
// index the static table, dynamic references index this table. Never
// mix the two (an early revision offset dynamic indexes by the static
// table size and was wire-incompatible with compliant peers).

pub const DynEntry = struct {
    name: []const u8,
    value: []const u8,
    /// Total size = name.len + value.len + ENTRY_OVERHEAD (32).
    totalSize: usize,
};

pub const DynTable = struct {
    entries: std.ArrayList(DynEntry),
    maxSize: usize,
    currentSize: usize = 0,
    /// Absolute index of the oldest retained dynamic entry.
    baseIndex: u64 = 0,
    /// Absolute index assigned to the next insertion (= insert count).
    nextIndex: u64 = 0,

    pub fn init(_: Allocator, maxSize: usize) DynTable {
        return .{
            .entries = std.ArrayList(DynEntry).empty,
            .maxSize = maxSize,
        };
    }

    pub fn deinit(self: *DynTable, allocator: Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        self.entries.deinit(allocator);
    }

    /// Inserts a new entry, evicting oldest entries to stay within maxSize.
    pub fn insert(self: *DynTable, allocator: Allocator, name: []const u8, value: []const u8) !u64 {
        const total = std.math.add(usize, std.math.add(usize, name.len, value.len) catch return Error.OutOfMemory, ENTRY_OVERHEAD) catch return Error.OutOfMemory;
        if (total > self.maxSize) return Error.TableCapacityExceeded;
        const index = self.nextIndex;
        _ = std.math.add(u64, self.nextIndex, 1) catch return Error.OutOfMemory;
        // Reserve the entry slot before evicting so a failed allocation
        // cannot leave the table observably changed.
        try self.entries.ensureUnusedCapacity(allocator, 1);

        const ownedName = try allocator.dupe(u8, name);
        errdefer allocator.free(ownedName);
        const ownedValue = try allocator.dupe(u8, value);
        errdefer allocator.free(ownedValue);

        // Evict oldest entries until the new one fits.
        while (self.currentSize + total > self.maxSize and self.entries.items.len > 0) {
            const old = self.entries.orderedRemove(0);
            self.currentSize -%= old.totalSize;
            self.baseIndex = std.math.add(u64, self.baseIndex, 1) catch return Error.OutOfMemory;
            allocator.free(old.name);
            allocator.free(old.value);
        }

        self.entries.appendAssumeCapacity(.{
            .name = ownedName,
            .value = ownedValue,
            .totalSize = total,
        });
        self.currentSize += total;
        self.nextIndex += 1;
        return @intCast(index);
    }

    /// Lowers (or raises) the capacity, evicting oldest entries to fit.
    /// Used for encoder-stream Set Capacity instructions.
    pub fn setMaxSize(self: *DynTable, allocator: Allocator, maxSize: usize) void {
        self.maxSize = maxSize;
        while (self.currentSize > self.maxSize and self.entries.items.len > 0) {
            const old = self.entries.orderedRemove(0);
            self.currentSize -%= old.totalSize;
            self.baseIndex +%= 1;
            allocator.free(old.name);
            allocator.free(old.value);
        }
    }

    /// Resolves a dynamic absolute index to a name+value pair, or null
    /// when evicted or never inserted. Static indexes never reach here;
    /// representations route by their T bit before calling.
    pub fn resolve(self: *const DynTable, absoluteIndex: u64) ?struct { name: []const u8, value: []const u8 } {
        if (absoluteIndex < self.baseIndex) return null;
        const dynIdx = absoluteIndex - self.baseIndex;
        if (dynIdx >= self.entries.items.len) return null;
        const e = self.entries.items[@intCast(dynIdx)];
        return .{ .name = e.name, .value = e.value };
    }
};

// Encoder

pub const Encoder = struct {
    allocator: Allocator,
    dyn: ?DynTable = null,
    /// Peer's QPACK_MAX_TABLE_CAPACITY (our table limit). Also sizes the
    /// Required Insert Count modulo in section prefixes.
    peerMaxCapacity: usize = 0,
    /// Peer's QPACK_BLOCKED_STREAMS hint, retained for policy tuning.
    peerMaxBlocked: u64 = 0,
    /// Absolute indexes below this are pinned against eviction: they may
    /// still be referenced by unacknowledged sections. The connection
    /// layer advances this from decoder-stream Section Acknowledgments.
    /// Defaults to pinning everything (literal fallback when full).
    evictBarrier: u64 = 0,
    /// Encoder-stream bytes not yet flushed (inserts, capacity changes).
    /// Drain with `takeEncoderBytes` and send on the encoder stream.
    pending: std.ArrayList(u8) = .empty,
    /// Buffered decoder-stream bytes with a consume cursor; a trailing
    /// split instruction waits for more bytes instead of erroring.
    decBuf: std.ArrayList(u8) = .empty,
    decOff: usize = 0,
    /// Highest insert count the peer confirmed via Insert Count Increment.
    peerKnownInserts: u64 = 0,
    /// Set while encoding a section whenever a dynamic reference is
    /// emitted. Builders read it via `sectionRic` to size the prefix.
    sectionUsedDynamic: bool = false,
    sectionMinRef: ?u64 = null,
    allowBlockingForSection: bool = true,
    outstanding: std.ArrayList(OutstandingSection) = .empty,

    const OutstandingSection = struct {
        streamId: u64,
        minRef: u64,
        requiredInsertCount: u64,
    };

    /// Cap on buffered decoder-stream bytes: a peer dripping partial
    /// bytes forever is a stream error, not unbounded memory.
    pub const MAX_DECODER_BUF: usize = 64 * 1024;

    pub fn init(allocator: Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    /// Releases the optional dynamic table and all strings owned by it.
    pub fn deinit(self: *Encoder) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        self.pending.deinit(self.allocator);
        self.decBuf.deinit(self.allocator);
        self.outstanding.deinit(self.allocator);
        self.decOff = 0;
    }

    /// Sizes the dynamic table to the peer's advertised capacity and
    /// queues a Set Capacity instruction for the encoder stream.
    pub fn setMaxTableCapacity(self: *Encoder, capacity: usize) void {
        var ib: [16]u8 = undefined;
        const n = encodeInt(&ib, 5, capacity) catch return;
        ib[0] |= 0x20;
        // Reserve the encoder-stream bytes before changing the local table:
        // dropping the instruction after the table was resized would leave
        // the peer's table out of sync.
        self.pending.ensureUnusedCapacity(self.allocator, n) catch return;
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        self.peerMaxCapacity = capacity;
        if (capacity != 0) {
            self.dyn = DynTable.init(self.allocator, capacity);
        }
        self.pending.appendSliceAssumeCapacity(ib[0..n]);
    }

    pub fn setMaxBlockedStreams(self: *Encoder, n: u64) void {
        self.peerMaxBlocked = n;
    }

    /// Starts a field section for `streamId`, allowing new references to
    /// unreceived inserts only if that stream is already blocked or the
    /// peer's distinct blocked-stream budget has room.
    pub fn beginSectionForStream(self: *Encoder, streamId: u64) void {
        self.beginSection();
        var blockedStreams: u64 = 0;
        var streamAlreadyBlocked = false;
        for (self.outstanding.items, 0..) |section, sectionIndex| {
            if (section.requiredInsertCount <= self.peerKnownInserts) continue;
            if (section.streamId == streamId) {
                streamAlreadyBlocked = true;
            } else {
                // Outstanding entries are per field section; count each
                // distinct stream once against the advertised setting.
                var firstForStream = true;
                for (self.outstanding.items[0..sectionIndex]) |earlier| {
                    if (earlier.streamId == section.streamId and earlier.requiredInsertCount > self.peerKnownInserts) {
                        firstForStream = false;
                        break;
                    }
                }
                if (firstForStream) blockedStreams += 1;
            }
        }
        self.allowBlockingForSection = streamAlreadyBlocked or blockedStreams < self.peerMaxBlocked;
    }

    pub fn setEvictBarrier(self: *Encoder, absIndex: u64) void {
        self.evictBarrier = absIndex;
    }

    /// Registers a completed field section that used dynamic references.
    /// Acknowledgments remove sections in stream order; cancellation removes
    /// every outstanding section for that stream.
    pub fn registerSection(self: *Encoder, streamId: u64) !void {
        const minRef = self.sectionMinRef orelse return;
        try self.outstanding.append(self.allocator, .{
            .streamId = streamId,
            .minRef = minRef,
            .requiredInsertCount = self.sectionRic(),
        });
        self.recomputeEvictBarrier();
    }

    fn recomputeEvictBarrier(self: *Encoder) void {
        var barrier = self.insertCount();
        for (self.outstanding.items) |section| barrier = @min(barrier, section.minRef);
        self.evictBarrier = barrier;
    }

    /// Next absolute dynamic index that will be assigned (= insert
    /// count, 0-based).
    pub fn insertCount(self: *const Encoder) u64 {
        if (self.dyn) |*d| return d.nextIndex;
        return 0;
    }

    /// Takes pending encoder-stream bytes; caller sends them on the
    /// encoder unidirectional stream, then frees the slice (always
    /// owned, even when empty).
    pub fn takeEncoderBytes(self: *Encoder) ![]u8 {
        if (self.pending.items.len == 0) return try self.allocator.dupe(u8, &.{});
        return try self.pending.toOwnedSlice(self.allocator);
    }

    fn emitString(self: *Encoder, out: *std.ArrayList(u8), str: []const u8, n: u3) !void {
        if (str.len == 0) {
            var tmp: [10]u8 = undefined;
            const nn = try encodeInt(&tmp, n, 0);
            try out.appendSlice(self.allocator, tmp[0..nn]);
            return;
        }
        const max = huff.maxEncodedLen(str.len);
        const buf = try self.allocator.alloc(u8, max);
        defer self.allocator.free(buf);
        if (huff.encode(buf, str)) |hlen| {
            if (hlen < str.len) {
                var tmp: [10]u8 = undefined;
                const nn = try encodeInt(&tmp, n, hlen);
                tmp[0] |= 0x80;
                try out.appendSlice(self.allocator, tmp[0..nn]);
                try out.appendSlice(self.allocator, buf[0..hlen]);
                return;
            }
        } else |_| {}
        var tmp: [10]u8 = undefined;
        const nn = try encodeInt(&tmp, n, str.len);
        try out.appendSlice(self.allocator, tmp[0..nn]);
        try out.appendSlice(self.allocator, str);
    }

    /// Encodes a header field, inserting into the dynamic table on first
    /// use when one is active (falling back to a literal when the table
    /// is full or every entry is pinned by `evictBarrier`).
    /// Sensitive names (authorization, cookie, set-cookie) are flagged
    /// never-index so intermediaries do not retain them.
    pub fn encodeField(
        self: *Encoder,
        out: *std.ArrayList(u8),
        name: []const u8,
        value: []const u8,
    ) !void {
        // Exact static match first.
        if (self.encodeStaticMatch(out, name, value)) return;

        // Exact dynamic match (newest first).
        if (self.dyn) |*dt| {
            var i: usize = dt.entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = dt.entries.items[i];
                if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.value, value)) {
                    if (dt.baseIndex + i >= self.peerKnownInserts and !self.allowBlockingForSection) break;
                    try self.encodeIndexedDynamic(out, dt.baseIndex + i, dt.nextIndex);
                    return;
                }
            }
        }

        // Static name-only match: literal with static name reference.
        for (staticTable, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                var ib: [10]u8 = undefined;
                const n = try encodeInt(&ib, 4, i);
                ib[0] |= 0x50 | (neverIndexBit(name) << 5);
                try out.appendSlice(self.allocator, ib[0..n]);
                try self.emitString(out, value, 7);
                return;
            }
        }

        // Dynamic name-only match (newest first).
        if (self.dyn) |*dt| {
            var i: usize = dt.entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = dt.entries.items[i];
                if (std.mem.eql(u8, e.name, name)) {
                    if (dt.baseIndex + i >= self.peerKnownInserts and !self.allowBlockingForSection) break;
                    const rel = dt.nextIndex - (dt.baseIndex + i) - 1;
                    var ib: [10]u8 = undefined;
                    const n = try encodeInt(&ib, 4, rel);
                    ib[0] |= 0x40 | (neverIndexBit(name) << 5);
                    try out.appendSlice(self.allocator, ib[0..n]);
                    try self.emitString(out, value, 7);
                    self.sectionUsedDynamic = true;
                    self.sectionMinRef = @min(self.sectionMinRef orelse (dt.baseIndex + i), dt.baseIndex + i);
                    return;
                }
            }
        }

        // No match: insert on first use, else literal without name ref.
        if (self.dyn != null and self.allowBlockingForSection) {
            if (try self.insertDynamic(name, value)) |abs| {
                try self.encodeIndexedDynamic(out, abs, self.insertCount());
                return;
            }
        }
        try self.encodeLiteral(out, name, value);
    }

    fn neverIndexBit(name: []const u8) u8 {
        if (std.mem.eql(u8, name, "authorization") or
            std.mem.eql(u8, name, "cookie") or
            std.mem.eql(u8, name, "set-cookie")) return 1;
        return 0;
    }

    /// Emits a literal without name reference: 001 | N | H | len(3+).
    fn encodeLiteral(self: *Encoder, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
        const max = huff.maxEncodedLen(name.len);
        const buf = try self.allocator.alloc(u8, max);
        defer self.allocator.free(buf);
        const hlen = huff.encode(buf, name) catch null;
        const useHuff = if (hlen) |hl| hl < name.len else false;
        const nlen = if (useHuff) hlen.? else name.len;
        var ib: [10]u8 = undefined;
        const n = try encodeInt(&ib, 3, nlen);
        ib[0] |= 0x20 | (neverIndexBit(name) << 4);
        if (useHuff) ib[0] |= 0x08;
        try out.appendSlice(self.allocator, ib[0..n]);
        if (useHuff) {
            try out.appendSlice(self.allocator, buf[0..hlen.?]);
        } else {
            try out.appendSlice(self.allocator, name);
        }
        try self.emitString(out, value, 7);
    }

    /// Inserts (name, value), emitting the encoder-stream instruction to
    /// `pending`. Returns the absolute index, or null when the table is
    /// full and every entry is pinned (caller falls back to a literal).
    /// Eviction only removes entries below `evictBarrier`.
    fn insertDynamic(self: *Encoder, name: []const u8, value: []const u8) !?u64 {
        const dt = if (self.dyn) |*d| d else return null;
        const total = std.math.add(
            usize,
            std.math.add(usize, name.len, value.len) catch return null,
            ENTRY_OVERHEAD,
        ) catch return null;
        if (total > dt.maxSize) return null;

        // Build the encoder-stream instruction first so an allocation
        // failure cannot leave the dynamic table ahead of the peer.
        var ins = std.ArrayList(u8).empty;
        defer ins.deinit(self.allocator);
        const max = huff.maxEncodedLen(name.len);
        const buf = try self.allocator.alloc(u8, max);
        defer self.allocator.free(buf);
        const hlen = huff.encode(buf, name) catch null;
        const useHuff = if (hlen) |hl| hl < name.len else false;
        const nlen = if (useHuff) hlen.? else name.len;
        var ib: [16]u8 = undefined;
        const n = try encodeInt(&ib, 5, nlen);
        ib[0] |= 0x40;
        if (useHuff) ib[0] |= 0x20;
        try ins.appendSlice(self.allocator, ib[0..n]);
        if (useHuff) {
            try ins.appendSlice(self.allocator, buf[0..hlen.?]);
        } else {
            try ins.appendSlice(self.allocator, name);
        }
        try self.emitString(&ins, value, 7);
        try self.pending.ensureUnusedCapacity(self.allocator, ins.items.len);

        while (dt.currentSize + total > dt.maxSize and dt.entries.items.len > 0) {
            const oldestAbs = dt.baseIndex;
            if (oldestAbs >= self.evictBarrier) return null;
            const old = dt.entries.orderedRemove(0);
            dt.currentSize -%= old.totalSize;
            dt.baseIndex +%= 1;
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
        if (dt.currentSize + total > dt.maxSize) return null;
        const abs = try dt.insert(self.allocator, name, value);
        self.pending.appendSliceAssumeCapacity(ins.items);
        self.sectionUsedDynamic = true;
        return abs;
    }

    /// Emits the field-section prefix for a section whose largest
    /// referenced absolute index is below `ric`, with `base` as Base
    /// (we always set Base == RIC: no post-base references emitted).
    pub fn encodePrefix(self: *Encoder, out: *std.ArrayList(u8), ric: u64, base: u64) !void {
        std.debug.assert(base <= ric);
        const maxEntries = @max(1, self.peerMaxCapacity / ENTRY_OVERHEAD);
        var encRic: u64 = 0;
        if (ric != 0) {
            const full = std.math.mul(u64, maxEntries, 2) catch std.math.maxInt(u64);
            encRic = (ric % @max(1, full)) + 1;
        }
        var tmp: [16]u8 = undefined;
        const n = try encodeInt(&tmp, 8, encRic);
        try out.appendSlice(self.allocator, tmp[0..n]);
        const delta = ric - base;
        const m = try encodeInt(&tmp, 7, delta);
        // S=0 (Base >= ... encoded as RIC + delta); top bit stays clear.
        try out.appendSlice(self.allocator, tmp[0..m]);
    }

    /// Starts a section: clears the dynamic-reference flag. After
    /// encoding the section's fields, `sectionRic` gives the prefix RIC.
    pub fn beginSection(self: *Encoder) void {
        self.sectionUsedDynamic = false;
        self.sectionMinRef = null;
        self.allowBlockingForSection = true;
    }

    /// Required Insert Count for the section currently being encoded:
    /// the insert count when dynamic references were used, else 0.
    pub fn sectionRic(self: *const Encoder) u64 {
        if (!self.sectionUsedDynamic) return 0;
        return self.insertCount();
    }

    /// Attempts to encode using a static table indexed match.
    fn encodeStaticMatch(self: *Encoder, out: *std.ArrayList(u8), name: []const u8, value: []const u8) bool {
        for (staticTable, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                self.encodeIndexedStatic(out, @intCast(i)) catch return false;
                return true;
            }
        }
        return false;
    }

    /// Encodes a static-table indexed field (T=1, 6-bit prefix).
    pub fn encodeIndexedStatic(self: *Encoder, out: *std.ArrayList(u8), index: u64) !void {
        var ib: [10]u8 = undefined;
        const n = try encodeInt(&ib, 6, index);
        ib[0] |= 0xC0; // S=1 + 6-bit prefix tag
        try out.appendSlice(self.allocator, ib[0..n]);
    }

    /// Encodes a dynamic-table indexed field (T=0, 6-bit prefix) as a
    /// relative index against `base` (normally the section Base).
    /// `absoluteIndex` must name a live dynamic entry.
    pub fn encodeIndexedDynamic(self: *Encoder, out: *std.ArrayList(u8), absoluteIndex: u64, base: u64) !void {
        std.debug.assert(base > absoluteIndex);
        const rel = base - absoluteIndex - 1;
        var ib: [10]u8 = undefined;
        const n = try encodeInt(&ib, 6, rel);
        ib[0] |= 0x80; // 1 | T=0 (dynamic)
        try out.appendSlice(self.allocator, ib[0..n]);
        self.sectionUsedDynamic = true;
        self.sectionMinRef = @min(self.sectionMinRef orelse absoluteIndex, absoluteIndex);
    }

    /// Processes decoder-stream bytes from the peer: Section
    /// Acknowledgment (0x80+, 7-bit), Stream Cancellation (0x40, 6-bit),
    /// Insert Count Increment (0x00, 6-bit). Pass `fin=true` when these
    /// are the stream's final bytes: a trailing split instruction is
    /// then corruption (InvalidInstruction), otherwise it is buffered
    /// until more bytes arrive.
    pub fn readDecoderStream(self: *Encoder, data: []const u8, fin: bool) !void {
        if (self.decBuf.items.len - self.decOff + data.len > MAX_DECODER_BUF) {
            return Error.InvalidInstruction;
        }
        try self.decBuf.appendSlice(self.allocator, data);
        var off: usize = self.decOff;
        const buf = self.decBuf.items;
        while (off < buf.len) {
            const start = off;
            _ = self.decodeDecoderOp(buf, &off) catch |e| {
                // Truncated on a live stream means a split instruction:
                // rewind and wait for more bytes. At FIN (or for any
                // other error) it is corruption.
                if (e == error.Truncated and !fin) {
                    off = start;
                    break;
                }
                self.decOff = off;
                self.compactDecBuf();
                return Error.InvalidInstruction;
            };
        }
        self.decOff = off;
        self.compactDecBuf();
    }

    fn decodeDecoderOp(self: *Encoder, buf: []const u8, off: *usize) Error!u64 {
        const first = buf[off.*];
        if (first & 0x80 != 0) {
            const streamId = try decodeInt(buf, off, 7);
            var i: usize = 0;
            while (i < self.outstanding.items.len and self.outstanding.items[i].streamId != streamId) : (i += 1) {}
            if (i == self.outstanding.items.len) return Error.InvalidInstruction;
            const section = self.outstanding.orderedRemove(i);
            self.peerKnownInserts = @max(self.peerKnownInserts, section.requiredInsertCount);
            self.recomputeEvictBarrier();
            return streamId;
        } else if (first & 0xC0 == 0x40) {
            const streamId = try decodeInt(buf, off, 6);
            var i: usize = 0;
            while (i < self.outstanding.items.len) {
                if (self.outstanding.items[i].streamId == streamId) {
                    _ = self.outstanding.orderedRemove(i);
                } else i += 1;
            }
            self.recomputeEvictBarrier();
            return streamId;
        }
        const n = try decodeInt(buf, off, 6); // Insert Count Increment
        // RFC 9204 Section 3.2.6: Increment of 0 or exceeding known inserts is a decoder stream error.
        if (n == 0) return Error.InvalidInstruction;
        const curInserts = self.insertCount();
        if (curInserts < self.peerKnownInserts or curInserts - self.peerKnownInserts < n) {
            return Error.InvalidInstruction;
        }
        self.peerKnownInserts = std.math.add(u64, self.peerKnownInserts, n) catch
            return Error.InvalidInstruction;
        return n;
    }

    fn compactDecBuf(self: *Encoder) void {
        if (self.decOff == 0) return;
        if (self.decOff >= self.decBuf.items.len) {
            self.decBuf.clearRetainingCapacity();
            self.decOff = 0;
            return;
        }
        std.mem.copyForwards(u8, self.decBuf.items[0..], self.decBuf.items[self.decOff..]);
        self.decBuf.items.len -= self.decOff;
        self.decOff = 0;
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
    /// Capacity we advertised via SETTINGS. Encoder-stream Set Capacity
    /// above this is a stream error.
    advertisedMax: usize = 0,
    /// Local MAX_FIELD_SECTION_SIZE enforcement on decoded field size.
    maxFieldSectionSize: u64 = 16384,
    /// Buffered encoder-stream bytes with a consume cursor; a trailing
    /// split instruction waits for more bytes instead of erroring.
    /// Bounded by MAX_ENCODER_BUF.
    encBuf: std.ArrayList(u8) = .empty,
    encOff: usize = 0,
    /// Inserts consumed and reported via Insert Count Increment.
    ackedInserts: u64 = 0,

    /// Cap on buffered encoder-stream bytes: a peer dripping partial
    /// bytes forever is a stream error, not unbounded memory.
    pub const MAX_ENCODER_BUF: usize = 128 * 1024;

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    /// Releases the optional dynamic table and all strings owned by it.
    pub fn deinit(self: *Decoder) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        self.encBuf.deinit(self.allocator);
        self.encOff = 0;
    }

    pub fn setMaxTableCapacity(self: *Decoder, capacity: usize) void {
        if (self.dyn) |*d| d.deinit(self.allocator);
        self.dyn = null;
        self.advertisedMax = capacity;
        self.ackedInserts = 0;
        self.encBuf.clearRetainingCapacity();
        self.encOff = 0;
        if (capacity != 0) {
            self.dyn = DynTable.init(self.allocator, capacity);
        }
    }

    pub fn setMaxFieldSectionSize(self: *Decoder, n: u64) void {
        self.maxFieldSectionSize = n;
    }

    /// Absolute index that the next encoder-stream insert will take
    /// (= insert count, 0-based).
    pub fn insertCount(self: *const Decoder) u64 {
        if (self.dyn) |*d| return d.nextIndex;
        return 0;
    }

    /// Feeds encoder-stream bytes, applying complete instructions to the
    /// dynamic table. Pass `fin=true` when these are the stream's final
    /// bytes: a trailing split instruction is then a stream error
    /// (InvalidInstruction), otherwise it is buffered. Anything else
    /// malformed is InvalidInstruction (connection error
    /// QPACK_ENCODER_STREAM_ERROR).
    pub fn readEncoderStream(self: *Decoder, data: []const u8, fin: bool) !void {
        if (self.encBuf.items.len - self.encOff + data.len > MAX_ENCODER_BUF) {
            return Error.InvalidInstruction;
        }
        try self.encBuf.appendSlice(self.allocator, data);
        var off: usize = self.encOff;
        const buf = self.encBuf.items;
        while (off < buf.len) {
            const start = off;
            self.decodeEncoderOp(buf, &off) catch |e| {
                // Truncated on a live stream means a split instruction:
                // rewind and wait for more bytes. At FIN (or for any
                // other error) it is corruption.
                if (e == error.Truncated and !fin) {
                    off = start;
                    break;
                }
                return Error.InvalidInstruction;
            };
        }
        self.encOff = off;
        self.compactEncBuf();
    }

    fn compactEncBuf(self: *Decoder) void {
        if (self.encOff == 0) return;
        if (self.encOff >= self.encBuf.items.len) {
            self.encBuf.clearRetainingCapacity();
            self.encOff = 0;
            return;
        }
        std.mem.copyForwards(u8, self.encBuf.items[0..], self.encBuf.items[self.encOff..]);
        self.encBuf.items.len -= self.encOff;
        self.encOff = 0;
    }

    fn decodeEncoderOp(self: *Decoder, buf: []const u8, off: *usize) Error!void {
        const first = buf[off.*];
        if (first & 0x80 != 0) {
            // Insert With Name Reference: 1 | T | idx(6+).
            // T polarity is inverted vs field sections: T=1 static.
            const isStatic = first & 0x40 != 0;
            const idx = try decodeInt(buf, off, 6);
            var name: []const u8 = undefined;
            if (isStatic) {
                if (idx >= STATIC_TABLE_SIZE) return Error.InvalidInstruction;
                name = staticTable[@intCast(idx)].name;
            } else {
                const abs = try self.encoderRelToAbs(idx);
                const res = self.lookupDynamic(abs) catch return Error.InvalidInstruction;
                name = res.name;
            }
            const value = try readString(self.allocator, buf, off, MAX_VALUE_LEN);
            errdefer self.allocator.free(value);
            try self.insertDecoded(name, value);
            // The table holds its own copies; release the parse buffer.
            self.allocator.free(value);
            return;
        }
        if (first & 0xC0 == 0x40) {
            // Insert With Literal Name: 01 | H | len(5+). Both 0x40
            // (raw) and 0x60 (Huffman) forms insert.
            const huffName = first & 0x20 != 0;
            const nlen = try decodeInt(buf, off, 5);
            if (nlen > MAX_NAME_LEN) return Error.InvalidInstruction;
            const nbytes = try take(buf, off, nlen);
            const name = try decodeStringBytes(self.allocator, nbytes, huffName, MAX_NAME_LEN);
            errdefer self.allocator.free(name);
            const value = try readString(self.allocator, buf, off, MAX_VALUE_LEN);
            errdefer self.allocator.free(value);
            try self.insertDecoded(name, value);
            self.allocator.free(name);
            self.allocator.free(value);
            return;
        }
        if (first & 0xE0 == 0x20) {
            // Set Dynamic Table Capacity: 001 | cap(5+).
            const cap = try decodeInt(buf, off, 5);
            const capUsize = std.math.cast(usize, cap) orelse return Error.InvalidInstruction;
            if (capUsize > self.advertisedMax) return Error.InvalidInstruction;
            if (self.dyn) |*d| {
                d.setMaxSize(self.allocator, capUsize);
            } else if (capUsize != 0) {
                return Error.InvalidInstruction;
            }
            return;
        }
        // Duplicate: 000 | rel(5+), relative to our insert count.
        const rel = try decodeInt(buf, off, 5);
        const abs = try self.encoderRelToAbs(rel);
        const res = self.lookupDynamic(abs) catch return Error.InvalidInstruction;
        const name = try self.allocator.dupe(u8, res.name);
        errdefer self.allocator.free(name);
        const value = try self.allocator.dupe(u8, res.value);
        errdefer self.allocator.free(value);
        try self.insertDecoded(name, value);
        self.allocator.free(name);
        self.allocator.free(value);
    }

    fn encoderRelToAbs(self: *const Decoder, rel: u64) Error!u64 {
        const have = self.insertCount();
        if (rel >= have) return Error.InvalidInstruction;
        return have - rel - 1;
    }

    fn insertDecoded(self: *Decoder, name: []const u8, value: []const u8) Error!void {
        const dt = if (self.dyn) |*d| d else return Error.InvalidInstruction;
        _ = dt.insert(self.allocator, name, value) catch |e| switch (e) {
            error.TableCapacityExceeded => return Error.InvalidInstruction,
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.InvalidInstruction,
        };
    }

    /// A resolved table entry (borrowed; owned by the static table or
    /// our dynamic table, never freed by the caller).
    pub const DynRef = struct { name: []const u8, value: []const u8 };

    fn lookupDynamic(self: *const Decoder, abs: u64) Error!DynRef {
        const dt = if (self.dyn) |*d| d else return Error.InvalidIndex;
        const r = dt.resolve(abs) orelse return Error.InvalidIndex;
        return .{ .name = r.name, .value = r.value };
    }

    /// Static references name the static table only; anything at or
    /// above 99 is malformed (never a dynamic lookup).
    fn lookupStatic(abs: u64) Error!DynRef {
        if (abs >= STATIC_TABLE_SIZE) return Error.InvalidIndex;
        const e = staticTable[@intCast(abs)];
        return .{ .name = e.name, .value = e.value };
    }

    /// Base-relative reference (field sections): abs = Base - rel - 1,
    /// additionally requiring abs < ric (the section may not name
    /// entries inserted after its Required Insert Count).
    fn baseRelative(_: *const Decoder, base: u64, ric: u64, rel: u64) Error!u64 {
        if (rel >= base) return Error.InvalidIndex;
        const abs = base - rel - 1;
        if (abs >= ric) return Error.InvalidInstruction;
        return abs;
    }

    fn reconstructRic(self: *const Decoder, encRic: u64) Error!u64 {
        if (encRic == 0) return 0;
        if (self.advertisedMax == 0) return Error.InvalidInstruction;
        const maxEnts = @max(1, self.advertisedMax / ENTRY_OVERHEAD);
        const full = std.math.mul(u64, maxEnts, 2) catch return Error.InvalidInstruction;
        if (encRic > full) return Error.InvalidInstruction;
        const max = std.math.add(u64, self.insertCount(), maxEnts) catch return Error.InvalidInstruction;
        const maxWrapped = max / full * full;
        var ric = std.math.add(u64, maxWrapped, encRic - 1) catch return Error.InvalidInstruction;
        if (ric > max) {
            if (ric <= full) return Error.InvalidInstruction;
            ric -= full;
        }
        if (ric == 0) return Error.InvalidInstruction;
        return ric;
    }

    /// Decodes an encoded field section into field lines (no prefix).
    /// Base and RIC both equal our insert count: only references
    /// resolvable right now decode; anything naming a future insert is
    /// an index error. Prefer `decodeSectionCounted` on the wire path.
    pub fn decodeSection(self: *Decoder, data: []const u8) Error![]FieldLine {
        const ic = self.insertCount();
        return self.decodeSectionInner(data, ic, ic);
    }

    /// Decodes a complete QPACK encoded field section, including its
    /// prefix, emitting a Section Acknowledgment for `streamId` into
    /// `ackOut` (when non-null) if dynamic entries were referenced.
    /// Returns `error.Blocked` when Required Insert Count runs ahead of
    /// our encoder-stream state: keep the section bytes and retry after
    /// feeding more encoder data. Never buffers internally.
    pub fn decodeSectionCounted(
        self: *Decoder,
        data: []const u8,
        streamId: u64,
        ackOut: ?*std.ArrayList(u8),
    ) Error![]FieldLine {
        if (data.len > std.math.add(u64, self.maxFieldSectionSize, 16) catch std.math.maxInt(u64)) {
            return Error.InvalidInstruction;
        }
        var offset: usize = 0;
        const encRic = try decodeInt(data, &offset, 8);
        const ric = try self.reconstructRic(encRic);
        if (offset >= data.len) return Error.InvalidInstruction;
        const sign = data[offset] & 0x80 != 0;
        const delta = try decodeInt(data, &offset, 7);
        var base: u64 = undefined;
        if (sign) {
            if (ric <= delta) return Error.InvalidInstruction;
            base = ric - delta - 1;
        } else {
            base = std.math.add(u64, ric, delta) catch return Error.InvalidInstruction;
        }
        if (ric != 0 and self.dyn == null) return Error.InvalidInstruction;
        if (ric > self.insertCount()) return Error.Blocked;
        const fields = try self.decodeSectionInner(data[offset..], base, ric);
        errdefer self.freeFields(fields);
        if (ric != 0) {
            if (ackOut) |out| {
                var ib: [16]u8 = undefined;
                const n = try encodeInt(&ib, 7, streamId);
                ib[0] |= 0x80;
                try out.appendSlice(self.allocator, ib[0..n]);
            }
        }
        return fields;
    }

    fn decodeSectionInner(self: *Decoder, data: []const u8, base: u64, ric: u64) Error![]FieldLine {
        var results = std.ArrayList(FieldLine).empty;
        var fieldSectionSize: u64 = 0;
        errdefer {
            for (results.items) |f| {
                if (f.allocated) {
                    self.allocator.free(f.name);
                    self.allocator.free(f.value);
                }
            }
            results.deinit(self.allocator);
        }
        var offset: usize = 0;

        while (offset < data.len) {
            const first = data[offset];

            if (first & 0x80 != 0) {
                // Indexed: 1 | T | idx(6+). T=1 names the static table
                // absolutely; T=0 is a dynamic Base-relative index.
                const dynRef = first & 0x40 == 0;
                const rel = try decodeInt(data, &offset, 6);
                const abs = if (dynRef) try self.baseRelative(base, ric, rel) else rel;
                const res = if (dynRef) try self.lookupDynamic(abs) else try lookupStatic(abs);
                try accountFieldSize(&fieldSectionSize, res.name, res.value, self.maxFieldSectionSize);
                try results.append(self.allocator, .{ .name = res.name, .value = res.value, .allocated = false });
            } else if (first & 0xC0 == 0x40) {
                // Literal with name reference: 01 | N | T | idx(4+).
                const dynRef = first & 0x10 == 0;
                const rel = try decodeInt(data, &offset, 4);
                const abs = if (dynRef) try self.baseRelative(base, ric, rel) else rel;
                const res = if (dynRef) try self.lookupDynamic(abs) else try lookupStatic(abs);
                const name = try self.allocator.dupe(u8, res.name);
                const value = readString(self.allocator, data, &offset, MAX_VALUE_LEN) catch |e| {
                    self.allocator.free(name);
                    return e;
                };
                appendOwnedField(&results, self.allocator, name, value) catch |e| {
                    self.allocator.free(name);
                    self.allocator.free(value);
                    return e;
                };
                try accountFieldSize(&fieldSectionSize, name, value, self.maxFieldSectionSize);
            } else if (first & 0xF0 == 0x20 or first & 0xF0 == 0x30) {
                // Literal without name reference: 001 | N | H | len(3+).
                // (A dynamic-table size update can only appear on the
                // encoder stream; here these bytes are always a literal.)
                const huffName = first & 0x08 != 0;
                const nlen = try decodeInt(data, &offset, 3);
                if (nlen > MAX_NAME_LEN) return Error.InvalidInstruction;
                const nbytes = try take(data, &offset, nlen);
                const name = try decodeStringBytes(self.allocator, nbytes, huffName, MAX_NAME_LEN);
                const value = readString(self.allocator, data, &offset, MAX_VALUE_LEN) catch |e| {
                    self.allocator.free(name);
                    return e;
                };
                appendOwnedField(&results, self.allocator, name, value) catch |e| {
                    self.allocator.free(name);
                    self.allocator.free(value);
                    return e;
                };
                try accountFieldSize(&fieldSectionSize, name, value, self.maxFieldSectionSize);
            } else if (first & 0xF0 == 0x10) {
                // Indexed with post-base index: 0001 | rel(4+).
                const rel = try decodeInt(data, &offset, 4);
                const abs = std.math.add(u64, base, rel) catch return Error.InvalidInstruction;
                if (abs >= ric) return Error.InvalidInstruction;
                const res = try self.lookupDynamic(abs);
                try accountFieldSize(&fieldSectionSize, res.name, res.value, self.maxFieldSectionSize);
                try results.append(self.allocator, .{ .name = res.name, .value = res.value, .allocated = false });
            } else {
                // Literal with post-base name reference: 000 | N | rel(3+).
                const rel = try decodeInt(data, &offset, 3);
                const abs = std.math.add(u64, base, rel) catch return Error.InvalidInstruction;
                if (abs >= ric) return Error.InvalidInstruction;
                const res = try self.lookupDynamic(abs);
                const name = try self.allocator.dupe(u8, res.name);
                const value = readString(self.allocator, data, &offset, MAX_VALUE_LEN) catch |e| {
                    self.allocator.free(name);
                    return e;
                };
                appendOwnedField(&results, self.allocator, name, value) catch |e| {
                    self.allocator.free(name);
                    self.allocator.free(value);
                    return e;
                };
                try accountFieldSize(&fieldSectionSize, name, value, self.maxFieldSectionSize);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Emits an Insert Count Increment for inserts consumed since the
    /// last call (decoder-stream traffic for the peer's encoder).
    /// No-op when nothing new arrived.
    pub fn insertCountIncrement(self: *Decoder, out: *std.ArrayList(u8)) !void {
        const n = self.insertCount() - self.ackedInserts;
        if (n == 0) return;
        var ib: [16]u8 = undefined;
        const m = try encodeInt(&ib, 6, n);
        try out.appendSlice(self.allocator, ib[0..m]);
        self.ackedInserts = self.insertCount();
    }

    /// Emits a Stream Cancellation for an abandoned section (decoder
    /// stream), e.g. after RESET_STREAM on a blocked request stream.
    pub fn cancelSection(self: *Decoder, out: *std.ArrayList(u8), streamId: u64) !void {
        var ib: [16]u8 = undefined;
        const m = try encodeInt(&ib, 6, streamId);
        ib[0] |= 0x40;
        try out.appendSlice(self.allocator, ib[0..m]);
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

fn accountFieldSize(total: *u64, name: []const u8, value: []const u8, limit: u64) Error!void {
    const fieldSize = std.math.add(u64, @intCast(name.len), @intCast(value.len)) catch return Error.InvalidInstruction;
    const withOverhead = std.math.add(u64, fieldSize, 32) catch return Error.InvalidInstruction;
    const next = std.math.add(u64, total.*, withOverhead) catch return Error.InvalidInstruction;
    if (next > limit) return Error.InvalidInstruction;
    total.* = next;
}

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
    try std.testing.expectEqualStrings(":method", staticTable[17].name);
    try std.testing.expectEqualStrings("GET", staticTable[17].value);
    try std.testing.expectEqualStrings(":status", staticTable[25].name);
    try std.testing.expectEqualStrings("200", staticTable[25].value);
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

    var lenBuf: [10]u8 = undefined;
    const indexBytes = try encodeInt(&lenBuf, 4, 17);
    lenBuf[0] |= 0x50; // 01, N=0, S=1
    try block.appendSlice(a, lenBuf[0..indexBytes]);
    const n = try encodeInt(&lenBuf, 7, 4);
    try block.appendSlice(a, lenBuf[0..n]);
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
    const fields = try dec.decodeSectionCounted(block.items, 0, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
}

test "qpack dynamic name references fail closed" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    // 0x41: literal with dynamic-table name reference, rel index 1.
    // No dynamic table exists, so the reference cannot resolve.
    try std.testing.expectError(Error.InvalidIndex, dec.decodeSection("\x41"));
}

test "qpack dynamic indexes remain monotonic across eviction" {
    const a = std.testing.allocator;
    var table = DynTable.init(a, 40);
    defer table.deinit(a);

    const first = try table.insert(a, "a", "1");
    const second = try table.insert(a, "b", "2");
    try std.testing.expectEqual(@as(u64, 0), first);
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
    try std.testing.expectEqual(@as(usize, 0), table.currentSize);
}

test "qpack huffman literal decodes through shared codec" {
    const a = std.testing.allocator;
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    // Literal without name reference: 001 | N | H | len(3+).
    var encoded: [64]u8 = undefined;
    const nameLen = try huff.encode(encoded[0..], ":path");
    var lenBuf: [10]u8 = undefined;
    var n = try encodeInt(&lenBuf, 3, nameLen);
    lenBuf[0] |= 0x20 | 0x08; // literal, raw name, Huffman-encoded
    try block.appendSlice(a, lenBuf[0..n]);
    try block.appendSlice(a, encoded[0..nameLen]);

    const valueLen = try huff.encode(encoded[0..], "/");
    n = try encodeInt(&lenBuf, 7, valueLen);
    lenBuf[0] |= 0x80;
    try block.appendSlice(a, lenBuf[0..n]);
    try block.appendSlice(a, encoded[0..valueLen]);

    var dec = Decoder.init(a);
    const fields = try dec.decodeSection(block.items);
    defer dec.freeFields(fields);
    try std.testing.expectEqualStrings(":path", fields[0].name);
    try std.testing.expectEqualStrings("/", fields[0].value);
}

test "qpack dynamic roundtrip through encoder and decoder streams" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);

    // Encode one field: unseen name+value inserts into the table.
    var field = std.ArrayList(u8).empty;
    defer field.deinit(a);
    enc.beginSection();
    try enc.encodeField(&field, "x-custom", "v1");
    const ric = enc.sectionRic();
    try std.testing.expectEqual(@as(u64, 1), ric);

    var section = std.ArrayList(u8).empty;
    defer section.deinit(a);
    try enc.encodePrefix(&section, ric, ric);
    try section.appendSlice(a, field.items);

    // Flush encoder-stream instructions (Set Capacity + Insert).
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);
    try std.testing.expect(encBytes.len > 0);

    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    try dec.readEncoderStream(encBytes, true);

    var ack = std.ArrayList(u8).empty;
    defer ack.deinit(a);
    const fields = try dec.decodeSectionCounted(section.items, 0, &ack);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("x-custom", fields[0].name);
    try std.testing.expectEqualStrings("v1", fields[0].value);
    // Dynamic section decoded: a Section Acknowledgment was staged
    // (single byte for small stream IDs: 0x80 | id(7+)).
    try std.testing.expectEqual(@as(usize, 1), ack.items.len);
    try std.testing.expectEqual(@as(u8, 0x80), ack.items[0]);

    // The consumed inserts are reportable via Insert Count Increment.
    var inc = std.ArrayList(u8).empty;
    defer inc.deinit(a);
    try dec.insertCountIncrement(&inc);
    try std.testing.expect(inc.items.len > 0);
}

test "qpack blocked section retries after encoder data arrives" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    enc.beginSection();
    var field = std.ArrayList(u8).empty;
    defer field.deinit(a);
    try enc.encodeField(&field, "x-blocked", "yes");
    const ric = enc.sectionRic();
    var section = std.ArrayList(u8).empty;
    defer section.deinit(a);
    try enc.encodePrefix(&section, ric, ric);
    try section.appendSlice(a, field.items);
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);

    // Fresh decoder knows nothing: same section must Block, not fail.
    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    try std.testing.expectError(Error.Blocked, dec.decodeSectionCounted(section.items, 4, null));

    // Feed the encoder stream, then the identical bytes decode.
    try dec.readEncoderStream(encBytes, true);
    const fields = try dec.decodeSectionCounted(section.items, 4, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqualStrings("x-blocked", fields[0].name);
    try std.testing.expectEqualStrings("yes", fields[0].value);
}

test "qpack post-base references resolve" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    // Two inserts: abs 0 (x-a) and abs 1 (x-b); insertCount 2.
    _ = try enc.insertDynamic("x-a", "1");
    _ = try enc.insertDynamic("x-b", "2");
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);

    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    try dec.readEncoderStream(encBytes, true);

    // Section with Base=0 (< RIC=2): post-base rel 0 -> abs 0.
    // RIC 2 with maxEntries 128 encodes as 2 % 256 + 1 = 3.
    var section = std.ArrayList(u8).empty;
    defer section.deinit(a);
    try section.appendSlice(a, &.{ 3, 0x81 }); // RIC=2, S=1, delta=1, Base=0
    try section.append(a, 0x10); // indexed post-base, rel 0
    const fields = try dec.decodeSectionCounted(section.items, 0, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("x-a", fields[0].name);

    // Post-base name reference: 000 | N | rel(3+), then a value.
    var section2 = std.ArrayList(u8).empty;
    defer section2.deinit(a);
    try section2.appendSlice(a, &.{ 3, 0x81, 0x01 });
    var tmp: [10]u8 = undefined;
    const n = try encodeInt(&tmp, 7, 3);
    try section2.appendSlice(a, tmp[0..n]);
    try section2.appendSlice(a, "two");
    const fields2 = try dec.decodeSectionCounted(section2.items, 0, null);
    defer dec.freeFields(fields2);
    try std.testing.expectEqualStrings("x-b", fields2[0].name);
    try std.testing.expectEqualStrings("two", fields2[0].value);
}

test "qpack encoder stream split delivery buffers" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    _ = try enc.insertDynamic("x-split", "s");
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);
    try std.testing.expect(encBytes.len > 2);

    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    // Feed one byte at a time: partial instructions buffer, never fail.
    for (encBytes) |b| {
        try dec.readEncoderStream(&.{b}, false);
    }
    try std.testing.expectEqual(@as(u64, 1), dec.insertCount());
    const res = try dec.lookupDynamic(0);
    try std.testing.expectEqualStrings("x-split", res.name);
    // The same truncation at FIN is corruption, not a split.
    try std.testing.expectError(Error.InvalidInstruction, dec.readEncoderStream(&.{0x40}, true));
}

test "qpack set capacity above advertised max is rejected" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(64);
    var ib: [16]u8 = undefined;
    const n = try encodeInt(&ib, 5, 4096);
    ib[0] |= 0x20;
    try std.testing.expectError(Error.InvalidInstruction, dec.readEncoderStream(ib[0..n], true));
}

test "qpack duplicate instruction copies entries" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    const abs0 = (try enc.insertDynamic("x-dup", "d")).?;
    try std.testing.expectEqual(@as(u64, 0), abs0);
    // Duplicate relative 0 -> copies abs 0 to abs 1.
    var dup: [16]u8 = undefined;
    const n = try encodeInt(&dup, 5, 0);
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(a);
    try combined.appendSlice(a, encBytes);
    try combined.appendSlice(a, dup[0..n]);

    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    try dec.readEncoderStream(combined.items, true);
    try std.testing.expectEqual(@as(u64, 2), dec.insertCount());
    const res = try dec.lookupDynamic(1);
    try std.testing.expectEqualStrings("x-dup", res.name);
    try std.testing.expectEqualStrings("d", res.value);
}

test "qpack decoder stream instructions parse strictly" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    _ = try enc.insertDynamic("x-a", "1");
    enc.sectionUsedDynamic = true;
    enc.sectionMinRef = 0;
    try enc.registerSection(4);
    _ = try enc.insertDynamic("x-b", "2");
    enc.sectionUsedDynamic = true;
    enc.sectionMinRef = 1;
    try enc.registerSection(4);
    // SectionAck(4) implies one insert was received; after canceling its
    // second section, only one additional insert needs an explicit increment.
    try enc.readDecoderStream(&.{ 0x84, 0x44, 0x01 }, true);
    try std.testing.expectEqual(@as(u64, 2), enc.peerKnownInserts);
    // Split delivery across calls buffers instead of failing:
    // SectionAck for stream 127: 0xFF (multi-byte prefix) split from 0x00
    enc.sectionUsedDynamic = true;
    enc.sectionMinRef = 0;
    try enc.registerSection(127);
    try enc.readDecoderStream(&.{0xFF}, false);
    try enc.readDecoderStream(&.{0x00}, false);
    // Overflowing increment is corruption, not a split: fatal mid-buffer.
    var bad: [16]u8 = undefined;
    const n = try encodeInt(&bad, 6, std.math.maxInt(u64));
    try std.testing.expectError(Error.InvalidInstruction, enc.readDecoderStream(bad[0..n], true));
}

test "qpack ack and cancel instruction bytes" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    var ack = std.ArrayList(u8).empty;
    defer ack.deinit(a);
    try dec.insertCountIncrement(&ack); // nothing new: silent
    try std.testing.expectEqual(@as(usize, 0), ack.items.len);

    var cancel = std.ArrayList(u8).empty;
    defer cancel.deinit(a);
    try dec.cancelSection(&cancel, 4);
    try std.testing.expectEqual(@as(usize, 1), cancel.items.len);
    try std.testing.expectEqual(@as(u8, 0x44), cancel.items[0]);
}

test "qpack field section size limit enforced" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxFieldSectionSize(8);
    var big = std.ArrayList(u8).empty;
    defer big.deinit(a);
    try big.appendSlice(a, &.{ 0x00, 0x00 });
    try big.appendNTimes(a, 0x41, 32);
    try std.testing.expectError(Error.InvalidInstruction, dec.decodeSectionCounted(big.items, 0, null));
}

test "qpack field section limit counts decoded indexed fields" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxFieldSectionSize(100);
    // Three references to static-table :method: GET are only three encoded
    // bytes, but expand to 126 bytes under RFC field-section accounting.
    const section = [_]u8{ 0x00, 0x00, 0xD1, 0xD1, 0xD1 };
    try std.testing.expectError(Error.InvalidInstruction, dec.decodeSectionCounted(&section, 0, null));
}

test "qpack encoder falls back to literal when entries are pinned" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    // Capacity fits exactly one 34-byte entry ("a"/"1").
    enc.setMaxTableCapacity(34);
    enc.beginSection();
    var first = std.ArrayList(u8).empty;
    defer first.deinit(a);
    try enc.encodeField(&first, "a", "1");
    // First insert fits without eviction.
    try std.testing.expectEqual(@as(u64, 1), enc.sectionRic());

    // Second distinct field needs eviction, but abs 0 is pinned by the
    // default barrier: literal fallback, still decodable statically.
    enc.beginSection();
    var second = std.ArrayList(u8).empty;
    defer second.deinit(a);
    try enc.encodeField(&second, "b", "2");
    var dec = Decoder.init(a);
    defer dec.deinit();
    const fields = try dec.decodeSection(second.items);
    defer dec.freeFields(fields);
    try std.testing.expectEqualStrings("b", fields[0].name);

    // Advancing the barrier past abs 0 permits eviction on next insert.
    enc.setEvictBarrier(1);
    const abs = try enc.insertDynamic("c", "3");
    try std.testing.expect(abs != null);
}

test "qpack acknowledgments and cancellation release dynamic references" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(68);

    enc.beginSection();
    var first = std.ArrayList(u8).empty;
    defer first.deinit(a);
    try enc.encodeField(&first, "a", "1");
    try enc.registerSection(0);

    enc.beginSection();
    var second = std.ArrayList(u8).empty;
    defer second.deinit(a);
    try enc.encodeField(&second, "b", "2");
    try enc.registerSection(0);
    try std.testing.expectEqual(@as(u64, 0), enc.evictBarrier);

    // Acknowledging the oldest section unpins entry 0, while the later
    // section continues pinning entry 1.
    try enc.readDecoderStream(&.{0x80}, true);
    try std.testing.expectEqual(@as(u64, 1), enc.evictBarrier);
    try std.testing.expectEqual(@as(u64, 1), enc.peerKnownInserts);
    const third = try enc.insertDynamic("c", "3");
    try std.testing.expect(third != null);

    // Cancellation releases all remaining sections for the stream.
    try enc.readDecoderStream(&.{0x40}, true);
    try std.testing.expectEqual(@as(u64, enc.insertCount()), enc.evictBarrier);
    const fourth = try enc.insertDynamic("d", "4");
    try std.testing.expect(fourth != null);
}

test "qpack encoder respects peer blocked stream limit" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(1024);

    // The default advertised peer limit is zero: use a literal so no new
    // stream can block on an insert the peer has not received.
    enc.beginSectionForStream(8);
    var zeroLimit = std.ArrayList(u8).empty;
    defer zeroLimit.deinit(a);
    try enc.encodeField(&zeroLimit, "x-zero", "blocked");
    try std.testing.expectEqual(@as(u64, 0), enc.sectionRic());

    enc.setMaxBlockedStreams(1);

    enc.beginSectionForStream(0);
    var first = std.ArrayList(u8).empty;
    defer first.deinit(a);
    try enc.encodeField(&first, "x-first", "one");
    try std.testing.expectEqual(@as(u64, 1), enc.sectionRic());
    try enc.registerSection(0);

    // A second stream must not create a second blocked stream while stream
    // zero is waiting for encoder instructions.
    enc.beginSectionForStream(4);
    var second = std.ArrayList(u8).empty;
    defer second.deinit(a);
    try enc.encodeField(&second, "x-second", "two");
    try std.testing.expectEqual(@as(u64, 0), enc.sectionRic());
    try enc.registerSection(4);

    // Another section on the already-blocked stream does not consume a new
    // blocked-stream slot and may continue to reference the dynamic table.
    enc.beginSectionForStream(0);
    var sameStream = std.ArrayList(u8).empty;
    defer sameStream.deinit(a);
    try enc.encodeField(&sameStream, "x-first", "one");
    try std.testing.expectEqual(@as(u64, 1), enc.sectionRic());
    try enc.registerSection(0);

    // An Insert Count Increment confirms the first insertion and frees the
    // blocked slot for a new stream.
    try enc.readDecoderStream(&.{0x01}, true);
    enc.beginSectionForStream(4);
    var afterIncrement = std.ArrayList(u8).empty;
    defer afterIncrement.deinit(a);
    try enc.encodeField(&afterIncrement, "x-second", "two");
    try std.testing.expectEqual(@as(u64, 2), enc.sectionRic());
}

test "qpack encoder prefix encodes nonzero insert counts" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.setMaxTableCapacity(4096);
    _ = try enc.insertDynamic("x-p", "v");
    const ric = enc.insertCount();
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(a);
    try enc.encodePrefix(&prefix, ric, ric);
    try std.testing.expectEqual(@as(usize, 2), prefix.items.len);
    // RIC 1 with 128 max entries: 1 % 256 + 1 = 2.
    try std.testing.expectEqual(@as(u8, 2), prefix.items[0]);
    try std.testing.expectEqual(@as(u8, 0x00), prefix.items[1]);

    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    // Prefix alone (no section body) decodes to zero fields after
    // feeding the encoder bytes the insert produced.
    const encBytes = try enc.takeEncoderBytes();
    defer a.free(encBytes);
    try dec.readEncoderStream(encBytes, true);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(a);
    try body.appendSlice(a, prefix.items);
    try enc.encodeIndexedStatic(&body, 17);
    const fields = try dec.decodeSectionCounted(body.items, 0, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqualStrings(":method", fields[0].name);
}

test "qpack rfc9204 B.1 literal static name reference vector" {
    // RFC 9204 Appendix B.1: prefix RIC=0/Base=0, literal field with
    // static name reference to index 1 (:path) and value /index.html.
    const a = std.testing.allocator;
    const section = "\x00\x00\x51\x0b/index.html";
    var dec = Decoder.init(a);
    defer dec.deinit();
    const fields = try dec.decodeSectionCounted(section, 0, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings(":path", fields[0].name);
    try std.testing.expectEqualStrings("/index.html", fields[0].value);
}

test "qpack rfc9204 B.2 dynamic table and post-base vector" {
    // RFC 9204 Appendix B.2: Set Capacity 220, two inserts with static
    // name references, then a section with RIC=2/Base=0 using indexed
    // post-base references, acknowledged for stream 4.
    const a = std.testing.allocator;
    const encoderStream =
        "\x3f\xbd\x01" ++ // Set Dynamic Table Capacity = 220
        "\xc0\x0fwww.example.com" ++ // Insert, static name 0 (:authority)
        "\xc1\x0c/sample/path"; // Insert, static name 1 (:path)
    var dec = Decoder.init(a);
    defer dec.deinit();
    dec.setMaxTableCapacity(4096);
    try dec.readEncoderStream(encoderStream, true);
    try std.testing.expectEqual(@as(u64, 2), dec.insertCount());

    const section = "\x03\x81\x10\x11"; // RIC=2, Base=0, post-base 0 and 1
    var ack = std.ArrayList(u8).empty;
    defer ack.deinit(a);
    const fields = try dec.decodeSectionCounted(section, 4, &ack);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings(":authority", fields[0].name);
    try std.testing.expectEqualStrings("www.example.com", fields[0].value);
    try std.testing.expectEqualStrings(":path", fields[1].name);
    try std.testing.expectEqualStrings("/sample/path", fields[1].value);
    try std.testing.expectEqual(@as(usize, 1), ack.items.len);
    try std.testing.expectEqual(@as(u8, 0x84), ack.items[0]);
}

test "qpack decoder stream bounded buffer rejection" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    // Feed 65 KiB of incomplete varint bytes (high bit set)
    const big = try a.alloc(u8, Encoder.MAX_DECODER_BUF + 1);
    defer a.free(big);
    @memset(big, 0xBF); // 6-bit prefix with continuation bit
    try std.testing.expectError(Error.InvalidInstruction, enc.readDecoderStream(big, false));
}

test "qpack insert count increment zero is rejected" {
    const a = std.testing.allocator;
    var enc = Encoder.init(a);
    defer enc.deinit();
    // Increment of 0: opcode 0x00
    try std.testing.expectError(Error.InvalidInstruction, enc.readDecoderStream(&.{0x00}, true));
}

test "qpack insert count increment exceeding dynamic insertions is rejected" {
    const a = std.testing.allocator;
    {
        var enc = Encoder.init(a);
        defer enc.deinit();
        enc.setMaxTableCapacity(4096);
        _ = try enc.insertDynamic("x-foo", "bar");
        try std.testing.expectEqual(@as(u64, 1), enc.insertCount());
        // Increment of 2 exceeds current insert count of 1
        try std.testing.expectError(Error.InvalidInstruction, enc.readDecoderStream(&.{0x02}, true));
    }
    {
        var enc = Encoder.init(a);
        defer enc.deinit();
        enc.setMaxTableCapacity(4096);
        _ = try enc.insertDynamic("x-foo", "bar");
        // Valid increment of 1 succeeds
        try enc.readDecoderStream(&.{0x01}, true);
        try std.testing.expectEqual(@as(u64, 1), enc.peerKnownInserts);
        // Further increment of 1 now exceeds (1 - 1 = 0 available)
        try std.testing.expectError(Error.InvalidInstruction, enc.readDecoderStream(&.{0x01}, true));
    }
}

test "qpack decodeSectionInner frees partial allocated fields on error" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    // Section with one valid literal with literal name:
    // 0010 0000 (0x20, raw name len 4): "test"
    // value raw len 5: "value"
    // followed by an invalid continuation byte that causes Truncated error.
    const malformed = "\x20\x04test\x05value\x20\x04abc";
    try std.testing.expectError(Error.InvalidInstruction, dec.decodeSection(malformed));
}
