//! Static dictionary hash tables for Brotli encoder.

const raw_data align(@alignOf(u16)) = @embedFile("dictionary_hash.bin").*;

pub const kStaticDictionaryHashWords: [32768]u16 = @as(*const [32768]u16, @ptrCast(raw_data[0 .. 32768 * 2])).*;
pub const kStaticDictionaryHashLengths: [32768]u8 = raw_data[32768 * 2 .. 32768 * 3].*;
