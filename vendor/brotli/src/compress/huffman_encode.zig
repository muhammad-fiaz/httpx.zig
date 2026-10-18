//! Native Huffman tree construction and serialization for the encoder.
//!
//! Produces RFC 7932 section 3.5 trees: simple trees for up to four used
//! symbols, complex code-length-coded trees otherwise. Code lengths are
//! generated from symbol frequencies and limited to fifteen bits.

const std = @import("std");
const prefix = @import("../decompress/prefix.zig");

const bit_writer = @import("../bitstream/bit_writer.zig");

pub const MAX_CODE_LENGTH = 15;

/// LSB-first bit sink over a preallocated buffer.
pub const BitSink = struct {
    buf: []u8,
    pos: usize = 0,

    pub inline fn put(self: *BitSink, n_bits: u6, value: u64) void {
        bit_writer.writeBits(n_bits, value, &self.pos, self.buf);
    }

    pub inline fn putBits(self: *BitSink, n_bits: u5, value: u64) void {
        if (n_bits == 0) return;
        self.put(@intCast(n_bits), value);
    }

    /// Zero-padding to the next byte boundary.
    pub fn alignToByte(self: *BitSink) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }
};

/// Width in bits used to store one raw symbol of an alphabet of size
/// `alphabet_size_max`.
pub fn alphabetBits(alphabet_size_max: u32) u6 {
    if (alphabet_size_max <= 1) return 1;
    return @as(u6, @intCast(std.math.log2_int_ceil(u32, alphabet_size_max)));
}

const EMPTY: u16 = 0xFFFF;
const UNDEF: usize = 0xFFFF_FFFF;
pub const MAX_ALPHABET = 704;

/// Assigns Huffman code lengths (<= max_depth) to nonzero frequencies.
/// `depths` is fully overwritten; zero-frequency symbols get depth 0.
pub fn generateCodeLengths(freqs: []const u32, max_depth: u8, depths: []u8) void {
    const n = freqs.len;
    std.debug.assert(depths.len >= n);
    @memset(depths[0..n], 0);

    var used: usize = 0;
    for (freqs) |f| {
        if (f != 0) used += 1;
    }
    if (used == 0) return;
    if (used == 1) return; // zero-bit code for the lone symbol

    // O(n^2) two-queue Huffman construction; alphabets are tiny (<=704).
    var weight: [2 * MAX_ALPHABET]u64 = undefined;
    var child_l: [2 * MAX_ALPHABET]u16 = undefined;
    var child_r: [2 * MAX_ALPHABET]u16 = undefined;
    var alive: [2 * MAX_ALPHABET]bool = undefined;
    var leaf_of: [MAX_ALPHABET]u16 = undefined;
    var count: usize = 0;
    for (freqs[0..n], 0..) |f, sym| {
        if (f == 0) continue;
        weight[count] = f;
        child_l[count] = EMPTY;
        child_r[count] = EMPTY;
        alive[count] = true;
        leaf_of[sym] = @intCast(count);
        count += 1;
    }

    while (true) {
        var a: usize = UNDEF;
        var b: usize = UNDEF;
        for (0..count) |i| {
            if (!alive[i]) continue;
            if (a == UNDEF or weight[i] < weight[a]) {
                b = a;
                a = i;
            } else if (b == UNDEF or weight[i] < weight[b]) {
                b = i;
            }
        }
        if (b == UNDEF) break; // root remains
        weight[count] = weight[a] + weight[b];
        child_l[count] = @intCast(a);
        child_r[count] = @intCast(b);
        alive[a] = false;
        alive[b] = false;
        alive[count] = true;
        count += 1;
    }

    // Depth of every node via iterative descent from the root.
    var depth_of: [2 * MAX_ALPHABET]u8 = undefined;
    const root = count - 1;
    depth_of[root] = 0;
    var stack: [64]usize = undefined;
    var sp: usize = 0;
    stack[sp] = root;
    sp += 1;
    while (sp != 0) {
        sp -= 1;
        const node = stack[sp];
        const d = depth_of[node];
        if (child_l[node] != EMPTY) {
            depth_of[child_l[node]] = d + 1;
            depth_of[child_r[node]] = d + 1;
            stack[sp] = child_l[node];
            sp += 1;
            stack[sp] = child_r[node];
            sp += 1;
        }
    }
    for (depths[0..n], 0..) |*d, sym| {
        if (freqs[sym] != 0) d.* = depth_of[leaf_of[sym]];
    }

    var deepest: u8 = 0;
    for (depths[0..n]) |d| {
        if (d > deepest) deepest = d;
    }
    if (deepest <= max_depth) return; // already complete within the cap

    // Fallback for skewed distributions: start from the minimal complete
    // uniform tree covering all used symbols, then improve by
    // cost-decreasing exchanges. Every intermediate state keeps the same
    // length multiset, so the result is always a valid complete code.
    exchangeLengths(freqs[0..n], max_depth, depths[0..n]);
}

