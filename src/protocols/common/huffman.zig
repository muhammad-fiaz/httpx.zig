//! RFC 7541 Appendix B Huffman code (shared by HPACK and QPACK).
//!
//! Encoding uses the canonical code table directly. Decoding uses a
//! nibble-indexed finite-state automaton compiled at comptime from the
//! same table: a binary trie over the code bits defines the states, and
//! every reachable state carries 16 transitions consuming the next 4
//! input bits. A symbol completing k < 4 bits into a nibble emits on that
//! transition and routes the remainder bits (the already-consumed prefix
//! of the next symbol) to the trie node they reach from the root. Input
//! may legally terminate only where the unconsumed trailing bits are an
//! all-ones run shorter than 8 bits — i.e. valid EOS-prefix padding.
//!
//! This mirrors the representation nghttp2/nghttp3 generate (mkhufftbl),
//! derived here from first principles.

const std = @import("std");
pub const table = @import("huffman_table.zig");

pub const Error = error{
    InvalidHuffmanCode,
    BufferTooSmall,
};

/// EOS: 30 one-bits (never emitted as a symbol).
pub const eos_len: u8 = 30;

const sym_table = table.sym_table;

// Encoder

/// Upper bound on encoded size for a plaintext of `len` bytes (worst 30 bits per byte).
pub fn maxEncodedLen(len: usize) usize {
    return len * 5 + 1;
}

/// Encodes `src` into `out`, padding the final byte with EOS MSBs.
/// Returns bytes written.
pub fn encode(out: []u8, src: []const u8) Error!usize {
    var acc: u64 = 0;
    var acc_bits: u6 = 0;
    var pos: usize = 0;

    for (src) |b| {
        const s = sym_table[b];
        const slen: u5 = @intCast(s.len);
        const top: u64 = s.code >> @as(u5, @intCast(32 - @as(usize, s.len)));
        acc = (acc << slen) | top;
        acc_bits += @intCast(s.len);
        while (acc_bits >= 8) {
            if (pos >= out.len) return Error.BufferTooSmall;
            acc_bits -= 8;
            out[pos] = @truncate(acc >> acc_bits);
            pos += 1;
            acc &= (@as(u64, 1) << acc_bits) - 1;
        }
    }
    if (acc_bits > 0) {
        if (pos >= out.len) return Error.BufferTooSmall;
        const pad: u3 = @intCast(8 - acc_bits);
        acc = (acc << pad) | ((@as(u64, 1) << pad) - 1);
        out[pos] = @truncate(acc);
        pos += 1;
    }
    return pos;
}

// Decoder automaton (comptime-built)

pub const FLAG_ACCEPTED: u8 = 0x01;
pub const FLAG_SYM: u8 = 0x02;
pub const fail_state: u16 = 0x100;

const Entry = struct {
    next: u16 = fail_state,
    flags: u8 = 0,
    sym: u8 = 0,
};

fn bitAt(code: u32, idx: usize) usize {
    const sh: u5 = @intCast(31 - idx);
    return @as(usize, (code >> sh) & 1);
}

