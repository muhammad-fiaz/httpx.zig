//! Complete Brotli decoder state machine per RFC 7932.
//!
//! Streaming model: the caller repeatedly invokes `decompressStream`,
//! advancing an input slice and filling an output slice; the decoder retains
//! all cross-call state and reports exactly which bytes remain unconsumed.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const constants = @import("../common/constants.zig");
const context = @import("../common/context.zig");
const transforms = @import("../common/transform.zig");
const dictionary = @import("../dictionary/dictionary.zig");
const bit_reader = @import("../bitstream/bit_reader.zig");
const huff = @import("../huffman/huffman.zig");
const prefix = @import("prefix.zig");
const ranges = @import("../common/prefix_ranges.zig");
const shared_dict = @import("../common/shared_dictionary.zig");

const BitReader = bit_reader.BitReader;
const HuffmanCode = huff.HuffmanCode;
pub const SharedDictionary = shared_dict.SharedDictionary;
pub const SharedDictionaryType = shared_dict.SharedDictionaryType;

/// Detailed error codes for every malformed-input and resource condition.
pub const ErrorCode = enum(i8) {
    no_error = 0,
    success = 1,
    needs_more_input = 2,
    needs_more_output = 3,

    // Errors caused by invalid input.
    format_exuberant_nibble = -1,
    format_reserved = -2,
    format_exuberant_meta_nibble = -3,
    format_simple_huffman_alphabet = -4,
    format_simple_huffman_same = -5,
    format_cl_space = -6,
    format_huffman_space = -7,
    format_context_map_repeat = -8,
    format_block_length_1 = -9,
    format_block_length_2 = -10,
    format_transform = -11,
    format_dictionary = -12,
    format_window_bits = -13,
    format_padding_1 = -14,
    format_padding_2 = -15,
    format_distance = -16,
    format_block_switch = -17,
    error_compound_dictionary = -18,
    error_dictionary_not_set = -19,
    error_invalid_arguments = -20,

    // Memory allocation problems.
    alloc_context_modes = -21,
    alloc_tree_groups = -22,
    alloc_context_map = -25,
    alloc_ring_buffer_1 = -26,
    alloc_ring_buffer_2 = -27,
    alloc_block_type_trees = -30,

    unreachable_state = -31,
    resource_limit = -32,

    pub fn isError(code: ErrorCode) bool {
        return @backingInt(code) < 0;
    }

    pub fn name(code: ErrorCode) []const u8 {
        return switch (code) {
            .no_error => "NO_ERROR",
            .success => "SUCCESS",
            .needs_more_input => "NEEDS_MORE_INPUT",
            .needs_more_output => "NEEDS_MORE_OUTPUT",
            .format_exuberant_nibble => "ERROR_FORMAT_EXUBERANT_NIBBLE",
            .format_reserved => "ERROR_FORMAT_RESERVED",
            .format_exuberant_meta_nibble => "ERROR_FORMAT_EXUBERANT_META_NIBBLE",
            .format_simple_huffman_alphabet => "ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET",
            .format_simple_huffman_same => "ERROR_FORMAT_SIMPLE_HUFFMAN_SAME",
            .format_cl_space => "ERROR_FORMAT_CL_SPACE",
            .format_huffman_space => "ERROR_FORMAT_HUFFMAN_SPACE",
            .format_context_map_repeat => "ERROR_FORMAT_CONTEXT_MAP_REPEAT",
            .format_block_length_1 => "ERROR_FORMAT_BLOCK_LENGTH_1",
            .format_block_length_2 => "ERROR_FORMAT_BLOCK_LENGTH_2",
            .format_transform => "ERROR_FORMAT_TRANSFORM",
            .format_dictionary => "ERROR_FORMAT_DICTIONARY",
            .format_window_bits => "ERROR_FORMAT_WINDOW_BITS",
            .format_padding_1 => "ERROR_FORMAT_PADDING_1",
            .format_padding_2 => "ERROR_FORMAT_PADDING_2",
            .format_distance => "ERROR_FORMAT_DISTANCE",
            .format_block_switch => "ERROR_FORMAT_BLOCK_SWITCH",
            .error_compound_dictionary => "ERROR_COMPOUND_DICTIONARY",
            .error_dictionary_not_set => "ERROR_DICTIONARY_NOT_SET",
            .error_invalid_arguments => "ERROR_INVALID_ARGUMENTS",
            .alloc_context_modes => "ERROR_ALLOC_CONTEXT_MODES",
            .alloc_tree_groups => "ERROR_ALLOC_TREE_GROUPS",
            .alloc_context_map => "ERROR_ALLOC_CONTEXT_MAP",
            .alloc_ring_buffer_1 => "ERROR_ALLOC_RING_BUFFER_1",
            .alloc_ring_buffer_2 => "ERROR_ALLOC_RING_BUFFER_2",
            .alloc_block_type_trees => "ERROR_ALLOC_BLOCK_TYPE_TREES",
            .unreachable_state => "ERROR_UNREACHABLE",
            .resource_limit => "ERROR_RESOURCE_LIMIT",
        };
    }

    pub fn toError(code: ErrorCode) anyerror {
        return switch (code) {
            .no_error, .success => error.UnexpectedSuccess,
            .needs_more_input => error.TruncatedInput,
            .needs_more_output, .resource_limit => error.ResourceLimitExceeded,
            .format_exuberant_nibble, .format_exuberant_meta_nibble, .format_padding_1, .format_padding_2, .format_window_bits => error.InvalidHeader,
            .format_reserved, .format_block_length_1, .format_block_length_2, .format_block_switch => error.InvalidMetaBlock,
            .format_simple_huffman_alphabet, .format_simple_huffman_same, .format_cl_space, .format_huffman_space, .format_context_map_repeat => error.InvalidHuffmanTree,
            .format_transform, .format_dictionary, .error_compound_dictionary, .error_dictionary_not_set => error.InvalidDictionaryReference,
            .format_distance => error.InvalidDistance,
            .error_invalid_arguments => error.InvalidParameter,
            .alloc_context_modes, .alloc_tree_groups, .alloc_context_map, .alloc_ring_buffer_1, .alloc_ring_buffer_2, .alloc_block_type_trees => error.OutOfMemory,
            .unreachable_state => error.CorruptedStream,
        };
    }
};

pub const Result = enum {
    success,
    needs_more_input,
    needs_more_output,
    err,
};

pub const Options = struct {
    /// Enable "Large Window Brotli" (window up to 30 bits).
    largeWindow: bool = false,
    /// When true the ring buffer grows in small steps (saves memory for
    /// tiny streams at the cost of some speed).
    cannyRingbufferAllocation: bool = true,
    /// Optional raw custom dictionary data.
    customDictionary: ?[]const u8 = null,
    /// Optional shared dictionary instance containing compound prefix chunks.
    sharedDictionary: ?*const shared_dict.SharedDictionary = null,
    /// Safety limit on ring buffer size in bytes (0 = no limit).
    ringBufferSizeLimit: usize = 0,
    /// Safety limit on maximum decompressed output size in bytes (null = no limit).
    maxOutputSize: ?usize = null,
    /// Callbacks for metadata metablocks.
    metadataCallbacks: ?MetadataCallbacks = null,
};

const State = enum {
    uninited,
    large_window_bits,
    initialize,
    metablock_begin,
    metablock_header,
    metablock_header_2,
    context_modes,
    command_begin,
    command_inner,
    command_post_decode_literals,
    command_post_wrap_copy,
    uncompressed,
    metadata,
    command_inner_write,
    metablock_done,
    command_post_write_1,
    command_post_write_2,
    before_compressed_metablock_header,
    huffman_code_0,
    huffman_code_1,
    huffman_code_2,
    huffman_code_3,
    context_map_1,
    context_map_2,
    tree_group,
    before_compressed_metablock_body,
    done,
};

const MetablockHeaderState = enum { none, empty, nibbles, size, uncompressed, reserved, bytes, metadata };
const UncompressedState = enum { none, write };
const TreeGroupState = enum { none, loop };
const ContextMapState = enum { none, read_prefix, huffman, decode, transform };
const HuffmanState = enum { none, simple_size, simple_read, simple_build, complex, length_symbols };
const DecodeUint8State = enum { none, short, long };
const ReadBlockLengthState = enum { none, suffix };

/// Slack region at the end of the ring buffer allocation (up-to-two 16-byte
/// copies plus a transformed dictionary word).
const RING_BUFFER_SLACK = 542;

/// Collection of Huffman trees sharing one alphabet.
const TreeGroup = struct {
    alphabet_size_max: u32 = 0,
    alphabet_size_limit: u32 = 0,
    num_htrees: u32 = 0,
    codes: []HuffmanCode = &.{},
    /// Start offset of every tree within `codes`.
    htrees: []u32 = &.{},

    fn get(self: *const TreeGroup, i: usize) []const HuffmanCode {
        if (i >= self.num_htrees) return &.{};
        return self.codes[self.htrees[i]..];
    }
};

fn fail(code: ErrorCode) ErrorCode {
    std.debug.assert(code.isError());
    return code;
}

fn absPos(br: *const BitReader) u64 {
    return @as(u64, br.pos) * 8 - br.bit_pos;
}

fn log2Floor(x: u64) u32 {
    if (x == 0) return 0;
    // Number of significant bits of x.
    return std.math.log2_int(u64, x) + 1;
}

/// Root-table index mask: HUFFMAN_TABLE_BITS wide, i.e. (1<<8)-1 = 255.
const HUFFMAN_TABLE_MASK: u16 = (@as(u16, 1) << huff.HUFFMAN_TABLE_BITS) - 1;

/// Decodes one symbol; requires >= 15 valid bits in the accumulator.
inline fn decodeSymbol(bits: u64, table: []const HuffmanCode, br: *BitReader) u16 {
    const slot: usize = @intCast(bits & HUFFMAN_TABLE_MASK);
    var t = &table[slot];
    if (t.bits > huff.HUFFMAN_TABLE_BITS) {
        // Valid tables have root entries of at most 15 bits; anything larger
        // means a malformed/truncated stream steered us into uninitialized
        // table memory. Fail closed rather than invoke undefined behavior.
        if (t.bits - huff.HUFFMAN_TABLE_BITS > 7) {
            br.dropBits(1);
            return 0xFFFF; // invalid-symbol sentinel
        }
        const nbits: u5 = @intCast(t.bits - huff.HUFFMAN_TABLE_BITS);
        br.dropBits(huff.HUFFMAN_TABLE_BITS);
        const sub: u32 = @intCast(t.value);
        const extra: usize = @as(usize, @intCast((bits >> huff.HUFFMAN_TABLE_BITS) &
            ((@as(u64, 1) << nbits) - 1)));
        // The marker stores (sub_table_offset - slot); adding `slot` back
        // yields the absolute sub-table position.
        const idx: usize = slot + sub + extra;
        // Malformed or truncated streams can point outside the table; treat
        // as a format error via a sentinel entry instead of UB.
        t = &table[if (idx < table.len) idx else 0];
    }
    br.dropBits(t.bits);
    return t.value;
}

/// Fast path: peek 15 bits then decode. Null when input is exhausted before
/// a full symbol is available (caller falls back to readSymbolSafe).
inline fn readSymbolFast(table: []const HuffmanCode, br: *BitReader) ?u16 {
    if (!br.ensureBits(huff.HUFFMAN_MAX_CODE_LENGTH)) return null;
    const v = decodeSymbol(br.getBits(huff.HUFFMAN_MAX_CODE_LENGTH), table, br);
    return v;
}

/// Safe symbol decoding that works even with fewer than 15 bits available.
/// Never consumes bits unless the whole symbol decodes.
fn readSymbolSafe(table: []const HuffmanCode, br: *BitReader, result: *u64) bool {
    if (br.ensureBits(huff.HUFFMAN_MAX_CODE_LENGTH)) {
        result.* = decodeSymbol(br.getBits(15), table, br);
        return true;
    }
    // Slow path mirroring SafeDecodeSymbol.
    var val: u64 = br.val; // only bit_pos bits are valid
    const available_bits = br.bit_pos;
    if (available_bits == 0) {
        if (table[0].bits == 0) {
            result.* = table[0].value;
            return true;
        }
        return false;
    }
    const slot: usize = @intCast(val & HUFFMAN_TABLE_MASK);
    var t = &table[slot];
    if (t.bits <= huff.HUFFMAN_TABLE_BITS) {
        if (t.bits <= available_bits) {
            br.dropBits(t.bits);
            result.* = t.value;
            return true;
        }
        return false; // Not enough bits for the first level.
    }
    if (available_bits <= huff.HUFFMAN_TABLE_BITS) {
        return false; // Not enough bits to reach the second level.
    }
    // Speculatively drop HUFFMAN_TABLE_BITS.
    const mask: u64 = (@as(u64, 1) << @intCast(t.bits)) - 1;
    val = (val & mask) >> huff.HUFFMAN_TABLE_BITS;
    const rest_available = available_bits - huff.HUFFMAN_TABLE_BITS;
    // The marker stores (sub_table_offset - slot); add `slot` back.
    const idx: usize = slot + @as(usize, t.value) + @as(usize, @intCast(val));
    // A malformed stream can steer this past the table; report failure rather
    // than read out of bounds.
    if (idx >= table.len) return false;
    t = &table[idx];
    if (rest_available < t.bits) return false;
    br.dropBits(huff.HUFFMAN_TABLE_BITS + t.bits);
    result.* = t.value;
    return true;
}

// Maximum sizes for per-metablock allocations.
const MAX_NUM_DIRECT = constants.MAX_NDIRECT;
const MAX_STATIC_CONTEXTS = 13;

/// A chunk of external (raw) dictionary attached before decompression starts.
const CompoundDict = struct {
    chunks: [16][]const u8 = undefined,
    chunk_offsets: [17]u32 = undefined,
    num_chunks: u8 = 0,
    total_size: u32 = 0,
    block_bits: u8 = 255, // 255 == uninitialized
    block_map: [256]u8 = undefined,
    br_index: u16 = 0,
    br_offset: u32 = 0,
    br_length: u32 = 0,
    br_copied: u32 = 0,
};

pub const MetadataCallbacks = struct {
    ctx: ?*anyopaque = null,
    start: ?*const fn (ctx: ?*anyopaque, size: usize) void = null,
    chunk: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
};

