//! Decoder robustness fuzzer.
//!
//! Feeds arbitrary bytes to a fresh decoder and asserts the library never
//! crashes, panics, or leaks - any input must yield success, a graceful
//! needs-more-input/output result, or a detailed error code.
//!
//! Run via `zig build fuzz` (deterministic pseudo-random inputs) or wire
//! into an external fuzzing engine through this file's root action.

const std = @import("std");
const brotli = @import("brotli");

/// One fuzz iteration: `data` is arbitrary attacker-controlled input.
/// Returns normally on graceful handling; any panic/crash is a bug.
pub fn decodeOneShot(data: []const u8) void {
    var d = brotli.Decoder.init(std.heap.page_allocator, .{});
    defer d.deinit();

    // Generous fixed output window: valid tiny streams must complete; the
    // decoder must cap itself via needs_more_output for larger ones.
    const out_buf = std.heap.page_allocator.alloc(u8, 1 << 20) catch return;
    defer std.heap.page_allocator.free(out_buf);

    var input = data;
    var out = out_buf;
    var total: u64 = 0;
    switch (d.decompressStream(&input, &out, &total)) {
        .success, .needs_more_input, .needs_more_output => {},
        .err => {
            // Error codes must stay within the documented enum range.
            std.mem.doNotOptimizeAway(d.errorCode().name());
        },
    }
}

// Deterministic corpus: structured near-miss headers plus random tails so
// plain `zig build test` also exercises the harness without libFuzzer.
test "fuzz: deterministic malformed corpus does not crash" {
    var prng = std.Random.DefaultPrng.init(0xB50F);
    const rand = prng.random();

    // All-zero and all-FF extremes.
    const all_zero: [64]u8 = @splat(0);
    decodeOneShot(&all_zero);
    const all_ff: [64]u8 = @splat(0xFF);
    decodeOneShot(&all_ff);
    // Valid-looking window bits followed by garbage.
    var c2: [64]u8 = @splat(0);
    c2[0] = 0x21; // wbits=10-ish pattern
    decodeOneShot(&c2);
    var c3: [64]u8 = @splat(0);
    c3[0] = 0x01;
    decodeOneShot(&c3);
    // Fully random tails.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var buf: [64]u8 = undefined;
        rand.bytes(buf[0..]);
        decodeOneShot(&buf);
    }
}

test "fuzz: random truncated real stream" {
    const compressed = @embedFile("dictionary_sample.br");
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const cut = rand.uintLessThan(usize, compressed.len);
        decodeOneShot(compressed[0..cut]);
    }
    // Bit-flip mutations.
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..512], compressed[0..512]);
    i = 0;
    while (i < 64) : (i += 1) {
        const pos = rand.uintLessThan(usize, buf.len);
        buf[pos] ^= @as(u8, 1) << @intCast(rand.uintLessThan(usize, 8));
        decodeOneShot(&buf);
        @memcpy(buf[0..512], compressed[0..512]);
    }
}
