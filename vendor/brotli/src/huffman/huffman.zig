//! Utilities for building Huffman decoding tables.
//!
//! Implementation note: symbol lists are threaded through explicit
//! head/next chains per code length rather than negative-index tricks.

const std = @import("std");
const constants = @import("../common/constants.zig");

pub const HUFFMAN_MAX_CODE_LENGTH = 15;
/// Decoding table size for a 26-symbol block-length alphabet.
pub const HUFFMAN_MAX_SIZE_26 = 396;
/// Decoding table size for a 258-symbol block-type alphabet.
pub const HUFFMAN_MAX_SIZE_258 = 632;
/// Decoding table size for a 272-symbol context-map alphabet.
pub const HUFFMAN_MAX_SIZE_272 = 646;
pub const HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH = 5;

pub const HUFFMAN_TABLE_BITS = 8;

/// Sentinel meaning "no symbol".
pub const EMPTY_SYMBOL: u16 = 0xFFFF;

/// A Huffman lookup table entry: `bits` is the code length (or sub-table
/// bits when > HUFFMAN_TABLE_BITS) and `value` the symbol or table offset.
pub const HuffmanCode = extern struct {
    bits: u8,
    value: u16,
};

const REVERSE_BITS_MAX = 8;

fn reverseBits8(v: usize) usize {
    return @as(usize, @bitReverse(@as(u8, @truncate(v))));
}

inline fn construct(bits: u8, value: u16) HuffmanCode {
    return .{ .bits = bits, .value = value };
}

/// Stores `code` in table[start], table[start+step], ... up to `end` entries.
inline fn replicate(table: []HuffmanCode, start: usize, step: usize, end: usize, code: HuffmanCode) void {
    var e = end;
    while (e >= step) {
        e -= step;
        table[start + e] = code;
    }
}

/// Returns the table width of the next 2nd level table. `count` is the
/// histogram of bit lengths for the remaining symbols, `len` the code length
/// of the next processed symbol.
fn nextTableBitSize(count: []const u16, len_in: usize, root_bits: usize) usize {
    var len = len_in;
    var left: isize = @as(isize, 1) << @intCast(len - root_bits);
    while (len < HUFFMAN_MAX_CODE_LENGTH) {
        left -= count[len];
        if (left <= 0) break;
        len += 1;
        left <<= 1;
    }
    return len - root_bits;
}