fn buildAutomaton() [256][16]Entry {
    @setEvalBranchQuota(200_000_000);

    const MAXN = 16384;
    const NONE: u32 = 0xFFFF_FFFF;

    // Phase 0: plain binary code trie.
    var child: [MAXN][2]u32 = [_][2]u32{.{ NONE, NONE }} ** MAXN;
    var sym_at: [MAXN]u16 = [_]u16{0xFFFF} ** MAXN;
    var n: usize = 1; // node 0 = root

    for (0..256) |si| {
        const s = sym_table[si];
        var t: u32 = 0;
        var pos: usize = 0;
        while (pos < s.len) : (pos += 1) {
            const b = bitAt(s.code, pos);
            if (child[t][b] == NONE) {
                child[t][b] = @intCast(n);
                n += 1;
            }
            t = child[t][b];
        }
        sym_at[t] = @intCast(si);
    }

    // Phase 1: evaluate every (node, nibble) pair deterministically.
    var e_next: [MAXN][16]u32 = [_][16]u32{[_]u32{NONE} ** 16} ** MAXN;
    var e_flags: [MAXN][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** MAXN;
    var e_sym: [MAXN][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** MAXN;

    // EOS-path chain nodes at depths 1..7 (legal pure-padding stops).
    var eos_chain: [8]u32 = .{0} ** 8; // [d] = node after d ones from root
    {
        var w: u32 = 0;
        var d: usize = 1;
        while (d <= 7) : (d += 1) {
            if (child[w][1] == NONE) {
                child[w][1] = @intCast(n);
                n += 1;
            }
            w = child[w][1];
            eos_chain[d] = w;
        }
    }

    var ni: usize = 0;
    while (ni < n) : (ni += 1) {
        const node: u32 = @intCast(ni);
        for (0..16) |nibi| {
            var w = node;
            var emitted: u16 = 0xFFFF;
            var consumed: usize = 0;
            var failed = false;

            for (0..4) |k| {
                const b = (@as(usize, nibi) >> @intCast(3 - k)) & 1;
                const c = child[w][b];
                if (c == NONE) {
                    failed = true;
                    break;
                }
                w = c;
                consumed = k + 1;
                if (sym_at[w] != 0xFFFF) {
                    emitted = sym_at[w];
                    break;
                }
            }

            if (failed) continue; // stays failure

            if (emitted != 0xFFFF) {
                const r: usize = 4 - consumed;
                var all_ones = true;
                var w2: u32 = 0;
                for (0..r) |k| {
                    // Remainder occupies the low r bits of the nibble,
                    // MSB first.
                    const sh: u3 = @intCast(r - 1 - k);
                    const b = (@as(usize, nibi) >> sh) & 1;
                    if (b == 0) all_ones = false;
                    if (child[w2][b] == NONE) {
                        child[w2][b] = @intCast(n);
                        n += 1;
                    }
                    w2 = child[w2][b];
                }
                e_next[node][nibi] = w2;
                e_flags[node][nibi] =
                    FLAG_SYM | if (all_ones) FLAG_ACCEPTED else 0;
                e_sym[node][nibi] = @intCast(emitted);
            } else {
                e_next[node][nibi] = w;
                // Legal stop without an emission: the walked path is an
                // all-ones run landing on the EOS chain at depth <= 7
                // (padding may span nibble boundaries inside the final
                // byte). Depth >= 8 means the stream contains 8+ EOS MSB
                // bits, which RFC 7541 treats as a decoded EOS -> error.
                if ((@as(usize, nibi) & 0xF) == 0xF) {
                    var d: usize = 1;
                    while (d <= 7) : (d += 1) {
                        if (w == eos_chain[d]) {
                            e_flags[node][nibi] |= FLAG_ACCEPTED;
                            break;
                        }
                    }
                }
            }
        }
    }

    // Phase 2: flatten via BFS over reachable states.
    var final_ids: [MAXN]u16 = [_]u16{0xFFFF} ** MAXN;
    var queue: [MAXN]u32 = undefined;
    var qh: usize = 0;
    var qt: usize = 0;
    var out: [256][16]Entry = [_][16]Entry{[_]Entry{.{}} ** 16} ** 256;
    var n_out: usize = 1;

    final_ids[0] = 0;
    queue[qt] = 0;
    qt += 1;

    while (qh < qt) {
        const t = queue[qh];
        qh += 1;
        const fid = final_ids[t];
        for (0..16) |nibi| {
            const target = e_next[t][nibi];
            if (target == NONE) continue;
            if (final_ids[target] == 0xFFFF) {
                if (n_out >= fail_state) {
                    @compileError("Huffman DFA exceeds 254 states");
                }
                final_ids[target] = @intCast(n_out);
                queue[qt] = target;
                qt += 1;
                n_out += 1;
            }
            out[fid][nibi] = .{
                .next = final_ids[target],
                .flags = e_flags[t][nibi],
                .sym = e_sym[t][nibi],
            };
        }
    }

    return out;
}

const decode_table = buildAutomaton();

/// Number of reachable DFA states (diagnostics).
pub const dfa_state_count: usize = blk: {
    @setEvalBranchQuota(1_000_000);
    var seen = [_]bool{false} ** 256;
    var queue: [512]u16 = .{0} ** 512;
    var qh: usize = 0;
    var qt: usize = 1;
    var count: usize = 0;
    while (qh < qt) {
        const s = queue[qh];
        qh += 1;
        if (seen[s]) continue;
        seen[s] = true;
        count += 1;
        for (decode_table[s]) |e| {
            if (e.next != fail_state and !seen[e.next] and qt < queue.len) {
                queue[qt] = e.next;
                qt += 1;
            }
        }
    }
    break :blk count;
};

/// Streaming decoder, resumable across arbitrary chunk boundaries.
pub const Decoder = struct {
    state: u16 = 0,
    /// Whether the automaton is parked on an accepting position.
    accepted: bool = true,
    /// Any symbol decoded (rejects pure-EOS/empty inputs at finish()).
    emitted_any: bool = false,

    pub fn init() Decoder {
        return .{};
    }

    /// Feeds compressed bytes, appending decoded symbols to out[*out_pos..].
    pub fn feed(self: *Decoder, out: []u8, out_pos: *usize, data: []const u8) Error!void {
        for (data) |byte| {
            inline for ([_]u3{ 4, 0 }) |shift| {
                const nib: u4 = @truncate(byte >> shift);
                const e = decode_table[self.state][nib];
                if (e.next == fail_state) return Error.InvalidHuffmanCode;
                self.accepted = e.flags & FLAG_ACCEPTED != 0;
                if (e.flags & FLAG_SYM != 0) {
                    if (out_pos.* >= out.len) return Error.BufferTooSmall;
                    out[out_pos.*] = e.sym;
                    out_pos.* += 1;
                    self.emitted_any = true;
                }
                self.state = e.next;
            }
        }
    }

    /// Validates stream termination. Empty input is valid per RFC 7541.
    pub fn finish(self: *const Decoder) Error!void {
        if (self.emitted_any and !self.accepted) return Error.InvalidHuffmanCode;
    }
};

/// Whole-buffer convenience decode with validation. Returns bytes written.
pub fn decode(out: []u8, src: []const u8) Error!usize {
    var d = Decoder.init();
    var pos: usize = 0;
    try d.feed(out, &pos, src);
    try d.finish();
    return pos;
}

// Tests

test "table sanity" {
    try std.testing.expectEqual(@as(u8, 5), sym_table['a'].len);
    try std.testing.expectEqual(@as(u32, 0b00011 << 27), sym_table['a'].code);
    try std.testing.expectEqual(@as(u8, 5), sym_table['0'].len);
    var max_len: u8 = 0;
    for (sym_table) |s| max_len = @max(max_len, s.len);
    try std.testing.expectEqual(@as(u8, 30), max_len);
}

test "dfa fits in u8 state space" {
    try std.testing.expect(dfa_state_count <= 254);
}

test "encode single 'a' pads with EOS MSBs" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try encode(&out, "a"));
    try std.testing.expectEqual(@as(u8, 0b00011111), out[0]);
}