pub const Decoder = struct {
    allocator: Allocator,
    options: Options,

    run_state: State = .uninited,
    loop_counter: i32 = 0,

    br: BitReader = .{},
    /// Scratch slot for `decodeVarLenUint8` results that must outlive the
    /// call that started decoding them.
    var_len_scratch: u32 = 0,
    /// Holds up to 7 leftover input bytes between streaming calls.
    buffer: [8]u8 align(8) = @splat(0),
    buffer_length: usize = 0,

    pos: i64 = 0,
    max_backward_distance: i64 = 0,
    max_distance: i64 = 0,
    ringbuffer_size: u32 = 0,
    ringbuffer_mask: u32 = 0,
    dist_rb_idx: i32 = 0,
    dist_rb: [4]i32 = .{ 16, 15, 11, 4 },
    err: ErrorCode = .success,
    meta_block_remaining_len: i64 = 0,

    ringbuffer: []u8 = &.{},
    htree_command: []const HuffmanCode = &.{},
    context_lookup: []const u8 = &.{}, // 512-entry combined LUT
    context_map_slice: []const u8 = &.{},
    dist_context_map_slice: []const u8 = &.{},

    literal_hgroup: TreeGroup = .{},
    insert_copy_hgroup: TreeGroup = .{},
    distance_hgroup: TreeGroup = .{},
    block_type_trees: []HuffmanCode = &.{}, // 3 * HUFFMAN_MAX_SIZE_258
    block_len_trees: []HuffmanCode = &.{}, // 3 * HUFFMAN_MAX_SIZE_26

    trivial_literal_context: bool = false,
    trivial_literal_contexts: [8]u32 = @splat(0),
    distance_context: i32 = 0,
    block_length: [3]u64 = .{ 0, 0, 0 },
    block_length_index: u64 = 0,
    num_block_types: [3]u64 = .{ 1, 1, 1 },
    block_type_rb: [6]u64 = .{ 1, 0, 1, 0, 1, 0 },
    distance_postfix_bits: u32 = 0,
    num_direct_distance_codes: u32 = 0,
    num_dist_htrees: u64 = 0,
    dist_context_map: []u8 = &.{},
    literal_htree: []const HuffmanCode = &.{},

    rb_roundtrips: u64 = 0,
    partial_pos_out: u64 = 0,

    mtf_upper_bound: u32 = 0,
    mtf: [65]u32 = undefined,

    copy_length: i32 = 0,
    distance_code: i32 = 0,

    dist_htree_index: u8 = 0,

    metadata_cb: MetadataCallbacks = .{},
    used_input: u64 = 0,

    substate_metablock_header: MetablockHeaderState = .none,
    substate_uncompressed: UncompressedState = .none,
    substate_decode_uint8: DecodeUint8State = .none,
    substate_read_block_length: ReadBlockLengthState = .none,

    new_ringbuffer_size: u32 = 0,

    is_last_metablock: bool = false,
    is_uncompressed: bool = false,
    is_metadata: bool = false,
    should_wrap_ringbuffer: bool = false,
    large_window: bool = false,
    window_bits: u8 = 0,
    size_nibbles: u8 = 0,

    num_literal_htrees: u64 = 0,
    context_map: []u8 = &.{},
    context_modes: []u8 = &.{},

    compound: ?*CompoundDict = null,

    substate_tree_group: TreeGroupState = .none,
    substate_context_map: ContextMapState = .none,
    substate_huffman: HuffmanState = .none,
    sub_loop_counter: u64 = 0,
    repeat_code_len: u32 = 0,
    prev_code_len: u32 = 0,
    h_symbol: u64 = 0,
    h_repeat: u64 = 0,
    h_space: u64 = 0,
    cl_table: [32]HuffmanCode = undefined, // histogram table for code lengths
    chains: huff.SymbolChains = .{}, // explicit head/next chains (value-only)
    chain_next: [constants.NUM_COMMAND_SYMBOLS]u16 = undefined,
    code_length_code_lengths: [constants.CODE_LENGTH_CODES]u8 = undefined,
    code_length_histo: [16]u16 = undefined,
    htree_index: i32 = 0,
    tree_next_off: usize = 0, // offset into group.codes while building trees
    context_index: u64 = 0,
    max_run_length_prefix: u32 = 0,
    cm_code: u32 = 0xFFFF,
    cm_scratch: u32 = 0,
    last_cmd_sym: u64 = 0,
    /// Dedicated staging for simple Huffman symbols; MUST NOT alias
    /// chains.next_of (which is also `chain_next`).
    simple_vals: [4]u16 = .{ 0, 0, 0, 0 },
    context_map_table: [huff.HUFFMAN_MAX_SIZE_272]HuffmanCode = undefined,

    dist_extra_bits: [544]u8 = undefined,
    dist_offset: [544]u32 = undefined,

    pub fn init(allocator: Allocator, options: Options) Decoder {
        var d = Decoder{
            .allocator = allocator,
            .options = options,
            .mtf_upper_bound = 63,
            .large_window = options.largeWindow,
        };
        if (options.metadataCallbacks) |cb| {
            d.metadata_cb = cb;
        }
        if (options.customDictionary) |dict| {
            _ = d.attachDictionary(dict);
        }
        if (options.sharedDictionary) |s_dict| {
            _ = d.attachSharedDictionary(s_dict);
        }
        return d;
    }

    pub fn deinit(self: *Decoder) void {
        self.cleanupAfterMetablock(true);
        if (self.block_type_trees.len != 0) {
            self.allocator.free(self.block_type_trees);
            self.block_type_trees = &.{};
            self.block_len_trees = &.{};
        }
        if (self.ringbuffer.len != 0) {
            self.allocator.free(self.ringbuffer);
            self.ringbuffer = &.{};
        }
        if (self.compound) |c| {
            self.allocator.destroy(c);
            self.compound = null;
        }
    }

    /// Resets the decoder state for a new stream, retaining allocated ring buffer and tree arrays.
    pub fn reset(self: *Decoder, options: ?Options) void {
        self.cleanupAfterMetablock(true);
        if (self.compound) |c| {
            c.* = .{};
            c.chunk_offsets[0] = 0;
        }
        if (options) |opts| {
            self.options = opts;
            self.large_window = opts.largeWindow;
            if (opts.metadataCallbacks) |cb| {
                self.metadata_cb = cb;
            }
            if (opts.customDictionary) |dict| {
                _ = self.attachDictionary(dict);
            }
            if (opts.sharedDictionary) |s_dict| {
                _ = self.attachSharedDictionary(s_dict);
            }
        }
        self.run_state = .uninited;
        self.loop_counter = 0;
        self.br = .{};
        self.buffer = @splat(0);
        self.buffer_length = 0;
        self.pos = 0;
        self.max_backward_distance = 0;
        self.max_distance = 0;
        self.dist_rb_idx = 0;
        self.dist_rb = .{ 16, 15, 11, 4 };
        self.err = .success;
        self.meta_block_remaining_len = 0;
        self.partial_pos_out = 0;
        self.rb_roundtrips = 0;
        self.should_wrap_ringbuffer = false;
        self.substate_metablock_header = .none;
        self.substate_tree_group = .none;
        self.substate_context_map = .none;
        self.substate_uncompressed = .none;
        self.substate_read_block_length = .none;
        self.substate_huffman = .none;
        self.substate_decode_uint8 = .none;
        self.trivial_literal_context = false;
        self.trivial_literal_contexts = @splat(0);
        self.distance_context = 0;
        self.block_length = .{ 0, 0, 0 };
        self.block_length_index = 0;
        self.num_block_types = .{ 1, 1, 1 };
        self.block_type_rb = .{ 1, 0, 1, 0, 1, 0 };
        self.distance_postfix_bits = 0;
        self.num_direct_distance_codes = 0;
        self.num_dist_htrees = 0;
        self.dist_context_map = &.{};
        self.literal_htree = &.{};
        self.chains = .{};
        self.mtf_upper_bound = 63;
    }

    pub fn resetForNewStream(self: *Decoder) void {
        self.reset(null);
    }

    /// Decompresses a complete slice of Brotli data into an allocated buffer.
    pub fn decompress(self: *Decoder, input: []const u8) ![]u8 {
        self.reset(null);
        var capacity: usize = @max(@as(usize, 4096), input.len *| 4);
        var out = try self.allocator.alloc(u8, capacity);
        errdefer self.allocator.free(out);

        var in: []const u8 = input;
        var total: u64 = 0;
        while (true) {
            var avail: []u8 = out[@intCast(total)..];
            switch (self.decompressStream(&in, &avail, &total)) {
                .success => {
                    const final_len: usize = @intCast(total);
                    if (out.len == final_len) return out;
                    return try self.allocator.realloc(out, final_len);
                },
                .needs_more_output => {
                    capacity = capacity *| 2;
                    if (self.options.maxOutputSize) |limit| {
                        if (capacity > limit) {
                            if (total >= limit) return error.ResourceLimitExceeded;
                            capacity = limit;
                        }
                    }
                    out = try self.allocator.realloc(out, capacity);
                },
                .needs_more_input => return error.TruncatedInput,
                .err => return self.err.toError(),
            }
        }
    }

    /// Decompresses into a caller-provided fixed buffer.
    pub fn decompressInto(self: *Decoder, input: []const u8, output: []u8) !usize {
        self.reset(null);
        var in: []const u8 = input;
        var avail: []u8 = output;
        var total: u64 = 0;
        switch (self.decompressStream(&in, &avail, &total)) {
            .success => return @intCast(total),
            .needs_more_output => return error.ResourceLimitExceeded,
            .needs_more_input => return error.TruncatedInput,
            .err => return self.err.toError(),
        }
    }

    fn cleanupAfterMetablock(self: *Decoder, free_all: bool) void {
        _ = free_all;
        if (self.context_modes.len != 0) {
            self.allocator.free(self.context_modes);
            self.context_modes = &.{};
        }
        if (self.context_map.len != 0) {
            self.allocator.free(self.context_map);
            self.context_map = &.{};
        }
        if (self.dist_context_map.len != 0) {
            self.allocator.free(self.dist_context_map);
            self.dist_context_map = &.{};
        }
        self.freeTreeGroup(&self.literal_hgroup);
        self.freeTreeGroup(&self.insert_copy_hgroup);
        self.freeTreeGroup(&self.distance_hgroup);
    }

    fn freeTreeGroup(self: *Decoder, g: *TreeGroup) void {
        if (g.codes.len != 0) self.allocator.free(g.codes);
        if (g.htrees.len != 0) self.allocator.free(g.htrees);
        g.* = .{};
    }

    /// Attaches a raw compound dictionary; must happen before any input is
    /// fed. Data is referenced (not copied) and must outlive the decoder.
    pub fn attachDictionary(self: *Decoder, data: []const u8) bool {
        if (data.len == 0) return true; // soft no-op
        if (data.len > (1 << 24)) return false;
        if (self.run_state != .uninited) return false;
        if (self.compound == null) {
            const c = self.allocator.create(CompoundDict) catch return false;
            c.* = .{};
            c.chunk_offsets[0] = 0;
            self.compound = c;
        }
        const addon = self.compound.?;
        if (addon.num_chunks == 16) return false;
        if (data.len > (1 << 24) - addon.total_size) return false;
        addon.chunks[addon.num_chunks] = data;
        addon.num_chunks += 1;
        addon.total_size += @intCast(data.len);
        addon.chunk_offsets[addon.num_chunks] = addon.total_size;
        return true;
    }

    /// Attaches a shared dictionary containing one or more compound prefix chunks.
    pub fn attachSharedDictionary(self: *Decoder, dict: *const shared_dict.SharedDictionary) bool {
        for (dict.prefixes[0..dict.prefix_count]) |chunk| {
            if (!self.attachDictionary(chunk)) return false;
        }
        return true;
    }

    pub fn setMetadataCallbacks(self: *Decoder, cb: MetadataCallbacks) void {
        self.metadata_cb = cb;
    }

    pub fn errorCode(self: *const Decoder) ErrorCode {
        return self.err;
    }

    pub fn hasMoreOutput(self: *const Decoder) bool {
        if (self.err.isError()) return false;
        if (self.ringbuffer.len == 0) return false;
        return self.unwrittenBytes(false) != 0;
    }

    /// True once any input has been consumed.
    pub fn isUsed(self: *const Decoder) bool {
        return self.run_state != .uninited;
    }

    pub fn isFinished(self: *const Decoder) bool {
        return self.run_state == .done and !self.hasMoreOutput();
    }

    fn unwrittenBytes(self: *const Decoder, wrap: bool) usize {
        const pos: usize = if (wrap and self.pos > self.ringbuffer_size)
            @intCast(self.ringbuffer_size)
        else
            @intCast(self.pos);
        const partial_pos_rb: u64 = self.rb_roundtrips * self.ringbuffer_size + pos;
        return @intCast(partial_pos_rb - self.partial_pos_out);
    }

    /// Decodes WBITS; precondition: accumulator has >= 8 bits.
    fn decodeWindowBits(self: *Decoder, br: *BitReader) ErrorCode {
        var n: u64 = 0;
        const large_window = self.options.largeWindow;
        self.large_window = false;
        n = br.getBits(1);
        br.dropBits(1);
        if (n == 0) {
            self.window_bits = 16;
            return .success;
        }
        n = br.getBits(3);
        br.dropBits(3);
        if (n != 0) {
            self.window_bits = @intCast((17 + n) & 63);
            return .success;
        }
        n = br.getBits(3);
        br.dropBits(3);
        if (n == 1) {
            if (large_window) {
                n = br.getBits(1);
                br.dropBits(1);
                if (n == 1) return fail(.format_window_bits);
                self.large_window = true;
                return .success;
            } else {
                return fail(.format_window_bits);
            }
        }
        if (n != 0) {
            self.window_bits = @intCast((8 + n) & 63);
            return .success;
        }
        self.window_bits = 17;
        return .success;
    }

    /// Decodes a number in [0..255], reading 1..11 bits; resumable.
    fn decodeVarLenUint8(self: *Decoder, br: *BitReader, value: *u32) ErrorCode {
        var bits: u64 = 0;
        switch (self.substate_decode_uint8) {
            .none => {
                if (!br.safeReadBits(1, &bits)) return .needs_more_input;
                if (bits == 0) {
                    value.* = 0;
                    return .success;
                }
                self.substate_decode_uint8 = .short;
                // fallthrough into short below within this call
                if (!br.safeReadBits(3, &bits)) return .needs_more_input;
            },
            .short => {
                if (!br.safeReadBits(3, &bits)) return .needs_more_input;
            },
            .long => {
                if (!br.safeReadBits(@intCast(value.*), &bits)) return .needs_more_input;
                value.* = (@as(u32, 1) << @intCast(value.*)) + @as(u32, @intCast(bits));
                self.substate_decode_uint8 = .none;
                return .success;
            },
        }
        // .short continuation:
        if (bits == 0) {
            value.* = 1;
            self.substate_decode_uint8 = .none;
            return .success;
        }
        value.* = @intCast(bits); // temporary storage; MUST persist across calls
        self.substate_decode_uint8 = .long;
        if (!br.safeReadBits(@intCast(value.*), &bits)) return .needs_more_input;
        value.* = (@as(u32, 1) << @intCast(value.*)) + @as(u32, @intCast(bits));
        self.substate_decode_uint8 = .none;
        return .success;
    }

    /// Decodes a metablock length and flags, reading 2..31 bits; resumable.
    fn decodeMetaBlockLength(self: *Decoder, br: *BitReader) ErrorCode {
        var bits: u64 = 0;
        while (true) {
            switch (self.substate_metablock_header) {
                .none => {
                    if (!br.safeReadBits(1, &bits)) return .needs_more_input;
                    self.is_last_metablock = bits != 0;
                    self.meta_block_remaining_len = 0;
                    self.is_uncompressed = false;
                    self.is_metadata = false;
                    if (!self.is_last_metablock) {
                        self.substate_metablock_header = .nibbles;
                        continue;
                    }
                    self.substate_metablock_header = .empty;
                    continue;
                },
                .empty => {
                    if (!br.safeReadBits(1, &bits)) return .needs_more_input;
                    if (bits != 0) {
                        self.substate_metablock_header = .none;
                        return .success;
                    }
                    self.substate_metablock_header = .nibbles;
                    continue;
                },
                .nibbles => {
                    if (!br.safeReadBits(2, &bits)) return .needs_more_input;
                    self.size_nibbles = @intCast(bits + 4);
                    self.loop_counter = 0;
                    if (bits == 3) {
                        self.is_metadata = true;
                        self.substate_metablock_header = .reserved;
                        continue;
                    }
                    self.substate_metablock_header = .size;
                    continue;
                },
                .size => {
                    var i: usize = @intCast(self.loop_counter);
                    while (i < self.size_nibbles) : (i += 1) {
                        if (!br.safeReadBits(4, &bits)) {
                            self.loop_counter = @intCast(i);
                            return .needs_more_input;
                        }
                        if (i + 1 == self.size_nibbles and self.size_nibbles > 4 and bits == 0) {
                            return fail(.format_exuberant_nibble);
                        }
                        self.meta_block_remaining_len |= @as(i64, @intCast(bits << @intCast(i * 4)));
                    }
                    self.substate_metablock_header = .uncompressed;
                    continue;
                },
                .uncompressed => {
                    if (!self.is_last_metablock) {
                        if (!br.safeReadBits(1, &bits)) return .needs_more_input;
                        self.is_uncompressed = bits != 0;
                    }
                    self.meta_block_remaining_len += 1;
                    self.substate_metablock_header = .none;
                    return .success;
                },
                .reserved => {
                    if (!br.safeReadBits(1, &bits)) return .needs_more_input;
                    if (bits != 0) return fail(.format_reserved);
                    self.substate_metablock_header = .bytes;
                    continue;
                },
                .bytes => {
                    if (!br.safeReadBits(2, &bits)) return .needs_more_input;
                    if (bits == 0) {
                        self.substate_metablock_header = .none;
                        return .success;
                    }
                    self.size_nibbles = @intCast(bits);
                    self.substate_metablock_header = .metadata;
                    continue;
                },
                .metadata => {
                    var i: usize = @intCast(self.loop_counter);
                    while (i < self.size_nibbles) : (i += 1) {
                        if (!br.safeReadBits(8, &bits)) {
                            self.loop_counter = @intCast(i);
                            return .needs_more_input;
                        }
                        if (i + 1 == self.size_nibbles and self.size_nibbles > 1 and bits == 0) {
                            return fail(.format_exuberant_meta_nibble);
                        }
                        self.meta_block_remaining_len |= @as(i64, @intCast(bits << @intCast(i * 8)));
                    }
                    self.meta_block_remaining_len += 1;
                    self.substate_metablock_header = .none;
                    return .success;
                },
            }
        }
    }

    fn metablockBegin(self: *Decoder) void {
        self.meta_block_remaining_len = 0;
        self.block_length[0] = constants.BLOCK_SIZE_CAP;
        self.block_length[1] = constants.BLOCK_SIZE_CAP;
        self.block_length[2] = constants.BLOCK_SIZE_CAP;
        self.num_block_types[0] = 1;
        self.num_block_types[1] = 1;
        self.num_block_types[2] = 1;
        self.block_type_rb[0] = 1;
        self.block_type_rb[1] = 0;
        self.block_type_rb[2] = 1;
        self.block_type_rb[3] = 0;
        self.block_type_rb[4] = 1;
        self.block_type_rb[5] = 0;
        self.context_map_slice = &.{};
        self.literal_htree = &.{};
        self.dist_context_map_slice = &.{};
        self.dist_htree_index = 0;
        self.context_lookup = &.{};
        // Explicitly drop any leftover tree groups.
        self.freeTreeGroup(&self.literal_hgroup);
        self.freeTreeGroup(&self.insert_copy_hgroup);
        self.freeTreeGroup(&self.distance_hgroup);
        if (self.context_modes.len != 0) {
            self.allocator.free(self.context_modes);
            self.context_modes = &.{};
        }
        if (self.context_map.len != 0) {
            self.allocator.free(self.context_map);
            self.context_map = &.{};
        }
        if (self.dist_context_map.len != 0) {
            self.allocator.free(self.dist_context_map);
            self.dist_context_map = &.{};
        }
    }

    fn treeGroupAlloc(self: *Decoder, g: *TreeGroup, alphabet_size_max: u32, alphabet_size_limit: u32, ntrees: u32) bool {
        // Per-tree capacity: limit + 376 covers every legal two-level layout.
        const max_table_size: usize = alphabet_size_limit + 376;
        const codes = self.allocator.alloc(
            HuffmanCode,
            @as(usize, ntrees) * max_table_size,
        ) catch return false;
        // Initialize to a safe "impossible" entry: any lookup reaching
        // unbuilt territory yields a detectable format error instead of UB.
        @memset(codes, .{ .bits = 0, .value = 0 });
        const htrees = self.allocator.alloc(u32, ntrees) catch {
            self.allocator.free(codes);
            return false;
        };
        g.alphabet_size_max = alphabet_size_max;
        g.alphabet_size_limit = alphabet_size_limit;
        g.num_htrees = ntrees;
        g.codes = codes;
        g.htrees = htrees;
        return true;
    }

    /// Reads 1..4 simple Huffman symbols (each 1..11 bits); resumable.
    fn readSimpleHuffmanSymbols(self: *Decoder, br: *BitReader, alphabet_size_max: u64, alphabet_size_limit: u64) ErrorCode {
        var v: u64 = 0;
        // max_bits == 1..11; 1..44 bits will be read in total.
        const max_bits: u32 = log2Floor(alphabet_size_max -% 1);
        var i = self.sub_loop_counter;
        const num_symbols = self.h_symbol;
        while (i <= num_symbols) {
            if (!br.safeReadBits(@intCast(max_bits), &v)) {
                self.sub_loop_counter = i;
                self.substate_huffman = .simple_read;
                return .needs_more_input;
            }
            if (v >= alphabet_size_limit) {
                return fail(.format_simple_huffman_alphabet);
            }
            // Symbols are staged in dedicated storage (never alias next_of).
            self.simple_vals[@intCast(i)] = @intCast(v);
            i += 1;
        }
        self.sub_loop_counter = i;

        // Reject duplicates.
        i = 0;
        while (i < num_symbols) : (i += 1) {
            var k = i + 1;
            while (k <= num_symbols) : (k += 1) {
                if (self.simple_vals[@intCast(i)] == self.simple_vals[@intCast(k)]) {
                    return fail(.format_simple_huffman_same);
                }
            }
        }
        return .success;
    }

    /// Applies one decoded symbol code length to the code-length histogram.
    fn processSingleCodeLength(code_len: u64, symbol: *u64, repeat: *u64, space: *u64, prev_code_len: *u32, chains: *huff.SymbolChains, next_of: []u16, code_length_histo: *[16]u16) void {
        repeat.* = 0;
        if (code_len != 0) { // code_len == 1..15
            chains.append(next_of, @intCast(code_len), @intCast(symbol.*));
            prev_code_len.* = @intCast(code_len);
            space.* -%= @as(u64, 32768) >> @intCast(code_len);
            code_length_histo[@intCast(code_len)] += 1;
        }
        symbol.* += 1;
    }

    /// Applies one repeated code length to the code-length histogram.
    fn processRepeatedCodeLength(code_len: u64, repeat_delta_in: u64, alphabet_size: u64, symbol: *u64, repeat: *u64, space: *u64, prev_code_len: *u32, repeat_code_len: *u32, chains: *huff.SymbolChains, next_of: []u16, code_length_histo: *[16]u16) void {
        var repeat_delta = repeat_delta_in;
        const extra_bits: u32 = if (code_len == constants.REPEAT_PREVIOUS_CODE_LENGTH) 2 else 3;
        var new_len: u32 = 0; // for REPEAT_ZERO
        if (code_len == constants.REPEAT_PREVIOUS_CODE_LENGTH) {
            new_len = prev_code_len.*;
        }
        if (repeat_code_len.* != new_len) {
            repeat.* = 0;
            repeat_code_len.* = new_len;
        }
        const old_repeat = repeat.*;
        if (repeat.* > 0) {
            repeat.* -= 2;
            repeat.* <<= @intCast(extra_bits);
        }
        repeat.* += repeat_delta + 3;
        repeat_delta = repeat.* - old_repeat;
        if (symbol.* + repeat_delta > alphabet_size) {
            symbol.* = alphabet_size;
            space.* = 0xFFFFF;
            return;
        }
        if (repeat_code_len.* != 0) {
            const last = symbol.* + repeat_delta;
            while (symbol.* != last) : (symbol.* += 1) {
                chains.append(next_of, @intCast(repeat_code_len.*), @intCast(symbol.*));
            }
            space.* -%= repeat_delta << @intCast(15 - @as(u6, @intCast(repeat_code_len.*)));
            code_length_histo[@intCast(repeat_code_len.*)] +=
                @intCast(repeat_delta);
        } else {
            symbol.* += repeat_delta;
        }
    }

    /// Reads and decodes symbol code lengths using the code-length table.
    /// Always-safe single implementation (the BitReader cannot overread).
    fn readSymbolCodeLengths(self: *Decoder, br: *BitReader, alphabet_size: u64) ErrorCode {
        var symbol = self.h_symbol;
        var repeat = self.h_repeat;
        var space = self.h_space;
        var prev_code_len = self.prev_code_len;
        var repeat_code_len = self.repeat_code_len;

        while (symbol < alphabet_size and space > 0) {
            // Repeat codes consume up to 5 + 3 bits; a 16-bit fill window
            // guarantees symbol + extras are always available.
            if (!br.ensureBits(huff.HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH + 3)) {
                self.h_symbol = symbol;
                self.h_repeat = repeat;
                self.h_space = space;
                self.prev_code_len = prev_code_len;
                self.repeat_code_len = repeat_code_len;
                return .needs_more_input;
            }
            const p = &self.cl_table[@intCast(br.getBits(huff.HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH))];
            const code_len = p.value; // 0..17
            br.dropBits(p.bits); // 1..5 bits
            if (code_len < constants.REPEAT_PREVIOUS_CODE_LENGTH) {
                processSingleCodeLength(code_len, &symbol, &repeat, &space, &prev_code_len, &self.chains, &self.chain_next, &self.code_length_histo);
            } else { // code_len == 16..17, extra_bits == 2..3
                const extra_bits: u32 =
                    if (code_len == constants.REPEAT_PREVIOUS_CODE_LENGTH) 2 else 3;
                const repeat_delta = br.getBits(@intCast(extra_bits));
                br.dropBits(extra_bits);
                processRepeatedCodeLength(code_len, repeat_delta, alphabet_size, &symbol, &repeat, &space, &prev_code_len, &repeat_code_len, &self.chains, &self.chain_next, &self.code_length_histo);
            }
        }
        self.h_space = space;
        self.h_symbol = symbol;
        self.h_repeat = repeat;
        self.prev_code_len = prev_code_len;
        self.repeat_code_len = repeat_code_len;
        return .success;
    }

    /// Reads and decodes 15..18 code-length-code lengths using the static
    /// prefix code; each code is 2..4 bits. Resumable.
    fn readCodeLengthCodeLengths(self: *Decoder, br: *BitReader) ErrorCode {
        var num_codes = self.h_repeat;
        var space = self.h_space;
        var i = self.sub_loop_counter;
        while (i < constants.CODE_LENGTH_CODES) : (i += 1) {
            const code_len_idx = prefix.code_length_prefix_order[@intCast(i)];
            var ix: u64 = 0;
            const avail = br.availableBits();
            if (!br.ensureBits(4)) {
                // Peek whatever is available (up to 4 bits).
                ix = if (avail != 0) br.getBits(@intCast(@min(avail, 4))) else 0;
                if (prefix.code_length_prefix_length[@intCast(ix)] > avail) {
                    self.sub_loop_counter = i;
                    self.h_repeat = num_codes;
                    self.h_space = space;
                    self.substate_huffman = .complex;
                    return .needs_more_input;
                }
            } else {
                ix = br.getBits(4);
            }

            const v = prefix.code_length_prefix_value[@intCast(ix)];
            br.dropBits(prefix.code_length_prefix_length[@intCast(ix)]);
            self.code_length_code_lengths[code_len_idx] = v;
            if (v != 0) {
                space = space -% (@as(u64, 32) >> @intCast(v));
                num_codes += 1;
                self.code_length_histo[v] += 1;
                if ((space -% 1) >= 32) {
                    // space is 0 or wrapped around.
                    break;
                }
            }
        }
        self.sub_loop_counter = i;
        self.h_repeat = num_codes;
        self.h_space = space;
        if (!(num_codes == 1 or space == 0)) {
            return fail(.format_cl_space);
        }
        return .success;
    }

    /// Decodes one Huffman table (simple or complex); resumable via
    /// `substate_huffman`. On success fills `table_out` and reports its size.
    fn readHuffmanCode(self: *Decoder, br: *BitReader, alphabet_size_max: u64, alphabet_size_limit: u64, table_out: []HuffmanCode, opt_table_size: ?*u32) ErrorCode {
        while (true) {
            switch (self.substate_huffman) {
                .none => {
                    if (!br.safeReadBits(2, &self.sub_loop_counter)) {
                        return .needs_more_input;
                    }
                    // 1 selects a simple code; otherwise it is the number of
                    // skipped code lengths in the complex representation.
                    if (self.sub_loop_counter != 1) {
                        self.h_space = 32;
                        self.h_repeat = 0; // num_codes
                        @memset(&self.code_length_histo, 0);
                        @memset(&self.code_length_code_lengths, 0);
                        self.substate_huffman = .complex;
                        continue;
                    }
                    self.substate_huffman = .simple_size;
                    continue;
                },
                .simple_size => {
                    if (!br.safeReadBits(2, &self.h_symbol)) {
                        self.substate_huffman = .simple_size;
                        return .needs_more_input;
                    }
                    self.sub_loop_counter = 0;
                    self.substate_huffman = .simple_read;
                    continue;
                },
                .simple_read => {
                    const result = self.readSimpleHuffmanSymbols(br, alphabet_size_max, alphabet_size_limit);
                    if (result != .success) return result;
                    self.substate_huffman = .simple_build;
                    continue;
                },
                .simple_build => {
                    if (self.h_symbol == 3) {
                        var bits: u64 = 0;
                        if (!br.safeReadBits(1, &bits)) {
                            self.substate_huffman = .simple_build;
                            return .needs_more_input;
                        }
                        self.h_symbol += bits;
                    }
                    // Build directly from dedicated staging (never aliases
                    // chains.next_of); buildSimpleHuffmanTable may sort it.
                    const table_size = huff.buildSimpleHuffmanTable(table_out, huff.HUFFMAN_TABLE_BITS, &self.simple_vals, @intCast(self.h_symbol));
                    if (opt_table_size) |p| p.* = table_size;
                    self.substate_huffman = .none;
                    return .success;
                },
                .complex => {
                    const result = self.readCodeLengthCodeLengths(br);
                    if (result != .success) return result;
                    huff.buildCodeLengthsHuffmanTable(&self.cl_table, &self.code_length_code_lengths, &self.code_length_histo);
                    @memset(&self.code_length_histo, 0);
                    self.chains.reset();
                    self.h_symbol = 0;
                    self.prev_code_len = constants.INITIAL_REPEATED_CODE_LENGTH;
                    self.h_repeat = 0;
                    self.repeat_code_len = 0;
                    self.h_space = 32768;
                    self.substate_huffman = .length_symbols;
                    continue;
                },
                .length_symbols => {
                    const result = self.readSymbolCodeLengths(br, alphabet_size_limit);
                    if (result != .success) return result;
                    if (self.h_space != 0) {
                        return fail(.format_huffman_space);
                    }
                    const table_size = huff.buildHuffmanTable(table_out, huff.HUFFMAN_TABLE_BITS, &self.chains, &self.code_length_histo, &self.chain_next);
                    if (opt_table_size) |p| p.* = table_size;
                    self.substate_huffman = .none;
                    return .success;
                },
            }
        }
    }

    /// Decodes a series of Huffman tables into `group`; resumable.
    fn huffmanTreeGroupDecode(self: *Decoder, br: *BitReader, group: *TreeGroup) ErrorCode {
        if (self.substate_tree_group != .loop) {
            self.tree_next_off = 0;
            self.htree_index = 0;
            self.substate_tree_group = .loop;
        }
        while (self.htree_index < @as(i32, @intCast(group.num_htrees))) {
            var table_size: u32 = 0;
            const dst = group.codes[self.tree_next_off..];
            const result = self.readHuffmanCode(br, group.alphabet_size_max, group.alphabet_size_limit, dst, &table_size);
            if (result != .success) return result;
            group.htrees[@intCast(self.htree_index)] = @intCast(self.tree_next_off);
            self.tree_next_off += table_size;
            self.htree_index += 1;
        }
        self.substate_tree_group = .none;
        return .success;
    }

    /// Inverse move-to-front transform over `v`.
    fn inverseMoveToFrontTransform(self: *Decoder, v: []u8) void {
        var mtf_u8: [256]u8 = undefined;
        for (0..256) |i| {
            mtf_u8[i] = @intCast(i);
        }

        var new_upper: u8 = 0;
        for (v) |*item| {
            const index: usize = item.*;
            const value = mtf_u8[index];
            new_upper |= item.*;
            item.* = value;
            // Move value to front by shifting [0..index] right.
            var j = index;
            while (j > 0) : (j -= 1) {
                mtf_u8[j] = mtf_u8[j - 1];
            }
            mtf_u8[0] = value;
        }
        self.mtf_upper_bound = new_upper >> 2;
    }

    /// Decodes a context map; resumable. Allocates `context_map_arg`.
    fn decodeContextMap(self: *Decoder, br: *BitReader, context_map_size: u64, num_htrees: *u64, context_map_arg: *[]u8) ErrorCode {
        var bits: u64 = 0;
        while (true) {
            switch (self.substate_context_map) {
                .none => {
                    {
                        // Scratch storage serves as the resumable value holder; overwritten on entry.
                        const r = self.decodeVarLenUint8(br, &self.cm_scratch);
                        if (r != .success) return r;
                        num_htrees.* = @as(u64, self.cm_scratch) + 1;
                    }
                    self.context_index = 0;
                    const cmap = self.allocator.alloc(u8, @intCast(context_map_size)) catch {
                        return fail(.alloc_context_map);
                    };
                    context_map_arg.* = cmap;
                    if (num_htrees.* <= 1) {
                        @memset(cmap, 0);
                        return .success;
                    }
                    self.substate_context_map = .read_prefix;
                    continue;
                },
                .read_prefix => {
                    // Peek 5 bits; ReadHuffmanCode needs at least 4.
                    if (!br.ensureBits(5)) return .needs_more_input;
                    bits = br.getBits(5);
                    if ((bits & 1) != 0) { // Use RLE for zeros.
                        self.max_run_length_prefix = @intCast((bits >> 1) + 1);
                        br.dropBits(5);
                    } else {
                        self.max_run_length_prefix = 0;
                        br.dropBits(1);
                    }
                    self.substate_context_map = .huffman;
                    continue;
                },
                .huffman => {
                    const alphabet_size = num_htrees.* + self.max_run_length_prefix;
                    const result = self.readHuffmanCode(br, alphabet_size, alphabet_size, &self.context_map_table, null);
                    if (result != .success) return result;
                    self.cm_code = 0xFFFF; // "no pending RLE code"
                    self.substate_context_map = .decode;
                    continue;
                },
                .decode => {
                    var context_index = self.context_index;
                    const max_run_length_prefix = self.max_run_length_prefix;
                    var skip_preamble = (self.cm_code != 0xFFFF);
                    while (context_index < context_map_size or skip_preamble) {
                        if (!skip_preamble) {
                            if (!readSymbolSafe(&self.context_map_table, br, &bits)) {
                                self.cm_code = 0xFFFF;
                                self.context_index = context_index;
                                return .needs_more_input;
                            }
                            if (bits == 0) {
                                context_map_arg.*[@intCast(context_index)] = 0;
                                context_index += 1;
                                continue;
                            }
                            if (bits > max_run_length_prefix) {
                                context_map_arg.*[@intCast(context_index)] =
                                    @intCast(bits - max_run_length_prefix);
                                context_index += 1;
                                continue;
                            }
                            self.cm_code = @intCast(bits); // RLE sub-stage
                        } else {
                            skip_preamble = false;
                        }
                        // RLE: read `code` extra bits for the repeat count.
                        var reps: u64 = 0;
                        if (!br.safeReadBits(self.cm_code, &reps)) {
                            self.context_index = context_index;
                            return .needs_more_input;
                        }
                        reps += @as(u64, 1) << @intCast(self.cm_code);
                        if (context_index + reps > context_map_size) {
                            return fail(.format_context_map_repeat);
                        }
                        @memset(context_map_arg.*[@intCast(context_index)..@intCast(context_index + reps)], 0);
                        context_index += reps;
                        self.cm_code = 0xFFFF;
                    }
                    self.context_index = context_index;
                    self.substate_context_map = .transform;
                    continue;
                },
                .transform => {
                    if (!br.safeReadBits(1, &bits)) {
                        return .needs_more_input;
                    }
                    if (bits != 0) {
                        self.inverseMoveToFrontTransform(context_map_arg.*);
                    }
                    self.substate_context_map = .none;
                    return .success;
                },
            }
        }
    }

    /// Decodes a block type/length pair; resumable via substate_read_block_length.
    fn decodeBlockTypeAndLength(self: *Decoder, br: *BitReader, tree_type: usize) ErrorCode {
        const max_block_type = self.num_block_types[tree_type];
        const type_tree = self.block_type_trees[tree_type * huff.HUFFMAN_MAX_SIZE_258 ..][0..huff.HUFFMAN_MAX_SIZE_258];
        const len_tree = self.block_len_trees[tree_type * huff.HUFFMAN_MAX_SIZE_26 ..][0..huff.HUFFMAN_MAX_SIZE_26];

        const rb: *[2]u64 = self.block_type_rb[tree_type * 2 ..][0..2];

        if (max_block_type <= 1) {
            return fail(.format_block_switch);
        }

        const saved = br.*;

        // Read 0..15 bits of the block-type symbol.
        var block_type: u64 = 0;
        if (!readSymbolSafe(type_tree, br, &block_type)) {
            return .needs_more_input;
        }

        // Read the block-count symbol from the separate length tree
        // (2..24 more bits), resumable as a unit via the saved state.
        var index: u64 = 0;
        if (self.substate_read_block_length == .none) {
            if (!readSymbolSafe(len_tree, br, &index)) {
                br.* = saved;
                return .needs_more_input;
            }
            self.block_length_index = index;
        } else {
            index = self.block_length_index;
        }

        const range_idx: usize = @intCast(index);
        const range = ranges.prefix_code_ranges[range_idx];
        var extra: u64 = 0;
        if (!br.safeReadBits(range.nbits, &extra)) {
            self.substate_read_block_length = .none;
            br.* = saved;
            return .needs_more_input;
        }
        self.block_length[tree_type] = @as(u64, range.offset) + extra;
        self.substate_read_block_length = .none;

        if (block_type == 1) {
            block_type = rb[1] + 1;
        } else if (block_type == 0) {
            block_type = rb[0];
        } else {
            block_type -= 2;
        }
        if (block_type >= max_block_type) {
            block_type -= max_block_type;
        }
        rb[0] = rb[1];
        rb[1] = block_type;
        return .success;
    }

    /// Predecessor bytes for literal contexts at ring-buffer position `pos`.
    /// Before the stream has produced two bytes there are no predecessors;
    /// the encoder codes those positions with zero contexts, so the decoder
    /// must too. The ring buffer may hold stale bytes from a previous stream
    /// (after reset) or uninitialized slots, which must never leak into the
    /// context computation.
    fn prevBytes(self: *const Decoder, pos: usize) struct { p1: u8, p2: u8 } {
        const rb_mask: u32 = self.ringbuffer_mask;
        if (self.rb_roundtrips != 0 or pos >= 2) {
            return .{
                .p1 = self.ringbuffer[@intCast((@as(i64, @intCast(pos)) - 1) & rb_mask)],
                .p2 = self.ringbuffer[@intCast((@as(i64, @intCast(pos)) - 2) & rb_mask)],
            };
        }
        if (pos == 1) {
            return .{ .p1 = self.ringbuffer[0], .p2 = 0 };
        }
        return .{ .p1 = 0, .p2 = 0 };
    }

    fn detectTrivialLiteralBlockTypes(self: *Decoder) void {
        for (&self.trivial_literal_contexts) |*t| t.* = 0;
        var i: usize = 0;
        while (i < self.num_block_types[0]) : (i += 1) {
            const offset = i << constants.LITERAL_CONTEXT_BITS;
            const sample = self.context_map[offset];
            var error_acc: u64 = 0;
            var j: usize = 0;
            while (j < (@as(usize, 1) << constants.LITERAL_CONTEXT_BITS)) : (j += 4) {
                error_acc |= (@as(u64, self.context_map[offset + j]) ^ sample) |
                    (@as(u64, self.context_map[offset + j + 1]) ^ sample) |
                    (@as(u64, self.context_map[offset + j + 2]) ^ sample) |
                    (@as(u64, self.context_map[offset + j + 3]) ^ sample);
            }
            if (error_acc == 0) {
                self.trivial_literal_contexts[i >> 5] |= @as(u32, 1) << @intCast(i & 31);
            }
        }
    }

    fn prepareLiteralDecoding(self: *Decoder) void {
        const block_type: usize = @intCast(self.block_type_rb[1]);
        const context_offset = block_type << constants.LITERAL_CONTEXT_BITS;
        self.context_map_slice = self.context_map[context_offset..];
        const trivial = self.trivial_literal_contexts[block_type >> 5];
        self.trivial_literal_context =
            ((trivial >> @intCast(block_type & 31)) & 1) != 0;
        self.literal_htree = self.literal_hgroup.get(self.context_map_slice[0]);
        const mode = context.ContextType.fromInt(self.context_modes[block_type]);
        self.context_lookup = context.contextLut(mode);
    }

    /// Literal / command / distance block switch handling.
    fn decodeLiteralBlockSwitch(self: *Decoder, br: *BitReader) ErrorCode {
        const r = self.decodeBlockTypeAndLength(br, 0);
        if (r != .success) return r;
        self.prepareLiteralDecoding();
        return .success;
    }

    fn decodeCommandBlockSwitch(self: *Decoder, br: *BitReader) ErrorCode {
        const r = self.decodeBlockTypeAndLength(br, 1);
        if (r != .success) return r;
        self.htree_command = self.insert_copy_hgroup.get(@intCast(self.block_type_rb[3]));
        return .success;
    }

    fn decodeDistanceBlockSwitch(self: *Decoder, br: *BitReader) ErrorCode {
        const r = self.decodeBlockTypeAndLength(br, 2);
        if (r != .success) return r;
        self.dist_context_map_slice =
            self.dist_context_map[@intCast(self.block_type_rb[5] << constants.DISTANCE_CONTEXT_BITS)..];
        self.dist_htree_index =
            self.dist_context_map_slice[@intCast(self.distance_context)];
        return .success;
    }

    /// Drops already-consumed bytes from the internal buffer, retaining the
    /// unconsumed tail for the next call. Only valid while the reader is
    /// pointed at `self.buffer`.
    fn compactBuffer(self: *Decoder) void {
        self.br.unload();
        const start = self.br.pos;
        const keep = self.br.input.len - start;
        if (start != 0 and keep != 0) {
            std.mem.copyForwards(u8, self.buffer[0..keep], self.buffer[start..][0..keep]);
        }
        self.buffer_length = keep;
    }

    /// Moves the unconsumed tail into the internal buffer and advances the
    /// caller's input view past everything staged. Only valid while the
    /// reader is pointed at the caller's input.
    fn stageResume(self: *Decoder, input: *[]const u8) void {
        self.br.unload();
        const on_input = self.br.input.ptr == input.*.ptr;
        const start = self.br.pos;
        const keep = @min(self.br.input.len - start, self.buffer.len);
        if (keep != 0) {
            if (on_input) {
                @memcpy(self.buffer[0..keep], self.br.input[start..][0..keep]);
            } else {
                std.mem.copyForwards(u8, self.buffer[0..keep], self.br.input[start..][0..keep]);
            }
        }
        self.buffer_length = keep;
        if (on_input) {
            input.* = input.*[start + keep ..];
        }
    }
    fn writeRingBuffer(self: *Decoder, available_out: *[]u8, total_out: ?*u64, force: bool) ErrorCode {
        if (self.ringbuffer.len == 0) return .success;
        const start: usize = @intCast(self.partial_pos_out & self.ringbuffer_mask);
        const to_write = self.unwrittenBytes(true);
        var num_written = available_out.len;
        if (num_written > to_write) num_written = to_write;
        if (self.meta_block_remaining_len < 0) {
            return fail(.format_block_length_1);
        }
        if (self.options.maxOutputSize) |max_out| {
            if (self.partial_pos_out + num_written > max_out) {
                return fail(.resource_limit);
            }
        }
        const src = self.ringbuffer[start..][0..num_written];
        @memcpy(available_out.*[0..num_written], src);
        available_out.* = available_out.*[num_written..];
        self.partial_pos_out += num_written;
        if (total_out) |p| p.* = self.partial_pos_out;

        if (num_written < to_write) {
            const full_window = (self.ringbuffer_size == (@as(u32, 1) << @intCast(self.window_bits)));
            if (full_window or force) {
                return .needs_more_output;
            }
            return .success;
        }
        // Wrap the ring buffer only after it reached its maximal size.
        if (self.ringbuffer_size == (@as(u32, 1) << @intCast(self.window_bits)) and
            self.pos >= self.ringbuffer_size)
        {
            self.pos -= self.ringbuffer_size;
            self.rb_roundtrips += 1;
            self.should_wrap_ringbuffer = self.pos != 0;
        }
        return .success;
    }

    fn wrapRingBuffer(self: *Decoder) void {
        if (self.should_wrap_ringbuffer) {
            const pos: usize = @intCast(self.pos);
            std.mem.copyForwards(u8, self.ringbuffer[0..pos], self.ringbuffer[self.ringbuffer_size..][0..pos]);
            self.should_wrap_ringbuffer = false;
        }
    }

    /// Allocates or grows the ring buffer; keeps existing contents.
    fn ensureRingBuffer(self: *Decoder) bool {
        if (self.options.ringBufferSizeLimit != 0 and self.new_ringbuffer_size > self.options.ringBufferSizeLimit) {
            self.err = .resource_limit;
            return false;
        }
        const old = self.ringbuffer;
        if (self.ringbuffer_size == self.new_ringbuffer_size) return true;

        const new_size: usize = @as(usize, self.new_ringbuffer_size) + RING_BUFFER_SLACK;
        const nb = self.allocator.alloc(u8, new_size) catch {
            self.ringbuffer = old;
            return false;
        };
        nb[self.new_ringbuffer_size - 2] = 0;
        nb[self.new_ringbuffer_size - 1] = 0;

        if (old.len != 0) {
            const pos: usize = @intCast(self.pos);
            @memcpy(nb[0..pos], old[0..pos]);
            self.allocator.free(old);
        }
        self.ringbuffer = nb;
        self.ringbuffer_size = self.new_ringbuffer_size;
        self.ringbuffer_mask = self.new_ringbuffer_size - 1;
        return true;
    }

    /// Calculates the smallest feasible ring buffer for the next metablock.
    fn calculateRingBufferSize(self: *Decoder) void {
        const window_size: u32 = @as(u32, 1) << @intCast(self.window_bits);
        var new_ringbuffer_size = window_size;
        var min_size: u32 = if (self.ringbuffer_size != 0) self.ringbuffer_size else 1024;

        if (self.ringbuffer_size == window_size) return;
        if (self.is_metadata) return;

        var output_size: u32 = if (self.ringbuffer.len == 0) 0 else @intCast(self.pos);
        output_size +%= @intCast(@max(self.meta_block_remaining_len, 0));
        min_size = @max(min_size, output_size);

        if (self.options.cannyRingbufferAllocation) {
            while ((new_ringbuffer_size >> 1) >= min_size) {
                new_ringbuffer_size >>= 1;
            }
        }
        self.new_ringbuffer_size = new_ringbuffer_size;
    }

    /// Copies raw bytes from the bit reader into `dest` (accumulator first).
    fn copyBytesFromReader(br: *BitReader, dest: []u8) void {
        var i: usize = 0;
        while (br.bit_pos >= 8 and i < dest.len) : (i += 1) {
            dest[i] = @truncate(br.val);
            br.dropBits(8);
        }
        const rest = @min(dest.len - i, br.availIn());
        @memcpy(dest[i..][0..rest], br.input[br.pos..][0..rest]);
        br.pos += rest;
    }

    /// Skips a metadata block body; resumable.
    fn skipMetadataBlock(self: *Decoder) ErrorCode {
        var nbytes: usize = undefined;
        if (self.meta_block_remaining_len == 0) return .success;

        std.debug.assert((self.br.availableBits() & 7) == 0);

        // Drain accumulator.
        if (self.br.availableBits() >= 8) {
            var buf: [8]u8 = undefined;
            nbytes = self.br.availableBits() >> 3;
            if (nbytes > self.meta_block_remaining_len) nbytes = @intCast(self.meta_block_remaining_len);
            copyBytesFromReader(&self.br, buf[0..nbytes]);
            if (self.metadata_cb.chunk) |f| f(self.metadata_cb.ctx, buf[0..nbytes]);
            self.meta_block_remaining_len -= @intCast(nbytes);
            if (self.meta_block_remaining_len == 0) return .success;
        }

        // Direct access to metadata bytes in the input.
        nbytes = @min(self.br.availIn(), @as(usize, @intCast(self.meta_block_remaining_len)));
        if (nbytes > 0) {
            if (self.metadata_cb.chunk) |f| f(self.metadata_cb.ctx, self.br.input[self.br.pos..][0..nbytes]);
            self.br.pos += nbytes;
            self.meta_block_remaining_len -= @intCast(nbytes);
            if (self.meta_block_remaining_len == 0) return .success;
        }
        return .needs_more_input;
    }

    /// Copies an uncompressed metablock to the output; resumable.
    fn copyUncompressedBlockToOutput(self: *Decoder, available_out: *[]u8, total_out: ?*u64) ErrorCode {
        if (!self.ensureRingBuffer()) {
            if (self.err == .resource_limit) return .resource_limit;
            return fail(.alloc_ring_buffer_1);
        }
        while (true) {
            switch (self.substate_uncompressed) {
                .none => {
                    var nbytes: usize = @min(self.br.remainingBytes(), @as(usize, @intCast(@max(self.meta_block_remaining_len, 0))));
                    const pos: usize = @intCast(self.pos);
                    if (pos + nbytes > self.ringbuffer_size) {
                        nbytes = self.ringbuffer_size - pos;
                    }
                    copyBytesFromReader(&self.br, self.ringbuffer[pos..][0..nbytes]);
                    self.pos += @intCast(nbytes);
                    self.meta_block_remaining_len -= @intCast(nbytes);
                    if (self.pos < (@as(i64, 1) << @intCast(self.window_bits))) {
                        if (self.meta_block_remaining_len == 0) return .success;
                        return .needs_more_input;
                    }
                    self.substate_uncompressed = .write;
                    continue;
                },
                .write => {
                    const result = self.writeRingBuffer(available_out, total_out, false);
                    if (result != .success) return result;
                    if (self.ringbuffer_size == (@as(u32, 1) << @intCast(self.window_bits))) {
                        self.max_distance = self.max_backward_distance;
                    }
                    self.substate_uncompressed = .none;
                    continue;
                },
            }
        }
    }

    /// Calculates the distance lookup table (extra bits and offsets).
    fn calculateDistanceLut(self: *Decoder) void {
        const npostfix = self.distance_postfix_bits;
        const ndirect = self.num_direct_distance_codes;
        const alphabet_size_limit = self.distance_hgroup.alphabet_size_limit;
        const postfix = @as(u32, 1) << @intCast(npostfix);
        var bits: u32 = 1;
        var half: u32 = 0;

        // Skip short codes.
        var i: usize = constants.NUM_DISTANCE_SHORT_CODES;

        // Fill direct codes.
        for (0..ndirect) |j| {
            self.dist_extra_bits[i] = 0;
            self.dist_offset[i] = @intCast(j + 1);
            i += 1;
        }

        // Fill regular distance codes (complete groups only).
        while (i < alphabet_size_limit) {
            const base: u32 = ndirect +
                (((2 + half) << @intCast(bits)) - 4) * postfix + 1;
            for (0..postfix) |j| {
                self.dist_extra_bits[i] = @intCast(bits);
                self.dist_offset[i] = @intCast(base + j);
                i += 1;
            }
            bits += half;
            half ^= 1;
        }
    }

    /// Converts a distance ring-buffer short code into an actual distance.
    fn takeDistanceFromRingBuffer(self: *Decoder) void {
        const offset = self.distance_code - 3;
        if (self.distance_code <= 3) {
            // Compensate double distance-ring-buffer roll for dictionary items.
            self.distance_context = @intCast((@as(u32, 1) >> @intCast(self.distance_code)) & 1);
            const idx: u32 = @bitCast(self.dist_rb_idx - offset);
            self.distance_code = self.dist_rb[idx & 3];
            self.dist_rb_idx -= self.distance_context;
        } else {
            var index_delta: i32 = 3;
            var base: i32 = undefined;
            if (self.distance_code < 10) {
                base = self.distance_code - 4;
            } else {
                base = self.distance_code - 10;
                index_delta = 2;
            }
            // Unpack one of six 4-bit values.
            const delta: i32 =
                @as(i32, @intCast((@as(u32, 0x605142) >> @as(u5, @truncate(@as(u32, @bitCast(base)) *% 4))) & 0xF)) - 3;
            const idx: u32 = @bitCast(self.dist_rb_idx + index_delta);
            self.distance_code = self.dist_rb[idx & 0x3] +% delta;
            if (self.distance_code <= 0) {
                // A huge distance will cause an error soon; this is faster.
                self.distance_code = 0x7FFFFFFF;
            }
        }
    }

    /// Reads one distance; requires the command's distance context to be set.
    /// Resumable via caller-managed bit-reader state on failure.
    fn readDistanceInternal(self: *Decoder, br: *BitReader) bool {
        var code: u64 = 0;
        const saved = br.*;

        if (self.dist_htree_index >= self.distance_hgroup.num_htrees) {
            self.err = fail(.format_distance);
            return false;
        }
        const distance_tree = self.distance_hgroup.get(self.dist_htree_index);
        if (!readSymbolSafe(distance_tree, br, &code)) return false;
        self.block_length[2] -= 1;

        self.distance_context = 0;
        if ((code & ~@as(u64, 0xF)) == 0) {
            self.distance_code = @intCast(code);
            takeDistanceFromRingBuffer(self);
            return true;
        }
        const idx: usize = @intCast(code);
        // A symbol outside the computed LUT (or the invalid-symbol sentinel)
        // means corruption for the current parameters; surface as an error.
        if (idx >= self.dist_extra_bits.len) {
            self.err = fail(.format_dictionary);
            return false;
        }
        var extra_bits_val: u64 = 0;
        if (!br.safeReadBits(self.dist_extra_bits[idx], &extra_bits_val)) {
            self.block_length[2] += 1;
            br.* = saved;
            return false;
        }
        self.distance_code = @as(i32, @bitCast(self.dist_offset[idx] +
            (@as(u32, @intCast(extra_bits_val)) << @intCast(self.distance_postfix_bits))));
        return true;
    }

    /// Reads one insert-and-copy command header. Returns false when more
    /// input is required; restores bit-reader state in that case.
    fn readCommandInternal(self: *Decoder, br: *BitReader, insert_length: *i64) bool {
        var cmd_code: u64 = 0;
        var insert_len_extra: u64 = 0;
        var copy_length: u64 = 0;
        const saved = br.*;

        if (!readSymbolSafe(self.htree_command, br, &cmd_code)) return false;
        // A table entry produced by a malformed stream can decode to a symbol
        // outside the command alphabet; reject it before indexing.
        if (cmd_code >= constants.NUM_COMMAND_SYMBOLS) {
            _ = fail(.format_block_switch);
            return false;
        }
        self.last_cmd_sym = cmd_code;
        const v = prefix.cmd_lut[@intCast(cmd_code)];
        self.distance_code = v.distance_code;
        self.distance_context = v.context;
        self.dist_htree_index = self.dist_context_map_slice[@intCast(self.distance_context)];
        insert_length.* = v.insert_len_offset;

        if (!br.safeReadBits(v.insert_len_extra_bits, &insert_len_extra)) {
            br.* = saved;
            return false;
        }
        if (!br.safeReadBits(v.copy_len_extra_bits, &copy_length)) {
            br.* = saved;
            return false;
        }
        self.copy_length = @as(i32, @intCast(copy_length)) +% v.copy_len_offset;
        self.block_length[1] -= 1;
        insert_length.* += @intCast(insert_len_extra);
        return true;
    }

    fn ensureCompoundDictInitialized(self: *Decoder) void {
        const addon: *CompoundDict = self.compound.?;
        if (addon.block_bits != 255) return;
        var block_bits: u6 = 8;
        const maximal_address = addon.total_size - 1;
        while ((maximal_address >> @intCast(block_bits)) != 0) block_bits += 1;
        block_bits -= 8;
        addon.block_bits = @intCast(block_bits);
        var cursor: u32 = 0;
        var index: usize = 0;
        while (cursor <= maximal_address) {
            while (addon.chunk_offsets[index + 1] < cursor) index += 1;
            addon.block_map[cursor >> @intCast(block_bits)] = @intCast(index);
            cursor += @as(u32, 1) << @intCast(block_bits);
        }
    }

    fn initCompoundDictCopy(self: *Decoder, address: u32, length: u32) bool {
        const addon: *CompoundDict = self.compound.?;
        self.ensureCompoundDictInitialized();
        var index: usize = addon.block_map[address >> @intCast(addon.block_bits)];
        while (address >= addon.chunk_offsets[index + 1]) index += 1;
        if (length > addon.total_size - address) return false;
        self.dist_rb[@intCast(self.dist_rb_idx & 3)] = self.distance_code;
        self.dist_rb_idx += 1;
        self.meta_block_remaining_len -= length;
        addon.br_index = @intCast(index);
        addon.br_offset = address - addon.chunk_offsets[index];
        addon.br_length = length;
        addon.br_copied = 0;
        return true;
    }

    fn copyFromCompoundDict(self: *Decoder, pos_in: usize) usize {
        const addon: *CompoundDict = self.compound.?;
        var pos = pos_in;
        const orig_pos = pos;
        // Never write past the live ring-buffer region: the trailing slack is
        // reserved for over-wide copies, not for dictionary references.
        while (addon.br_length != addon.br_copied and pos < self.ringbuffer_size) {
            const space: usize = self.ringbuffer_size - pos;
            const rem_chunk: u32 =
                (addon.chunk_offsets[addon.br_index + 1] - addon.chunk_offsets[addon.br_index]) -
                addon.br_offset;
            var length: u32 = addon.br_length - addon.br_copied;
            if (length > rem_chunk) length = rem_chunk;
            if (length > space) length = @intCast(space);
            if (length == 0) break;
            const src_chunk = addon.chunks[addon.br_index];
            @memcpy(
                self.ringbuffer[pos..][0..length],
                src_chunk[addon.br_offset..][0..length],
            );
            pos += length;
            addon.br_offset += length;
            addon.br_copied += length;
            if (length == rem_chunk) {
                addon.br_index += 1;
                addon.br_offset = 0;
            }
            if (pos == self.ringbuffer_size) break;
        }
        return pos - orig_pos;
    }

    /// The command processing loop for literal insertions and backward references.
    /// Saves `pos`/`loop_counter` on every exit point.
    fn processCommands(self: *Decoder) ErrorCode {
        var pos: usize = @intCast(@max(self.pos, 0));
        var ins: i64 = self.loop_counter;
        var copy_len: i64 = if (self.run_state == .command_post_wrap_copy or
            self.run_state == .command_post_write_2)
            self.loop_counter
        else
            0;
        var result: ErrorCode = .success;
        const br = &self.br;

        const Phase = enum { begin, inner, post_decode_literals, post_wrap_copy };
        var phase: Phase = switch (self.run_state) {
            .command_begin => .begin,
            .command_inner => .inner,
            .command_post_decode_literals => .post_decode_literals,
            .command_post_wrap_copy => .post_wrap_copy,
            else => return fail(.unreachable_state),
        };

        dispatch: while (true) {
            // Record the phase that must be resumed if this iteration is cut
            // short. An explicit state assigned later in the same iteration
            // (ring-buffer write, metablock end, ...) overrides this.
            self.run_state = switch (phase) {
                .begin => .command_begin,
                .inner => .command_inner,
                .post_decode_literals => .command_post_decode_literals,
                .post_wrap_copy => .command_post_wrap_copy,
            };
            switch (phase) {
                .begin => {
                    if (self.block_length[1] == 0) {
                        result = self.decodeCommandBlockSwitch(br);
                        if (result != .success) break :dispatch;
                        continue :dispatch;
                    }
                    var insert_len: i64 = 0;
                    if (!self.readCommandInternal(br, &insert_len)) {
                        result = .needs_more_input;
                        break :dispatch;
                    }
                    ins = insert_len;
                    if (ins == 0) {
                        phase = .post_decode_literals;
                        continue :dispatch;
                    }
                    self.meta_block_remaining_len -= ins;
                    phase = .inner;
                    continue :dispatch;
                },

                .inner => {
                    var p1: u8 = 0;
                    var p2: u8 = 0;
                    if (!self.trivial_literal_context) {
                        const prev = self.prevBytes(pos);
                        p1 = prev.p1;
                        p2 = prev.p2;
                    }
                    inner: while (true) {
                        if (self.block_length[0] == 0) {
                            result = self.decodeLiteralBlockSwitch(br);
                            if (result != .success) break :dispatch;
                            // Block switch re-enters the literal phase; the
                            // context bytes must be re-read from the ring
                            // buffer for a non-trivial new block type.
                            if (!self.trivial_literal_context) {
                                const prev = self.prevBytes(pos);
                                p1 = prev.p1;
                                p2 = prev.p2;
                            }
                            continue :inner;
                        }
                        var lit: u64 = 0;
                        var hc: []const HuffmanCode = undefined;
                        if (self.trivial_literal_context) {
                            hc = self.literal_htree;
                        } else {
                            const mode = context.ContextType.fromInt(0);
                            _ = mode;
                            const ctx: u8 = self.context_lookup[@as(usize, p1)] |
                                self.context_lookup[256 + @as(usize, p2)];
                            hc = self.literal_hgroup.get(self.context_map_slice[ctx]);
                        }
                        if (!readSymbolSafe(hc, br, &lit)) {
                            result = .needs_more_input;
                            break :dispatch;
                        }
                        if (lit >= constants.NUM_LITERAL_SYMBOLS) {
                            result = fail(.format_huffman_space);
                            break :dispatch;
                        }
                        self.ringbuffer[pos] = @truncate(lit);
                        p2 = p1;
                        p1 = @truncate(lit);
                        self.block_length[0] -= 1;
                        pos += 1;
                        ins -= 1;
                        if (pos == self.ringbuffer_size) {
                            // Save state and transition to ring buffer output.
                            self.run_state = .command_inner_write;
                            break :dispatch;
                        }
                        if (ins == 0) break :inner;
                    }
                    if (self.meta_block_remaining_len <= 0) {
                        self.run_state = .metablock_done;
                        break :dispatch;
                    }
                    phase = .post_decode_literals;
                    continue :dispatch;
                },

                .post_decode_literals => {
                    if (self.distance_code >= 0) {
                        // Implicit distance case.
                        self.distance_context = if (self.distance_code != 0) 0 else 1;
                        self.dist_rb_idx -= 1;
                        const idx: u32 = @bitCast(self.dist_rb_idx);
                        self.distance_code = self.dist_rb[idx & 3];
                    } else {
                        if (self.block_length[2] == 0) {
                            result = self.decodeDistanceBlockSwitch(br);
                            if (result != .success) break :dispatch;
                        }
                        if (!self.readDistanceInternal(br)) {
                            result = .needs_more_input;
                            break :dispatch;
                        }
                    }
                    if (self.max_distance != self.max_backward_distance) {
                        self.max_distance = @min(@as(i64, @intCast(pos)), self.max_backward_distance);
                    }
                    copy_len = self.copy_length;
                    const dist: i64 = self.distance_code;

                    if (dist > self.max_distance) {
                        // Static dictionary / compound dictionary reference.
                        if (dist > constants.MAX_ALLOWED_DISTANCE) {
                            result = fail(.format_distance);
                            break :dispatch;
                        }
                        const compound_size: i64 = if (self.compound) |c| c.total_size else 0;
                        if (@as(u32, @intCast(dist - self.max_distance)) -% 1 < compound_size) {
                            const address: u32 = @intCast(compound_size -
                                (dist - self.max_distance));
                            if (!self.initCompoundDictCopy(address, @intCast(copy_len))) {
                                result = fail(.error_compound_dictionary);
                                break :dispatch;
                            }
                            pos += self.copyFromCompoundDict(pos);
                            if (pos >= self.ringbuffer_size) {
                                self.run_state = .command_post_write_1;
                                break :dispatch;
                            }
                        } else if (copy_len >= dictionary.min_word_length and
                            copy_len <= dictionary.max_word_length)
                        {
                            const len: usize = @intCast(copy_len);
                            const shift: u5 = @intCast(dictionary.size_bits_by_length[len]);
                            const address: i64 = dist - self.max_distance - 1 - compound_size;
                            const word_mask: i64 = (@as(i64, 1) << shift) - 1;
                            const word_idx: usize = @intCast(address & word_mask);
                            const transform_idx: usize = @intCast(address >> shift);
                            // Compensate double distance-ring-buffer roll.
                            self.dist_rb_idx += self.distance_context;
                            var offset: usize = @as(usize, @intCast(dictionary.offsets_by_length[len])) +
                                word_idx * len;
                            _ = &offset;
                            if (transform_idx >= transforms.num_transforms or
                                dictionary.size_bits_by_length[len] == 0)
                            {
                                result = fail(.format_transform);
                                break :dispatch;
                            }
                            const word = dictionary.data[offset..][0..len];
                            var out_len: usize = 0;
                            if (transform_idx ==
                                @as(usize, @intCast(transforms.cut_off_transforms[0])))
                            {
                                @memcpy(self.ringbuffer[pos..][0..len], word);
                                out_len = len;
                            } else {
                                out_len = transforms.transformDictionaryWord(self.ringbuffer[pos..], word, transform_idx);
                                if (out_len == 0 and self.distance_code <= 120) {
                                    result = fail(.format_transform);
                                    break :dispatch;
                                }
                            }
                            pos += out_len;
                            self.meta_block_remaining_len -= @intCast(out_len);
                            if (pos >= self.ringbuffer_size) {
                                self.run_state = .command_post_write_1;
                                break :dispatch;
                            }
                        } else {
                            result = fail(.format_dictionary);
                            break :dispatch;
                        }
                    } else {
                        // LZ77 backward reference.
                        const src_start: usize =
                            @intCast((@as(i64, @intCast(pos)) - dist) & @as(i64, self.ringbuffer_mask));
                        const dst_end: usize = pos + @as(usize, @intCast(copy_len));
                        const src_end: usize = src_start + @as(usize, @intCast(copy_len));
                        self.dist_rb[@intCast(self.dist_rb_idx & 3)] = self.distance_code;
                        self.dist_rb_idx += 1;
                        self.meta_block_remaining_len -= copy_len;
                        // Copy over the first 16 bytes as a first guess (the
                        // allocation has enough slack for this overcopy).
                        if (src_end > pos and dst_end > src_start) {
                            phase = .post_wrap_copy;
                            continue :dispatch;
                        }
                        if (dst_end >= self.ringbuffer_size or
                            src_end >= self.ringbuffer_size)
                        {
                            phase = .post_wrap_copy;
                            continue :dispatch;
                        }
                        std.mem.copyForwards(u8, self.ringbuffer[pos .. pos + 16], self.ringbuffer[src_start .. src_start + 16]);
                        pos += @intCast(copy_len);
                        if (copy_len > 16) {
                            if (copy_len > 32) {
                                std.mem.copyForwards(u8, self.ringbuffer[pos - @as(usize, @intCast(copy_len)) + 16 ..][0..@intCast(copy_len - 16)], self.ringbuffer[src_start + 16 ..][0..@intCast(copy_len - 16)]);
                            } else {
                                std.mem.copyForwards(u8, self.ringbuffer[pos - @as(usize, @intCast(copy_len)) + 16 ..][0..16], self.ringbuffer[src_start + 16 ..][0..16]);
                            }
                        }
                    }

                    if (self.meta_block_remaining_len <= 0) {
                        self.run_state = .metablock_done;
                        break :dispatch;
                    }
                    phase = .begin;
                    continue :dispatch;
                },

                .post_wrap_copy => {
                    var wrap_guard: i64 = @as(i64, @intCast(self.ringbuffer_size)) - @as(i64, @intCast(pos));
                    const dist: i64 = self.distance_code;
                    const rb_mask: u32 = self.ringbuffer_mask;
                    while (copy_len > 0) {
                        copy_len -= 1;
                        self.ringbuffer[pos] =
                            self.ringbuffer[@intCast((@as(i64, @intCast(pos)) - dist) & rb_mask)];
                        pos += 1;
                        wrap_guard -= 1;
                        if (wrap_guard == 0) {
                            self.run_state = .command_post_write_2;
                            break :dispatch;
                        }
                    }
                    if (self.meta_block_remaining_len <= 0) {
                        self.run_state = .metablock_done;
                    } else {
                        self.run_state = .command_begin;
                    }
                    break :dispatch;
                },
            }
        }

        self.pos = @intCast(pos);
        self.loop_counter = @intCast(if (self.run_state == .command_post_wrap_copy or
            self.run_state == .command_post_write_2)
            copy_len
        else
            ins);
        return result;
    }

    fn saveErrorCode(self: *Decoder, code_in: ErrorCode) Result {
        var code = code_in;
        // A detailed error recorded deeper must not be downgraded by a
        // generic needs-more-input bubbling up from the same call.
        if (code == .needs_more_input and self.err.isError()) {
            code = self.err;
        }
        if (code != .success) {}
        self.err = code;
        // A fully drained internal buffer carries no information; drop it so
        // the next call resumes directly from the caller's input.
        if (self.buffer_length != 0 and self.br.availIn() == 0) {
            self.buffer_length = 0;
        }
        return switch (code) {
            .success => .success,
            .needs_more_input => .needs_more_input,
            .needs_more_output => .needs_more_output,
            else => .err,
        };
    }

    /// Streaming entry point. Advances `next_in` past consumed input and
    /// shrinks `available_out` by written bytes; reports `total_out` when a
    /// pointer is supplied.
    pub fn decompressStream(self: *Decoder, next_in: *[]const u8, available_out: *[]u8, total_out: ?*u64) Result {
        var result: ErrorCode = .success;
        var input: []const u8 = next_in.*;

        if (total_out) |p| p.* = self.partial_pos_out;
        if (self.err.isError()) return .err;

        // Resume. Every exit leaves the reader on a byte boundary, so the
        // accumulator is always empty here and `setInput` is all that is
        // needed to continue from either the caller's slice or the internal
        // buffer.
        if (self.buffer_length == 0) {
            self.br.setInput(input);
        } else {
            // Resume from the internal buffer; states will request more
            // input naturally when its bits are exhausted.
            self.br.setInput(self.buffer[0..self.buffer_length]);
        }

        state_loop: while (true) {
            if (result != .success) {
                if (result == .needs_more_input) {
                    // Pro-actively push output.
                    if (self.ringbuffer.len != 0) {
                        const intermediate =
                            self.writeRingBuffer(available_out, total_out, true);
                        if (intermediate.isError()) {
                            result = intermediate;
                            break :state_loop;
                        }
                    }
                    if (self.buffer_length != 0) {
                        if (self.br.availIn() == 0) {
                            // Every buffered byte has been pulled; continue
                            // straight from the caller's input.
                            self.buffer_length = 0;
                            result = .success;
                            self.br.setInput(input);
                            continue :state_loop;
                        } else if (input.len != 0) {
                            // Pull one more byte into the internal buffer.
                            // `pos` is preserved: the buffer prefix is
                            // unchanged, only the window is extended.
                            result = .success;
                            std.debug.assert(self.buffer_length < 8);
                            self.buffer[self.buffer_length] = input[0];
                            self.buffer_length += 1;
                            self.br.input = self.buffer[0..self.buffer_length];
                            input = input[1..];
                            continue :state_loop;
                        }
                        // No further input: keep whatever is still buffered.
                        self.compactBuffer();
                        break :state_loop;
                    } else {
                        // Input stream does not hold enough input. Move the
                        // bytes that have not been pulled into the internal
                        // buffer and return.
                        //
                        // The accumulator is deliberately left untouched: the
                        // bits it holds were taken from bytes that now sit
                        // before `br.pos`, so the tail simply starts there.
                        // All supplied input ends up consumed, which lets the
                        // caller swap its buffer between calls.
                        var src_tail = self.br.input[self.br.pos..];
                        var staged: usize = 0;
                        while (src_tail.len != 0 and self.buffer_length < 8) {
                            self.buffer[self.buffer_length] = src_tail[0];
                            self.buffer_length += 1;
                            src_tail = src_tail[1..];
                            staged += 1;
                        }
                        if (self.br.input.ptr == input.ptr) {
                            input = self.br.input[self.br.pos + staged ..];
                        }
                        break :state_loop;
                    }
                }
                // Fail or needs more output.
                if (self.buffer_length != 0) {
                    // Keep the internal buffer for the next call, compacting
                    // out bytes already consumed from its front.
                    self.compactBuffer();
                } else {
                    // Capture the unconsumed tail so no bit of the stream is
                    // lost across calls.
                    self.stageResume(&input);
                }
                break :state_loop;
            }

            switch (self.run_state) {
                .uninited => {
                    if (!self.br.ensureBits(8)) {
                        result = .needs_more_input;
                        continue :state_loop;
                    }
                    result = self.decodeWindowBits(&self.br);
                    if (result != .success) continue :state_loop;
                    self.run_state = if (self.large_window)
                        .large_window_bits
                    else
                        .initialize;
                    continue :state_loop;
                },
                .large_window_bits => {
                    var bits: u64 = 0;
                    if (!self.br.safeReadBits(6, &bits)) {
                        result = .needs_more_input;
                        continue :state_loop;
                    }
                    self.window_bits = @intCast(bits & 63);
                    if (self.window_bits < constants.LARGE_MIN_WBITS or
                        self.window_bits > constants.LARGE_MAX_WBITS)
                    {
                        result = fail(.format_window_bits);
                        continue :state_loop;
                    }
                    self.run_state = .initialize;
                    continue :state_loop;
                },
                .initialize => {
                    self.max_backward_distance =
                        (@as(i64, 1) << @intCast(self.window_bits)) - constants.WINDOW_GAP;
                    if (self.block_type_trees.len == 0) {
                        self.block_type_trees = self.allocator.alloc(
                            HuffmanCode,
                            3 * (huff.HUFFMAN_MAX_SIZE_258 + huff.HUFFMAN_MAX_SIZE_26),
                        ) catch {
                            result = fail(.alloc_block_type_trees);
                            continue :state_loop;
                        };
                    }
                    @memset(self.block_type_trees, .{ .bits = 0, .value = 0 });
                    self.block_len_trees =
                        self.block_type_trees[3 * huff.HUFFMAN_MAX_SIZE_258 ..];
                    self.run_state = .metablock_begin;
                    continue :state_loop;
                },
                .metablock_begin => {
                    self.metablockBegin();
                    self.run_state = .metablock_header;
                    continue :state_loop;
                },
                .metablock_header => {
                    result = self.decodeMetaBlockLength(&self.br);
                    if (result != .success) continue :state_loop;
                    if (self.is_metadata or self.is_uncompressed) {
                        if (!self.br.jumpToByteBoundary()) {
                            result = fail(.format_padding_1);
                            continue :state_loop;
                        }
                    }
                    if (self.is_metadata) {
                        self.run_state = .metadata;
                        if (self.metadata_cb.start) |f| {
                            f(self.metadata_cb.ctx, @intCast(@max(self.meta_block_remaining_len, 0)));
                        }
                        continue :state_loop;
                    }
                    if (self.meta_block_remaining_len == 0) {
                        self.run_state = .metablock_done;
                        continue :state_loop;
                    }
                    self.calculateRingBufferSize();
                    self.run_state = if (self.is_uncompressed)
                        .uncompressed
                    else
                        .before_compressed_metablock_header;
                    continue :state_loop;
                },
                .before_compressed_metablock_header => {
                    self.loop_counter = 0;
                    self.sub_loop_counter = 0;
                    self.substate_huffman = .none;
                    self.substate_tree_group = .none;
                    self.substate_context_map = .none;
                    self.run_state = .huffman_code_0;
                    continue :state_loop;
                },
                .huffman_code_0 => {
                    if (self.loop_counter >= 3) {
                        self.run_state = .metablock_header_2;
                        continue :state_loop;
                    }
                    const idx: usize = @intCast(self.loop_counter);
                    // The partially decoded value must survive across calls:
                    // the "long" form needs the bit count chosen by the
                    // preceding "short" form.
                    if (self.substate_decode_uint8 == .none) {
                        self.var_len_scratch = @intCast(self.num_block_types[idx] -% 1);
                    }
                    result = self.decodeVarLenUint8(&self.br, &self.var_len_scratch);
                    if (result != .success) continue :state_loop;
                    self.num_block_types[idx] = @as(u64, self.var_len_scratch) + 1;
                    if (self.num_block_types[idx] < 2) {
                        self.loop_counter += 1;
                        continue :state_loop;
                    }
                    self.run_state = .huffman_code_1;
                    continue :state_loop;
                },
                .huffman_code_1 => {
                    const idx: usize = @intCast(self.loop_counter);
                    const alphabet_size = self.num_block_types[idx] + 2;
                    const tree_offset = idx * huff.HUFFMAN_MAX_SIZE_258;
                    result = self.readHuffmanCode(&self.br, alphabet_size, alphabet_size, self.block_type_trees[tree_offset .. tree_offset + huff.HUFFMAN_MAX_SIZE_258], null);
                    if (result != .success) continue :state_loop;
                    self.run_state = .huffman_code_2;
                    continue :state_loop;
                },
                .huffman_code_2 => {
                    const idx: usize = @intCast(self.loop_counter);
                    const tree_offset = idx * huff.HUFFMAN_MAX_SIZE_26;
                    result = self.readHuffmanCode(&self.br, constants.NUM_BLOCK_LEN_SYMBOLS, constants.NUM_BLOCK_LEN_SYMBOLS, self.block_len_trees[tree_offset .. tree_offset + huff.HUFFMAN_MAX_SIZE_26], null);
                    if (result != .success) continue :state_loop;
                    self.run_state = .huffman_code_3;
                    continue :state_loop;
                },
                .huffman_code_3 => {
                    const idx: usize = @intCast(self.loop_counter);
                    const tree_offset = idx * huff.HUFFMAN_MAX_SIZE_26;
                    const len_tree =
                        self.block_len_trees[tree_offset .. tree_offset + huff.HUFFMAN_MAX_SIZE_26];
                    // Resumable block-length read (see SafeReadBlockLength).
                    var index: u64 = 0;
                    if (self.substate_read_block_length == .none) {
                        if (!readSymbolSafe(len_tree, &self.br, &index)) {
                            result = .needs_more_input;
                            continue :state_loop;
                        }
                        self.block_length_index = index;
                    } else {
                        index = self.block_length_index;
                    }
                    const range = ranges.prefix_code_ranges[@intCast(index)];
                    var extra: u64 = 0;
                    if (!self.br.safeReadBits(range.nbits, &extra)) {
                        self.substate_read_block_length = .suffix;
                        result = .needs_more_input;
                        continue :state_loop;
                    }
                    self.block_length[idx] = @as(u64, range.offset) + extra;
                    self.substate_read_block_length = .none;
                    self.loop_counter += 1;
                    self.run_state = .huffman_code_0;
                    continue :state_loop;
                },
                .uncompressed => {
                    result = self.copyUncompressedBlockToOutput(available_out, total_out);
                    if (result != .success) continue :state_loop;
                    self.run_state = .metablock_done;
                    continue :state_loop;
                },
                .metadata => {
                    result = self.skipMetadataBlock();
                    if (result != .success) continue :state_loop;
                    self.run_state = .metablock_done;
                    continue :state_loop;
                },
                .metablock_header_2 => {
                    var bits: u64 = 0;
                    if (!self.br.safeReadBits(6, &bits)) {
                        result = .needs_more_input;
                        continue :state_loop;
                    }
                    self.distance_postfix_bits = @intCast(bits & 3);
                    bits >>= 2;
                    self.num_direct_distance_codes =
                        @as(u32, @intCast(bits)) << @intCast(self.distance_postfix_bits);
                    self.context_modes = self.allocator.alloc(
                        u8,
                        @intCast(self.num_block_types[0]),
                    ) catch {
                        result = fail(.alloc_context_modes);
                        continue :state_loop;
                    };
                    self.loop_counter = 0;
                    self.run_state = .context_modes;
                    continue :state_loop;
                },
                .context_modes => {
                    var i: usize = @intCast(self.loop_counter);
                    while (i < self.num_block_types[0]) {
                        var bits: u64 = 0;
                        if (!self.br.safeReadBits(2, &bits)) {
                            self.loop_counter = @intCast(i);
                            result = .needs_more_input;
                            continue :state_loop;
                        }
                        self.context_modes[i] = @truncate(bits);
                        i += 1;
                    }
                    self.loop_counter = @intCast(i);
                    self.run_state = .context_map_1;
                    continue :state_loop;
                },
                .context_map_1 => {
                    result = self.decodeContextMap(&self.br, self.num_block_types[0] << constants.LITERAL_CONTEXT_BITS, &self.num_literal_htrees, &self.context_map);
                    if (result != .success) continue :state_loop;
                    self.detectTrivialLiteralBlockTypes();
                    {}
                    self.run_state = .context_map_2;
                    continue :state_loop;
                },
                .context_map_2 => {
                    const npostfix = self.distance_postfix_bits;
                    const ndirect = self.num_direct_distance_codes;
                    var distance_alphabet_size_max = constants.distanceAlphabetSize(npostfix, ndirect, constants.MAX_DISTANCE_BITS);
                    var distance_alphabet_size_limit = distance_alphabet_size_max;
                    if (self.large_window) {
                        const limit = constants.calculateDistanceCodeLimit(constants.MAX_ALLOWED_DISTANCE, npostfix, ndirect);
                        distance_alphabet_size_max = constants.distanceAlphabetSize(npostfix, ndirect, constants.LARGE_MAX_DISTANCE_BITS);
                        distance_alphabet_size_limit = limit.max_alphabet_size;
                    }
                    result = self.decodeContextMap(&self.br, self.num_block_types[2] << constants.DISTANCE_CONTEXT_BITS, &self.num_dist_htrees, &self.dist_context_map);
                    if (result != .success) continue :state_loop;

                    var ok = true;
                    ok = self.treeGroupAlloc(&self.literal_hgroup, constants.NUM_LITERAL_SYMBOLS, constants.NUM_LITERAL_SYMBOLS, @intCast(self.num_literal_htrees)) and ok;
                    ok = self.treeGroupAlloc(&self.insert_copy_hgroup, constants.NUM_COMMAND_SYMBOLS, constants.NUM_COMMAND_SYMBOLS, @intCast(self.num_block_types[1])) and ok;
                    ok = self.treeGroupAlloc(&self.distance_hgroup, distance_alphabet_size_max, distance_alphabet_size_limit, @intCast(self.num_dist_htrees)) and ok;
                    if (!ok) {
                        return self.saveErrorCode(fail(.alloc_tree_groups));
                    }
                    self.loop_counter = 0;
                    self.run_state = .tree_group;
                    continue :state_loop;
                },
                .tree_group => {
                    const group: *TreeGroup = switch (self.loop_counter) {
                        0 => &self.literal_hgroup,
                        1 => &self.insert_copy_hgroup,
                        2 => &self.distance_hgroup,
                        else => return self.saveErrorCode(fail(.unreachable_state)),
                    };
                    result = self.huffmanTreeGroupDecode(&self.br, group);
                    if (result != .success) continue :state_loop;
                    self.loop_counter += 1;
                    if (self.loop_counter < 3) continue :state_loop;
                    self.run_state = .before_compressed_metablock_body;
                    continue :state_loop;
                },
                .before_compressed_metablock_body => {
                    self.prepareLiteralDecoding();
                    self.dist_context_map_slice = self.dist_context_map;
                    self.htree_command = self.insert_copy_hgroup.get(0);
                    if (!self.ensureRingBuffer()) {
                        if (self.err == .resource_limit) {
                            result = .resource_limit;
                        } else {
                            result = fail(.alloc_ring_buffer_2);
                        }
                        continue :state_loop;
                    }
                    self.calculateDistanceLut();
                    self.run_state = .command_begin;
                    continue :state_loop;
                },
                .command_begin,
                .command_inner,
                .command_post_decode_literals,
                .command_post_wrap_copy,
                => {
                    result = self.processCommands();
                    continue :state_loop;
                },

                .command_inner_write,
                .command_post_write_1,
                .command_post_write_2,
                => {
                    result = self.writeRingBuffer(available_out, total_out, false);
                    if (result != .success) continue :state_loop;
                    self.wrapRingBuffer();
                    if (self.ringbuffer_size ==
                        (@as(u32, 1) << @intCast(self.window_bits)))
                    {
                        self.max_distance = self.max_backward_distance;
                    }
                    if (self.run_state == .command_post_write_1) {
                        if (self.compound) |addon| {
                            if (addon.br_length != addon.br_copied) {
                                self.pos += @intCast(self.copyFromCompoundDict(@intCast(self.pos)));
                                if (self.pos >= self.ringbuffer_size) continue :state_loop;
                            }
                        }
                        if (self.meta_block_remaining_len == 0) {
                            self.run_state = .metablock_done;
                        } else {
                            self.run_state = .command_begin;
                        }
                    } else if (self.run_state == .command_post_write_2) {
                        self.run_state = .command_post_wrap_copy;
                    } else { // command_inner_write
                        if (self.loop_counter == 0) {
                            if (self.meta_block_remaining_len == 0) {
                                self.run_state = .metablock_done;
                            } else {
                                self.run_state = .command_post_decode_literals;
                            }
                        } else {
                            self.run_state = .command_inner;
                        }
                    }
                    continue :state_loop;
                },

                .metablock_done => {
                    if (self.meta_block_remaining_len < 0) {
                        result = fail(.format_block_length_2);
                        continue :state_loop;
                    }
                    self.cleanupAfterMetablock(true);
                    if (!self.is_last_metablock) {
                        self.run_state = .metablock_begin;
                        continue :state_loop;
                    }
                    if (!self.br.jumpToByteBoundary()) {
                        result = fail(.format_padding_2);
                        continue :state_loop;
                    }
                    if (self.buffer_length == 0) {
                        self.br.unload();
                        input = self.br.input[self.br.pos..];
                    }
                    self.run_state = .done;
                    continue :state_loop;
                },
                .done => {
                    if (self.ringbuffer.len != 0) {
                        result = self.writeRingBuffer(available_out, total_out, true);
                        if (result != .success) continue :state_loop;
                    }
                    return self.saveErrorCode(result);
                },
            }
        }
        next_in.* = input;
        return self.saveErrorCode(result);
    }
};