/// Per-length chains of symbols: `heads[l]` is the first symbol with code
/// length `l`, `next_of[symbol]` its successor within the same length class.
pub const SymbolChains = struct {
    // NOTE: intentionally value-only (no back-pointers); the successor-link
    // storage is passed per-call so the struct can live inside a parent that
    // is moved/copied without dangling references.
    heads: [HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(EMPTY_SYMBOL),
    tails: [HUFFMAN_MAX_CODE_LENGTH + 1]u16 = @splat(0),

    pub inline fn append(self: *SymbolChains, next_of: []u16, len: usize, symbol: u16) void {
        if (self.heads[len] == EMPTY_SYMBOL) {
            self.heads[len] = symbol;
        } else {
            next_of[self.tails[len]] = symbol;
        }
        self.tails[len] = symbol;
    }

    /// Largest code length that has at least one symbol (0 when none).
    pub fn maxLength(self: *const SymbolChains) usize {
        var l: usize = HUFFMAN_MAX_CODE_LENGTH;
        while (l >= 1) : (l -= 1) {
            if (self.heads[l] != EMPTY_SYMBOL) return l;
            if (l == 1) break;
        }
        return 0;
    }

    pub fn reset(self: *SymbolChains) void {
        self.heads = @splat(EMPTY_SYMBOL);
        // tails/next_of are only read after being written for lengths that
        // appear in heads, so they do not need clearing.
    }
};

/// Builds the small table used to decode code-length codes (5-bit root).
pub fn buildCodeLengthsHuffmanTable(
    table: []HuffmanCode,
    code_lengths: []const u8,
    count: []const u16,
) void {
    std.debug.assert(table.len >= 32);
    std.debug.assert(code_lengths.len == constants.CODE_LENGTH_CODES);
    var sorted: [constants.CODE_LENGTH_CODES]u16 = undefined;
    var offset: [HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 1]isize = undefined;

    // Generate offsets into the sorted symbol table by code length.
    var symbol: isize = -1;
    var bits: usize = 1;
    inline for (0..HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH) |_| {
        symbol += count[bits];
        offset[bits] = symbol;
        bits += 1;
    }
    // Symbols with code length 0 are placed after all other symbols.
    offset[0] = constants.CODE_LENGTH_CODES - 1;

    // Sort symbols by length, by symbol order within each length.
    symbol = constants.CODE_LENGTH_CODES;
    while (symbol != 0) {
        inline for (0..6) |_| {
            symbol -= 1;
            const idx: usize = @intCast(symbol);
            const cl = code_lengths[idx];
            // Store at the current offset and decrement.
            const dst = offset[cl];
            offset[cl] -= 1;
            sorted[@intCast(dst)] = @intCast(idx);
        }
    }

    const table_size = 1 << HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH;

    // Special case: all symbols but one have 0 code length.
    if (offset[0] == 0) {
        const code = construct(0, sorted[0]);
        @memset(table[0..table_size], code);
        return;
    }

    // Fill in table.
    var key: usize = 0;
    var key_step: usize = 1 << (REVERSE_BITS_MAX - 1);
    var sym: usize = 0;
    bits = 1;
    var step: usize = 2;
    while (bits <= HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH) : (bits += 1) {
        var bits_count = count[bits];
        while (bits_count != 0) : (bits_count -= 1) {
            const code = construct(@intCast(bits), sorted[sym]);
            sym += 1;
            replicate(table, reverseBits8(key), step, table_size, code);
            key += key_step;
        }
        step <<= 1;
        key_step >>= 1;
    }
}

/// Builds an explicit Huffman decoding table. Consumes (decrements) `count`;
/// returns total table entries used.
pub fn buildHuffmanTable(
    root_table: []HuffmanCode,
    root_bits: comptime_int,
    chains: *const SymbolChains,
    count: []u16,
    next_of: []const u16,
) u32 {
    const max_length = chains.maxLength();
    std.debug.assert(root_bits <= REVERSE_BITS_MAX);

    var table_off: usize = 0; // offset of current sub-table within root_table
    var table_bits: usize = root_bits;
    var table_size: usize = @as(usize, 1) << @intCast(table_bits);
    var total_size: usize = table_size;

    // Fill in the root table; reduce its size if possible.
    if (table_bits > max_length) {
        table_bits = max_length;
        table_size = @as(usize, 1) << @intCast(table_bits);
    }
    var key: usize = 0;
    var key_step: usize = 1 << (REVERSE_BITS_MAX - 1);
    var bits: usize = 1;
    var step: usize = 2; // stride for current code length; doubles each level
    while (bits <= table_bits) : (bits += 1) {
        var symbol = chains.heads[bits];
        var bits_count = count[bits];
        while (bits_count != 0) : (bits_count -= 1) {
            const code = construct(@intCast(bits), symbol);
            replicate(root_table, reverseBits8(key), step, table_size, code);
            key += key_step;
            symbol = next_of[symbol];
        }
        step <<= 1;
        key_step >>= 1;
    }

    // Replicate to fill remaining slots of the root table.
    while (total_size != table_size) {
        std.mem.copyForwards(
            HuffmanCode,
            root_table[table_size .. 2 * table_size],
            root_table[0..table_size],
        );
        table_size <<= 1;
    }

    // Fill in 2nd level tables and add pointers to root table.
    key_step = (1 << (REVERSE_BITS_MAX - 1)) >> (root_bits - 1);
    var sub_key: usize = (1 << (REVERSE_BITS_MAX - 1)) << 1;
    var sub_key_step: usize = 1 << (REVERSE_BITS_MAX - 1);
    var len: usize = root_bits + 1;
    var step2: usize = 2;
    while (len <= max_length) : ({
        len += 1;
        step2 <<= 1;
        sub_key_step >>= 1;
    }) {
        var symbol = chains.heads[len];
        while (count[len] != 0) : (count[len] -= 1) {
            if (sub_key == ((1 << (REVERSE_BITS_MAX - 1)) << 1)) {
                table_off += table_size;
                table_bits = nextTableBitSize(count, len, root_bits);
                table_size = @as(usize, 1) << @intCast(table_bits);
                total_size += table_size;
                sub_key = reverseBits8(key);
                key += key_step;
                root_table[sub_key] = construct(
                    @intCast(table_bits + root_bits),
                    @intCast(table_off - sub_key),
                );
                sub_key = 0;
            }
            const code = construct(@intCast(len - root_bits), symbol);
            const off = table_off + reverseBits8(sub_key);
            replicate(root_table, off, step2, table_size, code);
            sub_key += sub_key_step;
            symbol = next_of[symbol];
        }
    }
    return @intCast(total_size);
}

/// Builds a simple Huffman table with 1..4 explicit symbols. `num_symbols`
/// follows the format's encoding: NSYM-1 plus the tree-select bit folded in
/// as value 4. Returns the table size.
pub fn buildSimpleHuffmanTable(
    table: []HuffmanCode,
    root_bits: comptime_int,
    val: *[4]u16,
    num_symbols: u32,
) u32 {
    var table_size: u32 = 1;
    const goal_size: u32 = @as(u32, 1) << @intCast(root_bits);
    switch (num_symbols) {
        0 => {
            table[0] = construct(0, val[0]);
        },
        1 => {
            if (val[1] > val[0]) {
                table[0] = construct(1, val[0]);
                table[1] = construct(1, val[1]);
            } else {
                table[0] = construct(1, val[1]);
                table[1] = construct(1, val[0]);
            }
            table_size = 2;
        },
        2 => {
            table[0] = construct(1, val[0]);
            table[2] = construct(1, val[0]);
            if (val[2] > val[1]) {
                table[1] = construct(2, val[1]);
                table[3] = construct(2, val[2]);
            } else {
                table[1] = construct(2, val[2]);
                table[3] = construct(2, val[1]);
            }
            table_size = 4;
        },
        3 => {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                var k: usize = i + 1;
                while (k < 4) : (k += 1) {
                    if (val[k] < val[i]) {
                        const t = val[k];
                        val[k] = val[i];
                        val[i] = t;
                    }
                }
            }
            table[0] = construct(2, val[0]);
            table[2] = construct(2, val[1]);
            table[1] = construct(2, val[2]);
            table[3] = construct(2, val[3]);
            table_size = 4;
        },
        4 => {
            if (val[3] < val[2]) {
                const t = val[3];
                val[3] = val[2];
                val[2] = t;
            }
            table[0] = construct(1, val[0]);
            table[1] = construct(2, val[1]);
            table[2] = construct(1, val[0]);
            table[3] = construct(3, val[2]);
            table[4] = construct(1, val[0]);
            table[5] = construct(2, val[1]);
            table[6] = construct(1, val[0]);
            table[7] = construct(3, val[3]);
            table_size = 8;
        },
        else => unreachable,
    }
    while (table_size != goal_size) : (table_size <<= 1) {
        std.mem.copyForwards(
            HuffmanCode,
            table[table_size .. table_size * 2],
            table[0..table_size],
        );
    }
    return goal_size;
}