test "roundtrip ascii corpus" {
    const samples = [_][]const u8{
        "a",
        "www.example.com",
        ":method",
        "GET",
        "/index.html",
        "custom-key",
        "custom-header",
        "https://example.com/path?q=1&x=2",
        "\x00\x01\x02\xff control bytes survive",
        "The quick brown fox jumps over the lazy dog 0123456789 !@#$%^&*()",
    };
    var buf: [512]u8 = undefined;
    var dec_buf: [512]u8 = undefined;
    for (samples) |s| {
        const n = try encode(&buf, s);
        try std.testing.expect(n <= maxEncodedLen(s.len));
        const m = try decode(&dec_buf, buf[0..n]);
        try std.testing.expectEqualStrings(s, dec_buf[0..m]);
    }
}

test "roundtrip every byte value" {
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var buf: [1024]u8 = undefined;
    var back: [256]u8 = undefined;
    const n = try encode(&buf, &src);
    const m = try decode(&back, buf[0..n]);
    try std.testing.expectEqualSlices(u8, &src, back[0..m]);
}

test "streaming decode across arbitrary boundaries" {
    const src = "multiplexed protocol negotiation over reliable transport";
    var enc: [128]u8 = undefined;
    const n = try encode(&enc, src);
    var d = Decoder.init();
    var out: [128]u8 = undefined;
    var pos: usize = 0;
    var off: usize = 0;
    while (off < n) {
        const step = @min(1 + off % 3, n - off);
        try d.feed(&out, &pos, enc[off .. off + step]);
        off += step;
    }
    try d.finish();
    try std.testing.expectEqualStrings(src, out[0..pos]);
}

test "rejects 8 or more trailing one-bits" {
    var buf: [64]u8 = undefined;
    var out: [8]u8 = undefined;

    // Valid: "a" + 3 ones padding.
    buf[0] = 0x1F;
    try std.testing.expectEqual(@as(usize, 1), try decode(&out, buf[0..1]));

    // Exactly 4 ones alone: accepted position but no symbol -> reject.
    buf[0] = 0xF0;
    try std.testing.expectError(Error.InvalidHuffmanCode, decode(&out, buf[0..1]));

    // Eight ones total across two nibbles: non-accepting termination.
    buf[0] = 0x0F;
    buf[1] = 0xF0;
    try std.testing.expectError(Error.InvalidHuffmanCode, decode(&out, buf[0..2]));

    // Full EOS-length run: failure node mid-stream.
    @memset(buf[0..4], 0xFF);
    try std.testing.expectError(Error.InvalidHuffmanCode, decode(&out, buf[0..4]));
}

test "known vectors (RFC 7541 spec examples, cross-checked vs quiche)" {
    const Case = struct { plain: []const u8, hex: []const u8 };
    const cases = [_]Case{
        .{ .plain = "www.example.com", .hex = "f1e3c2e5f23a6ba0ab90f4ff" },
        .{ .plain = "no-cache", .hex = "a8eb10649cbf" },
        .{ .plain = "custom-key", .hex = "25a849e95ba97d7f" },
    };
    var buf: [32]u8 = undefined;
    var back: [64]u8 = undefined;
    for (cases) |c| {
        const n = try encode(&buf, c.plain);
        try std.testing.expectEqual(c.hex.len / 2, n);
        for (0..n) |i| {
            const want = try std.fmt.parseInt(u8, c.hex[i * 2 .. i * 2 + 2], 16);
            try std.testing.expectEqual(want, buf[i]);
        }
        const m = try decode(&back, buf[0..n]);
        try std.testing.expectEqualStrings(c.plain, back[0..m]);
    }
}