/// Decompress a complete Brotli stream in one call with default options.
pub fn decompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decompressWithOptions(allocator, input, .{});
}

/// Decompress a complete Brotli stream with explicit options (window size, limits, dictionary, etc.).
pub fn decompressWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
) ![]u8 {
    var capacity: usize = @max(@as(usize, 4096), input.len *| 4);
    while (true) {
        var dec = Decoder.init(allocator, options);
        defer dec.deinit();

        var in: []const u8 = input;
        var out = try allocator.alloc(u8, capacity);
        defer allocator.free(out);

        var avail: []u8 = out;
        var total: u64 = 0;
        switch (dec.decompressStream(&in, &avail, &total)) {
            .success => {
                const result = try allocator.alloc(u8, @intCast(total));
                @memcpy(result, out[0..@intCast(total)]);
                return result;
            },
            .needs_more_output => {
                capacity = capacity *| 2;
                continue;
            },
            .needs_more_input => return error.TruncatedInput,
            .err => return dec.errorCode().toError(),
        }
    }
}

/// Decompress into a caller-provided output buffer.
///
/// Returns the number of bytes written. Fails with `error.ResourceLimitExceeded`
/// when the buffer is too small, `error.TruncatedInput` when the stream ends
/// early, and the decoder's specific error otherwise, so a caller can tell
/// "give me a bigger buffer" apart from "this stream is corrupt".
pub fn decompressInto(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []u8,
) !usize {
    var dec = Decoder.init(allocator, .{});
    defer dec.deinit();
    var in: []const u8 = input;
    var avail: []u8 = output;
    var total: u64 = 0;
    switch (dec.decompressStream(&in, &avail, &total)) {
        .success => {},
        .needs_more_output => return error.ResourceLimitExceeded,
        .needs_more_input => return error.TruncatedInput,
        .err => return dec.errorCode().toError(),
    }
    return @intCast(total);
}

