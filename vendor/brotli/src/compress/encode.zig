//! Native Brotli encoder state machine.
//!
//! One-shot and streaming compression producing RFC 7932 streams: window
//! header, compressed metablocks (three single-tree prefix codes, LZ77
//! backward references with recent-distance shortcuts) and stored metablocks
//! for incompressible regions.
const std = @import("std");
const huff_enc = @import("huffman_encode.zig");
const lz77 = @import("lz77.zig");
const prefix = @import("../decompress/prefix.zig");
const constants = @import("../common/constants.zig");
const context = @import("../common/context.zig");
const dictionary = @import("../dictionary/dictionary.zig");
const static_dict = @import("static_dict.zig");
const prefix_ranges = @import("../common/prefix_ranges.zig");
const shared_dict = @import("../common/shared_dictionary.zig");
const utf8_util = @import("utf8_util.zig");
pub const compress_fragment = @import("compress_fragment.zig");
pub const compress_fragment_two_pass = @import("compress_fragment_two_pass.zig");
pub const metablock_fast = @import("metablock_fast.zig");
pub const metablock = @import("metablock.zig");
pub const hlmq = @import("hash_longest_match_quickly.zig");
pub const backward_references = @import("backward_references.zig");
pub const hlms = @import("hash_longest_match_simd.zig");
pub const hlm = @import("hash_longest_match.zig");
pub const h2bt = @import("hash_to_binary_tree.zig");
pub const backward_references_hq = @import("backward_references_hq.zig");
pub const metablock_hq = @import("metablock_hq.zig");

fn getHashTableSizeQ0(input_size: usize) usize {
    const max_table_size: usize = 1 << 15;
    var htsize: usize = 256;
    while (htsize < max_table_size and htsize < input_size) {
        htsize <<= 1;
    }
    if ((htsize & 0xAAAAA) == 0) {
        htsize <<= 1;
    }
    return htsize;
}

fn getHashTableSizeQ1(input_size: usize) usize {
    const max_table_size: usize = 1 << 17;
    var htsize: usize = 256;
    while (htsize < max_table_size and htsize < input_size) {
        htsize <<= 1;
    }
    return htsize;
}

pub const SharedDictionary = shared_dict.SharedDictionary;
pub const SharedDictionaryType = shared_dict.SharedDictionaryType;
pub const Mode = enum(u3) {
    generic = 0,
    text = 1,
    font = 2,
    pub fn fromInt(v: u32) Mode {
        return switch (v & 3) {
            1 => .text,
            2 => .font,
            else => .generic,
        };
    }
};
pub const Operation = enum(u8) {
    process = 0,
    flush = 1,
    finish = 2,
    /// The input slice carries a metadata payload (see RFC 7932 section 9.2).
    emit_metadata = 3,
};
/// Optional progress observer fired while large inputs are compressed.
pub const ProgressCallback = *const fn (
    ctx: ?*anyopaque,
    bytes_done: usize,
    bytes_total: usize,
) void;
pub const Options = struct {
    quality: u32 = 11,
    lgWin: u32 = 22,
    mode: Mode = .generic,
    lgBlock: u32 = 0,
    disableLiteralContextModeling: bool = false,
    sizeHint: usize = 0,
    largeWindow: bool = false,
    nPostfix: u32 = 0,
    nDirect: u32 = 0,
    customDictionary: ?[]const u8 = null,
    sharedDictionary: ?*const shared_dict.SharedDictionary = null,
    progress: ?ProgressCallback = null,
    progressCtx: ?*anyopaque = null,
};
/// Parameter identifiers for encoder configuration.
pub const paramMode: u32 = 0;
pub const paramQuality: u32 = 1;
pub const paramLgWin: u32 = 2;
pub const paramLgBlock: u32 = 3;
pub const paramDisableLiteralContextModeling: u32 = 4;
pub const paramSizeHint: u32 = 5;
pub const paramLargeWindow: u32 = 6;
pub const paramNPostfix: u32 = 7;
pub const paramNDirect: u32 = 8;
const MAX_MLEN = 1 << 24;
const WINDOW_GAP = 16;
const MIN_WINDOW = 10;
const MAX_WINDOW = 24;
const LARGE_MAX_WINDOW = constants.LARGE_MAX_WBITS;
/// Widest possible distance alphabet across every supported configuration.
const DIST_ALPHABET_MAX = 544;
fn effectiveWindow(opts: Options) u32 {
    var w = opts.lgWin;
    if (opts.quality <= 1 and w < 18) w = 18;
    if (w < MIN_WINDOW) w = MIN_WINDOW;
    const cap: u32 = if (opts.largeWindow) LARGE_MAX_WINDOW else MAX_WINDOW;
    if (w > cap) w = cap;
    return w;
}
/// Normalizes nPostfix/nDirect the way the format requires: the four-bit
/// header field carries nDirect >> nPostfix, so nDirect stays within
/// 15 << nPostfix and is a multiple of the postfix multiplier.
fn sanitizeDistanceParams(opts: *Options) void {
    if (opts.nPostfix > constants.MAX_NPOSTFIX) opts.nPostfix = constants.MAX_NPOSTFIX;
    const mult = @as(u32, 1) << @intCast(opts.nPostfix);
    const max_nd = @as(u32, 15) * mult;
    var nd = opts.nDirect;
    if (nd > max_nd) nd = max_nd;
    nd -= nd % mult;
    opts.nDirect = nd;
}
const quality_params_table = [12]lz77.Params{
    .{ .max_chain = 1, .lazy = false, .probe_budget = 0, .num_cache_check = 0 },
    .{ .max_chain = 2, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 4, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 8, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 16, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 32, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 64, .lazy = true, .probe_budget = 0, .num_cache_check = 4 },
    .{ .max_chain = 128, .lazy = true, .probe_budget = 0, .num_cache_check = 10 },
    .{ .max_chain = 256, .lazy = true, .probe_budget = 0, .num_cache_check = 10 },
    .{ .max_chain = 512, .lazy = true, .probe_budget = 0, .num_cache_check = 16 },
    .{ .max_chain = 1024, .lazy = true, .probe_budget = 32, .num_cache_check = 16 },
    .{ .max_chain = 1024, .lazy = true, .probe_budget = 64, .num_cache_check = 16 },
};

inline fn qualityParams(q: u32) lz77.Params {
    return quality_params_table[@min(q, 11)];
}

const kInsEb = prefix_ranges.kInsertLengthExtraBits;
const kCopyEb = prefix_ranges.kCopyLengthExtraBits;
const ins_off = prefix_ranges.insert_length_offsets;
const copy_off = prefix_ranges.copy_length_offsets;
const codeFor = prefix_ranges.codeFor;

fn findCode(off: *const [24]u32, target: u32) u8 {
    for (off, 0..) |o, i| {
        if (o == target) return @intCast(i);
    }
    unreachable;
}
const CmdMaps = struct {
    explicit_sym: [24][24]u16,
    implicit_sym: [24][24]u16,
    fn init() CmdMaps {
        @setEvalBranchQuota(400000);
        var m: CmdMaps = undefined;
        for (&m.explicit_sym) |*row| @memset(row, 0xFFFF);
        for (&m.implicit_sym) |*row| @memset(row, 0xFFFF);
        for (prefix.cmd_lut, 0..) |e, sym| {
            const ic = findCode(&ins_off, e.insert_len_offset);
            const jc = findCode(&copy_off, e.copy_len_offset);
            if (e.distance_code < 0) {
                m.explicit_sym[ic][jc] = @intCast(sym);
            } else {
                m.implicit_sym[ic][jc] = @intCast(sym);
            }
        }
        return m;
    }
};
const cmd_maps = CmdMaps.init();
/// Encodes a copy distance into a distance symbol plus extra bits.
/// `d` is the raw distance (1-based); returns null when it exceeds the
/// representable range for the active configuration.
fn encodeCopyDistance(
    d: u32,
    ndirect: u32,
    npostfix: u32,
) ?struct { sym: u32, extra: u32, nbits: u5 } {
    if (d == 0) return null;
    const dc = d + constants.NUM_DISTANCE_SHORT_CODES - 1;
    if (dc < constants.NUM_DISTANCE_SHORT_CODES + ndirect) {
        return .{ .sym = dc, .extra = 0, .nbits = 0 };
    }
    const postfix = @as(u32, 1) << @intCast(npostfix);
    const postfix_mask = postfix - 1;
    const dist = (@as(u32, 1) << @intCast(npostfix + 2)) +
        (dc - constants.NUM_DISTANCE_SHORT_CODES - ndirect);
    const bl: u6 = @intCast(std.math.log2_int(u32, dist));
    if (bl == 0) return null;
    const b: u32 = bl - 1;
    if (b < npostfix) return null;
    const pv = dist & postfix_mask;
    const prefix_bit = (dist >> @intCast(b)) & 1;
    const offset = (@as(u32, 2) + prefix_bit) << @intCast(b);
    const nb = b - npostfix;
    const sym = constants.NUM_DISTANCE_SHORT_CODES + ndirect +
        (((2 * (nb - 1) + prefix_bit)) << @intCast(npostfix)) + pv;
    return .{
        .sym = sym,
        .extra = (dist -% offset) >> @intCast(npostfix),
        .nbits = @intCast(nb),
    };
}
/// Extra-bit count for the most recent distance encoding decision.
fn dc_dist_bits(dist: u32) u5 {
    if (dist <= 4) return 0;
    return @intCast(std.math.log2_int(u32, dist) - 2);
}
const PlanKind = enum { literals_only, implicit_last, explicit_dist };

/// Exact equality of two command sequences, used to detect a parse fixed
/// point so the refinement loop can stop without another full pass.
fn commandsEqual(a: []const lz77.Command, b: []const lz77.Command) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.insert_len != y.insert_len or x.copy_len != y.copy_len) return false;
        if (x.dist != y.dist) return false;
        const xd = x.dict;
        const yd = y.dict;
        if ((xd == null) != (yd == null)) return false;
        if (xd) |dx| {
            const dy = yd.?;
            if (dx.len_code != dy.len_code or
                dx.word_idx != dy.word_idx or
                dx.transform_idx != dy.transform_idx) return false;
        }
    }
    return true;
}
const PlannedCommand = struct {
    sym: u16,
    insert_len: u32,
    /// Actual output bytes produced by the copy (transformed length for
    /// dictionary references).
    copy_len: u32,
    /// Base length carried in the stream's copy-length code; equals
    /// `copy_len` except for dictionary references.
    copy_code_len: u32,
    ins_extra: u32,
    ins_nbits: u5,
    copy_extra: u32,
    copy_nbits: u5,
    kind: PlanKind,
    dist_code: u16 = 0,
    dist_extra: u32 = 0,
    dist_nbits: u5 = 0,
};
/// Maximum literal trees the context-modeling clusterer will emit.
const MAX_LIT_TREES = 64;
/// Maximum distinct literal block types the splitter may emit.
const MAX_LIT_BLOCK_TYPES = 8;
/// Maximum distinct command block types the splitter may emit.
const MAX_CMD_BLOCK_TYPES = 32;
/// Maximum distinct distance block types the splitter may emit.
const MAX_DIST_BLOCK_TYPES = 16;
/// Maximum switch runs one metablock may emit per category. Runs may revisit
/// types, so this is independent of the distinct-type caps below.
const MAX_SWITCH_RUNS = 256;
/// Widest block-type count any switch table must hold (switch codes reach
/// type id + 2, so this covers the command-type cap with margin).
const MAX_SWITCH_TYPES = 64;
/// Merge threshold in payload-gain bits: two clusters merge while combining
/// them loses no more than this (the lost payload is covered by the saved
/// Huffman tree + map overhead, roughly a few hundred bits). Negative because
/// payload gain is measured as separate-minus-combined (positive when merging
/// saves payload outright); pairs with mildly negative gain still merge when
/// the saved tree overhead outweighs the payload loss.
const CLUSTER_MIN_SAVING = -300.0;
/// Literal-context plan for one metablock.
const CtxPlan = struct {
    mode: context.ContextType,
    /// Tree assignment per context id (classic path), or per (block type,
    /// context) pair in row-major order when `lit_ntypes > 1` (combined
    /// block-type/context path; sized for the streaming cap).
    cmap: [MAX_LIT_STREAM_TYPES * 64]u8 = @splat(0),
    ntrees: u32 = 1,
    /// Literal block types sharing this map (1 = context-only classic path).
    lit_ntypes: u32 = 1,
};
/// A contiguous run of literals within the metablock output.
pub const LitRun = struct { off: u32, len: u32 };
/// Block-length prefix code lookup over the format's range table.
fn blockLengthPrefixCode(len: u32) u8 {
    return prefix_ranges.findPrefixCode(len);
}
/// Block-type switch code calculator mirroring the format's ring of the two
/// most recent block types.
const SwitchCalc = struct { last: u32 = 1, second: u32 = 0 };
fn nextBlockTypeCode(calc: *SwitchCalc, t: u32) u16 {
    const code: u16 = if (t == calc.last + 1)
        1
    else if (t == calc.second) 0 else @intCast(t + 2);
    calc.second = calc.last;
    calc.last = t;
    return code;
}
/// Everything needed to emit one category's block-switch machinery.
pub const SwitchTables = struct {
    /// Number of runs (switch points). Runs may revisit a type, so this can
    /// exceed `ndistinct`.
    ntypes: u32,
    /// Number of distinct block types. Headers, trees, and context maps use
    /// this; the switch sequence uses the runs.
    ndistinct: u32 = 0,
    /// Borrowed per-symbol type ids.
    types_blk: []const u8,
    /// Distinct-type run lengths, ordered.
    types: [MAX_SWITCH_RUNS]u8 = undefined,
    seg_lens: [MAX_SWITCH_RUNS]u32 = undefined,
    seg_idx: usize = 1,
    type_freq: [MAX_SWITCH_TYPES + 2]u32 = @splat(0),
    len_freq: [constants.NUM_BLOCK_LEN_SYMBOLS]u32 = @splat(0),
    type_depths: [MAX_SWITCH_TYPES + 2]u8 = undefined,
    type_codes: [MAX_SWITCH_TYPES + 2]u16 = undefined,
    len_depths: [constants.NUM_BLOCK_LEN_SYMBOLS]u8 = undefined,
    len_codes: [constants.NUM_BLOCK_LEN_SYMBOLS]u16 = undefined,
    pub fn finishTables(self: *SwitchTables) void {
        var calc = SwitchCalc{};
        var i: usize = 0;
        while (i < self.ntypes) : (i += 1) {
            const tc = nextBlockTypeCode(&calc, self.types[i]);
            if (i != 0) self.type_freq[tc] += 1;
            self.len_freq[blockLengthPrefixCode(self.seg_lens[i])] += 1;
        }
        huff_enc.generateCodeLengths(&self.type_freq, huff_enc.MAX_CODE_LENGTH, &self.type_depths);
        huff_enc.assignCanonicalCodes(&self.type_depths, &self.type_codes);
        huff_enc.generateCodeLengths(&self.len_freq, huff_enc.MAX_CODE_LENGTH, &self.len_depths);
        huff_enc.assignCanonicalCodes(&self.len_depths, &self.len_codes);
    }
};
/// Plans a literal-block segmentation over the literal stream in `runs`.
/// Tries even splits, keeps the cheapest by entropy plus switch overhead,
/// then merges similar neighbours. Returns the segment count.
fn planLiteralSegments(
    data: []const u8,
    runs: []const LitRun,
    seg_of: []u8,
) u32 {
    const total: usize = seg_of.len;
    if (total < 1024) {
        @memset(seg_of, 0);
        return 1;
    }
    var best_k: u32 = 1;
    var best_cost: f64 = blk: {
        var all: [256]u32 = @splat(0);
        for (runs) |r| {
            for (data[r.off..][0..r.len]) |b| all[b] += 1;
        }
        break :blk histEntropy(&all);
    };
    const candidates = [_]u32{ 2, 4, 8 };
    for (candidates) |k| {
        var hists: [MAX_LIT_BLOCK_TYPES][256]u32 = @splat(@splat(0));
        var counts: [MAX_LIT_BLOCK_TYPES]usize = @splat(0);
        const per: usize = total / k;
        var li: usize = 0;
        for (runs) |r| {
            for (data[r.off..][0..r.len]) |b| {
                const s = @min(k - 1, @as(u32, @intCast(li / per)));
                hists[s][b] += 1;
                counts[s] += 1;
                li += 1;
            }
        }
        // Total-bit costs on both sides of the comparison.

        var cost: f64 = @as(f64, @floatFromInt(k - 1)) * 16.0 +
            @as(f64, @floatFromInt(k)) * 60.0;
        for (hists[0..k]) |*h| cost += histEntropy(h);
        if (cost + 400.0 < best_cost) {
            best_cost = cost;
            best_k = k;
        }
    }
    if (best_k == 1) {
        @memset(seg_of, 0);
        return 1;
    }
    const per: usize = total / best_k;
    var li: usize = 0;
    for (runs) |r| {
        for (data[r.off..][0..r.len]) |_| {
            seg_of[li] = @intCast(@min(best_k - 1, li / per));
            li += 1;
        }
    }
    // Greedy adjacent merge of statistically similar neighbours.

    var merged: u32 = best_k;
    var s: u32 = 0;
    while (s + 1 < merged) {
        var ha: [256]u32 = @splat(0);
        var hb: [256]u32 = @splat(0);
        var ca: usize = 0;
        var cb: usize = 0;
        var idx: usize = 0;
        for (runs) |r| {
            for (data[r.off..][0..r.len]) |bb| {
                if (seg_of[idx] == s) {
                    ha[bb] += 1;
                    ca += 1;
                } else if (seg_of[idx] == s + 1) {
                    hb[bb] += 1;
                    cb += 1;
                }
                idx += 1;
            }
        }
        if (ca == 0 or cb == 0) break;
        var both = ha;
        for (&both, hb) |*d, sv| d.* += sv;
        // `gain` is the bits saved by keeping the neighbours separate. Merge
        // them only when the saving is smaller than the switch overhead an
        // extra type costs.
        const gain = histEntropy(&ha) + histEntropy(&hb) - histEntropy(&both);
        if (gain < 96.0) {
            for (seg_of) |*sid| {
                if (sid.* > s) sid.* -= 1;
            }
            merged -= 1;
            continue;
        }
        s += 1;
    }
    return merged;
}
/// Evaluates a combined literal model over per-(type, context) histograms
/// (one [64][256] block per literal block type, e.g., from the streaming
/// splitter): contexts are clustered within each type, and the resulting
/// trees are merged jointly across types. Fills `plan` (map over `ntypes` x
/// 64 pairs, tree count) and `tree_freq` with the final trees, and returns
/// the estimated total bits (switch + map + trees + payload).
fn evalCombinedLiteralModel(
    allocator: std.mem.Allocator,
    pair_hists: [][64][256]u32,
    mode: context.ContextType,
    seg_of: []const u8,
    ntypes: u32,
    tree_freq: [][256]u32,
    plan: *CtxPlan,
) !usize {
    const ntypes_usize: usize = ntypes;
    // Stage 1: cluster contexts within each type with the classic clusterer.
    var stage1_freq: [MAX_LIT_TREES][256]u32 = undefined;
    var stage1_cmap: [64]u8 = undefined;
    // Pool of stage-1 trees across types, plus each pair's pool index.
    const pool = try allocator.alloc([256]u32, ntypes_usize * MAX_LIT_TREES);
    defer allocator.free(pool);
    const pair_pool = try allocator.alloc(u32, ntypes_usize * 64);
    defer allocator.free(pair_pool);
    @memset(pair_pool, std.math.maxInt(u32));
    var npool: usize = 0;
    var t: usize = 0;
    while (t < ntypes_usize) : (t += 1) {
        var ntrees_t: u32 = 0;
        clusterContexts(&pair_hists[t], &stage1_freq, &stage1_cmap, &ntrees_t);
        var s: usize = 0;
        while (s < ntrees_t) : (s += 1) {
            pool[npool] = stage1_freq[s];
            // Pairs mapping to this stage-1 tree join its pool slot.
            var c: usize = 0;
            while (c < 64) : (c += 1) {
                if (stage1_cmap[c] == s) pair_pool[t * 64 + c] = @intCast(npool);
            }
            npool += 1;
        }
    }
    if (npool == 0) return std.math.maxInt(usize);
    // Stage 2: merge the pool jointly across types.
    const remap = try allocator.alloc(u8, npool);
    defer allocator.free(remap);
    var ntrees: u32 = 0;
    // tree_freq has MAX_LIT_TREES rows; stage 2 caps there too.
    try mergeTreePool(256, allocator, pool[0..npool], npool, MAX_LIT_TREES, tree_freq[0..MAX_LIT_TREES], remap, &ntrees);
    // Final (type, context) map through the pool remap.
    plan.mode = mode;
    plan.lit_ntypes = ntypes;
    plan.ntrees = ntrees;
    var pi: usize = 0;
    while (pi < ntypes_usize * 64) : (pi += 1) {
        const pp = pair_pool[pi];
        plan.cmap[pi] = if (pp == std.math.maxInt(u32)) 0 else remap[pp];
    }
    // Honest estimate: exact switch machinery + map + trees (stored + payload).
    var tmp_st = buildSwitchTables(seg_of);
    tmp_st.types_blk = &.{};
    var bits: usize = measureSwitchBits(&tmp_st);
    bits += sizeOfContextMapBits(plan.cmap[0 .. ntypes_usize * 64]) * 4 + 16 + @as(usize, ntrees) * 8;
    var tr: usize = 0;
    while (tr < ntrees) : (tr += 1) {
        const m = measureTreeBits(tree_freq[tr][0..], 256);
        bits += m.stored + m.payload;
    }
    return bits;
}
/// Exact emitted bits for one category's block-switch machinery: the type
/// count header, both Huffman trees (stored + payload over the true
/// frequencies the tables already carry), and the first run's length extra
/// bits. Mirrors the emitter exactly, so split adopt/reject decisions compare
/// truth instead of a per-type proxy (which undercounts badly when runs
/// revisit types).
fn varLenUint8Bits(v: u32) usize {
    if (v == 0) return 1;
    if (v == 1) return 4;
    const nb: usize = @intCast(std.math.log2_int(u32, v));
    return 4 + 2 * nb;
}
fn measureSwitchBits(st: *const SwitchTables) usize {
    const type_alphabet: u32 = st.ndistinct + 2;
    const tm = measureTreeBits(st.type_freq[0..type_alphabet], type_alphabet);
    const lm = measureTreeBits(&st.len_freq, constants.NUM_BLOCK_LEN_SYMBOLS);
    const lc0 = blockLengthPrefixCode(st.seg_lens[0]);
    const extra: usize = @intCast(prefix_ranges.prefix_code_ranges[lc0].nbits);
    return varLenUint8Bits(st.ndistinct - 1) + tm.stored + tm.payload + lm.stored + lm.payload + extra;
}
fn buildSwitchTables(type_of: []const u8) SwitchTables {
    var st = SwitchTables{ .ntypes = 0, .types_blk = type_of };
    var prev: ?u8 = null;
    for (st.types_blk) |t| {
        if (prev == null or t != prev.?) {
            if (st.ntypes >= MAX_SWITCH_RUNS) {
                // Cap reached: coalesce the tail into the last run rather
                // than overrunning the tables. Correctness is preserved
                // (fewer switches); only adaptivity is reduced.
                st.seg_lens[st.ntypes - 1] += 1;
                prev = t;
                continue;
            }
            st.types[st.ntypes] = t;
            st.seg_lens[st.ntypes] = 1;
            st.ntypes += 1;
            prev = t;
        } else {
            st.seg_lens[st.ntypes - 1] += 1;
        }
    }
    std.debug.assert(st.ntypes <= MAX_SWITCH_RUNS);
    // Distinct types drive headers, trees, and context maps; runs (which may
    // revisit a type) drive only the switch sequence.
    var seen: [256]bool = @splat(false);
    var distinct: u32 = 0;
    for (st.types[0..st.ntypes]) |t| {
        if (!seen[t]) {
            seen[t] = true;
            distinct += 1;
        }
    }
    st.ndistinct = distinct;
    st.finishTables();
    return st;
}
/// Greedy streaming block splitter for one symbol category (literals,
/// commands, or distances), optionally with several contexts per block type
/// (literals: one histogram per context, entropy summed across them in
/// multi-context mode). Accumulates fixed-size blocks;
/// at each boundary decides whether the block starts a new type, reuses the
/// second-last type, or merges into the last type, by comparing histogram
/// entropies. Produces block types, run lengths, and per-type histograms in
/// one pass. Bounded: O(symbols) time, O(types x contexts x alphabet) memory,
/// at most `max_types` types.
const GreedySplitter = struct {
    allocator: std.mem.Allocator,
    alphabet: usize,
    nctx: usize,
    /// Symbols actually distinguished for entropy (far-distance symbols
    /// beyond this share one implicit bucket and never force a split).
    entropy_n: usize,
    max_types: u32,
    min_block: usize,
    threshold: f64,
    types: std.ArrayList(u8),
    lengths: std.ArrayList(u32),
    /// Per-(type, context) histograms plus one scratch pair and the current set.
    hists: []u32,
    /// Scratch pair for combined-entropy evaluation.
    combined: []u32,
    num_types: u32 = 0,
    curr: usize = 0,
    last_ix: [2]usize = .{ 0, 0 },
    last_ent: [2][64]f64 = @splat(@splat(0)),
    block_size: usize = 0,
    target: usize,
    merge_last_count: usize = 0,

    fn setSize(self: *const GreedySplitter) usize {
        return self.nctx * self.alphabet;
    }

    fn init(
        allocator: std.mem.Allocator,
        alphabet: usize,
        nctx: usize,
        entropy_n: usize,
        max_types: u32,
        min_block: usize,
        threshold: f64,
    ) !GreedySplitter {
        std.debug.assert(nctx >= 1 and nctx <= 64);
        const set = nctx * alphabet;
        const hists = try allocator.alloc(u32, (@as(usize, max_types) + 1) * set);
        @memset(hists, 0);
        const combined = try allocator.alloc(u32, 2 * set);
        errdefer allocator.free(hists);
        errdefer allocator.free(combined);
        return .{
            .allocator = allocator,
            .alphabet = alphabet,
            .nctx = nctx,
            .entropy_n = entropy_n,
            .max_types = max_types,
            .min_block = min_block,
            .threshold = threshold,
            .types = .empty,
            .lengths = .empty,
            .hists = hists,
            .combined = combined,
            .target = min_block,
        };
    }

    fn deinit(self: *GreedySplitter) void {
        self.types.deinit(self.allocator);
        self.lengths.deinit(self.allocator);
        self.allocator.free(self.hists);
        self.allocator.free(self.combined);
        self.* = undefined;
    }

    fn curSet(self: *GreedySplitter) []u32 {
        return self.hists[self.curr * self.setSize() ..][0..self.setSize()];
    }

    fn curHist(self: *GreedySplitter, ctx: usize) []u32 {
        return self.curSet()[ctx * self.alphabet ..][0..self.alphabet];
    }

    fn addSymbol(self: *GreedySplitter, sym: u16, ctx: usize) !void {
        self.curHist(ctx)[sym] += 1;
        self.block_size += 1;
        if (self.block_size == self.target) {
            try self.finishBlock(false);
        }
    }

    fn entropyOf(self: *const GreedySplitter, hist: []const u32) f64 {
        return histEntropyN(hist[0..self.entropy_n]);
    }

    fn entropyOfSet(self: *const GreedySplitter, set: []const u32) f64 {
        var e: f64 = 0;
        var c: usize = 0;
        while (c < self.nctx) : (c += 1) {
            e += self.entropyOf(set[c * self.alphabet ..][0..self.alphabet]);
        }
        return e;
    }

    fn typeSet(self: *GreedySplitter, ix: usize) []u32 {
        return self.hists[ix * self.setSize() ..][0..self.setSize()];
    }

    fn finishBlock(self: *GreedySplitter, is_final: bool) !void {
        _ = is_final;
        if (self.block_size == 0 and self.types.items.len != 0) return;
        self.block_size = @max(self.block_size, self.min_block);
        if (self.types.items.len == 0) {
            // First block always starts type zero.
            try self.types.append(self.allocator, 0);
            try self.lengths.append(self.allocator, @intCast(self.block_size));
            var c: usize = 0;
            while (c < self.nctx) : (c += 1) {
                self.last_ent[0][c] = self.entropyOf(self.curHist(c));
                self.last_ent[1][c] = self.last_ent[0][c];
            }
            self.num_types = 1;
            self.curr += 1;
            if (self.curr < self.max_types + 1) {
                @memset(self.typeSet(self.curr), 0);
            }
            self.block_size = 0;
            return;
        }
        if (self.block_size == 0) return;
        var cur_ent: [64]f64 = @splat(0);
        var c0: usize = 0;
        while (c0 < self.nctx) : (c0 += 1) {
            cur_ent[c0] = self.entropyOf(self.curHist(c0));
        }
        var diff: [2]f64 = .{ 0, 0 };
        var comb_ent: [2][64]f64 = @splat(@splat(0));
        for (0..2) |j| {
            var c: usize = 0;
            while (c < self.nctx) : (c += 1) {
                const ch = self.combined[(j * self.nctx + c) * self.alphabet ..][0..self.alphabet];
                const lh = self.typeSet(self.last_ix[j])[c * self.alphabet ..][0..self.alphabet];
                const cur = self.curHist(c);
                for (ch, cur, lh) |*d, a, b| d.* = a + b;
                comb_ent[j][c] = self.entropyOf(ch);
                diff[j] += comb_ent[j][c] - cur_ent[c] - self.last_ent[j][c];
            }
        }
        if (self.num_types < self.max_types and
            diff[0] > self.threshold and diff[1] > self.threshold)
        {
            // New block type.
            try self.types.append(self.allocator, @intCast(self.num_types));
            try self.lengths.append(self.allocator, @intCast(self.block_size));
            self.last_ix[1] = self.last_ix[0];
            self.last_ix[0] = self.num_types;
            self.last_ent[1] = self.last_ent[0];
            var c: usize = 0;
            while (c < self.nctx) : (c += 1) {
                self.last_ent[0][c] = cur_ent[c];
            }
            self.num_types += 1;
            self.curr += 1;
            if (self.curr < self.max_types + 1) {
                @memset(self.typeSet(self.curr), 0);
            }
            self.block_size = 0;
            self.merge_last_count = 0;
            self.target = self.min_block;
        } else if (diff[1] < diff[0] - 20.0) {
            // Reuse the second-last block type.
            const reused: u8 = self.types.items[self.types.items.len - 2];
            try self.types.append(self.allocator, reused);
            try self.lengths.append(self.allocator, @intCast(self.block_size));
            const tmp = self.last_ix[0];
            self.last_ix[0] = self.last_ix[1];
            self.last_ix[1] = tmp;
            var c: usize = 0;
            while (c < self.nctx) : (c += 1) {
                const ch = self.combined[(1 * self.nctx + c) * self.alphabet ..][0..self.alphabet];
                const lh = self.typeSet(self.last_ix[0])[c * self.alphabet ..][0..self.alphabet];
                @memcpy(lh, ch);
                self.last_ent[1][c] = self.last_ent[0][c];
                self.last_ent[0][c] = comb_ent[1][c];
            }
            self.block_size = 0;
            self.merge_last_count = 0;
            self.target = self.min_block;
        } else {
            // Merge into the last block.
            self.lengths.items[self.lengths.items.len - 1] += @intCast(self.block_size);
            var c: usize = 0;
            while (c < self.nctx) : (c += 1) {
                const ch = self.combined[(0 * self.nctx + c) * self.alphabet ..][0..self.alphabet];
                const lh = self.typeSet(self.last_ix[0])[c * self.alphabet ..][0..self.alphabet];
                @memcpy(lh, ch);
                self.last_ent[0][c] = comb_ent[0][c];
                if (self.num_types == 1) self.last_ent[1][c] = self.last_ent[0][c];
            }
            self.block_size = 0;
            self.merge_last_count += 1;
            if (self.merge_last_count > 1) self.target += self.min_block;
        }
        // Clear the current set for the next block.
        @memset(self.curSet(), 0);
    }

    fn finish(self: *GreedySplitter) !void {
        try self.finishBlock(true);
    }
};
/// Plans a segmentation over a dense symbol stream (command or distance
/// symbols) with the greedy streaming splitter, then merges similar
/// neighbours. Returns the segment count. `alphabet` is the symbol range; histograms are
/// heap-allocated to keep large alphabets off the stack.
fn planDenseSegments(
    allocator: std.mem.Allocator,
    syms: []const u16,
    alphabet: usize,
    nctx: usize,
    ctx_of: ?[]const u8,
    entropy_n: usize,
    max_types: u32,
    min_block: usize,
    threshold: f64,
    seg_of: []u8,
) !u32 {
    const total: usize = seg_of.len;
    std.debug.assert(syms.len == total);
    if (ctx_of) |cf| std.debug.assert(cf.len == total);
    if (total < min_block or max_types < 2) {
        @memset(seg_of, 0);
        return 1;
    }
    // Greedy streaming segmentation, then expand block runs to per-symbol
    // types and merge similar neighbours.
    var splitter = try GreedySplitter.init(
        allocator,
        alphabet,
        nctx,
        entropy_n,
        max_types,
        min_block,
        threshold,
    );
    defer splitter.deinit();
    for (syms, 0..) |s, idx| {
        const cx: usize = if (ctx_of) |cf| cf[idx] else 0;
        try splitter.addSymbol(s, cx);
    }
    try splitter.finish();
    if (splitter.num_types <= 1) {
        @memset(seg_of, 0);
        return 1;
    }
    // Expand block runs to per-symbol type ids.
    {
        var li: usize = 0;
        for (splitter.types.items, splitter.lengths.items) |ty, ln| {
            var k: usize = 0;
            while (k < ln and li < total) : (k += 1) {
                seg_of[li] = ty;
                li += 1;
            }
        }
        while (li < total) : (li += 1) seg_of[li] = splitter.types.items[splitter.types.items.len - 1];
    }
    return splitter.num_types;
}
/// Streams the metablock's literals (in emission order, with their coding
/// contexts) through the greedy splitter, producing content-adaptive literal
/// block types with per-(type, context) histograms ready for the combined
/// model. Returns the type count (1 = no segmentation; seg_of zeroed).
/// `hist_out` receives one [64][256] block per type (caller provides room for
/// MAX_LIT_STREAM_TYPES).
const MAX_LIT_STREAM_TYPES = 16;
fn splitLiteralsStreaming(
    allocator: std.mem.Allocator,
    planned: []const PlannedCommand,
    data: []const u8,
    mode: context.ContextType,
    p1_init: u8,
    p2_init: u8,
    seg_of: []u8,
    hist_out: [][64][256]u32,
) !u32 {
    const total: usize = seg_of.len;
    if (total < 544) {
        @memset(seg_of, 0);
        return 1;
    }
    var splitter = try GreedySplitter.init(allocator, 256, 64, 256, MAX_LIT_STREAM_TYPES, 544, 28.1);
    defer splitter.deinit();
    {
        var p1 = p1_init;
        var p2 = p2_init;
        var lit_pos: usize = 0;
        for (planned) |p| {
            var li: usize = 0;
            while (li < p.insert_len) : (li += 1) {
                const b = data[lit_pos];
                lit_pos += 1;
                try splitter.addSymbol(b, context.contextId(p1, p2, mode));
                p2 = p1;
                p1 = b;
            }
            if (p.copy_len != 0) {
                const end_pos = lit_pos + p.copy_len;
                if (end_pos >= 2) {
                    p1 = data[end_pos - 1];
                    p2 = data[end_pos - 2];
                } else {
                    p1 = data[end_pos - 1];
                    p2 = 0;
                }
                lit_pos = end_pos;
            }
        }
    }
    try splitter.finish();
    if (splitter.num_types <= 1) {
        @memset(seg_of, 0);
        return 1;
    }
    // Expand block runs to per-literal type ids.
    {
        var li: usize = 0;
        for (splitter.types.items, splitter.lengths.items) |ty, ln| {
            var k: usize = 0;
            while (k < ln and li < total) : (k += 1) {
                seg_of[li] = ty;
                li += 1;
            }
        }
        while (li < total) : (li += 1) seg_of[li] = splitter.types.items[splitter.types.items.len - 1];
    }
    // Copy per-(type, context) histograms out before the splitter frees them.
    const ntypes: usize = splitter.num_types;
    var t: usize = 0;
    while (t < ntypes) : (t += 1) {
        const set = splitter.typeSet(t);
        var c: usize = 0;
        while (c < 64) : (c += 1) {
            @memcpy(hist_out[t][c][0..], set[c * 256 ..][0..256]);
        }
    }
    return @intCast(ntypes);
}
/// Mantissa resolution of the `log2Count` lookup table.
const LOG2_TABLE_BITS = 12;
const LOG2_TABLE_SIZE = 1 << LOG2_TABLE_BITS;

