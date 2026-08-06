//! Shared TLS crypto utilities
//!
//! Provides a single `tlsRandom()` function used across the TLS module
//! for generating cryptographic random bytes via the IO subsystem.

const std = @import("std");

/// Fill `buf` with cryptographically-secure random bytes using the
/// thread-local IO subsystem (Zig 0.16.0 API).
pub fn tlsRandom(buf: []u8) void {
    std.Io.Threaded.global_single_threaded.io().random(buf);
}

test "tlsRandom fills buffer with random bytes" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    tlsRandom(&buf1);
    tlsRandom(&buf2);
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "tlsRandom fills entire buffer" {
    var buf: [64]u8 = [_]u8{0} ** 64;
    tlsRandom(&buf);
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "tlsRandom with empty buffer does not panic" {
    var buf: [0]u8 = undefined;
    tlsRandom(&buf);
}
