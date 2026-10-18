//! Precomputed static dictionary lookup tables for Brotli Q10/Q11.

pub const DictWord = extern struct {
    len: u8,
    transform: u8,
    idx: u16,
};

const raw_lut align(@alignOf(DictWord)) = @embedFile("static_dict_lut.bin").*;

pub const kStaticDictionaryBuckets: [32768]u16 = @as(*const [32768]u16, @ptrCast(raw_lut[0 .. 32768 * 2])).*;
pub const kStaticDictionaryWords: [31705]DictWord = @as(*const [31705]DictWord, @ptrCast(raw_lut[32768 * 2 .. 32768 * 2 + 31705 * @sizeOf(DictWord)])).*;