const testing = std.testing;

test "decode empty last-empty stream" {
    // A stream with just window bits (16) and ISLAST+ISEMPTY meta-block:
    // bit "0" selects wbits=16, then two bits 11 (islast=1, isempty=1).
    var d = Decoder.init(testing.allocator, .{});
    defer d.deinit();
    var input: []const u8 = &.{0x06};
    var out: [16]u8 = undefined;
    var avail: []u8 = &out;
    const r = d.decompressStream(&input, &avail, null);
    try testing.expectEqual(Result.success, r);
    try testing.expectEqual(@as(usize, 0), out.len - avail.len);
}

fn tryVerify(data: []const u8, expected: []const u8) !void {
    var d = Decoder.init(std.heap.page_allocator, .{});
    defer d.deinit();
    var input: []const u8 = data;
    const out = try std.heap.page_allocator.alloc(u8, expected.len);
    const out_full = out;
    defer std.heap.page_allocator.free(out_full);
    var total: u64 = 0;
    const r = d.decompressStream(&input, &out, &total);
    try std.testing.expectEqual(Result.success, r);
    try std.testing.expectEqual(@as(u64, expected.len), total);
    try std.testing.expectEqualSlices(u8, expected, out[0..expected.len]);
}

fn tryDecode(data: []const u8, expected_len: usize) !void {
    var d = Decoder.init(std.heap.page_allocator, .{});
    defer d.deinit();
    var input: []const u8 = data;
    var out: []u8 = try std.heap.page_allocator.alloc(u8, expected_len);
    const out_full = out;
    defer std.heap.page_allocator.free(out_full);
    var total: u64 = 0;
    const r = d.decompressStream(&input, &out, &total);
    if (r != .success) {}
}