fn exchangeLengths(freqs: []const u32, max_depth: u8, depths: []u8) void {
    _ = max_depth;
    var order: [MAX_ALPHABET]u16 = undefined;
    var m: usize = 0;
    for (freqs, 0..) |f, s| {
        if (f != 0) {
            order[m] = @intCast(s);
            m += 1;
        }
    }
    const SortCtx = struct {
        freqs: []const u32,
        pub fn lessThan(ctx: @This(), a: u16, b: u16) bool {
            return ctx.freqs[a] > ctx.freqs[b];
        }
    };
    std.mem.sort(u16, order[0..m], SortCtx{ .freqs = freqs }, SortCtx.lessThan);

    const k: u6 = @intCast(std.math.log2_int_ceil(usize, @max(1, m)));
    // k = ceil(log2(m)); complete tree: x leaves at depth k-1, y at depth k.
    const kk: usize = k;
    const x: usize = (@as(usize, 1) << @intCast(kk)) - m;

    for (order[0..m], 0..) |s, i| {
        depths[s] = if (i < x)
            @intCast(kk -| 1)
        else
            @intCast(kk);
    }

    // Swapping lengths between a deeper higher-frequency leaf and a shallower
    // lower-frequency leaf preserves completeness and strictly reduces cost.
    var changed = true;
    while (changed) {
        changed = false;
        for (order[0..m]) |a| {
            for (order[0..m]) |b| {
                const da = depths[a];
                const db = depths[b];
                if (da > db and freqs[a] > freqs[b]) {
                    depths[a] = db;
                    depths[b] = da;
                    changed = true;
                }
            }
        }
    }
}

fn kraftSum(depths: []const u8, max_depth: u8) u64 {
    var sum: u64 = 0;
    for (depths) |d| {
        if (d != 0) sum += @as(u64, 1) << @intCast(max_depth - d);
    }
    return sum;
}

/// Canonical code assignment per RFC 7932 section 3.2, converted to
/// transmission order: the bit sink emits LSB-first while prefix codes are
/// matched most-significant-bit first, so stored codes are bit-reversed.
pub fn assignCanonicalCodes(depths: []const u8, codes: []u16) void {
    var bl_count: [MAX_CODE_LENGTH + 1]u32 = @splat(0);
    for (depths) |d| {
        if (d <= MAX_CODE_LENGTH) {
            bl_count[d] += 1;
        }
    }

    var next: [MAX_CODE_LENGTH + 2]u32 = undefined;
    var code: u32 = 0;
    for (1..MAX_CODE_LENGTH + 1) |l| {
        next[l] = code;
        code = (code + bl_count[l]) << 1;
    }

    for (depths, 0..) |d, sym| {
        if (d == 0) {
            codes[sym] = 0;
        } else {
            const canonical: u16 = @intCast(next[d]);
            codes[sym] = reverseN(canonical, @intCast(d));
            next[d] += 1;
        }
    }
}

/// Reverses the low `n` bits of `v`.
fn reverseN(v: u16, n: u5) u16 {
    if (n == 0) return 0;
    return @bitReverse(v) >> @as(u4, @intCast(16 - @as(u5, n)));
}