test "simple huffman table single symbol" {
    var table: [256]HuffmanCode = undefined;
    var vals = [4]u16{ 42, 0, 0, 0 };
    const size = buildSimpleHuffmanTable(&table, HUFFMAN_TABLE_BITS, &vals, 0);
    try std.testing.expectEqual(@as(u32, 256), size);
    try std.testing.expectEqual(@as(u8, 0), table[0].bits);
    try std.testing.expectEqual(@as(u16, 42), table[0].value);
    try std.testing.expectEqual(@as(u16, 42), table[255].value);
}

test "simple huffman table two symbols" {
    var table: [256]HuffmanCode = undefined;
    var vals = [4]u16{ 3, 7, 0, 0 };
    _ = buildSimpleHuffmanTable(&table, HUFFMAN_TABLE_BITS, &vals, 1);
    try std.testing.expectEqual(@as(u16, 3), table[0].value);
    try std.testing.expectEqual(@as(u16, 7), table[1].value);
}

test "complex table with explicit chains" {
    // Symbols {0,1,2,3} with lengths {1,2,3,3}: canonical prefix code where
    // bit '0' decodes to symbol 0.
    var table: [HUFFMAN_MAX_SIZE_272]HuffmanCode = undefined;
    var next_buf: [4]u16 = undefined;
    var chains = SymbolChains{};
    chains.append(&next_buf, 1, 0);
    chains.append(&next_buf, 2, 1);
    chains.append(&next_buf, 3, 2);
    chains.append(&next_buf, 3, 3);
    try std.testing.expectEqual(@as(usize, 3), chains.maxLength());
    var count = [_]u16{ 0, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const total = buildHuffmanTable(&table, HUFFMAN_TABLE_BITS, &chains, &count, &next_buf);
    try std.testing.expectEqual(@as(u32, 256), total);
    try std.testing.expectEqual(@as(u16, 0), table[0].value); // bit 0 -> sym 0
    try std.testing.expectEqual(@as(u8, 1), table[0].bits);
}

test "second-level markers satisfy slot-plus-value invariant" {
    // Lengths 1..9 for symbols 0..8 form a complete canonical tree whose
    // longest code (9 bits) must live in a second-level table. Every root
    // marker stores (sub_table_offset - root_slot); the decoder re-adds the
    // slot, so slot + value must land inside the allocated sub-table region.
    var table: [HUFFMAN_MAX_SIZE_272]HuffmanCode = @splat(construct(0, 0));
    var next_buf: [16]u16 = undefined;
    var chains = SymbolChains{};
    var count: [16]u16 = @splat(0);
    var len: usize = 1;
    while (len <= 9) : (len += 1) {
        chains.append(&next_buf, len, @intCast(len - 1));
        count[len] = 1;
    }
    const total = buildHuffmanTable(&table, HUFFMAN_TABLE_BITS, &chains, &count, &next_buf);
    // Root (256) plus one second-level table for the 9-bit code.
    try std.testing.expect(total > 256);
    var markers: usize = 0;
    for (table[0..256], 0..) |entry, slot| {
        if (entry.bits <= HUFFMAN_TABLE_BITS) continue;
        const target = slot + entry.value;
        try std.testing.expect(target >= 256);
        try std.testing.expect(target < total);
        // Entries of this sub-table never exceed the promised total code
        // length; the sub-table spans 1 << (bits - root_bits) slots.
        const sub_size = @as(usize, 1) << @intCast(entry.bits - HUFFMAN_TABLE_BITS);
        for (table[target .. target + sub_size]) |sub| {
            try std.testing.expect(sub.bits <= entry.bits);
        }
        markers += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), markers);
}