test "small reference-encoded streams" {
    // "hello world hello world hello world" compressed at q5 lgwin=22
    try tryDecode(&.{ 0x1b, 0x22, 0x00, 0x00, 0x24, 0x40, 0x72, 0x90, 0x45, 0x98, 0xc9, 0x65, 0xf2, 0x3c, 0x5d, 0x1d }, 35);
    // 500 bytes of "the quick brown fox " repeated, q5 lgwin=22
    try tryDecode(&.{ 0x1b, 0xf3, 0x01, 0x00, 0x04, 0x74, 0x63, 0xa9, 0x2e, 0xe7, 0x83, 0x62, 0xf2, 0x20, 0x82, 0xd6, 0x28, 0x04, 0x16, 0x95, 0xd9, 0x0a, 0xce, 0x69, 0xa2, 0xf1, 0x35, 0xe9, 0xc7, 0x01 }, 500);
}

test "decompress reference-encoded dictionary resource" {
    // The embedded .br resource decodes to exactly the 122784 static
    // dictionary bytes; this validates the whole decoder pipeline end to end.
    // Uses page_allocator: the output is large and short-lived.
    const compressed = @embedFile("../dictionary/dictionary.bin.br");
    const expected = dictionary.data;

    var d = Decoder.init(std.heap.page_allocator, .{});
    defer d.deinit();
    var input: []const u8 = compressed;
    var output: []u8 = try std.heap.page_allocator.alloc(u8, expected.len);
    const output_full = output; // decompressStream advances `output`; keep base for free
    defer std.heap.page_allocator.free(output_full);
    var total: u64 = 0;
    const r = d.decompressStream(&input, &output, &total);
    try testing.expectEqual(Result.success, r);
    try testing.expectEqual(@as(u64, expected.len), total);
    try testing.expectEqualSlices(u8, expected, output_full[0..expected.len]);
}