fn emitClLength(w: *BitSink, len: u8) void {
    // Fixed variable-length codes for code-length values 0..5 (RFC 3.5).
    switch (len) {
        0 => w.put(2, 0),
        4 => w.put(2, 1),
        3 => w.put(2, 2),
        1 => w.put(4, 7),
        2 => w.put(3, 3),
        5 => w.put(4, 15),
        else => unreachable,
    }
}

/// Serializes one prefix tree into `w`; fills `depths`/`codes` (sized >= limit)
/// for subsequent symbol emission. `cl_depths` must hold >= 18 entries.
pub fn storeHuffmanTree(
    w: *BitSink,
    freqs: []const u32,
    alphabet_size_max: u32,
    alphabet_size_limit: u32,
    depths: []u8,
    codes: []u16,
    cl_depths: []u8,
) void {
    const limit: usize = alphabet_size_limit;
    generateCodeLengths(freqs, MAX_CODE_LENGTH, depths[0..limit]);

    var syms: [MAX_ALPHABET]u16 = undefined;
    var nsyms: usize = 0;
    for (0..limit) |s| {
        if (freqs[s] != 0) {
            syms[nsyms] = @intCast(s);
            nsyms += 1;
        }
    }

    const width = alphabetBits(alphabet_size_max);

    if (nsyms == 0) {
        depths[0] = 0;
        codes[0] = 0;
        w.put(2, 1); // simple marker
        w.put(2, 0); // NSYM-1
        w.putBits(@intCast(width), 0);
        return;
    }

    if (nsyms <= 4) {
        w.put(2, 1); // simple marker
        w.put(2, @intCast(nsyms - 1));
        switch (nsyms) {
            1 => depths[syms[0]] = 0,
            2 => {
                depths[syms[0]] = 1;
                depths[syms[1]] = 1;
            },
            3 => {
                // Matches the decoder's three-symbol layout.
                depths[syms[0]] = 1;
                depths[syms[1]] = 2;
                depths[syms[2]] = 2;
            },
            else => {
                for (syms[0..nsyms]) |s| depths[s] = 2;
            },
        }
        assignCanonicalCodes(depths[0..limit], codes);
        for (syms[0..nsyms]) |s| w.putBits(@intCast(width), s);
        if (nsyms == 4) w.put(1, 0); // tree-select: uniform depths
        return;
    }

    // Complex tree with code-length coding.
    w.put(2, 0); // HSKIP = 0

    var cl_freqs: [18]u32 = @splat(0);
    // Detect the degenerate "every used symbol has the same nonzero depth"
    // case: its CL histogram would contain a single symbol, which the nested
    // tree cannot express. Splitting off one direct emission guarantees at
    // least two distinct CL symbols.
    var min_d: u8 = 255;
    var max_d: u8 = 0;
    for (depths[0..limit]) |d| {
        if (d == 0) continue;
        if (d < min_d) min_d = d;
        if (d > max_d) max_d = d;
    }
    const force_split = min_d != 255 and min_d == max_d;

    // A repeat symbol shortens the code-length stream but adds an entry to the
    // code-length alphabet, which in turn enlarges the nested tree. Which
    // effect wins depends on the shape of this particular tree, so serialize
    // both plans into a scratch sink and keep whichever is actually shorter.
    var scratch: [2048]u8 = @splat(0);
    var best_repeats = false;
    var best_len: usize = std.math.maxInt(usize);

    for ([_]bool{ false, true }) |allow| {
        var probe_freqs: [18]u32 = @splat(0);
        histogramDepths(depths[0..limit], &probe_freqs, force_split, allow);

        // The trial sink starts at zero: only the relative length of this
        // section matters, and seeding it with the caller's absolute position
        // would index far outside the scratch buffer.
        var trial: BitSink = .{ .buf = &scratch };
        var probe_depths: [18]u8 = undefined;
        emitClSection(&trial, depths[0..limit], &probe_freqs, force_split, allow, &probe_depths);

        const len = trial.pos;
        if (len < best_len) {
            best_len = len;
            best_repeats = allow;
        }
    }

    // Re-plan with the winner so the emitted bits and the tables agree.
    @memset(&cl_freqs, 0);
    histogramDepths(depths[0..limit], &cl_freqs, force_split, best_repeats);

    // Fill the caller-visible code tables for later symbol emission.
    assignCanonicalCodes(depths[0..limit], codes);

    emitClSection(w, depths[0..limit], &cl_freqs, force_split, best_repeats, cl_depths);
}