fn buildLog2Table() [LOG2_TABLE_SIZE + 1]f64 {
    @setEvalBranchQuota(LOG2_TABLE_SIZE + 16);
    var t: [LOG2_TABLE_SIZE + 1]f64 = undefined;
    var i: usize = 0;
    while (i <= LOG2_TABLE_SIZE) : (i += 1) {
        t[i] = @log2(1.0 + @as(f64, @floatFromInt(i)) / @as(f64, LOG2_TABLE_SIZE));
    }
    return t;
}

const LOG2_MANTISSA_TABLE = buildLog2Table();

/// log2 of a positive integer count without a libm call. The mantissa is
/// normalised to 32 fractional bits and linearly interpolated against the
/// table, which keeps the absolute error near 1e-6 bits (far below the
/// smallest cost difference the search acts on) at a fraction of libm cost.
fn log2U64(n: u64) f64 {
    if (n == 0) return 0;
    const e: u32 = std.math.log2_int(u64, n);
    // m is the mantissa scaled to [2^32, 2^33).
    const m: u64 = if (e >= 32)
        n >> @as(u6, @intCast(e - 32))
    else
        n << @as(u6, @intCast(32 - e));
    const idx: usize = @intCast((m >> 20) - LOG2_TABLE_SIZE);
    const frac: f64 = @as(f64, @floatFromInt(m & 0xFFFFF)) / 1048576.0;
    const base = LOG2_MANTISSA_TABLE[idx];
    return @as(f64, @floatFromInt(e)) + base + frac * (LOG2_MANTISSA_TABLE[idx + 1] - base);
}

fn log2Count(n: u32) f64 {
    return log2U64(n);
}

/// log2 of an arbitrary positive float; only called once per histogram.
fn log2Float(x: f64) f64 {
    return @log2(x);
}