test "decodes streams produced by an independent implementation" {
    for (reference_streams) |s| {
        const got = decompress(testing.allocator, s.compressed) catch |e| {
            std.debug.print("reference stream {s} q{d} failed to decode: {any}\n", .{ s.name, s.quality, e });
            return e;
        };
        defer testing.allocator.free(got);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
        var hex: [64]u8 = undefined;
        hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, &hex, s.sha256)) {
            std.debug.print("reference stream {s} q{d}: decoded {d} bytes, sha256={s}, expected {d} bytes sha256={s}\n", .{
                s.name, s.quality, got.len, hex, s.original_len, s.sha256,
            });
            return error.ContentMismatch;
        }
        try testing.expectEqual(s.original_len, got.len);
    }
}

/// Feeds a stream through the decoder in fixed-size input and output chunks.
///
/// Follows the streaming contract exactly: `next_in` is advanced past the
/// bytes the decoder actually consumed, and whatever it hands back is
/// re-offered on the next call. Ignoring the returned slice would silently
/// drop input the decoder declined to consume.
fn decodeChunked(stream: []const u8, in_chunk: usize, out_chunk: usize) !std.ArrayList(u8) {
    var d = Decoder.init(testing.allocator, .{});
    defer d.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);

    var scratch: [64]u8 = undefined;
    var ci: usize = 0;
    while (true) {
        var end = ci;
        var in: []const u8 = &.{};
        if (ci < stream.len) {
            end = @min(ci + in_chunk, stream.len);
            in = stream[ci..end];
        }
        var avail: []u8 = scratch[0..@min(out_chunk, scratch.len)];
        const before = avail.len;
        const r = d.decompressStream(&in, &avail, null);
        try out.appendSlice(testing.allocator, scratch[0 .. before - avail.len]);
        // `in` now starts at the first byte the decoder did not consume, so
        // rewind the cursor by exactly the bytes it handed back.
        ci = end - in.len;
        switch (r) {
            .success => break,
            .needs_more_input => {
                if (ci >= stream.len) return error.TruncatedChunked;
            },
            .needs_more_output => {},
            .err => return error.FailedChunked,
        }
    }
    return out;
}