/// Emits the nested code-length tree description followed by the code-length
/// stream itself.
///
/// Handles the degenerate case where the code-length alphabet ends up with a
/// single distinct symbol: the nested table is then written with a single
/// zero-width entry, so every code-length symbol is emitted for free and no
/// repeat symbol may be used.
fn emitClSection(
    w: *BitSink,
    depths: []const u8,
    cl_freqs: *const [18]u32,
    force_split: bool,
    allow_repeats: bool,
    cl_depths: []u8,
) void {
    var used_cl: usize = 0;
    var only_sym: u8 = 0;
    for (cl_freqs, 0..) |f, sym| {
        if (f != 0) {
            used_cl += 1;
            only_sym = @intCast(sym);
        }
    }

    if (used_cl <= 1) {
        @memset(cl_depths[0..18], 0);
        cl_depths[only_sym] = 1;
        var idx: usize = 0;
        var spc: u32 = 32;
        while (idx < 18) : (idx += 1) {
            const sym2 = prefix.code_length_prefix_order[idx];
            emitClLength(w, cl_depths[sym2]);
            if (cl_depths[sym2] != 0) {
                spc = spc -% (@as(u32, 32) >> @intCast(cl_depths[sym2]));
                if (spc == 0 or spc > 32) break;
            }
        }
        const z_depths: [18]u8 = @splat(0);
        const z_codes: [18]u16 = @splat(0);
        const zctx = ClContext{ .codes = z_codes, .depths = z_depths };
        emitDepthSymbols(w, depths, &zctx, false, false);
        return;
    }

    generateCodeLengths(cl_freqs, 5, cl_depths[0..18]);
    var cl_codes: [18]u16 = undefined;
    assignCanonicalCodes(cl_depths[0..18], &cl_codes);

    var spc: u32 = 32;
    var idx: usize = 0;
    while (idx < 18) : (idx += 1) {
        const sym2 = prefix.code_length_prefix_order[idx];
        emitClLength(w, cl_depths[sym2]);
        if (cl_depths[sym2] != 0) {
            spc = spc -% (@as(u32, 32) >> @intCast(cl_depths[sym2]));
            if (spc == 0 or spc > 32) break;
        }
    }

    const ctx = ClContext{ .codes = cl_codes, .depths = cl_depths[0..18].* };
    emitDepthSymbols(w, depths, &ctx, force_split, allow_repeats);
}

/// One code-length-alphabet emission: a symbol plus optional extra bits.
pub const ClItem = struct {
    sym: u8,
    nbits: u4 = 0,
    nval: u8 = 0,
};

const MAX_CL_ITEMS: usize = 1024;

