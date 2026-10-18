//! Format constants shared by the Brotli encoder and decoder.

/// Specification: 7.3. Encoding of the context map.
pub const CONTEXT_MAP_MAX_RLE = 16;

/// Specification: 2. Compressed representation overview.
pub const MAX_NUMBER_OF_BLOCK_TYPES = 256;

/// Specification: 3.3. Alphabet sizes.
pub const NUM_LITERAL_SYMBOLS = 256;
pub const NUM_COMMAND_SYMBOLS = 704;
pub const NUM_BLOCK_LEN_SYMBOLS = 26;
pub const MAX_CONTEXT_MAP_SYMBOLS = MAX_NUMBER_OF_BLOCK_TYPES + CONTEXT_MAP_MAX_RLE;
pub const MAX_BLOCK_TYPE_SYMBOLS = MAX_NUMBER_OF_BLOCK_TYPES + 2;

/// Specification: 3.5. Complex prefix codes.
pub const REPEAT_PREVIOUS_CODE_LENGTH = 16;
pub const REPEAT_ZERO_CODE_LENGTH = 17;
pub const CODE_LENGTH_CODES = REPEAT_ZERO_CODE_LENGTH + 1;
/// "code length of 8 is repeated"
pub const INITIAL_REPEATED_CODE_LENGTH = 8;

/// "Large Window Brotli".
pub const LARGE_MAX_DISTANCE_BITS = 62;
pub const LARGE_MIN_WBITS = 10;
pub const LARGE_MAX_WBITS = 30;

/// Specification: 4. Encoding of distances.
pub const NUM_DISTANCE_SHORT_CODES = 16;
pub const MAX_NPOSTFIX = 3;
pub const MAX_NDIRECT = 120;
pub const MAX_DISTANCE_BITS = 24;

/// Widest distance alphabet over all supported configurations (1128 symbols).
pub const NUM_DISTANCE_SYMBOLS: u32 =
    NUM_DISTANCE_SHORT_CODES + MAX_NDIRECT + (LARGE_MAX_DISTANCE_BITS << (MAX_NPOSTFIX + 1));

pub fn distanceAlphabetSize(npostfix: u32, ndirect: u32, max_nbits: u32) u32 {
    return NUM_DISTANCE_SHORT_CODES + ndirect + (@as(u32, max_nbits) << @intCast(npostfix + 1));
}

/// ((1 << 26) - 4) is the maximal distance expressible in RFC 7932 brotli
/// with NPOSTFIX=0 and NDIRECT=0.
pub const MAX_DISTANCE: u32 = 0x3FFFFFC;

/// Safe distance limit; allows safe distance calculation without overflow.
pub const MAX_ALLOWED_DISTANCE: u32 = 0x7FFFFFFC;

/// Specification: 4. Encoding of Literal Insertion Lengths and Copy Lengths.
pub const NUM_INS_COPY_CODES = 24;

/// 7.1. Context modes and context ID lookup for literals.
pub const LITERAL_CONTEXT_BITS = 6;

/// 7.2. Context ID for distances.
pub const DISTANCE_CONTEXT_BITS = 2;

/// 9.1. Format of the Stream Header.
pub const WINDOW_GAP = 16;

pub fn maxBackwardLimit(w: u32) usize {
    return (@as(usize, 1) << @intCast(w)) - WINDOW_GAP;
}

pub const DistanceCodeLimit = struct {
    max_alphabet_size: u32,
    max_distance: u32,
};

/// Calculates the maximal size of the distance alphabet such that distances
/// greater than `max_distance` cannot be represented. Only complete distance
/// code groups are admitted.
pub fn calculateDistanceCodeLimit(
    max_distance: u32,
    npostfix: u32,
    ndirect: u32,
) DistanceCodeLimit {
    if (max_distance <= ndirect) {
        return .{ .max_alphabet_size = max_distance + NUM_DISTANCE_SHORT_CODES, .max_distance = max_distance };
    }
    // The first prohibited value.
    var offset: u32 = max_distance + 1 - ndirect - 1;
    // Postfix for the last dcode in the group.
    const postfix = (@as(u32, 1) << @intCast(npostfix)) - 1;
    offset = (offset >> @intCast(npostfix)) + 4;
    const tmp = offset / 2;
    var ndistbits: u32 = std.math.log2_int(u32, tmp);
    const half = (offset >> @intCast(ndistbits)) & 1;
    var group = ((ndistbits - 1) << 1) | half;
    if (group == 0) {
        return .{ .max_alphabet_size = ndirect + NUM_DISTANCE_SHORT_CODES, .max_distance = ndirect };
    }
    group -= 1;
    ndistbits = (group >> 1) + 1;
    const extra = (@as(u32, 1) << @intCast(ndistbits)) - 1;
    var start = (@as(u32, 1) << @intCast(ndistbits + 1)) - 4;
    start += (group & 1) << @intCast(ndistbits);
    return .{
        .max_alphabet_size = ((group << @intCast(npostfix)) | postfix) +
            ndirect + NUM_DISTANCE_SHORT_CODES + 1,
        .max_distance = ((start + extra) << @intCast(npostfix)) + postfix + ndirect + 1,
    };
}

/// Literal/Command/Distance block size maximum; same as maximum metablock
/// size; used as block size when there is no block switching.
pub const BLOCK_SIZE_CAP: u32 = 1 << 24;

test "calculateDistanceCodeLimit sanity" {
    // RFC 7932: with npostfix=0, ndirect=0 the distance alphabet has 16
    // direct codes plus 4 rings of NPOSTFIX+NDIRECT-free slots.
    const l0 = calculateDistanceCodeLimit(MAX_ALLOWED_DISTANCE, 0, 0);
    try std.testing.expectEqual(@as(u32, 74), l0.max_alphabet_size);

    const l3 = calculateDistanceCodeLimit(MAX_ALLOWED_DISTANCE, 3, 120);
    try std.testing.expectEqual(@as(u32, 544), l3.max_alphabet_size);
}

const std = @import("std");