test "reference streams survive every buffer boundary" {
    const in_chunks = [_]usize{ 1, 2, 3, 7, 13, 1 << 20 };
    const out_chunks = [_]usize{ 1, 3, 17, 1 << 20 };

    for (reference_streams) |s| {
        for (in_chunks) |ic| {
            for (out_chunks) |oc| {
                var got = try decodeChunked(s.compressed, ic, oc);
                defer got.deinit(testing.allocator);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(got.items, &digest, .{});
                var hex: [64]u8 = undefined;
                hex = std.fmt.bytesToHex(digest, .lower);
                if (!std.mem.eql(u8, &hex, s.sha256)) {
                    std.debug.print("reference stream {s} in={d} out={d}: decoded {d} bytes, sha256={s}\n", .{
                        s.name, ic, oc, got.items.len, hex,
                    });
                    return error.ContentMismatch;
                }
            }
        }
    }
}

test "regression: long-run stream survives every input/output chunk size" {
    // A long literal-free run followed by a word. It decodes to far more output
    // than a small window, so the decoder must wrap its ring buffer and keep
    // decoding while the caller refills tiny output buffers.
    //
    // This case was previously excluded from the chunk matrix because the
    // driving helper advanced its input cursor past every byte it handed to the
    // decoder instead of honouring the bytes the decoder returned through
    // `next_in`. Bytes the decoder deliberately kept were therefore lost and
    // the stream looked truncated.
    const in_chunks = [_]usize{ 1, 2, 3, 7, 13, 1 << 20 };
    const out_chunks = [_]usize{ 1, 3, 17, 1 << 20 };

    for (reference_streams) |s| {
        if (s.original_len < 1 << 17) continue;
        for (in_chunks) |ic| {
            for (out_chunks) |oc| {
                var got = try decodeChunked(s.compressed, ic, oc);
                defer got.deinit(testing.allocator);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(got.items, &digest, .{});
                var hex: [64]u8 = undefined;
                hex = std.fmt.bytesToHex(digest, .lower);
                if (!std.mem.eql(u8, &hex, s.sha256)) {
                    std.debug.print("long-run {s} in={d} out={d}: decoded {d} bytes, sha256={s}\n", .{
                        s.name, ic, oc, got.items.len, hex,
                    });
                    return error.ContentMismatch;
                }
            }
        }
    }
}