/// Plans the code-length-alphabet stream for one tree.
///
/// The plan is the single source of truth for both the CL histogram and the
/// emitted bits, so the two can never drift apart. It stops exactly when the
/// Kraft space saturates, which is the same point the decoder stops.
///
/// Runs of equal code lengths are run-length encoded with the format's repeat
/// symbols. The first entry of a run is always written literally, which
/// establishes the "previous non-zero length"; symbol 16 then covers 3 to 6
/// further copies and symbol 17 covers 3 to 10 further zeroes, with two and
/// three extra bits respectively. Only the first of a run is charged to the
/// space budget directly, the rest are charged through the repeat.
///
/// `allow_repeats` must be false for the degenerate all-one-symbol case, where
/// the CL table is emitted with zero width and every symbol would be free.
fn planCodeLengths(
    depths: []const u8,
    force_split: bool,
    allow_repeats: bool,
    out: *[MAX_CL_ITEMS]ClItem,
) usize {
    var count: usize = 0;
    var space: u32 = 1 << MAX_CODE_LENGTH;
    var start: usize = 0;

    if (force_split and depths.len != 0 and depths[0] != 0) {
        out[count] = .{ .sym = depths[0] };
        count += 1;
        space -%= @as(u32, 1) << @intCast(MAX_CODE_LENGTH - depths[0]);
        start = 1;
    }

    var i = start;
    while (i < depths.len and space != 0) {
        const d = depths[i];

        var run_end = i + 1;
        if (allow_repeats) {
            while (run_end < depths.len and depths[run_end] == d) run_end += 1;
        }
        // Copies beyond the first that a single repeat symbol can cover.
        const more = run_end - (i + 1);
        const can_repeat = more >= 3 and
            (if (d == 0) more <= 10 else more <= 6);

        out[count] = .{ .sym = d };
        count += 1;
        if (d != 0) space -%= @as(u32, 1) << @intCast(MAX_CODE_LENGTH - d);

        // A repeat may only follow when space budget remains.
        if (can_repeat and space != 0) {
            if (d == 0) {
                out[count] = .{ .sym = 17, .nbits = 3, .nval = @intCast(more - 3) };
                count += 1;
                i += 1 + more;
            } else {
                out[count] = .{ .sym = 16, .nbits = 2, .nval = @intCast(more - 3) };
                count += 1;
                space -%= @as(u32, @intCast(more)) << @intCast(MAX_CODE_LENGTH - d);
                i += 1 + more;
            }
        } else {
            i += 1;
        }
    }
    return count;
}

fn histogramDepths(depths: []const u8, cl_freqs: *[18]u32, force_split: bool, allow_repeats: bool) void {
    var items: [MAX_CL_ITEMS]ClItem = undefined;
    const n = planCodeLengths(depths, force_split, allow_repeats, &items);
    for (items[0..n]) |it| cl_freqs[it.sym] += 1;
}

fn emitClSymbol(w: *BitSink, sym: u8, ctx: *const ClContext) void {
    const d = ctx.depths[sym];
    if (d != 0) w.putBits(@intCast(d), ctx.codes[sym]);
}

pub const ClContext = struct {
    codes: [18]u16,
    depths: [18]u8,
};

/// Writes the planned code-length-alphabet stream.
fn emitDepthSymbols(
    w: *BitSink,
    depths: []const u8,
    ctx: *const ClContext,
    force_split: bool,
    allow_repeats: bool,
) void {
    var items: [MAX_CL_ITEMS]ClItem = undefined;
    const n = planCodeLengths(depths, force_split, allow_repeats, &items);
    for (items[0..n]) |it| {
        emitClSymbol(w, it.sym, ctx);
        // Repeat symbols carry their count in trailing extra bits.
        if (it.nbits != 0) w.putBits(it.nbits, it.nval);
    }
}