/// Entropy of a histogram slice (generic-alphabet variant of histEntropy).
fn histEntropyN(h: []const u32) f64 {
    var total: u64 = 0;
    for (h) |f| total += f;
    if (total == 0) return 0;
    var e: f64 = 0;
    const log2tf: f64 = log2Float(@floatFromInt(total));
    for (h) |f| {
        if (f != 0) {
            const ff: f64 = @floatFromInt(f);
            e -= ff * (log2Count(f) - log2tf);
        }
    }
    return e;
}
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    window_bits: u32,
    max_backward: usize,
    match_max_dist: usize,
    buf: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    out: std.ArrayList(u8) = .empty,
    out_pos: usize = 0,
    bitbuf: std.ArrayList(u8) = .empty,
    w: huff_enc.BitSink = .{ .buf = &.{} },
    rb: lz77.DistRb = .{},
    started: bool = false,
    finished_: bool = false,
    failed: bool = false,
    input_total_seen: usize = 0,
    custom_dict: []const u8 = &.{},
    /// Total size of every dictionary chunk attached for the current stream.
    /// Static-dictionary references are offset by this amount so the decoder
    /// resolves them past the attached dictionary instead of colliding with
    /// it. Reset only by `reset`.
    attached_dict_len: usize = 0,
    dict_applied: bool = false,
    dict_seeded: bool = false,
    /// Index one past the last custom-dictionary byte in current buffer
    /// coordinates; 0 when no dictionary is in play.
    dict_front_idx: usize = 0,
    /// Sanitized distance-coding parameters.
    npostfix: u32 = 0,
    ndirect: u32 = 0,
    /// Distance alphabet bounds for tree storage (limit) and header
    /// declaration (max); differ only on large-window streams.
    dist_alphabet_limit: u32 = 64,
    dist_alphabet_max: u32 = 64,
    /// Real output bytes already planned/emitted for this stream, excluding
    /// any custom-dictionary seed.
    stream_pos: usize = 0,
    /// Last two real output bytes.
    p1: u8 = 0,
    p2: u8 = 0,
    /// Lazily built index over the built-in dictionary; enabled from
    /// quality 4 upward.
    static_lut: ?*static_dict.Lut = null,
    one_pass_arena: ?*compress_fragment.OnePassArena = null,
    two_pass_arena: ?*compress_fragment_two_pass.TwoPassArena = null,
    frag_table: ?[]i32 = null,
    frag_cmd_buf: ?[]u32 = null,
    frag_lit_buf: ?[]u8 = null,
    fast_arena: ?*metablock_fast.MetablockArena = null,
    q4_arena: ?*metablock.MetaBlockArena = null,
    h2_buckets: ?[]u32 = null,
    h3_buckets: ?[]u32 = null,
    h4_buckets: ?[]u32 = null,
    h58_num: ?[]u16 = null,
    h58_tags: ?[]u8 = null,
    h58_buckets: ?[]u32 = null,
    h68_num: ?[]u16 = null,
    h68_tags: ?[]u8 = null,
    h68_buckets: ?[]u32 = null,
    h78_num: ?[]u16 = null,
    h78_tags: ?[]u8 = null,
    h78_buckets: ?[]u32 = null,
    h85_num: ?[]u16 = null,
    h85_buckets: ?[]u32 = null,
    h95_num: ?[]u16 = null,
    h95_buckets: ?[]u32 = null,
    h10_hasher: ?h2bt.HashToBinaryTree(17, 64, 128) = null,
    fast_commands: ?[]hlmq.Command = null,
    fast_buf: std.ArrayList(u8) = .empty,
    fast_dist_cache: [16]i32 = .{ 4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    fast_saved_dist_cache: [16]i32 = .{ 4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    fast_last_insert_len: usize = 0,
    /// Input block size in bytes.
    fn blockSize(self: *const Encoder) usize {
        if (self.options.lgBlock != 0) {
            const lg = std.math.clamp(self.options.lgBlock, 10, 24);
            const capped = @min(lg, effectiveWindow(self.options));
            return @min(@as(usize, 1) << @intCast(capped), MAX_MLEN);
        }
        if (self.options.quality <= 1) {
            const capped = effectiveWindow(self.options);
            return @min(@as(usize, 1) << @intCast(capped), MAX_MLEN);
        }
        if (self.options.quality < 4) {
            return 1 << 14;
        }
        if (self.options.quality >= 9 and effectiveWindow(self.options) > 16) {
            const lg = @min(18, effectiveWindow(self.options));
            return @as(usize, 1) << @intCast(lg);
        }
        return 1 << 16;
    }
    fn maxMetablockSize(self: *const Encoder) usize {
        const win = effectiveWindow(self.options);
        const lg = if (self.options.lgBlock != 0)
            std.math.clamp(self.options.lgBlock, 10, 24)
        else
            16;
        const bits = @min(1 + @max(win, lg), 24);
        return @as(usize, 1) << @intCast(bits);
    }
    fn refreshDistParams(self: *Encoder) void {
        sanitizeDistanceParams(&self.options);
        self.npostfix = self.options.nPostfix;
        self.ndirect = self.options.nDirect;
        const np = self.npostfix;
        const nd = self.ndirect;
        if (self.options.largeWindow) {
            const lim = constants.calculateDistanceCodeLimit(
                constants.MAX_ALLOWED_DISTANCE,
                np,
                nd,
            );
            self.dist_alphabet_limit = @min(lim.max_alphabet_size, DIST_ALPHABET_MAX);
            // Keep the advertised alphabet width identical to the width derived

            // from the header during decoding.

            self.dist_alphabet_max =
                constants.distanceAlphabetSize(np, nd, constants.LARGE_MAX_DISTANCE_BITS);
        } else {
            const sz = constants.distanceAlphabetSize(np, nd, constants.MAX_DISTANCE_BITS);
            self.dist_alphabet_limit = @min(sz, DIST_ALPHABET_MAX);
            self.dist_alphabet_max = self.dist_alphabet_limit;
        }
    }
    pub fn init(allocator: std.mem.Allocator, options: Options) Encoder {
        var opts = options;
        sanitizeDistanceParams(&opts);
        var e = Encoder{
            .allocator = allocator,
            .options = opts,
            .window_bits = effectiveWindow(opts),
            .max_backward = 0,
            .match_max_dist = 0,
        };
        e.max_backward =
            (@as(usize, 1) << @intCast(e.window_bits)) - WINDOW_GAP;
        e.match_max_dist = e.max_backward;
        e.refreshDistParams();
        if (opts.customDictionary) |d| {
            _ = e.attachDictionary(d);
        }
        if (opts.sharedDictionary) |sd| {
            _ = e.attachSharedDictionary(sd);
        }
        return e;
    }
    pub fn deinit(self: *Encoder) void {
        self.buf.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.bitbuf.deinit(self.allocator);
        if (self.static_lut) |l| {
            l.deinit(self.allocator);
            self.allocator.destroy(l);
            self.static_lut = null;
        }
        if (self.one_pass_arena) |a| {
            self.allocator.destroy(a);
            self.one_pass_arena = null;
        }
        if (self.two_pass_arena) |a| {
            self.allocator.destroy(a);
            self.two_pass_arena = null;
        }
        if (self.frag_cmd_buf) |b| {
            self.allocator.free(b);
            self.frag_cmd_buf = null;
        }
        if (self.frag_lit_buf) |b| {
            self.allocator.free(b);
            self.frag_lit_buf = null;
        }
        if (self.frag_table) |t| {
            self.allocator.free(t);
            self.frag_table = null;
        }
        if (self.fast_arena) |a| {
            self.allocator.destroy(a);
            self.fast_arena = null;
        }
        if (self.h2_buckets) |b| {
            self.allocator.free(b);
            self.h2_buckets = null;
        }
        if (self.h3_buckets) |b| {
            self.allocator.free(b);
            self.h3_buckets = null;
        }
        if (self.h4_buckets) |b| {
            self.allocator.free(b);
            self.h4_buckets = null;
        }
        if (self.h58_num) |b| {
            self.allocator.free(b);
            self.h58_num = null;
        }
        if (self.h58_tags) |b| {
            self.allocator.free(b);
            self.h58_tags = null;
        }
        if (self.h58_buckets) |b| {
            self.allocator.free(b);
            self.h58_buckets = null;
        }
        if (self.h68_num) |b| {
            self.allocator.free(b);
            self.h68_num = null;
        }
        if (self.h68_tags) |b| {
            self.allocator.free(b);
            self.h68_tags = null;
        }
        if (self.h68_buckets) |b| {
            self.allocator.free(b);
            self.h68_buckets = null;
        }
        if (self.h78_num) |b| {
            self.allocator.free(b);
            self.h78_num = null;
        }
        if (self.h78_tags) |b| {
            self.allocator.free(b);
            self.h78_tags = null;
        }
        if (self.h78_buckets) |b| {
            self.allocator.free(b);
            self.h78_buckets = null;
        }
        if (self.h85_num) |b| {
            self.allocator.free(b);
            self.h85_num = null;
        }
        if (self.h85_buckets) |b| {
            self.allocator.free(b);
            self.h85_buckets = null;
        }
        if (self.h95_num) |b| {
            self.allocator.free(b);
            self.h95_num = null;
        }
        if (self.h95_buckets) |b| {
            self.allocator.free(b);
            self.h95_buckets = null;
        }
        if (self.q4_arena) |a| {
            a.deinit(self.allocator);
            self.allocator.destroy(a);
            self.q4_arena = null;
        }
        if (self.fast_commands) |c| {
            self.allocator.free(c);
            self.fast_commands = null;
        }
        if (self.h10_hasher) |*h| {
            h.deinit(self.allocator);
            self.h10_hasher = null;
        }
        self.fast_buf.deinit(self.allocator);
    }
    /// Resets the encoder state for a new stream, reusing allocated buffers and lookup tables.
    pub fn reset(self: *Encoder, options: ?Options) void {
        if (options) |opts| {
            var o = opts;
            sanitizeDistanceParams(&o);
            self.options = o;
            self.window_bits = effectiveWindow(o);
            self.max_backward = (@as(usize, 1) << @intCast(self.window_bits)) - WINDOW_GAP;
            self.match_max_dist = self.max_backward;
            self.refreshDistParams();
        }
        self.buf.clearRetainingCapacity();
        self.consumed = 0;
        self.out.clearRetainingCapacity();
        self.out_pos = 0;
        self.bitbuf.clearRetainingCapacity();
        self.w = .{ .buf = &.{} };
        self.rb = .{};
        self.started = false;
        self.finished_ = false;
        if (self.one_pass_arena) |a| a.* = compress_fragment.OnePassArena.init();
        if (self.two_pass_arena) |a| a.* = compress_fragment_two_pass.TwoPassArena.init();
        if (self.frag_table) |t| @memset(t, 0);
        if (self.fast_arena) |a| a.* = metablock_fast.MetablockArena.init();
        if (self.q4_arena) |a| a.clearRetainingCapacity();
        if (self.h2_buckets) |b| @memset(b, 0);
        if (self.h3_buckets) |b| @memset(b, 0);
        if (self.h4_buckets) |b| @memset(b, 0);
        if (self.h58_num) |b| @memset(b, 65535);
        if (self.h58_tags) |b| @memset(b, 0);
        if (self.h58_buckets) |b| @memset(b, 0);
        if (self.h68_num) |b| @memset(b, 65535);
        if (self.h68_tags) |b| @memset(b, 0);
        if (self.h68_buckets) |b| @memset(b, 0);
        if (self.h78_num) |b| @memset(b, 65535);
        if (self.h78_tags) |b| @memset(b, 0);
        if (self.h78_buckets) |b| @memset(b, 0);
        if (self.h85_num) |b| @memset(b, 0);
        if (self.h85_buckets) |b| @memset(b, 0);
        if (self.h95_num) |b| @memset(b, 0);
        if (self.h95_buckets) |b| @memset(b, 0);
        if (self.h10_hasher) |*h| {
            if (options != null) {
                h.deinit(self.allocator);
                self.h10_hasher = null;
            } else {
                h.prepare();
            }
        }
        self.fast_buf.clearRetainingCapacity();
        self.fast_dist_cache = .{ 4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        self.fast_saved_dist_cache = .{ 4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        self.fast_last_insert_len = 0;
        self.failed = false;
        self.input_total_seen = 0;
        self.custom_dict = &.{};
        self.attached_dict_len = 0;
        self.dict_applied = false;
        self.dict_seeded = false;
        self.dict_front_idx = 0;
        self.stream_pos = 0;
        self.p1 = 0;
        self.p2 = 0;
        if (self.options.customDictionary) |d| {
            _ = self.attachDictionary(d);
        }
        if (self.options.sharedDictionary) |sd| {
            _ = self.attachSharedDictionary(sd);
        }
    }
    /// Compresses a slice of input and returns an allocated output slice.
    pub fn compress(self: *Encoder, input: []const u8) ![]u8 {
        self.reset(null);
        self.options.sizeHint = input.len;
        try self.compressStream(.finish, input);
        const n = self.out.items.len - self.out_pos;
        const result = try self.allocator.alloc(u8, n);
        @memcpy(result, self.out.items[self.out_pos..]);
        self.out_pos = self.out.items.len;
        return result;
    }
    /// Builds the built-in-dictionary match index when quality permits.
    fn ensureStaticLut(self: *Encoder) !?*static_dict.Lut {
        if (self.options.quality < 4) return null;
        if (self.static_lut) |l| return l;
        const l = try self.allocator.create(static_dict.Lut);
        errdefer self.allocator.destroy(l);
        l.* = try static_dict.Lut.build(self.allocator);
        self.static_lut = l;
        return l;
    }
    /// Applies an encoder parameter.
    ///
    /// Stream-defining parameters are accepted only before the first byte of
    /// input is written: the window size and the distance-code layout are
    /// already baked into the metablock headers, so changing them mid-stream
    /// would produce a stream no decoder can read. `sizeHint` and the
    /// progress callback stay adjustable at any time.
    ///
    /// Returns false for unknown identifiers and for parameters that conflict
    /// with a stream already in progress.
    pub fn setParameter(self: *Encoder, id: u32, value: u32) bool {
        switch (id) {
            paramSizeHint => {
                self.options.sizeHint = value;
                return true;
            },
            paramDisableLiteralContextModeling => {
                if (value > 1) return false;
                if (self.started) return false;
                self.options.disableLiteralContextModeling = value != 0;
                return true;
            },
            paramMode => {
                if (self.started) return false;
                self.options.mode = Mode.fromInt(value);
            },
            paramQuality => {
                if (self.started) return false;
                self.options.quality = @min(value, 11);
            },
            paramLgWin => {
                if (self.started) return false;
                self.options.lgWin = value;
                self.window_bits = effectiveWindow(self.options);
                self.max_backward =
                    (@as(usize, 1) << @intCast(self.window_bits)) - WINDOW_GAP;
                self.match_max_dist = self.max_backward;
            },
            paramLgBlock => {
                if (self.started) return false;
                self.options.lgBlock = value;
            },
            paramLargeWindow => {
                if (self.started) return false;
                self.options.largeWindow = value != 0;
                self.window_bits = effectiveWindow(self.options);
                self.max_backward =
                    (@as(usize, 1) << @intCast(self.window_bits)) - WINDOW_GAP;
                self.match_max_dist = self.max_backward;
                self.refreshDistParams();
            },
            paramNPostfix => {
                if (self.started) return false;
                self.options.nPostfix = value;
                self.refreshDistParams();
            },
            paramNDirect => {
                if (self.started) return false;
                self.options.nDirect = value;
                self.refreshDistParams();
            },
            else => return false,
        }
        return true;
    }
    pub fn setProgress(self: *Encoder, cb: ?ProgressCallback, ctx: ?*anyopaque) void {
        self.options.progress = cb;
        self.options.progressCtx = ctx;
    }
    fn reportProgress(self: *Encoder) void {
        const cb = self.options.progress orelse return;
        cb(self.options.progressCtx, self.consumed, self.totalTarget());
    }
    fn totalTarget(self: *Encoder) usize {
        if (self.options.sizeHint != 0) return self.options.sizeHint;
        return self.input_total_seen;
    }
    pub fn isFinished(self: *const Encoder) bool {
        return self.finished_;
    }
    pub fn hasMoreOutput(self: *const Encoder) bool {
        return self.out_pos < self.out.items.len;
    }
    pub fn takeOutput(self: *Encoder, dst: []u8) usize {
        const avail = self.out.items.len - self.out_pos;
        const n = @min(avail, dst.len);
        @memcpy(dst[0..n], self.out.items[self.out_pos .. self.out_pos + n]);
        self.out_pos += n;
        if (self.out_pos == self.out.items.len) {
            self.out.clearRetainingCapacity();
            self.out_pos = 0;
        }
        return n;
    }
    /// Attaches a custom dictionary. Must be called before the first
    /// `compressStream`; data is referenced (not copied) and must outlive the
    /// encoder. Decoders must attach the identical bytes to resolve the
    /// dictionary back-references this produces.
    pub fn attachDictionary(self: *Encoder, data: []const u8) bool {
        if (data.len == 0) return true;
        // soft no-op

        if (data.len > (1 << 24)) return false;
        if (self.started or self.input_total_seen != 0) return false;
        if (self.dict_front_idx + data.len > (1 << 24)) return false;
        self.buf.appendSlice(self.allocator, data) catch return false;
        self.dict_front_idx += data.len;
        self.attached_dict_len += data.len;
        self.consumed = self.dict_front_idx;
        self.dict_applied = true;
        self.dict_seeded = true;
        return true;
    }
    /// Attaches a shared dictionary containing one or more compound prefix chunks.
    pub fn attachSharedDictionary(self: *Encoder, dict: *const shared_dict.SharedDictionary) bool {
        for (dict.prefixes[0..dict.prefix_count]) |chunk| {
            if (!self.attachDictionary(chunk)) return false;
        }
        return true;
    }
    pub fn compressStream(self: *Encoder, op: Operation, input: ?[]const u8) !void {
        if (self.failed) return error.BrotliCompressionFailed;
        if (input) |data| {
            // Metadata payloads ride the input parameter but are not stream

            // data; they must never enter the match-history buffer.

            if (op != .emit_metadata) {
                self.input_total_seen += data.len;
                try self.buf.appendSlice(self.allocator, data);
            }
        }
        switch (op) {
            .finish => {
                try self.emitAll(true);
                self.finished_ = true;
                self.reportProgress();
            },
            .flush => {
                try self.emitAll(false);
                // Seal the partial byte so everything produced so far is a

                // complete, independently decodable prefix of the stream.

                if (self.w.pos & 7 != 0) {
                    try self.emitMetadataBlock(&.{});
                }
                self.reportProgress();
            },
            .emit_metadata => {
                const payload = input orelse return error.BrotliCompressionFailed;
                try self.emitMetadataBlock(payload);
            },
            .process => {
                const high_water = self.blockSize();
                while (self.buf.items.len >= self.consumed + high_water) {
                    try self.emitBlock(high_water, false);
                    self.consumed += high_water;
                    try self.compact();
                    self.reportProgress();
                }
            },
        }
        if (op == .process and self.options.progress != null and
            input != null and input.?.len < (1 << 20))
        {
            self.reportProgress();
        }
    }
    fn compact(self: *Encoder) !void {
        // Retain up to max_backward history bytes for cross-block matches.

        const keep_from = if (self.consumed > self.max_backward)
            self.consumed - self.max_backward
        else
            0;
        if (keep_from > (1 << 20)) {
            const keep = self.buf.items[keep_from..];
            std.mem.copyForwards(u8, self.buf.items[0..keep.len], keep);
            self.buf.shrinkRetainingCapacity(keep.len);
            self.consumed -= keep_from;
            self.dict_front_idx -= @min(self.dict_front_idx, keep_from);
        }
    }
    /// Emits a metadata metablock (RFC 7932 section 9.2): ISLAST=0,
    /// MNIBBLES pattern `11`, reserved zero bit, then the payload length in
    /// 1..3 little-endian bytes followed by the byte-aligned payload.
    fn emitMetadataBlock(self: *Encoder, payload: []const u8) !void {
        if (payload.len >= MAX_MLEN) return error.BrotliCompressionFailed;
        try self.writeHeader();
        // The stored length follows the format-wide convention of MLEN-1;

        // an empty payload takes the dedicated zero-byte-count form.

        var nbytes_needed: usize = 0;
        var v: u64 = 0;
        if (payload.len != 0) {
            v = payload.len - 1;
            nbytes_needed =
                if (v <= 0xFF) 1 else if (v <= 0xFFFF) 2 else 3;
            // The final length byte must be nonzero when more than one is

            // present; widen the encoding if the minimal form would end in

            // a zero byte.

            while (nbytes_needed > 1 and
                ((v >> @intCast((nbytes_needed - 1) * 8)) & 0xFF) == 0)
            {
                if (nbytes_needed == 3) return error.BrotliCompressionFailed;
                nbytes_needed += 1;
            }
            if (nbytes_needed > 3) return error.BrotliCompressionFailed;
        }
        try self.reserve(payload.len * 8 + 64);
        self.syncW();
        self.w.put(1, 0);
        // ISLAST = 0

        self.w.put(2, 3);
        // MNIBBLES marker for metadata

        self.w.put(1, 0);
        // reserved

        self.w.put(2, @intCast(nbytes_needed));
        var i: usize = 0;
        while (i < nbytes_needed) : (i += 1) {
            self.w.put(8, v & 0xFF);
            v >>= 8;
        }
        // Byte-align, then copy the raw payload like a stored block body.

        self.w.pos = (self.w.pos + 7) & ~@as(usize, 7);
        const start_byte = self.w.pos >> 3;
        try self.reserve((start_byte + payload.len) * 8 - self.w.pos + 64);
        if (payload.len != 0) {
            @memcpy(
                self.bitbuf.items[start_byte .. start_byte + payload.len],
                payload,
            );
        }
        self.w.pos = (start_byte + payload.len) << 3;
        try self.finalizeBits(false);
    }
    /// Appends finished bytes of the current bit buffer to the output queue.
    /// Non-final blocks carry the partial byte into the next metablock; the
    /// final call zero-pads to a byte boundary instead.
    fn finalizeBits(self: *Encoder, final: bool) !void {
        var nbytes = self.w.pos >> 3;
        const rem = self.w.pos & 7;
        if (final) {
            if (rem != 0) {
                // Low bits already hold data; the reserved tail is zeroed.

                nbytes += 1;
            }
            try self.out.appendSlice(self.allocator, self.bitbuf.items[0..nbytes]);
            self.bitbuf.clearRetainingCapacity();
            self.w.pos = 0;
            return;
        }
        var partial: u8 = 0;
        if (rem != 0) partial = self.bitbuf.items[nbytes];
        try self.out.appendSlice(self.allocator, self.bitbuf.items[0..nbytes]);
        self.bitbuf.clearRetainingCapacity();
        if (rem != 0) {
            try self.bitbuf.resize(self.allocator, 1);
            self.bitbuf.items[0] = partial & ((@as(u8, 1) << @intCast(rem)) - 1);
            self.w.pos = rem;
        } else {
            self.w.pos = 0;
        }
    }
    fn reserve(self: *Encoder, extra_bits: usize) !void {
        const need_bytes = ((self.w.pos + extra_bits + 7) >> 3) + 16;
        const old_len = self.bitbuf.items.len;
        if (old_len >= need_bytes) return;
        try self.bitbuf.resize(self.allocator, need_bytes);
        @memset(self.bitbuf.items[old_len..], 0);
        self.syncW();
    }
    fn syncW(self: *Encoder) void {
        self.w.buf = self.bitbuf.items;
    }
    fn emitAll(self: *Encoder, is_last: bool) !void {
        var remaining = self.buf.items.len - self.consumed;
        if (remaining == 0) {
            if (is_last) {
                try self.writeHeader();
                try self.reserve(64);
                self.syncW();
                self.w.put(1, 1);
                // ISLAST

                self.w.put(1, 1);
                // ISLASTEMPTY

                try self.finalizeBits(true);
            }
            return;
        }
        const block_lim = if (is_last) self.maxMetablockSize() else self.blockSize();
        while (remaining > 0) {
            const take = @min(remaining, block_lim);
            const chunk_last = is_last and take == remaining;
            try self.emitBlock(take, chunk_last);
            self.consumed += take;
            remaining -= take;
            try self.compact();
        }
    }
    fn writeHeader(self: *Encoder) !void {
        if (self.started) return;
        self.started = true;
        try self.reserve(16);
        const wb = self.window_bits;
        if (self.options.largeWindow) {
            // Large-window marker: `1`, `000`, `001`, reserved zero, then six

            // window bits - 14 bits total.

            self.w.put(1, 1);
            self.w.put(3, 0);
            self.w.put(3, 1);
            self.w.put(1, 0);
            self.w.put(6, wb);
        } else if (wb == 16) {
            self.w.put(1, 0);
        } else if (wb == 17) {
            self.w.put(1, 1);
            self.w.put(3, 0);
            self.w.put(3, 0);
        } else if (wb >= 18 and wb <= 24) {
            self.w.put(1, 1);
            self.w.put(3, wb - 17);
        } else {
            self.w.put(1, 1);
            self.w.put(3, 0);
            self.w.put(3, (wb - 8) & 7);
        }
    }
    fn emitStoredBlock(self: *Encoder, mlen: usize, is_last: bool) !void {
        self.emitBlockHeader(mlen, false);
        self.w.put(1, 1); // ISUNCOMPRESSED
        self.w.pos = (self.w.pos + 7) & ~@as(usize, 7);
        const start_byte = self.w.pos >> 3;
        const need_bits = (start_byte + mlen) * 8 - self.w.pos + 64;
        try self.reserve(need_bits);
        @memcpy(
            self.bitbuf.items[start_byte .. start_byte + mlen],
            self.buf.items[self.consumed .. self.consumed + mlen],
        );
        self.w.pos = (start_byte + mlen) << 3;
        if (is_last) {
            self.bitbuf.items[start_byte + mlen] = 0;
            self.bitbuf.items[start_byte + mlen + 1] = 0;
            self.w.put(1, 1); // ISLAST of the empty final block
            self.w.put(1, 1); // ISLASTEMPTY
            self.w.pos = (self.w.pos + 7) & ~@as(usize, 7);
        }
        self.stream_pos += mlen;
        const stored = self.buf.items[self.consumed .. self.consumed + mlen];
        self.updatePrev(stored);
    }
    fn emitBlockFastOnePass(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.one_pass_arena == null) {
            self.one_pass_arena = try self.allocator.create(compress_fragment.OnePassArena);
            self.one_pass_arena.?.* = compress_fragment.OnePassArena.init();
        }
        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;

        const table_size = getHashTableSizeQ0(data.len);
        if (self.frag_table == null or self.frag_table.?.len < table_size) {
            if (self.frag_table) |t| self.allocator.free(t);
            self.frag_table = try self.allocator.alloc(i32, table_size);
        }
        @memset(self.frag_table.?[0..table_size], 0);

        compress_fragment.compressFragmentFast(
            self.one_pass_arena.?,
            data,
            is_last,
            self.frag_table.?[0..table_size],
            &storage_ix,
            storage,
        );

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockFastTwoPass(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.two_pass_arena == null) {
            self.two_pass_arena = try self.allocator.create(compress_fragment_two_pass.TwoPassArena);
            self.two_pass_arena.?.* = compress_fragment_two_pass.TwoPassArena.init();
        }
        if (self.frag_cmd_buf == null) {
            self.frag_cmd_buf = try self.allocator.alloc(u32, compress_fragment_two_pass.kCompressFragmentTwoPassBlockSize);
            self.frag_lit_buf = try self.allocator.alloc(u8, compress_fragment_two_pass.kCompressFragmentTwoPassBlockSize);
        }
        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;

        const table_size = getHashTableSizeQ1(data.len);
        if (self.frag_table == null or self.frag_table.?.len < table_size) {
            if (self.frag_table) |t| self.allocator.free(t);
            self.frag_table = try self.allocator.alloc(i32, table_size);
        }
        @memset(self.frag_table.?[0..table_size], 0);

        compress_fragment_two_pass.compressFragmentTwoPass(
            self.two_pass_arena.?,
            data,
            is_last,
            self.frag_cmd_buf.?,
            self.frag_lit_buf.?,
            self.frag_table.?[0..table_size],
            &storage_ix,
            storage,
        );

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality2(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.fast_arena == null) {
            self.fast_arena = try self.allocator.create(metablock_fast.MetablockArena);
            self.fast_arena.?.* = metablock_fast.MetablockArena.init();
        }
        if (self.h2_buckets == null) {
            self.h2_buckets = try self.allocator.alloc(u32, hlmq.H2.BUCKET_SIZE);
            @memset(self.h2_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h2 = hlmq.H2.init(self.h2_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h2.prepare(one_shot, data.len, ringbuffer);
        } else {
            h2.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlmq.H2,
            &h2,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            2,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            metablock_fast.storeMetaBlockFast(
                self.fast_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality3(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.fast_arena == null) {
            self.fast_arena = try self.allocator.create(metablock_fast.MetablockArena);
            self.fast_arena.?.* = metablock_fast.MetablockArena.init();
        }
        if (self.h3_buckets == null) {
            self.h3_buckets = try self.allocator.alloc(u32, hlmq.H3.BUCKET_SIZE);
            @memset(self.h3_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h3 = hlmq.H3.init(self.h3_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h3.prepare(one_shot, data.len, ringbuffer);
        } else {
            h3.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlmq.H3,
            &h3,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            3,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            metablock_fast.storeMetaBlockTrivial(
                self.fast_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality4(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h4_buckets == null) {
            self.h4_buckets = try self.allocator.alloc(u32, hlmq.H4.BUCKET_SIZE);
            @memset(self.h4_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h4 = hlmq.H4.init(self.h4_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h4.prepare(one_shot, data.len, ringbuffer);
        } else {
            h4.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlmq.H4,
            &h4,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            4,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                4,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality5(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h58_num == null) {
            self.h58_num = try self.allocator.alloc(u16, hlms.H58.BUCKET_SIZE);
            self.h58_tags = try self.allocator.alloc(u8, hlms.H58.TOTAL_ENTRIES);
            self.h58_buckets = try self.allocator.alloc(u32, hlms.H58.TOTAL_ENTRIES);
            @memset(self.h58_num.?, 65535);
            @memset(self.h58_tags.?, 0);
            @memset(self.h58_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h58 = hlms.H58.init(self.h58_num.?, self.h58_tags.?, self.h58_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h58.prepare(one_shot, data.len, ringbuffer);
        } else {
            h58.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlms.H58,
            &h58,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            5,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                5,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality6(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h68_num == null) {
            self.h68_num = try self.allocator.alloc(u16, hlms.H68.BUCKET_SIZE);
            self.h68_tags = try self.allocator.alloc(u8, hlms.H68.TOTAL_ENTRIES);
            self.h68_buckets = try self.allocator.alloc(u32, hlms.H68.TOTAL_ENTRIES);
            @memset(self.h68_num.?, 65535);
            @memset(self.h68_tags.?, 0);
            @memset(self.h68_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h68 = hlms.H68.init(self.h68_num.?, self.h68_tags.?, self.h68_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h68.prepare(one_shot, data.len, ringbuffer);
        } else {
            h68.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlms.H68,
            &h68,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            6,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                6,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality7(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h78_num == null) {
            self.h78_num = try self.allocator.alloc(u16, hlms.H78.BUCKET_SIZE);
            self.h78_tags = try self.allocator.alloc(u8, hlms.H78.TOTAL_ENTRIES);
            self.h78_buckets = try self.allocator.alloc(u32, hlms.H78.TOTAL_ENTRIES);
            @memset(self.h78_num.?, 65535);
            @memset(self.h78_tags.?, 0);
            @memset(self.h78_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h78 = hlms.H78.init(self.h78_num.?, self.h78_tags.?, self.h78_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h78.prepare(one_shot, data.len, ringbuffer);
        } else {
            h78.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlms.H78,
            &h78,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            7,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                7,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality8(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h85_num == null) {
            self.h85_num = try self.allocator.alloc(u16, hlm.H85.BUCKET_SIZE);
            self.h85_buckets = try self.allocator.alloc(u32, hlm.H85.TOTAL_ENTRIES);
            @memset(self.h85_num.?, 0);
            @memset(self.h85_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h85 = hlm.H85.init(self.h85_num.?, self.h85_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h85.prepare(one_shot, data.len, ringbuffer);
        } else {
            h85.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlm.H85,
            &h85,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            8,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                8,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockQuality9(self: *Encoder, data: []const u8, is_last: bool) !void {
        try self.writeHeader();
        if (self.q4_arena == null) {
            self.q4_arena = try self.allocator.create(metablock.MetaBlockArena);
            self.q4_arena.?.* = metablock.MetaBlockArena.init();
        }
        if (self.h95_num == null) {
            self.h95_num = try self.allocator.alloc(u16, hlm.H95.BUCKET_SIZE);
            self.h95_buckets = try self.allocator.alloc(u32, hlm.H95.TOTAL_ENTRIES);
            @memset(self.h95_num.?, 0);
            @memset(self.h95_buckets.?, 0);
        }
        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        var h95 = hlm.H95.init(self.h95_num.?, self.h95_buckets.?);
        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.stream_pos == 0) {
            h95.prepare(one_shot, data.len, ringbuffer);
        } else {
            h95.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        const num_direct_codes: usize = 0;
        const postfix_bits: usize = 0;
        const max_distance = (1 << 24) * 4 - 4;
        const num_distance_symbols: usize = 64;

        var num_commands: usize = 0;
        var num_literals: usize = 0;
        const position_offset = self.stream_pos - self.consumed;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        backward_references.createBackwardReferences(
            hlm.H95,
            &h95,
            data.len,
            self.consumed,
            ringbuffer,
            mask,
            9,
            self.window_bits,
            position_offset,
            num_direct_codes,
            postfix_bits,
            max_distance,
            &self.fast_dist_cache,
            &self.fast_last_insert_len,
            self.fast_commands.?,
            &num_commands,
            &num_literals,
        );

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            try metablock.storeMetaBlockGreedy(
                self.allocator,
                self.q4_arena.?,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                self.fast_commands.?[0..num_commands],
                num_distance_symbols,
                9,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlockHQ(self: *Encoder, data: []const u8, is_last: bool, quality: u32) !void {
        try self.writeHeader();

        const one_shot = (self.stream_pos == 0 and is_last);
        if (self.h10_hasher == null) {
            self.h10_hasher = try h2bt.HashToBinaryTree(17, 64, 128).init(
                self.allocator,
                @as(u5, @intCast(self.window_bits)),
                one_shot,
                data.len,
            );
        }

        const max_commands = data.len / 2 + 16;
        if (self.fast_commands == null or self.fast_commands.?.len < max_commands) {
            if (self.fast_commands) |c| self.allocator.free(c);
            self.fast_commands = try self.allocator.alloc(hlmq.Command, max_commands);
        }

        const storage_size = 2 * data.len + 503;
        try self.bitbuf.resize(self.allocator, (self.w.pos >> 3) + storage_size);
        self.syncW();

        const storage = self.bitbuf.items[self.w.pos >> 3 ..];
        var storage_ix = self.w.pos & 7;
        if (storage_ix == 0) {
            @memset(storage, 0);
        } else {
            storage[0] &= (@as(u8, 1) << @intCast(storage_ix)) - 1;
            if (storage.len > 1) {
                @memset(storage[1..], 0);
            }
        }

        try self.buf.appendNTimes(self.allocator, 0, 16);
        defer self.buf.shrinkRetainingCapacity(self.buf.items.len - 16);
        const ringbuffer = self.buf.items;
        const mask: usize = (1 << 24) - 1;

        if (self.stream_pos == 0) {
            self.h10_hasher.?.prepare();
        } else {
            self.h10_hasher.?.stitchToPreviousBlock(data.len, self.consumed, ringbuffer, mask);
        }

        var num_direct_codes: usize = 0;
        var distance_postfix_bits: usize = 0;
        if (self.options.mode == .font) {
            num_direct_codes = 12;
            distance_postfix_bits = 1;
        } else {
            num_direct_codes = self.ndirect;
            distance_postfix_bits = self.npostfix;
        }
        var alphabet_size_limit: u32 = constants.distanceAlphabetSize(
            @intCast(distance_postfix_bits),
            @intCast(num_direct_codes),
            constants.MAX_DISTANCE_BITS,
        );
        const max_distance = (1 << 24) * 4 - 4;

        var num_commands: usize = 0;
        var num_literals: usize = 0;

        self.fast_saved_dist_cache = self.fast_dist_cache;

        if (quality == 10) {
            try backward_references_hq.createZopfliBackwardReferences(
                self.allocator,
                data.len,
                self.consumed,
                ringbuffer,
                mask,
                quality,
                @as(u5, @intCast(self.window_bits)),
                num_direct_codes,
                distance_postfix_bits,
                alphabet_size_limit,
                max_distance,
                &self.h10_hasher.?,
                &self.fast_dist_cache,
                &self.fast_last_insert_len,
                self.fast_commands.?,
                &num_commands,
                &num_literals,
            );
        } else {
            try backward_references_hq.createHqZopfliBackwardReferences(
                self.allocator,
                data.len,
                self.consumed,
                ringbuffer,
                mask,
                quality,
                @as(u5, @intCast(self.window_bits)),
                num_direct_codes,
                distance_postfix_bits,
                alphabet_size_limit,
                max_distance,
                &self.h10_hasher.?,
                &self.fast_dist_cache,
                &self.fast_last_insert_len,
                self.fast_commands.?,
                &num_commands,
                &num_literals,
            );
        }

        if (self.fast_last_insert_len > 0) {
            self.fast_commands.?[num_commands].initInsert(self.fast_last_insert_len);
            num_commands += 1;
            num_literals += self.fast_last_insert_len;
            self.fast_last_insert_len = 0;
        }

        if (!metablock_fast.shouldCompress(ringbuffer, mask, self.consumed, data.len, num_literals, num_commands)) {
            self.fast_dist_cache = self.fast_saved_dist_cache;
            metablock_fast.storeUncompressedMetaBlock(
                is_last,
                ringbuffer,
                self.consumed,
                mask,
                data.len,
                &storage_ix,
                storage,
            );
        } else {
            const saved_storage_ix = storage_ix;
            const saved_last_bytes: u16 = if (storage.len > 1) (@as(u16, storage[1]) << 8) | storage[0] else storage[0];

            var mb = metablock_hq.MetaBlockHQ{};
            defer mb.deinit(self.allocator);

            const literal_context_mode: context.ContextType = if (quality >= 10 and !utf8_util.brotliIsMostlyUTF8(ringbuffer, self.consumed, mask, data.len, utf8_util.MIN_UTF8_RATIO))
                .signed
            else
                .utf8;

            try metablock_hq.buildMetaBlockHQ(
                self.allocator,
                ringbuffer,
                self.consumed,
                mask,
                quality,
                self.fast_commands.?[0..num_commands],
                &num_direct_codes,
                &distance_postfix_bits,
                &alphabet_size_limit,
                max_distance,
                literal_context_mode,
                &mb,
            );

            try metablock_hq.storeMetaBlockHQ(
                self.allocator,
                ringbuffer,
                self.consumed,
                data.len,
                mask,
                is_last,
                num_direct_codes,
                distance_postfix_bits,
                alphabet_size_limit,
                literal_context_mode,
                self.fast_commands.?[0..num_commands],
                &mb,
                &storage_ix,
                storage,
            );

            if (data.len + 4 < (storage_ix >> 3)) {
                self.fast_dist_cache = self.fast_saved_dist_cache;
                storage[0] = @truncate(saved_last_bytes);
                if (storage.len > 1) storage[1] = @truncate(saved_last_bytes >> 8);
                if (storage.len > 2) @memset(storage[2..], 0);
                storage_ix = saved_storage_ix;
                metablock_fast.storeUncompressedMetaBlock(
                    is_last,
                    ringbuffer,
                    self.consumed,
                    mask,
                    data.len,
                    &storage_ix,
                    storage,
                );
            }
        }

        self.w.pos = (self.w.pos & ~@as(usize, 7)) + storage_ix;
        try self.finalizeBits(is_last);
    }

    fn emitBlock(self: *Encoder, mlen: usize, is_last: bool) !void {
        if (self.options.quality == 0 and self.custom_dict.len == 0 and self.attached_dict_len == 0) {
            try self.emitBlockFastOnePass(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 1 and self.custom_dict.len == 0 and self.attached_dict_len == 0) {
            try self.emitBlockFastTwoPass(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 2 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality2(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 3 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality3(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 4 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality4(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 5 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality5(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 6 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality6(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 7 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality7(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 8 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality8(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 9 and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockQuality9(self.buf.items[self.consumed .. self.consumed + mlen], is_last);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 10 and !self.options.largeWindow and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockHQ(self.buf.items[self.consumed .. self.consumed + mlen], is_last, 10);
            self.stream_pos += mlen;
            return;
        }
        if (self.options.quality == 11 and !self.options.largeWindow and self.custom_dict.len == 0 and self.attached_dict_len == 0 and self.npostfix == 0 and self.ndirect == 0) {
            try self.emitBlockHQ(self.buf.items[self.consumed .. self.consumed + mlen], is_last, 11);
            self.stream_pos += mlen;
            return;
        }
        try self.writeHeader();
        try self.reserve(mlen * 15 + (1 << 20));
        self.syncW();

        const start_bit_pos = self.w.pos;
        const rb_saved = self.rb;
        if (try self.tryCompressed(mlen, is_last)) {
            const compressed_bits = self.w.pos - start_bit_pos;
            if (compressed_bits > mlen * 8 + 32) {
                const clear_start = start_bit_pos >> 3;
                const rem = start_bit_pos & 7;
                if (rem != 0) {
                    self.bitbuf.items[clear_start] &= (@as(u8, 1) << @intCast(rem)) - 1;
                    if (clear_start + 1 < self.bitbuf.items.len) {
                        @memset(self.bitbuf.items[clear_start + 1 ..], 0);
                    }
                } else {
                    @memset(self.bitbuf.items[clear_start..], 0);
                }
                self.w.pos = start_bit_pos;
                self.rb = rb_saved;
                try self.emitStoredBlock(mlen, is_last);
                try self.finalizeBits(true);
                return;
            }
            try self.finalizeBits(is_last);
            return;
        }
        const clear_start = start_bit_pos >> 3;
        const rem = start_bit_pos & 7;
        if (rem != 0) {
            self.bitbuf.items[clear_start] &= (@as(u8, 1) << @intCast(rem)) - 1;
            if (clear_start + 1 < self.bitbuf.items.len) {
                @memset(self.bitbuf.items[clear_start + 1 ..], 0);
            }
        } else {
            @memset(self.bitbuf.items[clear_start..], 0);
        }
        self.w.pos = start_bit_pos;
        self.rb = rb_saved;
        try self.emitStoredBlock(mlen, is_last);
        try self.finalizeBits(true);
    }
    /// Updates the rolling P1/P2 state after `data` became real output.
    fn updatePrev(self: *Encoder, data: []const u8) void {
        switch (data.len) {
            0 => {},
            1 => {
                self.p2 = self.p1;
                self.p1 = data[0];
            },
            else => {
                self.p1 = data[data.len - 1];
                self.p2 = data[data.len - 2];
            },
        }
    }
    fn emitAllLiterals(self: *Encoder, mlen: usize) !void {
        var lit_tree_freq: [MAX_LIT_TREES][256]u32 = @splat(@splat(0));
        var ic_freq: [704]u32 = @splat(0);
        var dist_freq: [DIST_ALPHABET_MAX]u32 = @splat(0);
        // A single literals-only command; the decoder finishes the metablock

        // right after the insert run, so no copy or distance is consumed.

        const ins = codeFor(&ins_off, @intCast(mlen));
        var sym = cmd_maps.implicit_sym[ins.code][0];
        if (sym == 0xFFFF) sym = cmd_maps.explicit_sym[ins.code][0];
        const data = self.buf.items[self.consumed .. self.consumed + mlen];
        for (data) |b| lit_tree_freq[0][b] += 1;
        const planned = [_]PlannedCommand{.{
            .sym = sym,
            .insert_len = @intCast(mlen),
            .copy_len = 0,
            .copy_code_len = 0,
            .ins_extra = ins.extra,
            .ins_nbits = @intCast(kInsEb[ins.code]),
            .copy_extra = 0,
            .copy_nbits = 0,
            .kind = .literals_only,
        }};
        ic_freq[sym] += 1;
        var cmd_single: [MAX_CMD_BLOCK_TYPES][704]u32 = @splat(@splat(0));
        cmd_single[0] = ic_freq;
        var dist_single: [MAX_DIST_BLOCK_TYPES][DIST_ALPHABET_MAX]u32 = @splat(@splat(0));
        @memcpy(dist_single[0][0..self.dist_alphabet_limit], dist_freq[0..self.dist_alphabet_limit]);
        const no_dist_types: []const u8 = &.{};
        try self.serializeCompressed(
            true,
            &lit_tree_freq,
            1,
            null,
            null,
            &cmd_single,
            1,
            null,
            &dist_single,
            1,
            null,
            no_dist_types,
            &planned,
            data,
        );
        self.stream_pos += mlen;
        self.updatePrev(data);
    }
    // Cost-based parse

    /// Upper bound on the distance alphabet the cost model has to score. The
    /// large-window extension can widen the distance alphabet past the ordinary
    /// 544-symbol cap.
    const MAX_COST_DIST_SYMBOLS = 1200;
    /// Bits charged to each kind of symbol while searching for a cheaper parse.
    /// Costs are derived from the same histograms used for the emitted trees.
    /// Fractional-bit cost that never compares equal for symbols of different
    /// frequency. Whole-bit tables tie constantly (every common byte costs
    /// "2"), and the search drifts among tied options into monocultures;
    /// fractional costs break those ties by true entropy.
    const cost_inf: f32 = 1e30;
    /// Structural price per literal byte (context-map + tree overhead
    /// amortized): measured ~3.4-3.5 bits/byte across parses of all shapes.
    /// The per-symbol model cannot see map/tree structure, so without this
    /// the search literal-izes marginal matches (saving a few modeled bits
    /// per byte while spending ~3.5 structural ones) and fragments the parse.
    const STRUCT_LIT_BITS: f32 = 3.5;
    /// Structural price per copy command (switch + tree overhead amortized).
    /// Without it the search spams short copies: a len-4 copy's symbols look
    /// cheap once frequent (rich-get-richer), while the per-command overhead
    /// they each incur is invisible. Charging it favors fewer, longer copies
    /// (which amortize it) exactly as serialization rewards.
    const STRUCT_CMD_BITS: f32 = 3.0;
    const ParseCosts = struct {
        /// Per-byte literal costs from a global histogram (parse literals for
        /// refinement, block bytes for the flat iteration).
        flat_lit: [256]f32,
        /// Extra bits on the insert-length field, indexed by insert code.
        ins_extra_bits: [24]f32,
        /// Extra bits on the copy-length field, indexed by copy code.
        copy_extra_bits: [24]f32,
        /// Bits for the explicit command symbol, indexed by insert_code * 24 + copy_code.
        cmd_bits: [24 * 24]f32,
        /// Bits for the implicit (last-distance) command symbol, same index.
        /// `cost_inf` when the slot has no implicit form.
        cmd_bits_implicit: [24 * 24]f32,
        /// Bits for a distance symbol plus its extra field.
        dist_bits: [MAX_COST_DIST_SYMBOLS]f32,
        /// Commands this encoder cannot represent are never searched.
        cmd_valid: [24 * 24]bool,
    };
    /// Shannon cost of one symbol under a total, in fractional bits, floored
    /// at one bit (nothing codes below a bit).
    fn shannonCostBits(count: u64, total: u64) f32 {
        if (count == 0 or total == 0) return cost_inf;
        const bits = log2Float(@as(f64, @floatFromInt(total))) - log2U64(count);
        return @floatCast(@max(1.0, bits));
    }
    /// Block-scoped parameters needed to mirror the command planner's
    /// per-command decisions (distance-cache flow, dictionary folding,
    /// representability limits) while costing a parse.
    const CostCtx = struct {
        ndirect: u32,
        npostfix: u32,
        dist_limit: usize,
        max_backward: usize,
        dict_front_idx: usize,
        attached_dict_len: usize,
        stream_pos_base: usize,
        large_window: bool,
    };

    /// One command's planned form, mirroring the emitter's decisions in
    /// `tryCompressed`: which command symbol is used, which distance symbol
    /// (short code or explicit) is paid for, whether a dictionary reference
    /// is folded back into literals, and whether the command is unrepresentable.
    const PlanFormKind = enum { literals_only, implicit_last, explicit_dist, folded_literals };
    const PlanForm = struct {
        kind: PlanFormKind = .literals_only,
        cmd_sym: u16 = 0,
        dist_sym: u32 = 0,
        dist_nbits: u5 = 0,
        reject: bool = false,
    };

    /// Mirrors the emitter's per-command planning for cost-model purposes.
    /// `out_cursor` is the block-relative output offset at the command start
    /// and `rb` is advanced exactly as the emitter advances its cache, so
    /// repeated calls walk the same cache flow the serialized stream uses.
    fn planForm(
        cmd: lz77.Command,
        out_cursor: usize,
        rb: *lz77.DistRb,
        ctx: CostCtx,
    ) PlanForm {
        const ic = codeFor(&ins_off, cmd.insert_len).code;
        if (cmd.copy_len == 0) {
            var sym = cmd_maps.implicit_sym[ic][0];
            if (sym == 0xFFFF) sym = cmd_maps.explicit_sym[ic][0];
            return .{ .kind = .literals_only, .cmd_sym = sym };
        }
        if (cmd.dict) |ref| {
            const l = ref.len_code;
            if (l < dictionary.min_word_length or l > dictionary.max_word_length) {
                return .{ .reject = true };
            }
            const abs_pos = ctx.stream_pos_base + out_cursor + cmd.insert_len;
            const md: u32 = @intCast(@min(abs_pos, ctx.max_backward));
            const shift: u5 = @intCast(dictionary.size_bits_by_length[l]);
            const address = (@as(u32, ref.transform_idx) << shift) | ref.word_idx;
            const dist = md + 1 + @as(u32, @intCast(ctx.attached_dict_len)) + address;
            const cc = codeFor(&copy_off, l).code;
            const sym = cmd_maps.explicit_sym[ic][cc];
            if (sym == 0xFFFF) return .{ .reject = true };
            const dcv = encodeCopyDistance(dist, ctx.ndirect, ctx.npostfix) orelse
                return .{ .kind = .folded_literals };
            if (dcv.sym >= ctx.dist_limit or
                (!ctx.large_window and dcv.nbits > constants.MAX_DISTANCE_BITS))
            {
                return .{ .kind = .folded_literals };
            }
            // Same profitability gate as the emitter: short words are cheaper
            // as literals than as a dictionary reference.
            const est_cmd_bits: usize = 24 + 2 * @as(usize, dc_dist_bits(dist));
            if (@as(usize, cmd.copy_len) * 8 < est_cmd_bits + 16) {
                return .{ .kind = .folded_literals };
            }
            return .{
                .kind = .explicit_dist,
                .cmd_sym = sym,
                .dist_sym = dcv.sym,
                .dist_nbits = dcv.nbits,
            };
        }
        const cc = codeFor(&copy_off, cmd.copy_len).code;
        const from_dict = ctx.dict_front_idx > 0 and
            cmd.dist > out_cursor + cmd.insert_len;
        const use_implicit = !from_dict and
            cmd.dist == rb.last() and
            cmd_maps.implicit_sym[ic][cc] != 0xFFFF;
        if (use_implicit) {
            return .{
                .kind = .implicit_last,
                .cmd_sym = cmd_maps.implicit_sym[ic][cc],
            };
        }
        if (from_dict) {
            if (out_cursor + cmd.insert_len > ctx.max_backward) {
                return .{ .reject = true };
            }
        } else {
            if (rb.shortCodeFor(cmd.dist)) |code| {
                const sym = cmd_maps.explicit_sym[ic][cc];
                if (sym == 0xFFFF) return .{ .reject = true };
                rb.applyShort(code, cmd.dist);
                return .{
                    .kind = .explicit_dist,
                    .cmd_sym = sym,
                    .dist_sym = code,
                    .dist_nbits = 0,
                };
            }
        }
        const dc = encodeCopyDistance(cmd.dist, ctx.ndirect, ctx.npostfix) orelse
            return .{ .reject = true };
        if (dc.sym >= ctx.dist_limit or
            (!ctx.large_window and dc.nbits > constants.MAX_DISTANCE_BITS))
        {
            return .{ .reject = true };
        }
        const sym = cmd_maps.explicit_sym[ic][cc];
        if (sym == 0xFFFF) return .{ .reject = true };
        rb.push(cmd.dist);
        return .{
            .kind = .explicit_dist,
            .cmd_sym = sym,
            .dist_sym = dc.sym,
            .dist_nbits = dc.nbits,
        };
    }

    /// Shannon (entropy) prices for one symbol histogram, in fractional bits.
    /// Used symbols cost their ideal code length (floored at one bit);
    /// unused ones cost log2(total) + 2 (for command/distance histograms the
    /// absent mass counts too, since the final trees must still describe
    /// those symbols).
    fn setShannonCosts(freqs: []const u32, literal: bool, out: []f32) void {
        var sum: u64 = 0;
        for (freqs) |f| sum += f;
        var missing_sum = sum;
        if (!literal) {
            for (freqs) |f| {
                if (f == 0) missing_sum += 1;
            }
        }
        const missing_cost: f32 = if (missing_sum <= 1)
            3.0
        else
            @floatCast(@log2(@as(f64, @floatFromInt(missing_sum))) + 2.0);
        for (freqs, 0..) |f, i| {
            out[i] = if (f == 0) missing_cost else shannonCostBits(f, sum);
        }
    }
    /// Builds a refinement cost model from a parse's own command list.
    /// Literal costs come from the parse's single global insert-byte
    /// histogram (context-free, so sparse contexts cannot underprice their
    /// bytes and drag the search toward literals); command and distance
    /// costs are Shannon prices of the emitted symbols, counted through the
    /// same planning decisions the emitter makes (implicit reuse, short
    /// codes, dictionary folding) so the model prices what is serialized.
    fn buildParseCosts(
        allocator: std.mem.Allocator,
        cmds: []const lz77.Command,
        data: []const u8,
        dist_limit: usize,
        start_rb: lz77.DistRb,
        cost_ctx: CostCtx,
    ) !ParseCosts {
        var costs: ParseCosts = std.mem.zeroes(ParseCosts);
        // Literal costs: one global histogram over the parse's insert bytes.

        var lit_hist: [256]u32 = @splat(0);
        {
            var pos: usize = 0;
            for (cmds) |c| {
                var li: usize = 0;
                while (li < c.insert_len) : (li += 1) {
                    lit_hist[data[pos]] += 1;
                    pos += 1;
                }
                pos += c.copy_len;
            }
        }
        var flat: [256]f32 = undefined;
        setShannonCosts(&lit_hist, true, &flat);
        for (&flat) |*c| c.* += STRUCT_LIT_BITS;
        costs.flat_lit = flat;
        // Command costs.

        var ic_freq: [704]u32 = @splat(0);
        var dist_freq: [MAX_COST_DIST_SYMBOLS]u32 = @splat(0);
        {
            // Count the symbols the emitter would actually write: implicit
            // reuse and short codes included, folded dictionary references
            // excluded. The cache starts where this block's stream state
            // left it, exactly as planning sees it.
            var rb = start_rb;
            var out_cursor: usize = 0;
            for (cmds) |c| {
                const form = planForm(c, out_cursor, &rb, cost_ctx);
                out_cursor += c.insert_len + c.copy_len;
                if (form.reject or form.kind == .folded_literals) continue;
                ic_freq[form.cmd_sym] += 1;
                if (form.kind == .explicit_dist and form.dist_sym < dist_limit) {
                    dist_freq[@as(usize, form.dist_sym)] += 1;
                }
            }
        }
        var cmd_costs: [704]f32 = undefined;
        setShannonCosts(&ic_freq, false, &cmd_costs);
        for (0..24) |ic| {
            for (0..24) |cc| {
                const sym_e = cmd_maps.explicit_sym[ic][cc];
                const sym_i = cmd_maps.implicit_sym[ic][cc];
                const have_e = sym_e != 0xFFFF;
                const have_i = sym_i != 0xFFFF;
                if (!have_e and !have_i) continue;
                costs.cmd_bits[ic * 24 + cc] =
                    if (have_e) cmd_costs[sym_e] else cost_inf;
                costs.cmd_bits_implicit[ic * 24 + cc] =
                    if (have_i) cmd_costs[sym_i] else cost_inf;
                costs.cmd_valid[ic * 24 + cc] = true;
            }
        }
        var dist_costs: [MAX_COST_DIST_SYMBOLS]f32 = undefined;
        setShannonCosts(dist_freq[0..dist_limit], false, dist_costs[0..dist_limit]);
        for (dist_costs[0..dist_limit], 0..) |d, sym| {
            costs.dist_bits[sym] = d;
        }
        // Symbols outside the representable range stay unusable.

        for (&costs.dist_bits, 0..) |*d, sym| {
            if (sym >= dist_limit) d.* = cost_inf;
        }
        for (&costs.cmd_bits, 0..) |*c, i| {
            if (costs.cmd_valid[i]) continue;
            c.* = cost_inf;
        }
        for (0..24) |i| {
            costs.ins_extra_bits[i] = @floatFromInt(kInsEb[i]);
            costs.copy_extra_bits[i] = @floatFromInt(kCopyEb[i]);
        }
        _ = allocator;
        return costs;
    }
    /// Builds the flat first-iteration cost model: parse-independent prices so
    /// the search can leave the greedy parse's neighborhood instead of
    /// re-rating greedy's own symbol choices. Literal costs come from the
    /// block's global byte histogram (greedy-independent, unlike the
    /// per-context histograms of a refinement iteration); command and
    /// distance symbols cost log2(index + base), which prices rare symbols by
    /// position rather than by absence from some other parse's histograms.
    fn buildFlatCosts(data: []const u8, dist_limit: usize) ParseCosts {
        var costs: ParseCosts = std.mem.zeroes(ParseCosts);
        var hist: [256]u32 = @splat(0);
        for (data) |b| hist[b] += 1;
        var flat: [256]f32 = undefined;
        setShannonCosts(&hist, true, &flat);
        for (&flat) |*c| c.* += STRUCT_LIT_BITS;
        costs.flat_lit = flat;
        for (0..24) |ic| {
            for (0..24) |cc| {
                const sym_e = cmd_maps.explicit_sym[ic][cc];
                const sym_i = cmd_maps.implicit_sym[ic][cc];
                const have_e = sym_e != 0xFFFF;
                const have_i = sym_i != 0xFFFF;
                if (!have_e and !have_i) continue;
                // Log cost of the emitted symbol index under a
                // flat model (log2(11 + cmdcode)).
                costs.cmd_bits[ic * 24 + cc] = if (have_e)
                    @floatCast(@log2(@as(f64, @floatFromInt(11 + @as(u32, sym_e)))))
                else
                    cost_inf;
                costs.cmd_bits_implicit[ic * 24 + cc] = if (have_i)
                    @floatCast(@log2(@as(f64, @floatFromInt(11 + @as(u32, sym_i)))))
                else
                    cost_inf;
                costs.cmd_valid[ic * 24 + cc] = true;
            }
        }
        for (0..MAX_COST_DIST_SYMBOLS) |sym| {
            // Log cost of the distance symbol index (log2(20 + sym)).
            costs.dist_bits[sym] = if (sym < dist_limit)
                @floatCast(@log2(@as(f64, @floatFromInt(20 + @as(u32, @intCast(sym))))))
            else
                cost_inf;
        }
        for (0..24) |i| {
            costs.ins_extra_bits[i] = @floatFromInt(kInsEb[i]);
            costs.copy_extra_bits[i] = @floatFromInt(kCopyEb[i]);
        }
        return costs;
    }
    /// Number of copy lengths tried per match.
    const COST_PARSE_LENGTH_LADDER = 32;
    /// Distinct matches considered per position.
    const COST_PARSE_MAX_CANDIDATES = 8;
    /// Fills `out` with a bounded, descending ladder of copy lengths up to
    /// `max_len`. The longest length is always included. Lengths at or below
    /// 16 are all tried (command coding interacts most with length choice
    /// there); longer lengths follow a descending geometric ladder.
    fn buildLengthLadder(max_len: usize, out: []usize) usize {
        const min_len = @min(max_len, lz77.MIN_MATCH);
        var n: usize = 0;
        var l = max_len;
        while (n < out.len) {
            out[n] = l;
            n += 1;
            if (l <= min_len) break;
            if (l <= 17) {
                l -= 1;
            } else {
                const next = l / 2;
                l = if (next < 17) 16 else next;
            }
        }
        return n;
    }
    /// One reconstructed backward reference.
    const ParseStep = struct {
        insert_len: u32,
        copy_len: u32,
        dist: u32,
        /// Present for built-in dictionary references (dist stays zero).
        dict: ?lz77.DictRef = null,
    };
    /// Which distance representation won a priced transition, so the
    /// path's distance cache can advance exactly as the emitter advances
    /// its own (implicit reuse leaves it, a short code applies, an
    /// explicit distance pushes).
    const DistWin = enum { explicit_dist, implicit_last, short_code };
    /// (Command bits, distance bits) for one (insert code, copy code, distance)
    /// under the given cache, committing exactly what serialization replays:
    /// implicit last-distance reuse first, then the short code, then the
    /// explicit distance. A cheaper form the emitter would not choose is a
    /// phantom saving: the search would chase it while the replay prices
    /// something else, so the committed form is reported and the cache is
    /// advanced by it. Null when no representation is available.
    fn distCmdPrice(
        costs: *const ParseCosts,
        rb: lz77.DistRb,
        dist: u32,
        icode: u8,
        ccode: u8,
        short_dc: ?f32,
        short_code: ?u4,
        explicit_dc: ?f32,
    ) ?struct { cmd: f32, dist: f32, win: DistWin, code: u4 } {
        const slot: usize = @as(usize, icode) * 24 + ccode;
        if (!costs.cmd_valid[slot]) return null;
        if (dist == rb.last() and
            cmd_maps.implicit_sym[icode][ccode] != 0xFFFF)
        {
            const ic = costs.cmd_bits_implicit[slot];
            if (ic != cost_inf) {
                return .{ .cmd = ic, .dist = 0, .win = .implicit_last, .code = 0 };
            }
        }
        if (short_dc) |sdc| {
            const ec = costs.cmd_bits[slot];
            if (ec != cost_inf) {
                return .{ .cmd = ec, .dist = sdc, .win = .short_code, .code = short_code orelse 0 };
            }
        }
        if (explicit_dc) |edc| {
            const ec = costs.cmd_bits[slot];
            if (ec != cost_inf) {
                return .{ .cmd = ec, .dist = edc, .win = .explicit_dist, .code = 0 };
            }
        }
        return null;
    }
    /// Advances a path cache by the committed effect of a priced transition.
    fn advanceRb(rb: lz77.DistRb, win: DistWin, code: u4, dist: u32) lz77.DistRb {
        var out = rb;
        switch (win) {
            .implicit_last => {},
            .short_code => out.applyShort(code, dist),
            .explicit_dist => out.push(dist),
        }
        return out;
    }
    /// Searches for a parse cheaper than the greedy one the caller already has.
    /// Dynamic programming over output positions. Every candidate is charged
    /// the command, insert-length, copy-length and distance cost, including
    /// the literal bits of any insert run it closes. Distance pricing uses the
    /// exact cache along the best path reaching each command start (memoized
    /// forward as costs settle, since every edge moves forward), so short
    /// codes and last-distance reuse are credited exactly as serialization
    /// would price them. Short-code distances from that cache are also tried
    /// as copy candidates directly, since hash chains alone bury them.
    /// Matches stay inside `end` and distances are validated against the
    /// window and the distance alphabet. Positions covered by a very long
    /// best match (`skip_len`) skip candidate search, using a
    /// long-copy shortcut: a match that long is always taken
    /// with no insert run.
    fn parseOptimal(
        allocator: std.mem.Allocator,
        matcher: *lz77.Matcher,
        buf: []const u8,
        start: usize,
        end: usize,
        max_dist: u32,
        costs: *const ParseCosts,
        ndirect: u32,
        npostfix: u32,
        dist_limit: usize,
        max_insert: usize,
        skip_len: usize,
        rb_before: lz77.DistRb,
        greedy_cmds: []const lz77.Command,
        greedy_starts: []const usize,
        cost_ctx: CostCtx,
        out: *std.ArrayList(lz77.Command),
        result_cost: *f32,
    ) !bool {
        const n = end - start;
        if (n == 0) return false;
        const INF: f32 = cost_inf;
        // Cumulative literal cost per output position, so an insert run's
        // price is one subtraction. Per-byte costs from the model's global
        // histogram (fractional bits keep close alternatives distinct).
        const lit_prefix = try allocator.alloc(f32, n + 1);
        defer allocator.free(lit_prefix);
        lit_prefix[0] = 0;
        {
            const fl = costs.flat_lit;
            var lf: usize = 0;
            while (lf < n) : (lf += 1) {
                lit_prefix[lf + 1] = lit_prefix[lf] + fl[buf[start + lf]];
            }
        }
        // Chain candidates plus one slot for the greedy seed below.
        var cands: [COST_PARSE_MAX_CANDIDATES + 1]lz77.Candidate = undefined;
        var seed_cur: usize = 0;
        const cost = try allocator.alloc(f32, n + 1);
        defer allocator.free(cost);
        const back = try allocator.alloc(u32, n + 1);
        defer allocator.free(back);
        const kind = try allocator.alloc(u8, n + 1);
        defer allocator.free(kind);
        const mdist = try allocator.alloc(u32, n + 1);
        defer allocator.free(mdist);
        const mins = try allocator.alloc(u8, n + 1);
        defer allocator.free(mins);
        // Exact distance cache along the best path reaching each position.
        // Every edge moves forward, so when the loop arrives at `p` all
        // incoming relaxations are done and `memo[p]` is final.
        const memo = try allocator.alloc(lz77.DistRb, n + 1);
        defer allocator.free(memo);
        // Dictionary reference for copy steps that reproduce greedy static
        // dictionary commands (null otherwise); read only along the winning
        // path, so every entry is written before use.
        const mdict = try allocator.alloc(?lz77.DictRef, n + 1);
        defer allocator.free(mdict);
        @memset(mdict, null);
        // Start of the current literal chain reaching each position: when a
        // copy edge leaves `from`, the merged command's insert run is the
        // chain before `from` plus the edge's own run, and the insert code
        // must be charged for that whole run (serialization merges them into
        // one command). Valid exactly when kind[from] == 0; copy landings
        // start a fresh (empty) chain.
        const runstart = try allocator.alloc(u32, n + 1);
        defer allocator.free(runstart);
        @memset(cost, INF);
        @memset(kind, 0);
        cost[0] = 0;
        memo[0] = rb_before;
        runstart[0] = 0;
        // Positions covered by a taken long match skip candidate search;
        // literals still flow through them.
        var skip_until: usize = 0;
        var p: usize = 0;
        while (p < n) : (p += 1) {
            const base = cost[p];
            if (base == INF) continue;
            const abs_p = start + p;
            const path_rb = memo[p];
            // Emit this byte as a literal (cache unchanged). A literal extends
            // the current chain (or starts one at a copy landing), so record
            // where the chain reaching p+1 begins for merged-icode pricing.

            const lit_total = base + (lit_prefix[p + 1] - lit_prefix[p]);
            if (lit_total < cost[p + 1]) {
                cost[p + 1] = lit_total;
                back[p + 1] = @intCast(p);
                kind[p + 1] = 0;
                memo[p + 1] = path_rb;
                runstart[p + 1] = if (kind[p] == 0) runstart[p] else @intCast(p);
            }
            // Close an insert run here and copy a match forward. Search

            // before chaining: the chain must not contain this position yet,

            // or the search would immediately stop on the self reference and

            // find nothing.

            if (abs_p + lz77.MIN_MATCH > end) {
                if (abs_p + matcher.params.min_match <= end) matcher.insertAt(abs_p);
                continue;
            }
            if (p < skip_until) {
                if (abs_p + matcher.params.min_match <= end) matcher.insertAt(abs_p);
                continue;
            }
            const ncand_chain = matcher.findCandidates(abs_p, end, max_dist, cands[0..COST_PARSE_MAX_CANDIDATES]);
            if (abs_p + matcher.params.min_match <= end) matcher.insertAt(abs_p);
            var ncand = ncand_chain;
            // Seed the greedy command starting here, if any. Its distance is
            // known good, and seeding it guarantees the search can reproduce
            // the greedy path (the bounded chain walk might never probe that
            // distance). Unlike chain candidates the seed's length was
            // verified at the greedy copy start, not here, so it must always
            // be re-verified per insert run (never trusted). Verification and
            // pricing below decide whether it wins.
            var seed_idx: ?usize = null;
            while (seed_cur < greedy_starts.len and greedy_starts[seed_cur] < p) seed_cur += 1;
            if (seed_cur < greedy_starts.len and greedy_starts[seed_cur] == p and ncand < cands.len) {
                const g = greedy_cmds[seed_cur];
                if (g.copy_len != 0 and g.dict == null and g.dist != 0 and g.dist <= max_dist) {
                    seed_idx = ncand;
                    cands[ncand] = .{ .len = g.copy_len, .dist = g.dist };
                    ncand += 1;
                }
            }
            // Seed a greedy dictionary reference starting here, if any. Its
            // bytes were verified by greedy at this exact copy start, so the
            // reference is trusted at its exact insert run below (dictionary
            // matches are positional; no discovery, just reproduction).
            var seed_dict: ?struct { il: usize, len: usize, ref: lz77.DictRef } = null;
            if (seed_cur < greedy_starts.len and greedy_starts[seed_cur] == p) {
                const g = greedy_cmds[seed_cur];
                if (g.copy_len != 0 and g.dict != null) {
                    const gi: usize = g.insert_len;
                    const glen: usize = g.copy_len;
                    if (gi <= max_insert and p + gi + glen <= n) {
                        seed_dict = .{ .il = gi, .len = glen, .ref = g.dict.? };
                    }
                }
            }
            // Long-copy shortcut: a match longer than `skip_len` is taken
            // with no insert run, and covered positions skip candidate
            // search. Only the longest chain candidate is considered here
            // (chain lengths were verified at this position; the seed's was
            // not, so it goes through the verified path below).
            if (ncand_chain > 0 and cands[0].len > skip_len and cands[0].dist != 0 and cands[0].dist <= max_dist) {
                const m = cands[0];
                const idx = p + m.len;
                if (idx <= n) {
                    // Merged insert run: chain before p (no own run here).
                    const merged_len: usize = if (kind[p] == 0) p - runstart[p] else 0;
                    const icode = codeFor(&ins_off, @intCast(@min(merged_len, std.math.maxInt(u32)))).code;
                    const ccode = codeFor(&copy_off, @intCast(m.len)).code;
                    var short_dc: ?f32 = null;
                    var short_code: ?u4 = null;
                    if (path_rb.shortCodeFor(m.dist)) |code| {
                        if (code < dist_limit) {
                            short_dc = costs.dist_bits[code];
                            short_code = code;
                        }
                    }
                    var explicit_dc: ?f32 = null;
                    if (encodeCopyDistance(m.dist, ndirect, npostfix)) |dcv| {
                        if (dcv.sym < dist_limit) explicit_dc = costs.dist_bits[dcv.sym] + dcv.nbits;
                    }
                    if (distCmdPrice(costs, path_rb, m.dist, icode, ccode, short_dc, short_code, explicit_dc)) |pr| {
                        // Per-command structural charge (see STRUCT_CMD_BITS).
                        const total = base +
                            costs.ins_extra_bits[icode] +
                            pr.cmd +
                            costs.copy_extra_bits[ccode] +
                            pr.dist +
                            STRUCT_CMD_BITS;
                        if (total < cost[idx]) {
                            cost[idx] = total;
                            back[idx] = @intCast(p);
                            kind[idx] = 1;
                            mdist[idx] = m.dist;
                            mins[idx] = 0;

                            memo[idx] = advanceRb(path_rb, pr.win, pr.code, m.dist);
                            // Only suppress the covered span when this edge
                            // actually won: suppressing on a losing edge
                            // blinds the search (seeds included) for no gain.
                            skip_until = @max(skip_until, p + m.len);
                        }
                    }
                }
                continue;
            }
            for (cands[0..ncand], 0..) |m, mi| {
                if (m.dist == 0 or m.dist > max_dist) continue;
                const is_seed = seed_idx != null and mi == seed_idx.?;
                // Exact-cache short-code price plus the precomputed explicit
                // price; the per-length step picks the cheapest available
                // representation (implicit, short, explicit).
                var short_dc: ?f32 = null;
                var short_code: ?u4 = null;
                if (path_rb.shortCodeFor(m.dist)) |code| {
                    if (code < dist_limit) {
                        short_dc = costs.dist_bits[code];
                        short_code = code;
                    }
                }
                var explicit_dc: ?f32 = null;
                if (encodeCopyDistance(m.dist, ndirect, npostfix)) |dcv| {
                    if (dcv.sym < dist_limit) explicit_dc = costs.dist_bits[dcv.sym] + dcv.nbits;
                }
                if (short_dc == null and explicit_dc == null) continue;
                // Try a bounded ladder of copy lengths for this distance.

                var lengths: [COST_PARSE_LENGTH_LADDER]usize = undefined;
                const nl = buildLengthLadder(m.len, &lengths);
                // `lengths` is descending, so the shortest entry bounds how

                // large an insert run can still be.

                const longest = lengths[0];
                const shortest = lengths[nl - 1];
                // Insert runs are the outer loop so the byte comparison runs

                // once per (distance, insert run) instead of once per

                // (distance, length, insert run). Every ladder length is a

                // prefix of `longest`, so a single pass establishes exactly

                // which lengths are backed by matching bytes, and the shorter

                // ones inherit that answer rather than repeating the scan.

                const max_il = @min(max_insert, n -| p -| shortest);
                // Literal chain reaching p (bytes the merge folds into the
                // following copy's insert run); computed once per candidate.
                const chain_len: usize = if (kind[p] == 0) p - runstart[p] else 0;
                var il: usize = 0;
                while (il <= max_il) : (il += 1) {
                    const avail = n - p - il;
                    if (avail < shortest) break;
                    // Merged insert code: serialization folds the chain into
                    // this copy's insert run and charges one code for all of
                    // it, so the search must price that code (not the edge's
                    // own run alone), or literal chains dodge the charge.
                    const merged_icode = codeFor(&ins_off, @intCast(@min(chain_len + il, std.math.maxInt(u32)))).code;
                    // The insert run's literal bits: output reproduces input,
                    // so the run price is one prefix-sum subtraction. (Chain
                    // bytes were priced by their own literal steps already.)
                    const lit_run = lit_prefix[p + il] - lit_prefix[p];
                    // Cheap arithmetic pre-filter. Verifying match bytes is far

                    // more expensive than pricing a transition, and most

                    // transitions lose to a cheaper path already recorded, so

                    // pay for the byte scan only when some length here wins.

                    var any_improves = false;
                    for (lengths[0..nl]) |mlen| {
                        if (mlen > avail) break;
                        const ccode = codeFor(&copy_off, @intCast(mlen)).code;
                        const pr = distCmdPrice(costs, path_rb, m.dist, merged_icode, ccode, short_dc, short_code, explicit_dc) orelse continue;
                        const total = base +
                            lit_run +
                            costs.ins_extra_bits[merged_icode] +
                            pr.cmd +
                            costs.copy_extra_bits[ccode] +
                            pr.dist +
                            STRUCT_CMD_BITS;
                        if (total < cost[p + il + mlen]) {
                            any_improves = true;
                            break;
                        }
                    }
                    if (!any_improves) continue;
                    // Number of leading bytes known to match here. A chain
                    // candidate was verified at the search position, so a
                    // zero-length insert run already matches; otherwise the
                    // insert run shifts the copy and needs its own check. The
                    // greedy seed is always re-verified: its length belongs
                    // to the greedy copy start, not to this position.
                    var verified: usize = longest;
                    if (il != 0 or is_seed) {
                        const abs_copy = start + p + il;
                        if (m.dist > abs_copy) continue;
                        const abs_from = abs_copy - m.dist;
                        const vlen = @min(longest, avail);
                        const k = lz77.matchLenAt(buf, abs_copy, abs_from, vlen);
                        verified = k;
                    }
                    for (lengths[0..nl]) |mlen| {
                        // Descending: the first length that outruns the

                        // verified prefix (or the block) ends the ladder.

                        if (mlen > avail or mlen > verified) break;
                        const ccode = codeFor(&copy_off, @intCast(mlen)).code;
                        const pr = distCmdPrice(costs, path_rb, m.dist, merged_icode, ccode, short_dc, short_code, explicit_dc) orelse continue;
                        const total = base +
                            lit_run +
                            costs.ins_extra_bits[merged_icode] +
                            pr.cmd +
                            costs.copy_extra_bits[ccode] +
                            pr.dist +
                            STRUCT_CMD_BITS;
                        const idx = p + il + mlen;
                        if (total < cost[idx]) {
                            cost[idx] = total;
                            back[idx] = @intCast(p);
                            kind[idx] = 1;
                            mdist[idx] = m.dist;
                            mins[idx] = @intCast(il);

                            memo[idx] = advanceRb(path_rb, pr.win, pr.code, m.dist);
                            // Clear any dictionary reference a previous
                            // winner recorded here; window copies carry none
                            // and reconstruction reads mdict for every copy.
                            mdict[idx] = null;
                        }
                    }
                }
            }
            // Short-code tries: distances from the exact command-start cache
            // that hash chains alone bury. Each code is verified against the
            // shifted copy start with a continuation gate, then priced over
            // the ladder exactly like a chain candidate. Codes already
            // covered by a chain candidate are skipped (the chain path prices
            // their short form with the same cache and verifies the same
            // bytes, so re-trying them only repeats full scans).
            {
                var covered: u16 = 0;
                for (cands[0..ncand]) |m| {
                    if (m.dist == 0 or m.dist > max_dist) continue;
                    if (path_rb.shortCodeFor(m.dist)) |code| {
                        covered |= @as(u16, 1) << code;
                    }
                }
                if (covered != 0xFFFF) {
                    const max_il_sc = @min(max_insert, n -| p -| lz77.MIN_MATCH);
                    // Same merged-icode rule as the chain path (see above).
                    const sc_chain: usize = if (kind[p] == 0) p - runstart[p] else 0;
                    var il: usize = 0;
                    while (il <= max_il_sc) : (il += 1) {
                        const abs_copy = start + p + il;
                        const avail = n - p - il;
                        if (avail < lz77.MIN_MATCH) break;
                        const icode = codeFor(&ins_off, @intCast(@min(sc_chain + il, std.math.maxInt(u32)))).code;
                        const lit_run = lit_prefix[p + il] - lit_prefix[p];
                        // Feasibility ladder over the whole remaining run for
                        // the arithmetic pre-filter (over-approximates: lengths
                        // are re-checked against verified bytes below).
                        var pre_lengths: [COST_PARSE_LENGTH_LADDER]usize = undefined;
                        const pre_nl = buildLengthLadder(avail, &pre_lengths);
                        // Best verified copy length at this insert run so far;
                        // the continuation byte proves whether a code can
                        // extend past it before paying for a full scan.
                        var best: usize = lz77.MIN_MATCH - 1;
                        var c: u32 = 0;
                        while (c < 16) : (c += 1) {
                            if ((covered >> @intCast(c)) & 1 != 0) continue;
                            if (c >= dist_limit) continue;
                            const d = lz77.cacheEntry(&path_rb, c);
                            if (d == 0 or d > max_dist or d > abs_copy) continue;
                            const code: u4 = @intCast(c);
                            const sdc: f32 = costs.dist_bits[c];
                            // Arithmetic pre-filter: skip the byte scan when
                            // no ladder length can beat a recorded path.
                            var any_improves = false;
                            for (pre_lengths[0..pre_nl]) |mlen| {
                                if (mlen > avail) break;
                                const ccode = codeFor(&copy_off, @intCast(mlen)).code;
                                const pr = distCmdPrice(costs, path_rb, d, icode, ccode, sdc, code, null) orelse continue;
                                const total = base +
                                    lit_run +
                                    costs.ins_extra_bits[icode] +
                                    pr.cmd +
                                    costs.copy_extra_bits[ccode] +
                                    pr.dist +
                                    STRUCT_CMD_BITS;
                                if (total < cost[p + il + mlen]) {
                                    any_improves = true;
                                    break;
                                }
                            }
                            if (!any_improves) continue;
                            const abs_from = abs_copy - d;
                            if (abs_copy + best < end and
                                buf[abs_copy + best] != buf[abs_from + best])
                            {
                                continue;
                            }
                            const k = lz77.matchLenAt(buf, abs_copy, abs_from, avail);
                            if (k < lz77.MIN_MATCH) continue;
                            if (k > best) best = k;
                            var sc_lengths: [COST_PARSE_LENGTH_LADDER]usize = undefined;
                            const sc_nl = buildLengthLadder(k, &sc_lengths);
                            for (sc_lengths[0..sc_nl]) |mlen| {
                                if (mlen > avail or mlen > k) break;
                                const ccode = codeFor(&copy_off, @intCast(mlen)).code;
                                const pr = distCmdPrice(costs, path_rb, d, icode, ccode, sdc, code, null) orelse continue;
                                const total = base +
                                    lit_run +
                                    costs.ins_extra_bits[icode] +
                                    pr.cmd +
                                    costs.copy_extra_bits[ccode] +
                                    pr.dist +
                                    STRUCT_CMD_BITS;
                                const idx = p + il + mlen;
                                if (total < cost[idx]) {
                                    cost[idx] = total;
                                    back[idx] = @intCast(p);
                                    kind[idx] = 1;
                                    mdist[idx] = d;
                                    mins[idx] = @intCast(il);

                                    memo[idx] = advanceRb(path_rb, pr.win, pr.code, d);
                                    // Window copies carry no dictionary
                                    // reference (see chain/shortcut sites).
                                    mdict[idx] = null;
                                }
                            }
                        }
                    }
                }
            }
            // Greedy dictionary seed (see above): price the exact reference
            // greedy used here. The merged insert code covers the literal
            // chain plus the edge's own run (same G2 rule as window copies);
            // the cache is untouched by dictionary references.
            if (seed_dict) |sd| {
                const chain_len: usize = if (kind[p] == 0) p - runstart[p] else 0;
                const merged_len = chain_len + sd.il;
                const merged_icode = codeFor(&ins_off, @intCast(@min(merged_len, std.math.maxInt(u32)))).code;
                const lit_run = lit_prefix[p + sd.il] - lit_prefix[p];
                var rb_tmp = path_rb;
                const form = planForm(.{
                    .insert_len = @intCast(@min(merged_len, std.math.maxInt(u32))),
                    .copy_len = @intCast(sd.len),
                    .dist = 0,
                    .dict = sd.ref,
                }, p, &rb_tmp, cost_ctx);
                if (!form.reject and form.kind == .explicit_dist) {
                    const cc = codeFor(&copy_off, sd.ref.len_code).code;
                    const slot: usize = @as(usize, merged_icode) * 24 + cc;
                    if (costs.cmd_valid[slot]) {
                        const total = base +
                            lit_run +
                            costs.ins_extra_bits[merged_icode] +
                            costs.cmd_bits[slot] +
                            costs.copy_extra_bits[cc] +
                            costs.dist_bits[@as(usize, form.dist_sym)] +
                            form.dist_nbits +
                            STRUCT_CMD_BITS;
                        const idx = p + sd.il + sd.len;
                        if (total < cost[idx]) {
                            cost[idx] = total;
                            back[idx] = @intCast(p);
                            kind[idx] = 1;
                            mdist[idx] = 0;
                            mins[idx] = @intCast(sd.il);

                            memo[idx] = path_rb;
                            mdict[idx] = sd.ref;
                        }
                    }
                }
            }
        }
        if (cost[n] == INF) return false;
        result_cost.* = cost[n];
        // Reconstruct the chosen path back into commands.

        var steps: std.ArrayList(ParseStep) = .empty;
        defer steps.deinit(allocator);
        var cur = n;
        while (cur > 0) {
            if (kind[cur] == 1) {
                const from = back[cur];
                const il: usize = mins[cur];
                const cl = cur - from - il;
                if (cl == 0) return false;
                steps.append(allocator, .{
                    .insert_len = @intCast(il),
                    .copy_len = @intCast(cl),
                    .dist = mdist[cur],
                    .dict = mdict[cur],
                }) catch return false;
                cur = from;
            } else {
                var lit: usize = 0;
                var t = cur;
                while (t > 0 and kind[t] == 0) {
                    lit += 1;
                    t = back[t];
                }
                if (lit != 0) {
                    steps.append(allocator, .{
                        .insert_len = @intCast(lit),
                        .copy_len = 0,
                        .dist = 0,
                    }) catch return false;
                }
                cur = t;
            }
        }
        if (steps.items.len == 0) return false;
        // Merge literal runs into the following copy's insert length so every

        // command but the trailing one carries a copy, matching the greedy

        // command structure the planner accepts. A trailing run becomes the

        // final insert-only command.

        var merged: std.ArrayList(ParseStep) = .empty;
        defer merged.deinit(allocator);
        {
            var pending: u32 = 0;
            var i = steps.items.len;
            while (i > 0) {
                i -= 1;
                const st = steps.items[i];
                pending += st.insert_len;
                if (st.copy_len == 0) continue;
                merged.append(allocator, .{
                    .insert_len = pending,
                    .copy_len = st.copy_len,
                    .dist = st.dist,
                    .dict = st.dict,
                }) catch return false;
                pending = 0;
            }
            if (pending != 0) {
                merged.append(allocator, .{
                    .insert_len = pending,
                    .copy_len = 0,
                    .dist = 0,
                }) catch return false;
            }
        }
        if (merged.items.len == 0) return false;
        // Validate coverage, distances, and copied bytes before trusting it.

        {
            var covered: usize = 0;
            for (merged.items) |st| {
                covered += st.insert_len + st.copy_len;
                if (st.copy_len != 0 and st.dist == 0 and st.dict == null) return false;
                if (st.copy_len != 0 and st.dist > max_dist) return false;
            }
            if (covered != n) return false;
            // `merged` is in stream order; replay it directly. Dictionary
            // steps are trusted (their bytes were verified by greedy at this
            // exact copy start); only window copies are re-verified here.

            var at: usize = 0;
            for (merged.items) |st| {
                at += st.insert_len;
                // Dictionary steps cover output bytes (advance) but verify
                // against the static dictionary, not the ring buffer, and
                // were already verified by greedy at this exact position.
                if (st.dict != null) {
                    at += st.copy_len;
                    continue;
                }
                if (st.copy_len == 0) continue;
                const abs_at = start + at;
                if (st.dist == 0 or st.dist > abs_at) return false;
                const from = abs_at - st.dist;
                var k: usize = 0;
                while (k < st.copy_len) : (k += 1) {
                    if (buf[abs_at + k] != buf[from + k]) return false;
                }
                at += st.copy_len;
            }
            if (at != n) return false;
        }
        // Emit the merged list in stream order.

        for (merged.items) |st| {
            try out.append(allocator, .{
                .insert_len = st.insert_len,
                .copy_len = st.copy_len,
                .dist = st.dist,
                .dict = st.dict,
            });
        }
        return true;
    }
    /// Writes one metablock header (ISLAST/MNIBBLES/MLEN) for a block that
    /// carries data. `last_for_block` is the ISLAST value this block goes out
    /// with (a final stored block uses false here, followed by an empty final).
    fn emitBlockHeader(self: *Encoder, mlen: usize, last_for_block: bool) void {
        self.w.put(1, if (last_for_block) 1 else 0);
        if (last_for_block) self.w.put(1, 0);
        // MNIBBLES + MLEN (value stored is MLEN-1).

        const v = mlen - 1;
        const nibbles: usize = if (v < (1 << 16)) 0 else if (v < (1 << 20)) 1 else 2;
        self.w.put(2, @intCast(nibbles));
        const count: usize = 4 + nibbles;
        for (0..count) |i| {
            self.w.put(4, (v >> @intCast(i * 4)) & 0xF);
        }
    }
    fn tryCompressed(self: *Encoder, mlen: usize, is_last: bool) !bool {
        const alloc = self.allocator;
        const params = qualityParams(self.options.quality);
        const full = self.buf.items;
        const lut = try self.ensureStaticLut();
        var cmds: std.ArrayList(lz77.Command) = .empty;
        defer cmds.deinit(alloc);
        const search_dist = self.match_max_dist + self.dict_front_idx;
        try lz77.compress(alloc, full, self.consumed, self.consumed + mlen, search_dist, params, &cmds, lut);
        if (cmds.items.len == 0) {
            return false;
        }
        // At the top qualities, price alternative parses and keep each one

        // that costs less than the current best. Costs are re-estimated from

        // every adopted parse; the top quality runs a second iteration. The

        // search carries the exact distance cache along each path itself, so

        // no snapshots of the current parse are needed.

        if (self.options.quality >= COST_PARSE_MIN_QUALITY and mlen > 0) {
            const block_end = self.consumed + mlen;
            const iters: usize = if (self.options.quality >= 11) 2 else 1;
            const rb_before = self.rb;
            // Long-copy shortcut bound (150 at q10, 325 at q11):
            // longer best matches are taken as-is.
            const skip_len: usize = if (self.options.quality >= 11) 325 else 150;
            const cost_ctx = CostCtx{
                .ndirect = self.ndirect,
                .npostfix = self.npostfix,
                .dist_limit = self.dist_alphabet_limit,
                .max_backward = self.max_backward,
                .dict_front_idx = self.dict_front_idx,
                .attached_dict_len = self.attached_dict_len,
                .stream_pos_base = self.stream_pos,
                .large_window = self.options.largeWindow,
            };
            var it: usize = 0;
            while (it < iters) : (it += 1) {
                // Block-relative start offset of each command of the current
                // best parse, rebuilt every iteration so the seed always
                // reflects the latest adoption.
                var greedy_starts: std.ArrayList(usize) = .empty;
                defer greedy_starts.deinit(alloc);
                {
                    var off: usize = 0;
                    for (cmds.items) |c| {
                        try greedy_starts.append(alloc, off);
                        off += c.insert_len + c.copy_len;
                    }
                }
                // First iteration uses parse-independent flat costs so the
                // search leaves the greedy neighborhood. Later iterations
                // refine under histograms of the latest parse BLENDED with
                // flat costs (shrinkage): pure histogram costs overfit to
                // the current parse (rare-but-efficient symbols price
                // themselves out of the next parse), while the flat
                // component keeps every symbol feasible by position.
                var costs: ParseCosts = if (it == 0)
                    buildFlatCosts(
                        full[self.consumed..block_end],
                        self.dist_alphabet_limit,
                    )
                else blk: {
                    var from_parse = try buildParseCosts(
                        alloc,
                        cmds.items,
                        full[self.consumed..block_end],
                        self.dist_alphabet_limit,
                        rb_before,
                        cost_ctx,
                    );
                    const flat = buildFlatCosts(
                        full[self.consumed..block_end],
                        self.dist_alphabet_limit,
                    );
                    for (from_parse.flat_lit[0..], flat.flat_lit[0..]) |*d, s| d.* = 0.5 * (d.* + s);
                    for (from_parse.cmd_bits[0..], flat.cmd_bits[0..]) |*d, s| {
                        if (d.* != cost_inf and s != cost_inf) d.* = 0.5 * (d.* + s);
                    }
                    for (from_parse.cmd_bits_implicit[0..], flat.cmd_bits_implicit[0..]) |*d, s| {
                        if (d.* != cost_inf and s != cost_inf) d.* = 0.5 * (d.* + s);
                    }
                    for (from_parse.dist_bits[0..self.dist_alphabet_limit], flat.dist_bits[0..self.dist_alphabet_limit]) |*d, s| {
                        if (d.* != cost_inf and s != cost_inf) d.* = 0.5 * (d.* + s);
                    }
                    break :blk from_parse;
                };
                var matcher = try lz77.Matcher.init(alloc, full, params);
                defer matcher.deinit();
                matcher.primeHistory(self.consumed);
                var alt: std.ArrayList(lz77.Command) = .empty;
                defer alt.deinit(alloc);
                var parsed_cost: f32 = 0;
                if (try parseOptimal(
                    alloc,
                    &matcher,
                    full,
                    self.consumed,
                    block_end,
                    @intCast(search_dist),
                    &costs,
                    self.ndirect,
                    self.npostfix,
                    self.dist_alphabet_limit,
                    cost_parse_max_insert,
                    skip_len,
                    rb_before,
                    cmds.items,
                    greedy_starts.items,
                    cost_ctx,
                    &alt,
                    &parsed_cost,
                )) {
                    // Take the refined parse unconditionally: the flat first
                    // iteration already left the greedy neighborhood, and the
                    // refinement iteration re-rates under the latest parse's
                    // own histograms, so each step is self-consistent. (A
                    // modeled veto here would reintroduce greedy bias through
                    // the deadband between model error and decision margin.)
                    if (alt.items.len != 0) {
                        // Fixed point: the refined parse reproduced the current
                        // one exactly, so re-running the search under the same
                        // histogram model cannot change it. Stop instead of
                        // paying for another full pass over the block.
                        if (commandsEqual(cmds.items, alt.items)) break;
                        cmds.clearRetainingCapacity();
                        try cmds.appendSlice(alloc, alt.items);
                    } else break;
                } else break;
            }
        }
        var lit_tree_freq: [MAX_LIT_TREES][256]u32 = @splat(@splat(0));
        var ic_freq: [704]u32 = @splat(0);
        var dist_freq: [DIST_ALPHABET_MAX]u32 = @splat(0);
        const planned = try alloc.alloc(PlannedCommand, cmds.items.len + 1);
        defer alloc.free(planned);
        const rb_saved = self.rb;
        const block_stream_base = self.stream_pos;
        // Output cursor (bytes of this block already planned).

        var out_cursor: usize = 0;
        // Literals carried forward when a dictionary reference is folded back.

        var carry_insert: usize = 0;
        var used: usize = 0;
        var ok = true;
        for (cmds.items, 0..) |cmd, ci| {
            const ic = codeFor(&ins_off, cmd.insert_len + @as(u32, @intCast(carry_insert)));
            var p: PlannedCommand = undefined;
            p.insert_len = cmd.insert_len + @as(u32, @intCast(carry_insert));
            carry_insert = 0;
            p.copy_len = cmd.copy_len;
            p.copy_code_len = cmd.copy_len;
            p.ins_extra = ic.extra;
            p.ins_nbits = @intCast(kInsEb[ic.code]);
            p.dist_code = 0;
            p.dist_extra = 0;
            p.dist_nbits = 0;
            if (cmd.copy_len == 0) {
                if (ci + 1 != cmds.items.len) {
                    ok = false;
                    break;
                }
                p.copy_extra = 0;
                p.copy_nbits = 0;
                var sym = cmd_maps.implicit_sym[ic.code][0];
                if (sym == 0xFFFF) sym = cmd_maps.explicit_sym[ic.code][0];
                p.sym = sym;
                p.kind = .literals_only;
                planned[used] = p;
                used += 1;
                ic_freq[sym] += 1;
                out_cursor += p.insert_len;
                continue;
            }
            if (cmd.dict) |ref| {
                // Built-in dictionary reference: the stream carries the base

                // word length and the transform is applied on decode.

                const l = ref.len_code;
                if (l < dictionary.min_word_length or l > dictionary.max_word_length) {
                    ok = false;
                    break;
                }
                const abs_pos = block_stream_base + out_cursor + p.insert_len;
                const md: u32 = @intCast(@min(abs_pos, self.max_backward));
                const shift: u5 = @intCast(dictionary.size_bits_by_length[l]);
                const address = (@as(u32, ref.transform_idx) << shift) | ref.word_idx;
                const dist = md + 1 + @as(u32, @intCast(self.attached_dict_len)) + address;
                const dc_ok =
                    dist <= constants.MAX_ALLOWED_DISTANCE and
                    blk: {
                        const dcv = encodeCopyDistance(dist, self.ndirect, self.npostfix) orelse break :blk false;
                        break :blk dcv.sym < self.dist_alphabet_limit and
                            dcv.nbits <= constants.MAX_DISTANCE_BITS;
                    };
                // Keep the reference only when it beats emitting the bytes as

                // literals.

                const est_cmd_bits: usize = 24 + 2 * @as(usize, dc_dist_bits(dist));
                if (!dc_ok or @as(usize, cmd.copy_len) * 8 < est_cmd_bits + 16) {
                    // Fold back into literals for the successor command.

                    carry_insert += p.insert_len + cmd.copy_len;
                    continue;
                }
                const cc = codeFor(&copy_off, l);
                p.copy_code_len = l;
                p.copy_extra = cc.extra;
                p.copy_nbits = @intCast(kCopyEb[cc.code]);
                const dcv = encodeCopyDistance(dist, self.ndirect, self.npostfix).?;
                const sym = cmd_maps.explicit_sym[ic.code][cc.code];
                if (sym == 0xFFFF) {
                    ok = false;
                    break;
                }
                p.sym = sym;
                p.kind = .explicit_dist;
                p.dist_code = @intCast(dcv.sym);
                p.dist_extra = dcv.extra;
                p.dist_nbits = dcv.nbits;
                dist_freq[dcv.sym] += 1;
                // Static-dictionary references leave the distance cache

                // unchanged.

                planned[used] = p;
                used += 1;
                ic_freq[p.sym] += 1;
                out_cursor += p.insert_len + p.copy_len;
                continue;
            }
            const cc = codeFor(&copy_off, cmd.copy_len);
            p.copy_extra = cc.extra;
            p.copy_nbits = @intCast(kCopyEb[cc.code]);
            // A source inside the custom dictionary uses an explicit distance

            // and is only valid while output fits the window.

            const from_dict = self.dict_front_idx > 0 and
                cmd.dist > out_cursor + cmd.insert_len;
            const use_implicit = !from_dict and
                cmd.dist == self.rb.last() and
                cmd_maps.implicit_sym[ic.code][cc.code] != 0xFFFF;
            if (use_implicit) {
                p.sym = cmd_maps.implicit_sym[ic.code][cc.code];
                p.kind = .implicit_last;
            } else {
                if (from_dict) {
                    // Reject matches that cannot resolve before the window fills.

                    if (out_cursor + cmd.insert_len > self.max_backward) {
                        ok = false;
                        break;
                    }
                }
                // Prefer a distance short code when the cache reproduces this

                // distance: no extra bits and usually a cheap symbol.

                if (!from_dict) {
                    if (self.rb.shortCodeFor(cmd.dist)) |code| {
                        const sym = cmd_maps.explicit_sym[ic.code][cc.code];
                        if (sym == 0xFFFF) {
                            ok = false;
                            break;
                        }
                        p.sym = sym;
                        p.kind = .explicit_dist;
                        p.dist_code = code;
                        p.dist_extra = 0;
                        p.dist_nbits = 0;
                        dist_freq[code] += 1;
                        self.rb.applyShort(code, cmd.dist);
                        planned[used] = p;
                        used += 1;
                        ic_freq[p.sym] += 1;
                        out_cursor += p.insert_len + p.copy_len;
                        continue;
                    }
                }
                const dc = encodeCopyDistance(cmd.dist, self.ndirect, self.npostfix) orelse {
                    ok = false;
                    break;
                };
                if (dc.sym >= self.dist_alphabet_limit or
                    (!self.options.largeWindow and dc.nbits > constants.MAX_DISTANCE_BITS))
                {
                    ok = false;
                    break;
                }
                const sym = cmd_maps.explicit_sym[ic.code][cc.code];
                if (sym == 0xFFFF) {
                    ok = false;
                    break;
                }
                p.sym = sym;
                p.kind = .explicit_dist;
                p.dist_code = @intCast(dc.sym);
                p.dist_extra = dc.extra;
                p.dist_nbits = dc.nbits;
                dist_freq[dc.sym] += 1;
                self.rb.push(cmd.dist);
            }
            planned[used] = p;
            used += 1;
            ic_freq[p.sym] += 1;
            out_cursor += p.insert_len + p.copy_len;
        }
        if (!ok) {
            self.rb = rb_saved;
            return false;
        }
        // Fold any trailing carried literals into a final literal run.

        if (carry_insert != 0) {
            const ins_t = codeFor(&ins_off, @intCast(carry_insert));
            var sym_t = cmd_maps.implicit_sym[ins_t.code][0];
            if (sym_t == 0xFFFF) sym_t = cmd_maps.explicit_sym[ins_t.code][0];
            planned[used] = .{
                .sym = sym_t,
                .insert_len = @intCast(carry_insert),
                .copy_len = 0,
                .copy_code_len = 0,
                .ins_extra = ins_t.extra,
                .ins_nbits = @intCast(kInsEb[ins_t.code]),
                .copy_extra = 0,
                .copy_nbits = 0,
                .kind = .literals_only,
            };
            used += 1;
            ic_freq[sym_t] += 1;
        }
        const data = self.buf.items[self.consumed .. self.consumed + mlen];
        // Literal layout selection: plain single tree, context modeling, or

        // literal block switching. The cheapest option by estimated total bits

        // wins.

        var lit_bits_best: usize = 0;
        var cm: ?CtxPlan = null;
        var split: ?SwitchTables = null;
        {
            var literal_count: usize = 0;
            for (planned[0..used]) |p| literal_count += p.insert_len;
            const want_cm = !self.options.disableLiteralContextModeling and
                self.options.quality >= 4 and mlen >= 128 and literal_count >= 256;
            const want_split = !self.options.disableLiteralContextModeling and
                self.options.quality >= 4 and mlen >= 2048 and literal_count >= 1024;
            // Literal runs: byte ranges emitted as literals. Copy output is not

            // literal data and stays out of the histograms.

            var runs: std.ArrayList(LitRun) = .empty;
            defer runs.deinit(alloc);
            {
                var run_off: usize = 0;
                for (planned[0..used]) |p| {
                    if (p.insert_len != 0) {
                        runs.append(alloc, .{
                            .off = @intCast(run_off),
                            .len = p.insert_len,
                        }) catch break;
                    }
                    run_off += p.insert_len + p.copy_len;
                }
            }
            // Plain baseline over literal bytes only.

            var all: [256]u32 = @splat(0);
            for (runs.items) |r| {
                for (data[r.off..][0..r.len]) |b| all[b] += 1;
            }
            const pm = measureTreeBits(&all, 256);
            var best_layout: Layout = .plain;
            var best_bits: usize = pm.stored + pm.payload;
            var cm_cand: ?CtxPlan = null;
            var split_cand: ?SwitchTables = null;
            if (want_cm) {
                const mode = chooseContextMode(data, self.options.quality);
                var ctx_hist: [64][256]u32 = @splat(@splat(0));
                buildContextHistograms(planned[0..used], data, mode, self.p1, self.p2, &ctx_hist);
                var plan = CtxPlan{ .mode = mode };
                clusterContexts(&ctx_hist, &lit_tree_freq, @as(*[64]u8, @ptrCast(&plan.cmap)), &plan.ntrees);
                var bits: usize = sizeOfContextMapBits(plan.cmap[0..64]) * 4 + 16 + plan.ntrees * 8;
                var t: usize = 0;
                while (t < plan.ntrees) : (t += 1) {
                    const m = measureTreeBits(&lit_tree_freq[t], 256);
                    bits += m.stored + m.payload;
                }
                if (bits < best_bits) {
                    best_bits = bits;
                    best_layout = .cm_w;
                    cm_cand = plan;
                }
            }
            if (want_split) {
                if (runs.items.len != 0) {
                    const seg_of = alloc.alloc(u8, literal_count) catch return false;
                    defer alloc.free(seg_of);
                    const k = planLiteralSegments(data, runs.items, seg_of);
                    if (k > 1) {
                        var seg_hist: [MAX_LIT_BLOCK_TYPES][256]u32 = @splat(@splat(0));
                        {
                            var li: usize = 0;
                            for (runs.items) |r| {
                                for (data[r.off..][0..r.len]) |b| {
                                    seg_hist[seg_of[li]][b] += 1;
                                    li += 1;
                                }
                            }
                        }
                        const st = buildSwitchTables(seg_of);
                        // Exact switch machinery plus the identity context
                        // map cost.

                        var bits: usize = measureSwitchBits(&st) + k * 8;
                        var t: usize = 0;
                        while (t < k) : (t += 1) {
                            const m = measureTreeBits(&seg_hist[t], 256);
                            bits += m.stored + m.payload;
                        }
                        if (bits + 28 < best_bits) {
                            best_bits = bits;
                            best_layout = .split_w;
                            split_cand = st;
                            // Commit the segment histograms only on win; the

                            // shared tables still hold the context-modeling

                            // result until a winner is chosen below.

                            for (&lit_tree_freq) |*tt| tt.* = @splat(0);
                            t = 0;
                            while (t < k) : (t += 1) lit_tree_freq[t] = seg_hist[t];
                            // The switch tables borrow the per-literal type

                            // array, which is freed with this block; release

                            // the borrow now that construction is complete.

                            split_cand.?.types_blk = &.{};
                        }
                    }
                    // Combined block-type/context model: segmentations the
                    // context-free gate rejects can still pay once contexts
                    // separate each segment, so force even candidates (plus
                    // the splitter's own when it fired) and let the honest
                    // switch+map+tree estimate decide.
                    if (self.options.quality >= 9) {
                        const mode_c = chooseContextMode(data, self.options.quality);
                        // Content-adaptive segmentation with per-(type,
                        // context) histograms straight from the splitter.
                        const stream_hists = try alloc.alloc([64][256]u32, MAX_LIT_STREAM_TYPES);
                        defer alloc.free(stream_hists);
                        const ntypes_s = try splitLiteralsStreaming(
                            alloc,
                            planned[0..used],
                            data,
                            mode_c,
                            self.p1,
                            self.p2,
                            seg_of,
                            stream_hists,
                        );
                        if (ntypes_s > 1) {
                            var plan_tmp: CtxPlan = .{ .mode = mode_c };
                            var tmp_trees: [MAX_LIT_TREES][256]u32 = @splat(@splat(0));
                            const cb_bits = evalCombinedLiteralModel(
                                alloc,
                                stream_hists[0..ntypes_s],
                                mode_c,
                                seg_of,
                                ntypes_s,
                                tmp_trees[0..],
                                &plan_tmp,
                            ) catch std.math.maxInt(usize);
                            if (cb_bits + 28 < best_bits) {
                                best_bits = cb_bits;
                                best_layout = .combined;
                                // seg_of already holds this segmentation; the
                                // switch tables are self-contained copies.
                                var st = buildSwitchTables(seg_of);
                                st.types_blk = &.{};
                                split_cand = st;
                                cm_cand = plan_tmp;
                                lit_tree_freq = tmp_trees;
                            }
                        }
                    }
                }
            }
            switch (best_layout) {
                .cm_w => cm = cm_cand,
                .split_w => split = split_cand,
                .combined => {
                    cm = cm_cand;
                    split = split_cand;
                },
                .plain => {
                    // Must be the histogram that was measured above.

                    lit_tree_freq[0] = all;
                },
            }
            lit_bits_best = best_bits;
        }
        // Command and distance block splitting. Each category is segmented
        // independently (even splits plus similarity merging); the cheapest
        // of a single tree and per-type trees wins by estimated total bits.
        var cmd_tree_freq: [MAX_CMD_BLOCK_TYPES][704]u32 = @splat(@splat(0));
        var dist_tree_freq: [MAX_DIST_BLOCK_TYPES][DIST_ALPHABET_MAX]u32 = @splat(@splat(0));
        var cmd_split: ?SwitchTables = null;
        var dist_split: ?SwitchTables = null;
        var cmd_ntypes: u32 = 1;
        var dist_ntypes: u32 = 1;
        // Per-planned-command distance type, valid for explicit_dist only.
        const dist_type_of = try alloc.alloc(u8, used);
        defer alloc.free(dist_type_of);
        @memset(dist_type_of, 0);
        {
            const want_cat_split = !self.options.disableLiteralContextModeling and
                self.options.quality >= 4;
            // Command symbols, dense over planned commands.
            const cmd_syms = try alloc.alloc(u16, used);
            defer alloc.free(cmd_syms);
            for (planned[0..used], 0..) |p, i| cmd_syms[i] = p.sym;
            var n_dist: usize = 0;
            for (planned[0..used]) |p| {
                if (p.kind == .explicit_dist) n_dist += 1;
            }
            const dist_syms = try alloc.alloc(u16, n_dist);
            defer alloc.free(dist_syms);
            const dist_cmd = try alloc.alloc(u32, n_dist);
            defer alloc.free(dist_cmd);
            {
                var di: usize = 0;
                for (planned[0..used], 0..) |p, i| {
                    if (p.kind != .explicit_dist) continue;
                    dist_syms[di] = p.dist_code;
                    dist_cmd[di] = @intCast(i);
                    di += 1;
                }
            }
            const d_alphabet = @as(usize, self.dist_alphabet_limit);
            if (want_cat_split and used >= 512) {
                const seg = try alloc.alloc(u8, used);
                defer alloc.free(seg);
                // Two proposal granularities: coarse (proven clean blocks)
                // and fine (ref-calibrated, finds structure coarse misses).
                // Clustering cleans either; the honest estimate picks.
                const cfgs = [_]struct { min_block: usize, thresh: f64 }{
                    .{ .min_block = 1024, .thresh = 500.0 },
                    .{ .min_block = 530, .thresh = 13.5 },
                };
                var best_bits: usize = std.math.maxInt(usize);
                var best_seg: []u8 = &.{};
                defer {
                    if (best_seg.len != 0) alloc.free(best_seg);
                }
                var best_trees: [][704]u32 = &.{};
                defer {
                    if (best_trees.len != 0) alloc.free(best_trees);
                }
                var best_ntypes: u32 = 0;
                for (cfgs) |cfg| {
                    const k = try planDenseSegments(alloc, cmd_syms, 704, 1, null, 704, MAX_CMD_BLOCK_TYPES, cfg.min_block, cfg.thresh, seg);
                    if (k <= 1) continue;
                    var seg_hist: [MAX_CMD_BLOCK_TYPES][704]u32 = @splat(@splat(0));
                    for (cmd_syms, 0..) |s, li| seg_hist[seg[li]][s] += 1;
                    // Cluster raw types to a clean set: streaming fragments
                    // merge back by gain; the remapped runs coalesce.
                    const first_raw: u8 = seg[0];
                    var remap: [MAX_CMD_BLOCK_TYPES]u8 = undefined;
                    var ntrees_c: u32 = 0;
                    const cand_trees = try alloc.alloc([704]u32, MAX_CMD_BLOCK_TYPES);
                    defer alloc.free(cand_trees);
                    try mergeTreePool(704, alloc, seg_hist[0..k], k, MAX_CMD_BLOCK_TYPES, cand_trees, remap[0..k], &ntrees_c);
                    for (seg) |*v| v.* = remap[v.*];
                    // The format codes the first run's type implicitly as
                    // zero, so swap ids to send the first run's type to zero
                    // (across segment values and tree rows alike).
                    const f_c: u8 = remap[first_raw];
                    if (f_c != 0) {
                        for (seg) |*v| {
                            if (v.* == 0) v.* = f_c else if (v.* == f_c) v.* = 0;
                        }
                        const tmp = cand_trees[0];
                        cand_trees[0] = cand_trees[f_c];
                        cand_trees[f_c] = tmp;
                    }
                    const st = buildSwitchTables(seg);
                    var bits: usize = measureSwitchBits(&st);
                    var t: u32 = 0;
                    while (t < ntrees_c) : (t += 1) {
                        const m = measureTreeBits(cand_trees[t][0..], 704);
                        bits += m.stored + m.payload;
                    }
                    if (bits < best_bits) {
                        best_bits = bits;
                        best_ntypes = ntrees_c;
                        if (best_seg.len != 0) alloc.free(best_seg);
                        if (best_trees.len != 0) alloc.free(best_trees);
                        best_seg = try alloc.dupe(u8, seg);
                        best_trees = try alloc.dupe([704]u32, cand_trees[0..ntrees_c]);
                    }
                }
                {
                    const single = measureTreeBits(ic_freq[0..], 704);
                    if (best_ntypes > 1 and best_bits + 1500 < single.stored + single.payload) {
                        for (best_trees, 0..) |*h, ti| cmd_tree_freq[ti] = h.*;
                        var st = buildSwitchTables(best_seg);
                        st.types_blk = &.{};
                        cmd_split = st;
                        cmd_ntypes = best_ntypes;
                    }
                }
            } else {
                cmd_tree_freq[0] = ic_freq;
            }
            if (cmd_split == null and want_cat_split) {
                // Split undesired or unprofitable; keep the single histogram.
                cmd_tree_freq[0] = ic_freq;
            }
            if (want_cat_split and n_dist >= 256) {
                const seg = try alloc.alloc(u8, n_dist);
                defer alloc.free(seg);
                const dcfgs = [_]struct { min_block: usize, thresh: f64 }{
                    .{ .min_block = 512, .thresh = 100.0 },
                    .{ .min_block = 544, .thresh = 14.6 },
                };
                var dbest_bits: usize = std.math.maxInt(usize);
                var dbest_seg: []u8 = &.{};
                defer {
                    if (dbest_seg.len != 0) alloc.free(dbest_seg);
                }
                var dbest_trees: [][DIST_ALPHABET_MAX]u32 = &.{};
                defer {
                    if (dbest_trees.len != 0) alloc.free(dbest_trees);
                }
                var dbest_ntypes: u32 = 0;
                for (dcfgs) |cfg| {
                    const k = try planDenseSegments(alloc, dist_syms, d_alphabet, 1, null, 64, MAX_DIST_BLOCK_TYPES, cfg.min_block, cfg.thresh, seg);
                    if (k <= 1) continue;
                    var seg_hist: [MAX_DIST_BLOCK_TYPES][DIST_ALPHABET_MAX]u32 = @splat(@splat(0));
                    for (dist_syms, 0..) |s, li| seg_hist[seg[li]][s] += 1;
                    const first_raw_d: u8 = seg[0];
                    var remap: [MAX_DIST_BLOCK_TYPES]u8 = undefined;
                    var ntrees_d: u32 = 0;
                    const cand_trees = try alloc.alloc([DIST_ALPHABET_MAX]u32, MAX_DIST_BLOCK_TYPES);
                    defer alloc.free(cand_trees);
                    try mergeTreePool(DIST_ALPHABET_MAX, alloc, seg_hist[0..k], k, MAX_DIST_BLOCK_TYPES, cand_trees, remap[0..k], &ntrees_d);
                    for (seg) |*v| v.* = remap[v.*];
                    // First run's type is implicit zero (see command path).
                    const f_d: u8 = remap[first_raw_d];
                    if (f_d != 0) {
                        for (seg) |*v| {
                            if (v.* == 0) v.* = f_d else if (v.* == f_d) v.* = 0;
                        }
                        const tmp = cand_trees[0];
                        cand_trees[0] = cand_trees[f_d];
                        cand_trees[f_d] = tmp;
                    }
                    const st = buildSwitchTables(seg);
                    var bits: usize = measureSwitchBits(&st);
                    var t: u32 = 0;
                    while (t < ntrees_d) : (t += 1) {
                        const m = measureTreeBits(cand_trees[t][0..d_alphabet], @intCast(d_alphabet));
                        bits += m.stored + m.payload;
                    }
                    if (bits < dbest_bits) {
                        dbest_bits = bits;
                        dbest_ntypes = ntrees_d;
                        if (dbest_seg.len != 0) alloc.free(dbest_seg);
                        if (dbest_trees.len != 0) alloc.free(dbest_trees);
                        dbest_seg = try alloc.dupe(u8, seg);
                        dbest_trees = try alloc.dupe([DIST_ALPHABET_MAX]u32, cand_trees[0..ntrees_d]);
                    }
                }
                {
                    const single = measureTreeBits(dist_freq[0..d_alphabet], @intCast(d_alphabet));
                    if (dbest_ntypes > 1 and dbest_bits + 15 < single.stored + single.payload) {
                        for (dbest_trees, 0..) |*h, ti| dist_tree_freq[ti] = h.*;
                        var st = buildSwitchTables(dbest_seg);
                        st.types_blk = &.{};
                        dist_split = st;
                        dist_ntypes = dbest_ntypes;
                        for (dbest_seg, dist_cmd) |ty, planned_idx| dist_type_of[planned_idx] = ty;
                    }
                }
            }
            if (dist_split == null) {
                @memcpy(dist_tree_freq[0][0..d_alphabet], dist_freq[0..d_alphabet]);
            }
        }
        // Profitability check against stored representation.
        var cost_bits: usize = lit_bits_best + 64;
        for (planned[0..used]) |p| {
            cost_bits += 8;
            cost_bits += @as(usize, p.ins_nbits) + @as(usize, p.copy_nbits);
            switch (p.kind) {
                .literals_only, .implicit_last => {},
                .explicit_dist => cost_bits += 6 + p.dist_nbits,
            }
        }
        if (cost_bits > mlen * 8 + 32) {
            self.rb = rb_saved;
            return false;
        }
        self.emitBlockHeader(mlen, is_last);
        // Clustered trees win over one-tree-per-type whenever a context map
        // is present (classic and combined paths alike).
        const ntrees_final: u32 = if (cm) |c| c.ntrees else if (split) |s| s.ndistinct else 1;
        if (self.options.quality >= 4) {
            for (0..ntrees_final) |t| {
                huff_enc.optimizeHuffmanCountsForRle(&lit_tree_freq[t]);
            }
            for (0..cmd_ntypes) |t| {
                huff_enc.optimizeHuffmanCountsForRle(&cmd_tree_freq[t]);
            }
            for (0..dist_ntypes) |t| {
                huff_enc.optimizeHuffmanCountsForRle(dist_tree_freq[t][0..self.dist_alphabet_limit]);
            }
        }
        try self.serializeCompressed(
            is_last,
            &lit_tree_freq,
            ntrees_final,
            if (cm) |c| c else null,
            split,
            &cmd_tree_freq,
            cmd_ntypes,
            cmd_split,
            &dist_tree_freq,
            dist_ntypes,
            dist_split,
            dist_type_of,
            planned[0..used],
            data,
        );
        self.stream_pos += mlen;
        self.updatePrev(data);
        return true;
    }
    fn serializeCompressed(
        self: *Encoder,
        is_last: bool,
        lit_tree_freq: *const [MAX_LIT_TREES][256]u32,
        ntrees_lit: u32,
        cm: ?CtxPlan,
        split_param: ?SwitchTables,
        cmd_tree_freq: *const [MAX_CMD_BLOCK_TYPES][704]u32,
        cmd_ntypes: u32,
        cmd_split_param: ?SwitchTables,
        dist_tree_freq: *const [MAX_DIST_BLOCK_TYPES][DIST_ALPHABET_MAX]u32,
        dist_ntypes: u32,
        dist_split_param: ?SwitchTables,
        dist_type_of: []const u8,
        planned: []const PlannedCommand,
        data: []const u8,
    ) !void {
        var split = split_param;
        var cmd_split = cmd_split_param;
        var dist_split = dist_split_param;
        var cl_scratch: [18]u8 = undefined;
        // ISUNCOMPRESSED exists only in non-final metablocks.

        if (!is_last) self.w.put(1, 0);
        var sw_type_depths: [MAX_SWITCH_TYPES + 2]u8 = undefined;
        var sw_type_codes: [MAX_SWITCH_TYPES + 2]u16 = undefined;
        var sw_len_depths: [constants.NUM_BLOCK_LEN_SYMBOLS]u8 = undefined;
        var sw_len_codes: [constants.NUM_BLOCK_LEN_SYMBOLS]u16 = undefined;
        // Emits one category's block-type header: type count, type and length
        // trees, and the initial run length. Type zero is implicit, so only
        // the first run length is coded here.
        const emitSwitchHeader = struct {
            fn go(
                enc: *Encoder,
                s: *SwitchTables,
                w_type_depths: *[MAX_SWITCH_TYPES + 2]u8,
                w_type_codes: *[MAX_SWITCH_TYPES + 2]u16,
                w_len_depths: *[constants.NUM_BLOCK_LEN_SYMBOLS]u8,
                w_len_codes: *[constants.NUM_BLOCK_LEN_SYMBOLS]u16,
                cl: *[18]u8,
            ) !void {
                try enc.putVarLenUint8(s.ndistinct - 1);
                huff_enc.storeHuffmanTree(
                    &enc.w,
                    s.type_freq[0 .. s.ndistinct + 2],
                    s.ndistinct + 2,
                    s.ndistinct + 2,
                    w_type_depths,
                    w_type_codes,
                    cl[0..],
                );
                huff_enc.storeHuffmanTree(
                    &enc.w,
                    &s.len_freq,
                    constants.NUM_BLOCK_LEN_SYMBOLS,
                    constants.NUM_BLOCK_LEN_SYMBOLS,
                    w_len_depths,
                    w_len_codes,
                    cl[0..],
                );
                const lc0 = blockLengthPrefixCode(s.seg_lens[0]);
                enc.w.putBits(@intCast(w_len_depths[lc0]), w_len_codes[lc0]);
                enc.w.putBits(
                    @intCast(prefix_ranges.prefix_code_ranges[lc0].nbits),
                    s.seg_lens[0] - prefix_ranges.prefix_code_ranges[lc0].offset,
                );
            }
        }.go;
        // Literal block types and their switch codes. Type zero is implicit,

        // so only the initial block length is coded here.

        if (split) |*s| {
            try emitSwitchHeader(self, s, &sw_type_depths, &sw_type_codes, &sw_len_depths, &sw_len_codes, &cl_scratch);
        } else {
            self.w.put(1, 0);
            // NBLTYPESL = 1

        }
        // Command block types.
        var cmd_sw_type_depths: [MAX_SWITCH_TYPES + 2]u8 = undefined;
        var cmd_sw_type_codes: [MAX_SWITCH_TYPES + 2]u16 = undefined;
        var cmd_sw_len_depths: [constants.NUM_BLOCK_LEN_SYMBOLS]u8 = undefined;
        var cmd_sw_len_codes: [constants.NUM_BLOCK_LEN_SYMBOLS]u16 = undefined;
        if (cmd_split) |*s| {
            try emitSwitchHeader(self, s, &cmd_sw_type_depths, &cmd_sw_type_codes, &cmd_sw_len_depths, &cmd_sw_len_codes, &cl_scratch);
        } else {
            self.w.put(1, 0);
            // NBLTYPESI = 1

        }
        // Distance block types.
        var dist_sw_type_depths: [MAX_SWITCH_TYPES + 2]u8 = undefined;
        var dist_sw_type_codes: [MAX_SWITCH_TYPES + 2]u16 = undefined;
        var dist_sw_len_depths: [constants.NUM_BLOCK_LEN_SYMBOLS]u8 = undefined;
        var dist_sw_len_codes: [constants.NUM_BLOCK_LEN_SYMBOLS]u16 = undefined;
        if (dist_split) |*s| {
            try emitSwitchHeader(self, s, &dist_sw_type_depths, &dist_sw_type_codes, &dist_sw_len_depths, &dist_sw_len_codes, &cl_scratch);
        } else {
            self.w.put(1, 0);
            // NBLTYPESD = 1

        }
        // NPOSTFIX / NDIRECT as one six-bit field.

        {
            const nd_raw = self.ndirect >> @intCast(self.npostfix);
            self.w.put(6, @as(u64, self.npostfix) | (@as(u64, nd_raw) << 2));
        }
        // One two-bit context mode per literal block type.

        {
            const mode_val: u64 = if (cm) |c| @backingInt(c.mode) else 0;
            const ntypes: usize = if (split) |s| @intCast(s.ndistinct) else 1;
            var t: usize = 0;
            while (t < ntypes) : (t += 1) self.w.put(2, mode_val);
        }
        // Literal tree count and context map.

        try self.putVarLenUint8(ntrees_lit - 1);
        if (split) |s| {
            if (cm) |c| {
                // Combined block-type/context path: the real (type, context)
                // map (clustered), not the per-type identity map.
                try self.emitLiteralContextMap(c.cmap[0 .. @as(usize, s.ndistinct) * 64], ntrees_lit);
            } else {
                var ident: [MAX_LIT_STREAM_TYPES * 64]u8 = undefined;
                for (&ident, 0..) |*e, i| e.* = @intCast(i / 64);
                try self.emitLiteralContextMap(ident[0 .. @as(usize, s.ndistinct) * 64], ntrees_lit);
            }
        } else if (ntrees_lit > 1) {
            const cmv = cm.?;
            const map_len: usize = @as(usize, cmv.lit_ntypes) * 64;
            try self.emitLiteralContextMap(cm.?.cmap[0..map_len], cm.?.ntrees);
        }
        // Distance trees: one per distance block type, selected through an
        // identity context map (type-major over the four distance contexts).
        // A single type keeps the historical single-tree encoding.
        const d_limit_usize: usize = self.dist_alphabet_limit;
        var dist_cmap_buf: [MAX_DIST_BLOCK_TYPES * 4]u8 = undefined;
        for (&dist_cmap_buf, 0..) |*e, i| e.* = @intCast(i / 4);
        const dist_cmap = dist_cmap_buf[0 .. @as(usize, dist_ntypes) * 4];
        try self.putVarLenUint8(dist_ntypes - 1);
        if (dist_ntypes > 1) {
            try self.emitLiteralContextMap(dist_cmap, dist_ntypes);
        }

        // Literal trees, then command, then distance trees.

        var lit_depths: [MAX_LIT_TREES][256]u8 = undefined;
        var lit_codes: [MAX_LIT_TREES][256]u16 = undefined;
        {
            var t: usize = 0;
            while (t < ntrees_lit) : (t += 1) {
                huff_enc.storeHuffmanTree(
                    &self.w,
                    &lit_tree_freq[t],
                    256,
                    256,
                    &lit_depths[t],
                    &lit_codes[t],
                    &cl_scratch,
                );
            }
        }
        const cmd_depths = try self.allocator.alloc(u8, @as(usize, cmd_ntypes) * 704);
        defer self.allocator.free(cmd_depths);
        const cmd_codes = try self.allocator.alloc(u16, @as(usize, cmd_ntypes) * 704);
        defer self.allocator.free(cmd_codes);
        {
            var t: usize = 0;
            while (t < cmd_ntypes) : (t += 1) {
                huff_enc.storeHuffmanTree(
                    &self.w,
                    cmd_tree_freq[t][0..],
                    constants.NUM_COMMAND_SYMBOLS,
                    constants.NUM_COMMAND_SYMBOLS,
                    cmd_depths[t * 704 ..][0..704],
                    cmd_codes[t * 704 ..][0..704],
                    &cl_scratch,
                );
            }
        }
        const d_limit = self.dist_alphabet_limit;
        const d_max = self.dist_alphabet_max;
        const d_depths = try self.allocator.alloc(u8, @as(usize, dist_ntypes) * d_max);
        defer self.allocator.free(d_depths);
        const d_codes = try self.allocator.alloc(u16, @as(usize, dist_ntypes) * d_max);
        defer self.allocator.free(d_codes);
        {
            var t: usize = 0;
            while (t < dist_ntypes) : (t += 1) {
                huff_enc.storeHuffmanTree(
                    &self.w,
                    dist_tree_freq[t][0..d_limit_usize],
                    d_max,
                    d_limit,
                    d_depths[@as(usize, t) * d_max ..][0..d_max],
                    d_codes[@as(usize, t) * d_max ..][0..d_max],
                    &cl_scratch,
                );
            }
        }
        // Emit commands, literals, and distances in stream order, tracking

        // P1/P2 across literals and copies.

        var p1 = self.p1;
        var p2 = self.p2;
        var lit_remaining: u32 = if (split) |s| s.seg_lens[0] else 0;
        var sw_calc = SwitchCalc{};
        var cur_type: u8 = 0;
        // Command block tracking: one switch per type run over commands.
        var cmd_remaining: u32 = if (cmd_split) |s| s.seg_lens[0] else 0;
        var cmd_sw_calc = SwitchCalc{};
        var cur_cmd_type: u8 = 0;
        // Distance block tracking: runs count explicit distances only.
        var dist_remaining: u32 = if (dist_split) |s| s.seg_lens[0] else 0;
        var dist_sw_calc = SwitchCalc{};
        // The implicit first run still advances the switch calculator, exactly
        // as the frequency counting in finishTables does. Without this the
        // emitted switch codes diverge from the transmitted type tree.
        if (split) |s| _ = nextBlockTypeCode(&sw_calc, s.types[0]);
        if (cmd_split) |s| _ = nextBlockTypeCode(&cmd_sw_calc, s.types[0]);
        if (dist_split) |s| _ = nextBlockTypeCode(&dist_sw_calc, s.types[0]);
        // Emits a block-type switch plus the new run length using the given
        // category tables.
        const emitSwitch = struct {
            fn go(
                enc: *Encoder,
                s: *SwitchTables,
                calc: *SwitchCalc,
                t_new: u32,
                w_type_depths: []const u8,
                w_type_codes: []const u16,
                w_len_depths: []const u8,
                w_len_codes: []const u16,
            ) void {
                const tc = nextBlockTypeCode(calc, t_new);
                enc.w.putBits(@intCast(w_type_depths[tc]), w_type_codes[tc]);
                const lc = blockLengthPrefixCode(s.seg_lens[s.seg_idx]);
                enc.w.putBits(@intCast(w_len_depths[lc]), w_len_codes[lc]);
                enc.w.putBits(
                    @intCast(prefix_ranges.prefix_code_ranges[lc].nbits),
                    s.seg_lens[s.seg_idx] - prefix_ranges.prefix_code_ranges[lc].offset,
                );
            }
        }.go;
        var lit_pos: usize = 0;
        for (planned, 0..) |p, pi| {
            if (cmd_remaining == 0 and cmd_split != null) {
                const s = &cmd_split.?;
                const t_new: u32 = s.types[s.seg_idx];
                emitSwitch(self, s, &cmd_sw_calc, t_new, &cmd_sw_type_depths, &cmd_sw_type_codes, &cmd_sw_len_depths, &cmd_sw_len_codes);
                cmd_remaining = s.seg_lens[s.seg_idx];
                cur_cmd_type = @intCast(t_new);
                s.seg_idx += 1;
            }
            cmd_remaining -|= 1;
            const cmd_base: usize = @as(usize, cur_cmd_type) * 704;
            self.w.putBits(@intCast(cmd_depths[cmd_base + p.sym]), cmd_codes[cmd_base + p.sym]);
            self.w.putBits(p.ins_nbits, p.ins_extra);
            self.w.putBits(p.copy_nbits, p.copy_extra);
            const tree_of = struct {
                fn go(plan: ?CtxPlan, prev: u8, prev2: u8) usize {
                    const pl = plan orelse return 0;
                    const cid = context.contextId(prev, prev2, pl.mode);
                    return pl.cmap[cid];
                }
            }.go;
            var li: usize = 0;
            while (li < p.insert_len) : (li += 1) {
                if (lit_remaining == 0 and split != null) {
                    const s = &split.?;
                    const t_new: u32 = s.types[s.seg_idx];
                    const tc = nextBlockTypeCode(&sw_calc, t_new);
                    // Use the header-stored switch tables (sw_*), not the
                    // splitter's own (s.type_*): the header recomputes depths
                    // over the transmitted alphabet slice, and the body must
                    // use exactly those codes.
                    self.w.putBits(@intCast(sw_type_depths[tc]), sw_type_codes[tc]);
                    const lc = blockLengthPrefixCode(s.seg_lens[s.seg_idx]);
                    self.w.putBits(@intCast(sw_len_depths[lc]), sw_len_codes[lc]);
                    self.w.putBits(
                        @intCast(prefix_ranges.prefix_code_ranges[lc].nbits),
                        s.seg_lens[s.seg_idx] - prefix_ranges.prefix_code_ranges[lc].offset,
                    );
                    lit_remaining = s.seg_lens[s.seg_idx];
                    cur_type = @intCast(t_new);
                    s.seg_idx += 1;
                }
                lit_remaining -|= 1;
                const b = data[lit_pos];
                lit_pos += 1;
                // Combined path (block types and a context map): the tree is
                // the map entry for this (type, context) pair. Block types
                // alone use one tree per type; contexts alone use the map.
                const t: usize = if (split != null and cm != null)
                    cm.?.cmap[@as(usize, cur_type) * 64 + context.contextId(p1, p2, cm.?.mode)]
                else if (split != null)
                    cur_type
                else
                    tree_of(cm, p1, p2);
                self.w.putBits(@intCast(lit_depths[t][b]), lit_codes[t][b]);
                p2 = p1;
                p1 = b;
            }
            // Copies advance P1/P2 to the tail of the copied region.

            if (p.copy_len != 0) {
                const end_pos = lit_pos + p.copy_len;
                if (end_pos >= 2) {
                    p1 = data[end_pos - 1];
                    p2 = data[end_pos - 2];
                } else {
                    p1 = data[end_pos - 1];
                    p2 = 0;
                }
                lit_pos = end_pos;
            }
            switch (p.kind) {
                .literals_only, .implicit_last => {},
                .explicit_dist => {
                    if (dist_remaining == 0 and dist_split != null) {
                        const s = &dist_split.?;
                        const t_new: u32 = s.types[s.seg_idx];
                        emitSwitch(self, s, &dist_sw_calc, t_new, &dist_sw_type_depths, &dist_sw_type_codes, &dist_sw_len_depths, &dist_sw_len_codes);
                        dist_remaining = s.seg_lens[s.seg_idx];
                        s.seg_idx += 1;
                    }
                    dist_remaining -|= 1;
                    const dist_type: usize = if (dist_split != null) dist_type_of[pi] else 0;
                    const distctx: usize = prefix.cmd_lut[p.sym].context;
                    const tree: usize = if (dist_ntypes > 1) dist_cmap[dist_type * 4 + distctx] else 0;
                    const d_base: usize = @as(usize, tree) * d_max;
                    self.w.putBits(@intCast(d_depths[d_base + p.dist_code]), d_codes[d_base + p.dist_code]);
                    self.w.putBits(p.dist_nbits, p.dist_extra);
                },
            }
        }
        std.debug.assert(lit_pos == data.len);
    }
    fn putVarLenUint8(self: *Encoder, v: u32) !void {
        try self.reserve(16);
        if (v == 0) {
            self.w.put(1, 0);
            return;
        }
        if (v == 1) {
            self.w.put(1, 1);
            self.w.put(3, 0);
            return;
        }
        const nb: u6 = @intCast(std.math.log2_int(u32, v));
        self.w.put(1, 1);
        self.w.put(3, nb);
        self.w.put(nb, v - (@as(u32, 1) << @intCast(nb)));
    }
    /// Emits the literal context map with optional zero-run-length coding,
    /// keeping the cheapest of several run-length settings. The inverse-MTF
    /// transform is not applied.
    fn emitLiteralContextMap(self: *Encoder, cmap: []const u8, ntrees: u32) !void {
        const alloc = self.allocator;
        const size = cmap.len;
        const RunSym = struct {
            sym: u16,
            extra: u16 = 0,
            nbits: u5 = 0,
        };
        // Try each run-length setting and keep the cheapest.

        var best_rle: u32 = 0;
        // zero means "RLE disabled"

        var best_cost: f64 = std.math.floatMax(f64);
        var best_syms: []RunSym = &.{};
        defer alloc.free(best_syms);
        var rle_opt: u32 = 0;
        while (rle_opt <= 6) : (rle_opt += 1) {
            var syms: std.ArrayList(RunSym) = .empty;
            defer syms.deinit(alloc);
            var cost: f64 = 5;
            // prefix bits + IMTF bit overhead

            if (rle_opt == 0) {
                try syms.ensureTotalCapacity(alloc, size);
                var i: usize = 0;
                while (i < size) : (i += 1) {
                    syms.appendAssumeCapacity(.{ .sym = @as(u16, cmap[i]) + 0 });
                }
            } else {
                const rle_max = rle_opt;
                var i: usize = 0;
                while (i < size) {
                    if (cmap[i] != 0) {
                        try syms.append(alloc, .{ .sym = @as(u16, cmap[i]) + @as(u16, @intCast(rle_max)) });
                        i += 1;
                        continue;
                    }
                    var run: usize = 0;
                    while (i + run < size and cmap[i + run] == 0) run += 1;
                    var left = run;
                    while (left > 0) {
                        if (left == 1) {
                            try syms.append(alloc, .{ .sym = 0 });
                            cost += 2;
                            left -= 1;
                        } else {
                            // Largest representable chunk: reps in 2^c..2^(c+1)-1.

                            var cc: u5 = 1;
                            while (cc + 1 <= rle_max and
                                (@as(usize, 1) << @as(u5, @intCast(cc + 1))) <= left) cc += 1;
                            const base_rep = @as(usize, 1) << cc;
                            var extra = left - base_rep;
                            const max_extra = (@as(usize, 1) << cc) - 1;
                            if (extra > max_extra) extra = max_extra;
                            try syms.append(alloc, .{
                                .sym = cc,
                                .extra = @intCast(extra),
                                .nbits = cc,
                            });
                            cost += 2 + @as(f64, @floatFromInt(cc));
                            left -= base_rep + extra;
                        }
                    }
                    i += run;
                }
            }
            // Entropy estimate over this symbol stream.

            var freq: [constants.MAX_CONTEXT_MAP_SYMBOLS]u32 = @splat(0);
            for (syms.items) |s| freq[s.sym] += 1;
            var total: u64 = 0;
            for (freq) |f| total += f;
            if (total != 0) {
                const log2total: f64 = log2Float(@floatFromInt(total));
                for (freq) |f| {
                    if (f != 0) {
                        const pf: f64 = @floatFromInt(f);
                        cost -= pf * (log2Count(f) - log2total);
                    }
                }
            }
            if (cost < best_cost) {
                best_cost = cost;
                best_rle = rle_opt;
                alloc.free(best_syms);
                best_syms = try syms.toOwnedSlice(alloc);
            }
        }
        const rle_max: u32 = best_rle;
        self.reserve(8) catch return error.BrotliCompressionFailed;
        self.syncW();
        if (rle_max == 0) {
            self.w.put(1, 0);
        } else {
            self.w.put(1, 1);
            self.w.put(4, rle_max - 1);
        }
        const alphabet: u32 = ntrees + rle_max;
        var freq: [constants.MAX_CONTEXT_MAP_SYMBOLS]u32 = @splat(0);
        for (best_syms) |s| freq[s.sym] += 1;
        var depths: [constants.MAX_CONTEXT_MAP_SYMBOLS]u8 = undefined;
        var codes: [constants.MAX_CONTEXT_MAP_SYMBOLS]u16 = undefined;
        var cl_scratch: [18]u8 = undefined;
        huff_enc.storeHuffmanTree(&self.w, freq[0..alphabet], alphabet, alphabet, &depths, &codes, &cl_scratch);
        for (best_syms) |s| {
            self.w.putBits(@intCast(depths[s.sym]), codes[s.sym]);
            self.w.putBits(s.nbits, s.extra);
        }
        self.w.put(1, 0);
        // no inverse MTF

    }
};
// Literal context-modeling helpers
/// Checks whether data is predominantly valid UTF-8.
fn isMostlyUTF8(data: []const u8) bool {
    const sample_len = @min(data.len, 1 << 16);
    return utf8_util.isMostlyUTF8(data[0..sample_len], utf8_util.MIN_UTF8_RATIO);
}
/// Chooses the literal context mode for a metablock: UTF8 modeling unless
/// the data is non-UTF8 binary at the top qualities, which use signed-byte
/// contexts.
fn chooseContextMode(data: []const u8, quality: u32) context.ContextType {
    if (quality >= 10 and !isMostlyUTF8(data)) return .signed;
    return .utf8;
}
/// Per-context histograms over the literal bytes a metablock emits, in
/// emission order starting from the carried P1/P2 state. Copy output jumps
/// P1/P2 to the tail of the copied region without contributing histogram
/// samples, exactly as serialization tracks it, so every emitted literal is
/// counted in the context it is coded with.
fn buildContextHistograms(
    planned: []const PlannedCommand,
    data: []const u8,
    mode: context.ContextType,
    p1_init: u8,
    p2_init: u8,
    out: *[64][256]u32,
) void {
    var p1 = p1_init;
    var p2 = p2_init;
    var lit_pos: usize = 0;
    for (planned) |p| {
        var li: usize = 0;
        while (li < p.insert_len) : (li += 1) {
            const b = data[lit_pos];
            lit_pos += 1;
            const cid = context.contextId(p1, p2, mode);
            out[cid][b] += 1;
            p2 = p1;
            p1 = b;
        }
        if (p.copy_len != 0) {
            const end_pos = lit_pos + p.copy_len;
            if (end_pos >= 2) {
                p1 = data[end_pos - 1];
                p2 = data[end_pos - 2];
            } else {
                p1 = data[end_pos - 1];
                p2 = 0;
            }
            lit_pos = end_pos;
        }
    }
}
fn histEntropy(h: *const [256]u32) f64 {
    var total: u64 = 0;
    for (h) |f| total += f;
    if (total == 0) return 0;
    var e: f64 = 0;
    const log2tf: f64 = log2Float(@floatFromInt(total));
    for (h) |f| {
        if (f != 0) {
            const ff: f64 = @floatFromInt(f);
            e -= ff * (log2Count(f) - log2tf);
        }
    }
    return e;
}
/// Estimated emitted size of a context map in bits.
fn sizeOfContextMapBits(cmap: []const u8) usize {
    var syms: usize = 0;
    var i: usize = 0;
    while (i < cmap.len) {
        if (cmap[i] != 0) {
            syms += 1;
            i += 1;
        } else {
            while (i < cmap.len and cmap[i] == 0) i += 1;
            syms += 1;
        }
    }
    return syms * 4 + 8;
}
/// Serializes one prefix tree into a scratch sink; returns the stored bit
/// count plus the weighted payload bit count.
fn measureTreeBits(freqs: []const u32, alphabet: u32) struct { stored: usize, payload: usize } {
    var buf: [16384]u8 = @splat(0);
    var w = huff_enc.BitSink{ .buf = &buf };
    var depths: [MAX_ALPHABET_SCRATCH]u8 = undefined;
    var codes: [MAX_ALPHABET_SCRATCH]u16 = undefined;
    var cl: [18]u8 = undefined;
    huff_enc.storeHuffmanTree(&w, freqs, alphabet, alphabet, &depths, &codes, &cl);
    var payload: usize = 0;
    for (freqs, 0..) |f, s| {
        if (f != 0) payload += @as(usize, f) * depths[s];
    }
    return .{ .stored = w.pos, .payload = payload };
}
/// First quality level that pays for a cost-based parse search.
/// Longest literal run the parse search will consider closing a match after;
/// longer runs stay as separate literal commands as the greedy parse emits.
const COST_PARSE_MIN_QUALITY: u32 = 10;
const cost_parse_max_insert: usize = 0;
const Layout = enum { plain, cm_w, split_w, combined };
const MAX_ALPHABET_SCRATCH = 704;
/// Greedy bottom-up clustering of context histograms into at most
/// `MAX_LIT_TREES` trees. Produces the per-tree frequencies and the
/// 64-entry context map.
fn clusterContexts(
    ctx_hist: *const [64][256]u32,
    lit_tree_freq: *[MAX_LIT_TREES][256]u32,
    cmap: *[64]u8,
    ntrees_out: *u32,
) void {
    // Working state: up to 64 singleton clusters.

    var hists: [64][256]u32 = undefined;
    var members: [64]u64 = undefined;
    // bitmask of contexts in each cluster

    var ent: [64]f64 = undefined;
    var alive: [64]bool = @splat(false);
    var ctx_cluster: [64]usize = undefined;
    var count: usize = 0;
    for (0..64) |c| {
        var total: u64 = 0;
        for (ctx_hist[c]) |f| total += f;
        if (total == 0) {
            cmap[c] = 0;
            ctx_cluster[c] = std.math.maxInt(usize);
            continue;
        }
        hists[count] = ctx_hist[c];
        members[count] = @as(u64, 1) << @intCast(c);
        ent[count] = histEntropy(&hists[count]);
        ctx_cluster[c] = count;
        alive[count] = true;
        count += 1;
    }
    if (count == 0) {
        ntrees_out.* = 1;
        return;
    }
    // Beneficial merges first. Terminates via the breaks below: forced
    // reduction while over the tree cap, else only while some pair saves
    // more than the clustering threshold.
    while (true) {
        var best_i: usize = 0;
        var best_j: usize = 0;
        var best_gain: f64 = 0;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            if (!alive[i]) continue;
            var j = i + 1;
            while (j < 64) : (j += 1) {
                if (!alive[j]) continue;
                var merged: [256]u32 = undefined;
                for (0..256) |k| merged[k] = hists[i][k] + hists[j][k];
                const gain = ent[i] + ent[j] - histEntropy(&merged);
                if (gain > best_gain) {
                    best_gain = gain;
                    best_i = i;
                    best_j = j;
                }
            }
        }
        if (count > MAX_LIT_TREES) {
            // Forced reduction: take whatever pair exists.

            if (best_j == 0 and best_i == 0 and best_gain == 0) {
                // find any two alive

                outer: for (0..64) |a| {
                    if (!alive[a]) continue;
                    var b = a + 1;
                    while (b < 64) : (b += 1) {
                        if (alive[b]) {
                            best_i = a;
                            best_j = b;
                            break :outer;
                        }
                    }
                }
            }
        } else if (best_gain <= CLUSTER_MIN_SAVING) {
            break;
        } else if (best_j <= best_i) {
            // no beneficial pair found (best_* remain zero-initialized)

            if (best_gain == 0) break;
        }
        if (best_i == best_j) break;
        // Merge j into i.

        for (0..256) |k| hists[best_i][k] += hists[best_j][k];
        members[best_i] |= members[best_j];
        ent[best_i] = histEntropy(&hists[best_i]);
        alive[best_j] = false;
        count -= 1;
        if (count == 1) break;
    }
    // Dense-remap surviving clusters by descending size into tree slots.

    const Slot = struct { idx: usize, total: u64 };
    var slots: [MAX_LIT_TREES]Slot = undefined;
    var used: usize = 0;
    for (0..64) |c| {
        if (!alive[c]) continue;
        var total: u64 = 0;
        for (hists[c]) |f| total += f;
        if (used < MAX_LIT_TREES) {
            slots[used] = .{ .idx = c, .total = total };
            used += 1;
        } else {
            // Replace the smallest slot when this cluster is larger.

            var min_k: usize = 0;
            for (1..used) |k| {
                if (slots[k].total < slots[min_k].total) min_k = k;
            }
            if (total > slots[min_k].total) {
                slots[min_k] = .{ .idx = c, .total = total };
            }
        }
    }
    std.mem.sort(Slot, slots[0..used], {}, struct {
        fn lt(_: void, a: Slot, b: Slot) bool {
            return a.total > b.total;
        }
    }.lt);
    for (lit_tree_freq[0..]) |*t| t.* = @splat(0);
    for (slots[0..used], 0..) |slot, t| {
        lit_tree_freq[t] = hists[slot.idx];
    }
    var map: [64]u8 = @splat(0);
    for (0..used) |t| {
        var mset = members[slots[t].idx];
        while (mset != 0) {
            const c = @ctz(mset);
            mset &= mset - 1;
            map[c] = @intCast(t);
        }
    }
    cmap.* = map;
    ntrees_out.* = @max(1, @as(u32, @intCast(used)));
}
/// Jointly merges a pool of histogram trees (e.g., per-type context clusters)
/// into at most `max_trees` by best entropy gain, with incremental pair
/// updates so large pools stay practical. Outputs the merged frequencies and
/// `remap` (pool index -> final tree). Same gain criterion and threshold as
/// the context clusterer, so the two stages agree on what a merge is worth.
fn mergeTreePool(
    comptime ALPH: usize,
    allocator: std.mem.Allocator,
    pool: [][ALPH]u32,
    npool: usize,
    max_trees: usize,
    out_freq: [][ALPH]u32,
    remap: []u8,
    ntrees_out: *u32,
) !void {
    if (npool == 0) {
        ntrees_out.* = 1;
        return;
    }
    const work = try allocator.alloc([ALPH]u32, npool);
    defer allocator.free(work);
    for (pool[0..npool], 0..) |*h, i| work[i] = h.*;
    const ent = try allocator.alloc(f64, npool);
    defer allocator.free(ent);
    const alive = try allocator.alloc(bool, npool);
    defer allocator.free(alive);
    const at = try allocator.alloc(usize, npool);
    defer allocator.free(at);
    for (0..npool) |i| {
        ent[i] = histEntropyN(&work[i]);
        alive[i] = true;
        at[i] = i;
    }
    // Pair gains, maintained incrementally: only the merged cluster's row
    // and column are recomputed per round; the global best is a cheap rescan
    // (no logarithms).
    const gains = try allocator.alloc(f64, npool * npool);
    defer allocator.free(gains);
    @memset(gains, -1e300);
    var i: usize = 0;
    while (i < npool) : (i += 1) {
        var j = i + 1;
        while (j < npool) : (j += 1) {
            var merged: [ALPH]u32 = undefined;
            for (0..ALPH) |k| merged[k] = work[i][k] + work[j][k];
            gains[i * npool + j] = ent[i] + ent[j] - histEntropyN(&merged);
        }
    }
    var count = npool;
    while (count > 1) {
        var best_gain: f64 = -1e300;
        var best_i: usize = 0;
        var best_j: usize = 0;
        var a: usize = 0;
        while (a < npool) : (a += 1) {
            if (!alive[a]) continue;
            var b = a + 1;
            while (b < npool) : (b += 1) {
                if (!alive[b]) continue;
                const g = gains[a * npool + b];
                if (g > best_gain) {
                    best_gain = g;
                    best_i = a;
                    best_j = b;
                }
            }
        }
        if (count <= max_trees and best_gain <= CLUSTER_MIN_SAVING) break;
        // Merge j into i.
        for (0..ALPH) |k| work[best_i][k] += work[best_j][k];
        ent[best_i] = histEntropyN(&work[best_i]);
        alive[best_j] = false;
        for (0..npool) |o| {
            if (at[o] == best_j) at[o] = best_i;
        }
        count -= 1;
        // Recompute the merged cluster's pairs.
        var c: usize = 0;
        while (c < npool) : (c += 1) {
            if (!alive[c] or c == best_i) continue;
            var merged: [ALPH]u32 = undefined;
            for (0..ALPH) |k| merged[k] = work[best_i][k] + work[c][k];
            const g = ent[best_i] + ent[c] - histEntropyN(&merged);
            if (c < best_i) {
                gains[c * npool + best_i] = g;
            } else {
                gains[best_i * npool + c] = g;
            }
        }
    }
    // Dense-remap survivors by descending size.
    const Slot = struct { idx: usize, total: u64 };
    const slots = try allocator.alloc(Slot, count);
    defer allocator.free(slots);
    var used: usize = 0;
    for (0..npool) |c| {
        if (!alive[c]) continue;
        var total: u64 = 0;
        for (work[c]) |f| total += f;
        slots[used] = .{ .idx = c, .total = total };
        used += 1;
    }
    std.mem.sort(Slot, slots[0..used], {}, struct {
        fn lt(_: void, x: Slot, y: Slot) bool {
            return x.total > y.total;
        }
    }.lt);
    const new_id_of = try allocator.alloc(usize, npool);
    defer allocator.free(new_id_of);
    for (slots[0..used], 0..) |slot, t| {
        out_freq[t] = work[slot.idx];
        new_id_of[slot.idx] = t;
    }
    for (0..npool) |o| remap[o] = @intCast(new_id_of[at[o]]);
    ntrees_out.* = @max(1, @as(u32, @intCast(used)));
}
test "mergeTreePool merges identical, keeps opposite" {
    const alloc = std.testing.allocator;
    // Two identical histograms (payload-neutral merge, covered by saved tree
    // overhead) plus one opposite-peaked histogram (merging costs ~1755 bits).
    var pool: [3][8]u32 = @splat(@splat(0));
    pool[0][0] = 1000;
    pool[0][1] = 1000;
    pool[1][0] = 1000;
    pool[1][1] = 1000;
    pool[2][2] = 1000;
    var out: [3][8]u32 = undefined;
    var remap: [3]u8 = undefined;
    var ntrees: u32 = 0;
    try mergeTreePool(8, alloc, pool[0..], 3, 3, out[0..], remap[0..], &ntrees);
    try std.testing.expectEqual(@as(u32, 2), ntrees);
    try std.testing.expectEqual(remap[0], remap[1]);
    try std.testing.expect(remap[2] != remap[0]);
    // Merged tree equals the summed histogram; lone tree is untouched.
    var sum: [8]u32 = @splat(0);
    sum[0] = 2000;
    sum[1] = 2000;
    try std.testing.expectEqualSlices(u32, sum[0..], out[remap[0]][0..]);
    try std.testing.expectEqualSlices(u32, pool[2][0..], out[remap[2]][0..]);
}
/// Upper bound on compressed size for a given input size.
pub fn maxCompressedSize(input_size: usize) usize {
    if (input_size == 0) return 2;
    const num_large_blocks = input_size >> 14;
    const overhead = 2 + 4 * num_large_blocks + 4;
    const result = input_size +% overhead;
    if (result < input_size) return 0;
    return result;
}
/// Compress a complete byte slice in one call with default options.
pub fn compress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return compressWithOptions(allocator, input, .{});
}
/// Compress a complete byte slice in one call with explicit options.
pub fn compressWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
) ![]u8 {
    var enc = Encoder.init(allocator, options);
    defer enc.deinit();
    enc.options.sizeHint = input.len;
    enc.compressStream(.finish, input) catch return error.BrotliCompressionError;
    const n = enc.out.items.len - enc.out_pos;
    const result = try allocator.alloc(u8, n);
    @memcpy(result, enc.out.items[enc.out_pos..]);
    enc.out_pos = enc.out.items.len;
    return result;
}
const testing = std.testing;
test "distance encoding covers small distances" {
    const e1 = encodeCopyDistance(1, 0, 0).?;
    try testing.expectEqual(@as(u32, 16), e1.sym);
    try testing.expectEqual(@as(u32, 0), e1.extra);
    const e2 = encodeCopyDistance(2, 0, 0).?;
    try testing.expectEqual(@as(u32, 16), e2.sym);
    try testing.expectEqual(@as(u32, 1), e2.extra);
    const e3 = encodeCopyDistance(3, 0, 0).?;
    try testing.expectEqual(@as(u32, 17), e3.sym);
}
test "distance encoding round-trips through offsets" {
    // Verify symbol/extra pairs against an independently built LUT for

    // several postfix/direct configurations.

    inline for (.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 4 }, .{ 3, 120 }, .{ 0, 24 } }) |cfg| {
        const np: u32 = cfg[0];
        const nd_raw: u32 = cfg[1];
        const nd: u32 = nd_raw << @intCast(np);
        var d: u32 = 1;
        while (d < 100000) : (d += 1) {
            const enc = encodeCopyDistance(d, nd, np) orelse continue;
            // Rebuild the decoder offset for this symbol.

            const postfix = @as(u32, 1) << @intCast(np);
            var off: u32 = undefined;
            var nbits: u5 = undefined;
            if (enc.sym < constants.NUM_DISTANCE_SHORT_CODES + nd) {
                try testing.expect(d == enc.sym - constants.NUM_DISTANCE_SHORT_CODES + 1);
                continue;
            }
            const rel = enc.sym - constants.NUM_DISTANCE_SHORT_CODES - nd;
            const group = rel >> np;
            const pv = rel & (postfix - 1);
            nbits = @intCast((group >> 1) + 1);
            const half: u32 = group & 1;
            off = nd + (((2 + half) << @intCast(nbits)) - 4) * postfix + 1 + pv;
            const dist = off + (@as(u32, enc.extra) << @intCast(np));
            try testing.expectEqual(d, dist);
            try testing.expectEqual(enc.nbits, nbits);
        }
    }
}
test "command maps cover every insert/copy combination" {
    var ic: usize = 0;
    while (ic < 24) : (ic += 1) {
        var jc: usize = 0;
        while (jc < 24) : (jc += 1) {
            try testing.expect(cmd_maps.explicit_sym[ic][jc] != 0xFFFF);
        }
    }
}
test "long runs become single copy commands" {
    // The format expresses copy lengths up to 2^24; a long run must become
    // one copy, not thousands of capped chunks. Guards the match-length cap.
    const allocator = testing.allocator;
    const zeros = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(zeros);
    @memset(zeros, 0);
    const comp = try compressWithOptions(allocator, zeros, .{ .quality = 9 });
    defer allocator.free(comp);
    // One copy plus headers fits easily in 64 bytes; capped chunks need 200+.
    try testing.expect(comp.len < 64);
    const decoded = try decoder.decompress(allocator, comp);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, zeros, decoded);

    var period: [100000]u8 = undefined;
    for (&period, 0..) |*b, i| b.* = @intCast(i % 251);
    const comp2 = try compressWithOptions(allocator, &period, .{ .quality = 9 });
    defer allocator.free(comp2);
    const decoded2 = try decoder.decompress(allocator, comp2);
    defer allocator.free(decoded2);
    try testing.expectEqualSlices(u8, &period, decoded2);
}
test "cost parse never regresses the greedy parse" {
    // The optimal parser must account for insert-run literals; otherwise it
    // adopts pathologically cheap-looking parses that serialize much larger.
    // Mixed-entropy data exposed a 3.5x blowup from uncharged insert runs.
    const allocator = testing.allocator;
    var input: [60000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    for (&input, 0..) |*b, i| {
        b.* = if (i % 7 == 0) prng.random().int(u8) else @truncate((i / 3) & 0xFF);
    }
    const greedy = try compressWithOptions(allocator, &input, .{ .quality = 9 });
    defer allocator.free(greedy);
    const best = try compressWithOptions(allocator, &input, .{ .quality = 11 });
    defer allocator.free(best);
    // Top quality must not serialize dramatically worse than the greedy base
    // it refines; allow modest modeling slack.
    try testing.expect(best.len * 10 <= greedy.len * 12);
    const decoded = try decoder.decompress(allocator, best);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, &input, decoded);
}
test "switch tables count distinct types, not runs" {
    // Runs may revisit a type (A,B,A); headers, trees, and context maps must
    // use the distinct count, while the switch sequence uses the runs.
    const seg = [_]u8{ 0, 0, 1, 1, 1, 0, 0, 2, 2, 1 };
    const st = buildSwitchTables(&seg);
    try testing.expectEqual(@as(u32, 5), st.ntypes);
    try testing.expectEqual(@as(u32, 3), st.ndistinct);
    try testing.expectEqual(@as(u8, 0), st.types[0]);
    try testing.expectEqual(@as(u8, 1), st.types[1]);
    try testing.expectEqual(@as(u8, 0), st.types[2]);
    try testing.expectEqual(@as(u8, 2), st.types[3]);
    try testing.expectEqual(@as(u8, 1), st.types[4]);
    try testing.expectEqual(@as(u32, 2), st.seg_lens[0]);
    try testing.expectEqual(@as(u32, 3), st.seg_lens[1]);
    try testing.expectEqual(@as(u32, 2), st.seg_lens[2]);
    try testing.expectEqual(@as(u32, 2), st.seg_lens[3]);
    try testing.expectEqual(@as(u32, 1), st.seg_lens[4]);
}
test "emitted switch codes always exist in the transmitted type tree" {
    // The implicit first run advances the switch calculator exactly as the
    // frequency counting does. Without that rotation the emitter produces
    // codes the tree never describes (zero frequency), corrupting the stream.
    const segs = [_][]const u8{
        &.{ 0, 0, 1, 1, 0, 0 },
        &.{ 0, 1, 2, 0, 1, 2 },
        &.{ 0, 0, 0, 1, 1, 1 },
        &.{ 1, 1, 0, 0, 2, 2 },
    };
    for (segs) |seg| {
        const st = buildSwitchTables(seg);
        // First run is implicit but still rotates the calculator.
        var calc = SwitchCalc{};
        _ = nextBlockTypeCode(&calc, st.types[0]);
        var r: usize = 1;
        while (r < st.ntypes) : (r += 1) {
            const tc = nextBlockTypeCode(&calc, st.types[r]);
            // Every emitted switch code must have been counted when the type
            // tree was built; otherwise the tree carries no code for it and
            // the bit writer emits nothing, desynchronizing the stream.
            // (A zero depth is fine only for a single-symbol 0-bit code,
            // which still has nonzero frequency.)
            try testing.expect(st.type_freq[tc] != 0);
        }
    }
}
const decoder = @import("../decompress/decode.zig");
fn roundTripAt(input: []const u8, quality: u32, lg_win: u32) !void {
    const allocator = testing.allocator;
    const compressed = try compressWithOptions(allocator, input, .{
        .quality = quality,
        .lgWin = lg_win,
    });
    defer allocator.free(compressed);
    // The documented bound plus room for metablock headers on tiny inputs.

    const bound = @max(maxCompressedSize(input.len), input.len * 2 + 1024);
    try testing.expect(compressed.len <= bound);
    const decoded = try decoder.decompress(allocator, compressed);
    defer allocator.free(decoded);
    testing.expectEqualSlices(u8, input, decoded) catch |e| {
        std.debug.print("input {d} bytes at quality {d} wbits {d}: {any}\n", .{
            input.len, quality, lg_win, e,
        });
        return e;
    };
}
fn roundTrip(input: []const u8, quality: u32) !void {
    return roundTripAt(input, quality, 22);
}
test "round trips every generated payload at every quality level" {
    const allocator = testing.allocator;
    // Generate once per payload (not per quality): formatting thousands of
    // rows per quality level dominates Debug suite time.
    for (payload_names) |name| {
        const payload = try generatePayload(allocator, name);
        defer allocator.free(payload);
        var q: u32 = 0;
        while (q <= 11) : (q += 1) {
            if (@import("builtin").mode == .debug) {
                if (q >= 10 and payload.len > 32768) continue;
            }
            try roundTrip(payload, q);
        }
    }
}
test "round trips highly compressible and incompressible payloads" {
    const allocator = testing.allocator;
    const repetitive: [70_000]u8 = @splat(0xAB);
    const zeros: [40_000]u8 = @splat(0);
    var random: [50_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(20_240_917);
    prng.random().bytes(&random);
    var prng2 = std.Random.DefaultPrng.init(7);
    var mixed: [65_536]u8 = undefined;
    for (&mixed, 0..) |*b, i| {
        b.* = if (i % 7 == 0) prng2.random().int(u8) else @truncate(i / 3);
    }
    const payloads = [_][]const u8{ &repetitive, &zeros, &random, &mixed };
    inline for (.{ 0, 1, 2, 5, 9, 11 }) |quality| {
        for (payloads) |payload| {
            const compressed = try compressWithOptions(allocator, payload, .{ .quality = quality });
            defer allocator.free(compressed);
            const decoded = try decoder.decompress(allocator, compressed);
            defer allocator.free(decoded);
            try testing.expectEqualSlices(u8, payload, decoded);
        }
    }
}
test "matches never cross a metablock boundary" {
    // Payload larger than one metablock; matches must stay inside the block.
    // (End-bounding is size-independent, so this stays small for fast suites.)

    const allocator = testing.allocator;
    const total = (64 << 10) + 4096;
    const payload = try allocator.alloc(u8, total);
    defer allocator.free(payload);
    inline for (.{ 0, 2, 5, 9, 11 }) |quality| {
        for (payload, 0..) |*b, i| {
            b.* = switch (i % 211) {
                0 => 'A',
                1 => 'B',
                2 => 'C',
                3 => 'D',
                else => @truncate(i *% 31 +% (i >> 5)),
            };
        }
        const compressed = try compressWithOptions(allocator, payload, .{ .quality = quality });
        defer allocator.free(compressed);
        const decoded = try decoder.decompress(allocator, compressed);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, payload, decoded);
    }
}
test "round trips across every supported window size" {
    const payload = try generatePayload(testing.allocator, "rep_periodic");
    defer testing.allocator.free(payload);
    var padded: [9000]u8 = undefined;
    for (&padded, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 3));
    inline for (.{ 10, 12, 16, 18, 20, 22, 24 }) |w| {
        try roundTripAt(payload, 9, w);
        try roundTripAt(&padded, 5, w);
        try roundTripAt(&padded, 11, w);
    }
}
test "large window streams round trip" {
    var payload: [40_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1234);
    for (&payload) |*b| b.* = prng.random().intRangeAtMost(u8, 'a', 'z');
    inline for (.{ 25, 28, 30 }) |w| {
        const allocator = testing.allocator;
        const compressed = try compressWithOptions(allocator, &payload, .{
            .quality = 11,
            .lgWin = w,
            .largeWindow = true,
        });
        defer allocator.free(compressed);
        const decoded = try decoder.decompressWithOptions(allocator, compressed, .{ .largeWindow = true });
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, &payload, decoded);
    }
}
test "every encoder alphabet fits the fixed Huffman workspace" {
    // `generateCodeLengths` sizes its working arrays from MAX_ALPHABET, so no

    // alphabet the encoder builds may exceed it. The distance alphabet is the

    // one that grows with parameters, and it is capped before use.

    try testing.expectEqual(constants.NUM_COMMAND_SYMBOLS, huff_enc.MAX_ALPHABET);
    try testing.expect(DIST_ALPHABET_MAX <= huff_enc.MAX_ALPHABET);
    try testing.expect(constants.NUM_LITERAL_SYMBOLS <= huff_enc.MAX_ALPHABET);
    try testing.expect(constants.NUM_BLOCK_LEN_SYMBOLS <= huff_enc.MAX_ALPHABET);
    try testing.expect(constants.MAX_BLOCK_TYPE_SYMBOLS <= huff_enc.MAX_ALPHABET);
    try testing.expect(constants.MAX_CONTEXT_MAP_SYMBOLS <= huff_enc.MAX_ALPHABET);
    try testing.expect(constants.CODE_LENGTH_CODES <= huff_enc.MAX_ALPHABET);
}
test "distance alphabet stays within the cap for every parameter combination" {
    const npostfix_values = [_]u32{ 0, 1, 2, 3 };
    const ndirect_values = [_]u32{ 0, 4, 30, 60, 120 };
    const window_bits_values = [_]u32{ 10, 16, 22, 24, 25, 30 };
    for (window_bits_values) |wbits| {
        for (npostfix_values) |np| {
            for (ndirect_values) |nd| {
                const limit = constants.calculateDistanceCodeLimit(
                    (@as(u32, 1) << @intCast(wbits)) - constants.WINDOW_GAP,
                    np,
                    nd,
                );
                try testing.expect(limit.max_alphabet_size <= DIST_ALPHABET_MAX);
                try testing.expect(limit.max_alphabet_size <= huff_enc.MAX_ALPHABET);
                // The widest theoretical distance alphabet (large window).

                const wide = constants.distanceAlphabetSize(
                    np,
                    nd,
                    constants.LARGE_MAX_DISTANCE_BITS,
                );
                const capped = @min(wide, DIST_ALPHABET_MAX);
                try testing.expect(capped <= huff_enc.MAX_ALPHABET);
            }
        }
    }
}
test "extreme distance parameters round trip at every window size" {
    const allocator = testing.allocator;
    var src: [30_000]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate((i / 13) % 173);
    const combos = [_][2]u32{
        .{ 0, 0 },
        .{ 0, 120 },
        .{ 1, 0 },
        .{ 1, 120 },
        .{ 2, 60 },
        .{ 3, 120 },
        .{ 3, 0 },
        .{ 0, 60 },
    };
    for (window_bits_values_under_test()) |wbits| {
        for (combos, 0..) |combo, ci| {
            const q: u32 = if (ci == 0) 11 else 5;
            const compressed = try compressWithOptions(allocator, &src, .{
                .quality = q,
                .lgWin = wbits,
                .largeWindow = wbits > 24,
                .nPostfix = combo[0],
                .nDirect = combo[1],
            });
            defer allocator.free(compressed);
            const decoded = try decoder.decompressWithOptions(allocator, compressed, .{
                .largeWindow = wbits > 24,
            });
            defer allocator.free(decoded);
            try testing.expectEqualSlices(u8, &src, decoded);
        }
    }
}
fn window_bits_values_under_test() []const u32 {
    return &.{ 10, 16, 24, 25, 30 };
}
const Payload = struct {
    name: []const u8,
    data: []const u8,
};
/// Deterministic byte source. A plain LCG keeps the output identical across
/// Zig versions, unlike the standard library generators.
const Rng = struct {
    s: u64,
    fn init(seed: u64) Rng {
        return .{ .s = seed };
    }
    fn next(self: *Rng) u64 {
        self.s = self.s *% 6364136223846793005 +% 1442695040888963407;
        return self.s >> 17;
    }
    fn fill(self: *Rng, out: []u8) void {
        var i: usize = 0;
        while (i < out.len) {
            const v = self.next();
            const n = @min(8, out.len - i);
            var b: usize = 0;
            while (b < n) : (b += 1) {
                out[i + b] = @truncate(v >> @intCast(b * 8));
            }
            i += n;
        }
    }
    fn below(self: *Rng, n: u32) u32 {
        return @intCast(self.next() % n);
    }
};
const words = [_][]const u8{
    "the",
    "quick",
    "brown",
    "fox",
    "jumps",
    "over",
    "lazy",
    "dog",
    "while",
    "brotli",
    "compresses",
    "the",
    "stream",
    "with",
    "a",
    "backwards",
    "reference",
    "into",
    "sliding",
    "window",
    "dictionary",
    "the",
    "encoder",
    "builds",
    "huffman",
    "tree",
    "per",
    "alphabet",
    "and",
    "emits",
    "literals",
    "or",
    "matches",
    "according",
    "to",
    "a",
    "cost",
    "model",
    "at",
    "quality",
    "eleven",
    "also",
    "supports",
    "static",
    "dictionaries",
    "transforms",
    "and",
    "shared",
    "dictionaries",
    "for",
    "small",
    "payloads",
};
fn writeText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), n: usize, seed: u64) !void {
    var rng = Rng.init(seed);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, words[rng.below(words.len)]);
    }
}
fn generatePayload(allocator: std.mem.Allocator, which: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (std.mem.eql(u8, which, "empty")) {
        // nothing

    } else if (std.mem.eql(u8, which, "one_byte")) {
        try out.append(allocator, 'a');
    } else if (std.mem.eql(u8, which, "tiny")) {
        try out.appendSlice(allocator, "hello brotli");
    } else if (std.mem.eql(u8, which, "text_en")) {
        try writeText(allocator, &out, 19_800, 0x9E3779B97F4A7C15);
    } else if (std.mem.eql(u8, which, "text_utf8")) {
        for ([_][]const u8{
            "\u{0421}\u{044a}\u{0435}\u{0448}\u{044c} \u{0436}\u{0435} \u{0435}\u{0449}\u{0451} ",
            "\u{03b7} \u{03b6} \u{03b7} \u{03c3}\u{03c4}\u{03b7}\u{03bd} ",
            "\u{6c38}\u{56fd}\u{9645}\u{5b57}\u{5178}\u{538b}\u{7f29}\u{6d4b}\u{8bd5}\u{6570}\u{636e} ",
            "\u{0645}\u{0631}\u{062d}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645} ",
        }) |snippet| {
            for (0..60) |_| try out.appendSlice(allocator, snippet);
        }
    } else if (std.mem.eql(u8, which, "rep_periodic")) {
        for (0..8_000) |_| try out.appendSlice(allocator, "ABCD");
    } else if (std.mem.eql(u8, which, "rep_single")) {
        try out.appendNTimes(allocator, 0, 32_768);
    } else if (std.mem.eql(u8, which, "rle")) {
        try out.appendNTimes(allocator, 7, 32_768);
        for (0..100) |_| try out.appendSlice(allocator, "tail marker");
    } else if (std.mem.eql(u8, which, "random")) {
        try out.appendNTimes(allocator, 0, 32_768);
        var rng = Rng.init(0xDEADBEEFCAFEF00D);
        rng.fill(out.items);
    } else if (std.mem.eql(u8, which, "random_skewed")) {
        var rng = Rng.init(0x0123456789ABCDEF);
        for (0..32_768) |_| {
            const r = rng.below(1000);
            try out.append(allocator, if (r < 800) @as(u8, 42) else @intCast(r % 251));
        }
    } else if (std.mem.eql(u8, which, "records")) {
        var rng = Rng.init(0x5EED1234ABCD0001);
        var i: u32 = 0;
        while (i < 1_000) : (i += 1) {
            try out.print(allocator, "{d},{d},{d}\n", .{ i, i *% 7 % 100_003, rng.below(1_000_000) });
        }
    } else if (std.mem.eql(u8, which, "table_csv")) {
        try out.appendSlice(allocator, "id,name,email,city,country,balance\n");
        var i: u32 = 0;
        while (i < 1_000) : (i += 1) {
            try out.print(
                allocator,
                "{d},user{d},user{d}@example.com,City{d},Country{d},{d}\n",
                .{ i, i, i, i % 97, i % 13, i *% 3 % 100_000 },
            );
        }
    } else if (std.mem.eql(u8, which, "nested_json")) {
        var i: u32 = 1;
        while (i < 300) : (i += 1) {
            try out.print(
                allocator,
                "{{\"k{d}\":{{\"a\":{d},\"b\":[{d},{d},{d}],\"c\":\"value {d}\"}},",
                .{ i, i, i, i + 1, i + 2, i },
            );
        }
        try out.appendSlice(allocator, "{\"end\":true}");
    } else if (std.mem.eql(u8, which, "dict_friendly")) {
        for ([_][]const u8{
            "time year people way day man thing woman life child world school ",
            "state family student group country problem hand part place case week ",
            "company system program question work government number night point ",
            "home water room mother area money story fact month lot right study ",
            "book eye job word business issue side kind head house service friend ",
        }) |snippet| {
            for (0..50) |_| try out.appendSlice(allocator, snippet);
        }
    } else if (std.mem.eql(u8, which, "blocky")) {
        try out.appendSlice(allocator, "the quick brown fox jumps over the lazy dog ");
        for (0..40) |_| try out.appendSlice(allocator, "the quick brown fox jumps over the lazy dog ");
        try out.append(allocator, '\n');
        for (0..1_000) |_| {
            try out.appendSlice(allocator, "the quick brown fox jumps over the lazy dog ");
            try out.append(allocator, '\n');
        }
    } else if (std.mem.eql(u8, which, "large_mixed")) {
        // Spans several metablocks and straddles a block boundary, which is
        // where a match finder that ignores the boundary produces bad commands.
        var rng = Rng.init(0x1234ABCD5678EF90);
        const total = (64 << 10) + 4096;
        try out.appendNTimes(allocator, 0, total);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            out.items[i] = switch (i % 211) {
                0 => 'A',
                1 => 'B',
                2 => 'C',
                3 => 'D',
                else => blk: {
                    if (i % 997 == 0) break :blk @truncate(rng.next());
                    break :blk @truncate(i *% 31 +% (i >> 5));
                },
            };
        }
    } else if (std.mem.eql(u8, which, "zeros_ukkonooa")) {
        // A long literal-free run followed by a word, the shape that exposed
        // the chunk-resumption and block-boundary handling.
        try out.appendNTimes(allocator, 0, 32_768);
        try out.appendSlice(allocator, "ukkonooa");
    } else {
        return error.UnknownPayload;
    }
    return out.toOwnedSlice(allocator);
}
/// Every generated payload, in a fixed order.
const payload_names = [_][]const u8{
    "empty",
    "one_byte",
    "tiny",
    "text_en",
    "text_utf8",
    "rep_periodic",
    "rep_single",
    "rle",
    "random",
    "random_skewed",
    "records",
    "table_csv",
    "nested_json",
    "dict_friendly",
    "blocky",
    "large_mixed",
    "zeros_ukkonooa",
};
test "higher qualities do not blow up structured input" {
    // Structured input must round-trip at every quality, and the top

    // qualities must stay within 20% of the best mid-quality size.

    const allocator = testing.allocator;
    var buf: [220_000]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        buf[i] = switch (i % 997) {
            0 => '{',
            1 => '}',
            2 => ':',
            3 => ',',
            4 => '"',
            else => @truncate('0' + (i / 37) % 10),
        };
    }
    // Make it structured enough that matches dominate.

    for (0..buf.len / 64) |k| {
        const base = k * 64;
        @memcpy(buf[base..][0..30], "{\"k\":{\"a\":000,\"b\":[00,00,00]},");
    }
    const payload = buf[0..];
    var sizes: [12]usize = @splat(0);
    for (0..12) |q| {
        const c = try compressWithOptions(allocator, payload, .{ .quality = @intCast(q) });
        sizes[q] = c.len;
        defer allocator.free(c);
        const d = try decoder.decompress(allocator, c);
        defer allocator.free(d);
        try testing.expectEqualSlices(u8, payload, d);
    }
    // The top qualities must stay within 20% of the best mid-quality size.

    const worst_top = @max(sizes[10], sizes[11]);
    const best_mid = @min(sizes[5], sizes[9]);
    try testing.expect(worst_top * 10 <= best_mid * 12);
}