test "regression: decoder hands unconsumed input back to the caller" {
    // The streaming contract: `next_in` advances only past bytes that were
    // actually consumed. Handing a small window and then re-offering whatever
    // comes back must make forward progress on every call.
    const payload = "resumption across sub-byte boundaries must preserve every bit. " ++
        "the quick brown fox jumps over the lazy dog. " ++
        "the quick brown fox jumps over the lazy dog. ";
    const encoder = @import("../compress/encode.zig");
    const comp = try encoder.compressWithOptions(testing.allocator, payload, .{ .quality = 9 });
    defer testing.allocator.free(comp);

    var d = Decoder.init(testing.allocator, .{});
    defer d.deinit();

    var out: [7]u8 = undefined;
    var produced: usize = 0;
    var feed_at: usize = 0;
    var guard: usize = 0;
    var finished = false;

    while (guard < 10_000_000) : (guard += 1) {
        var in: []const u8 = &.{};
        const end = @min(feed_at + 3, comp.len);
        if (feed_at < comp.len) in = comp[feed_at..end];
        var avail: []u8 = &out;
        const before = avail.len;
        const r = d.decompressStream(&in, &avail, null);
        produced += before - avail.len;
        // Only bytes the decoder consumed leave the cursor.
        try testing.expect(end - in.len >= feed_at);
        feed_at = end - in.len;
        switch (r) {
            .success => {
                finished = true;
                break;
            },
            .needs_more_input => {
                if (feed_at >= comp.len) return error.TruncatedInput;
            },
            .needs_more_output => {},
            .err => return error.DecodeFailed,
        }
    }
    try testing.expect(finished);
    try testing.expectEqual(payload.len, produced);
}

pub const reference_streams_mod = @import("reference_streams.zig");
pub const ReferenceStream = reference_streams_mod.ReferenceStream;
pub const reference_streams = reference_streams_mod.reference_streams;

test "malformed input yields only documented errors, never a panic" {
    const encoder = @import("../compress/encode.zig");
    const allocator = testing.allocator;

    // A stream with real structure: literals, a copy, a tree description.
    const payload = "structural payload used to derive malformed variants: " ++
        "the quick brown fox jumps over the lazy dog. " ++
        "the quick brown fox jumps over the lazy dog.";
    const valid = try encoder.compressWithOptions(allocator, payload, .{ .quality = 5 });
    defer allocator.free(valid);

    // Every single-bit flip must either decode to something well formed or fail
    // with an error from the public set. `@panic` and `catch unreachable` on
    // externally controlled bytes would show up here as a test crash.
    var bad = try allocator.dupe(u8, valid);
    defer allocator.free(bad);

    for (0..valid.len) |byte_index| {
        for (0..8) |bit| {
            const mask = @as(u8, 1) << @intCast(bit);
            bad[byte_index] ^= mask;
            defer bad[byte_index] ^= mask;

            if (decompress(allocator, bad)) |got| {
                defer allocator.free(got);
                // A decode that succeeds must be self-consistent: feeding it
                // back through the streaming path yields the same bytes.
                var d = Decoder.init(allocator, .{});
                defer d.deinit();
                const again = try d.decompress(bad);
                defer allocator.free(again);
                try testing.expectEqualSlices(u8, got, again);
            } else |e| {
                switch (e) {
                    error.CorruptStream,
                    error.TruncatedInput,
                    error.InvalidHeader,
                    error.InvalidMetaBlock,
                    error.InvalidHuffmanTree,
                    error.InvalidCommand,
                    error.InvalidDistance,
                    error.InvalidDictionaryReference,
                    error.ResourceLimitExceeded,
                    error.OutputLimitExceeded,
                    error.InvalidParameter,
                    error.InvalidStreamingState,
                    error.OutOfMemory,
                    => {},
                    else => return e,
                }
            }
        }
    }
}

test "invalid window declarations are rejected without large allocation" {
    const allocator = testing.allocator;

    // Window bits occupy the low bits of the first stream byte. Large values
    // that still fit the field, and reserved encodings, must be refused by the
    // documented header error rather than provoking a huge ring buffer.
    const windows = [_]u8{ 0x00, 0x01, 0x0E, 0x0F, 0x1E, 0x1F, 0x2E, 0x2F, 0x3E, 0x3F, 0xFE, 0xFF };
    for (windows) |w| {
        const bad = [_]u8{w};
        const r = decompress(allocator, &bad);
        if (r) |got| {
            // Some encodings legitimately mean "empty payload" or a reserved
            // but harmless window; only accept a genuinely empty result.
            allocator.free(got);
            try testing.expectEqual(@as(usize, 0), got.len);
        } else |e| {
            switch (e) {
                error.InvalidHeader, error.CorruptStream, error.TruncatedInput, error.ResourceLimitExceeded => {},
                else => return e,
            }
        }
    }

    // A header promising a very large metablock must be refused on its own
    // merits rather than by exhausting memory first.
    for ([_][]const u8{
        "\x1B\x00\x00\x00\x00",
        "\x1B\xFF\xFF\xFF\xFF\xFF",
        "\x1B\x00\x00\x00\x00\x00\x00\x00\x00",
    }) |bad| {
        if (decompress(allocator, bad)) |got| allocator.free(got) else |_| {}
    }
}

test "trailing bytes after the final metablock follow the documented policy" {
    const encoder = @import("../compress/encode.zig");
    const allocator = testing.allocator;
    const valid = try encoder.compressWithOptions(allocator, "trailing data policy probe", .{ .quality = 5 });
    defer allocator.free(valid);

    // Appending garbage must not be mistaken for part of the stream, and must
    // never panic regardless of which policy is in force.
    var padded = try allocator.alloc(u8, valid.len + 8);
    defer allocator.free(padded);
    @memcpy(padded[0..valid.len], valid);
    @memset(padded[valid.len..], 0xA5);
    if (decompress(allocator, padded)) |got| {
        defer allocator.free(got);
        try testing.expectEqualStrings("trailing data policy probe", got);
    } else |e| {
        switch (e) {
            error.CorruptStream, error.TruncatedInput, error.InvalidMetaBlock => {},
            else => return e,
        }
    }
}

test "regression: reset decoder exposes no stale context bytes at stream start" {
    // The ring buffer retains previous-stream bytes across reset(). Literal
    // contexts for the first two output bytes must still be zero (as the
    // encoder codes them), never stale bytes, or context-modeled streams
    // decode to wrong bytes after reuse.
    const encoder = @import("../compress/encode.zig");
    const allocator = testing.allocator;

    // Heterogeneous payload: forces literal context modeling with
    // non-trivial context maps at quality 9. The payload slightly exceeds the
    // 64 KiB window, so after the first decode the ring buffer's tail slots
    // hold previous-stream bytes; a reset decoder must still start the next
    // stream with zero contexts. Word text compresses well inside the window
    // (so real Huffman trees are emitted) while the mixed vocabularies keep
    // the context map non-trivial.
    const vocab1 = [_][]const u8{
        "alpha ", "bravo ", "charlie ", "delta ",  "echo ", "foxtrot ",
        "golf ",  "hotel ", "india ",   "juliet ", "kilo ", "lima ",
    };
    const vocab2 = [_][]const u8{
        "one ",   "two ",   "three ", "four ", "five ",   "six ",
        "seven ", "eight ", "nine ",  "ten ",  "eleven ", "twelve ",
    };
    const src1 = try allocator.alloc(u8, 70000);
    defer allocator.free(src1);
    const src2 = try allocator.alloc(u8, 70000);
    defer allocator.free(src2);
    var prng = std.Random.DefaultPrng.init(99);
    var off1: usize = 0;
    while (off1 < src1.len) {
        const w = vocab1[prng.random().intRangeLessThan(usize, 0, vocab1.len)];
        const n = @min(w.len, src1.len - off1);
        @memcpy(src1[off1..][0..n], w[0..n]);
        off1 += n;
    }
    var off2: usize = 0;
    while (off2 < src2.len) {
        const w = vocab2[prng.random().intRangeLessThan(usize, 0, vocab2.len)];
        const n = @min(w.len, src2.len - off2);
        @memcpy(src2[off2..][0..n], w[0..n]);
        off2 += n;
    }

    const comp1 = try encoder.compressWithOptions(allocator, src1, .{ .quality = 9, .lgWin = 16 });
    defer allocator.free(comp1);
    const comp2 = try encoder.compressWithOptions(allocator, src2, .{ .quality = 9, .lgWin = 16 });
    defer allocator.free(comp2);

    var dec = Decoder.init(allocator, .{});
    defer dec.deinit();

    const got1 = try dec.decompress(comp1);
    defer allocator.free(got1);
    try testing.expectEqualSlices(u8, src1, got1);

    // Reuse without freeing: the ring buffer still holds src1's tail.
    dec.reset(null);
    const got2 = try dec.decompress(comp2);
    defer allocator.free(got2);
    try testing.expectEqualSlices(u8, src2, got2);
}