/// Adjusts histogram frequencies to improve RLE compression of Huffman code lengths.
pub fn optimizeHuffmanCountsForRle(counts: []u32) void {
    var length = counts.len;
    var nonzero_count: usize = 0;
    for (counts[0..length]) |c| {
        if (c != 0) nonzero_count += 1;
    }
    if (nonzero_count < 16) return;

    while (length != 0 and counts[length - 1] == 0) {
        length -= 1;
    }
    if (length == 0) return;

    {
        var nonzeros: usize = 0;
        var smallest_nonzero: u32 = 1 << 30;
        for (counts[0..length]) |c| {
            if (c != 0) {
                nonzeros += 1;
                if (smallest_nonzero > c) smallest_nonzero = c;
            }
        }
        if (nonzeros < 5) return;
        if (smallest_nonzero < 4) {
            const zeros = length - nonzeros;
            if (zeros < 6) {
                var i: usize = 1;
                while (i + 1 < length) : (i += 1) {
                    if (counts[i - 1] != 0 and counts[i] == 0 and counts[i + 1] != 0) {
                        counts[i] = 1;
                    }
                }
            }
        }
        if (nonzeros < 28) return;
    }

    if (length > MAX_ALPHABET) return;
    var good_for_rle: [MAX_ALPHABET]u8 = @splat(0);
    {
        var symbol: u32 = counts[0];
        var step: usize = 0;
        for (0..length + 1) |i| {
            if (i == length or counts[i] != symbol) {
                if ((symbol == 0 and step >= 5) or (symbol != 0 and step >= 7)) {
                    for (0..step) |k| {
                        good_for_rle[i - k - 1] = 1;
                    }
                }
                step = 1;
                if (i != length) {
                    symbol = counts[i];
                }
            } else {
                step += 1;
            }
        }
    }

    const streak_limit: usize = 1240;
    var stride: usize = 0;
    var limit: usize = (256 * (@as(usize, counts[0]) + counts[1] + counts[2])) / 3 + 420;
    var sum: usize = 0;
    for (0..length + 1) |i| {
        var break_stride = false;
        if (i == length or good_for_rle[i] != 0 or (i != 0 and good_for_rle[i - 1] != 0)) {
            break_stride = true;
        } else {
            const val: i64 = @as(i64, @intCast(counts[i])) * 256 - @as(i64, @intCast(limit));
            if (val + @as(i64, streak_limit) < 0 or val + @as(i64, streak_limit) >= @as(i64, 2 * streak_limit)) {
                break_stride = true;
            }
        }

        if (break_stride) {
            if (stride >= 4 or (stride >= 3 and sum == 0)) {
                var count: usize = (sum + stride / 2) / stride;
                if (count == 0) count = 1;
                if (sum == 0) count = 0;
                for (0..stride) |k| {
                    counts[i - k - 1] = @intCast(count);
                }
            }
            stride = 0;
            sum = 0;
            if (i + 2 < length) {
                limit = (256 * (@as(usize, counts[i]) + counts[i + 1] + counts[i + 2])) / 3 + 420;
            } else if (i < length) {
                limit = 256 * counts[i];
            } else {
                limit = 0;
            }
        }
        stride += 1;
        if (i != length) {
            sum += counts[i];
            if (stride >= 4) {
                limit = (256 * sum + stride / 2) / stride;
            }
            if (stride == 4) {
                limit += 120;
            }
        }
    }
}

test "optimizeHuffmanCountsForRle handles sparse and dense counts safely" {
    var sparse: [256]u32 = @splat(0);
    sparse[10] = 5;
    sparse[20] = 8;
    optimizeHuffmanCountsForRle(&sparse);
    try std.testing.expectEqual(@as(u32, 5), sparse[10]);
    try std.testing.expectEqual(@as(u32, 8), sparse[20]);

    var dense: [256]u32 = @splat(0);
    for (0..60) |i| {
        dense[i] = @intCast(10 + (i % 3));
    }
    optimizeHuffmanCountsForRle(&dense);
    // Nonzero count should remain intact or smoothed
    var nz: usize = 0;
    for (dense) |c| if (c != 0) {
        nz += 1;
    };
    try std.testing.expect(nz >= 50);
}

test "code-length plan covers every entry until the Kraft space saturates" {
    // A complete uniform tree: every symbol is described exactly once.
    var depths: [256]u8 = @splat(8);
    var items: [MAX_CL_ITEMS]ClItem = undefined;
    const n = planCodeLengths(&depths, false, false, &items);
    try std.testing.expectEqual(@as(usize, 256), n);
    for (items[0..n]) |it| try std.testing.expectEqual(@as(u8, 8), it.sym);

    // A tree that saturates early only describes its leading symbols.
    var early: [256]u8 = undefined;
    for (&early, 0..) |*d, i| d.* = if (i % 2 == 0) 1 else 0;
    const m = planCodeLengths(&early, false, false, &items);
    try std.testing.expectEqual(@as(usize, 3), m);
}

test "code-length plan histogram matches the emitted symbols" {
    // The histogram and the bit stream are produced from one plan, so they
    // cannot drift apart.
    var depths: [704]u8 = @splat(0);
    var k: usize = 0;
    while (k < 704) : (k += 1) {
        if (k % 97 == 0) depths[k] = 4;
    }
    depths[0] = 6;

    var items: [MAX_CL_ITEMS]ClItem = undefined;
    const n = planCodeLengths(&depths, false, false, &items);

    var counted: [18]u32 = @splat(0);
    for (items[0..n]) |it| counted[it.sym] += 1;

    var viaHistogram: [18]u32 = @splat(0);
    histogramDepths(&depths, &viaHistogram, false, false);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&counted), std.mem.asBytes(&viaHistogram));

    // Every symbol the plan references must be representable.
    for (items[0..n]) |it| try std.testing.expect(it.sym < 18);
}

test "code-length plan stops before overrunning the alphabet" {
    var depths: [64]u8 = @splat(0);
    for (0..64) |i| depths[i] = if (i % 3 == 0) 2 else 0;
    var items: [MAX_CL_ITEMS]ClItem = undefined;
    const n = planCodeLengths(&depths, false, false, &items);
    try std.testing.expect(n <= depths.len);
}

test "code-length plan emits repeat symbols for long runs" {
    var items: [MAX_CL_ITEMS]ClItem = undefined;

    // A run of equal non-zero lengths that fits symbol 16's count of 3 to 6.
    var nonzero: [256]u8 = @splat(0);
    nonzero[0] = 2;
    for (1..6) |i| nonzero[i] = 2;
    const n16 = planCodeLengths(&nonzero, false, true, &items);
    var saw16 = false;
    for (items[0..n16]) |it| if (it.sym == 16) {
        saw16 = true;
        try std.testing.expect(it.nbits == 2);
        // Symbol 16 carries a count of 3..6 further copies.
        try std.testing.expect(it.nval >= 0 and it.nval <= 3);
    };
    try std.testing.expect(saw16);

    // A run of zeroes that fits symbol 17's count of 3 to 10.
    var zeros: [256]u8 = @splat(0);
    zeros[0] = 3;
    for (1..8) |i| zeros[i] = 0;
    const n17 = planCodeLengths(&zeros, false, true, &items);
    var saw17 = false;
    for (items[0..n17]) |it| if (it.sym == 17) {
        saw17 = true;
        try std.testing.expect(it.nbits == 3);
        // Symbol 17 carries a count of 3..10 further zeroes.
        try std.testing.expect(it.nval <= 7);
    };
    try std.testing.expect(saw17);
}

test "code-length plan emits only applicable repeats" {
    var items: [MAX_CL_ITEMS]ClItem = undefined;
    var depths: [256]u8 = @splat(0);

    // Mixed runs, including a run that starts immediately after a zero run.
    depths[0] = 0;
    depths[1] = 5;
    for (2..8) |i| depths[i] = 5;
    for (8..18) |i| depths[i] = 0;
    for (18..24) |i| depths[i] = 7;
    depths[24] = 3;

    const n = planCodeLengths(&depths, false, true, &items);

    // Symbol 16 may only follow a literal non-zero length; replay the plan
    // in decode order and confirm every repeat resolves.
    var prev_non_zero: ?u8 = null;
    var expect_prev: ?u8 = null;
    for (items[0..n]) |it| {
        switch (it.sym) {
            0 => prev_non_zero = null,
            16 => {
                const p = prev_non_zero orelse return error.BadPlan;
                if (expect_prev) |e| try std.testing.expectEqual(e, p);
                expect_prev = p;
            },
            17 => expect_prev = null,
            else => {
                prev_non_zero = it.sym;
                expect_prev = null;
            },
        }
        try std.testing.expect(it.sym < 18);
    }
}

test "repeats are only planned when they fit the format's count limits" {
    var items: [MAX_CL_ITEMS]ClItem = undefined;

    // Two equal lengths cannot be a repeat; three copies is the minimum.
    var short_run: [256]u8 = @splat(0);
    short_run[0] = 4;
    short_run[1] = 4;
    const n = planCodeLengths(&short_run, false, true, &items);
    for (items[0..n]) |it| try std.testing.expect(it.sym != 16);

    // A zero-length run uses 17, which can express at most ten more zeroes.
    var zeros: [256]u8 = @splat(0);
    zeros[0] = 2;
    for (1..12) |i| zeros[i] = 0;
    const m = planCodeLengths(&zeros, false, true, &items);
    for (items[0..m]) |it| {
        if (it.sym != 17) continue;
        try std.testing.expectEqual(@as(u4, 3), it.nbits);
        try std.testing.expect(it.nval <= 7);
    }
}
