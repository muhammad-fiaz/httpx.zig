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
pub const table = @import("huffmanTable.zig");

pub const Error = error{
    InvalidHuffmanCode,
    BufferTooSmall,
};

/// EOS: 30 one-bits (never emitted as a symbol).
pub const eosLen: u8 = 30;

const symTable = table.symTable;

// Encoder

/// Upper bound on encoded size for a plaintext of `len` bytes (worst 30 bits per byte).
pub fn maxEncodedLen(len: usize) usize {
    return len * 5 + 1;
}

/// Encodes `src` into `out`, padding the final byte with EOS MSBs.
/// Returns bytes written.
pub fn encode(out: []u8, src: []const u8) Error!usize {
    var acc: u64 = 0;
    var accBits: u6 = 0;
    var pos: usize = 0;

    for (src) |b| {
        const s = symTable[b];
        const slen: u5 = @intCast(s.len);
        const top: u64 = s.code >> @as(u5, @intCast(32 - @as(usize, s.len)));
        acc = (acc << slen) | top;
        accBits += @intCast(s.len);
        while (accBits >= 8) {
            if (pos >= out.len) return Error.BufferTooSmall;
            accBits -= 8;
            out[pos] = @truncate(acc >> accBits);
            pos += 1;
            acc &= (@as(u64, 1) << accBits) - 1;
        }
    }
    if (accBits > 0) {
        if (pos >= out.len) return Error.BufferTooSmall;
        const pad: u3 = @intCast(8 - accBits);
        acc = (acc << pad) | ((@as(u64, 1) << pad) - 1);
        out[pos] = @truncate(acc);
        pos += 1;
    }
    return pos;
}

// Decoder automaton (comptime-built)

pub const FLAG_ACCEPTED: u8 = 0x01;
pub const FLAG_SYM: u8 = 0x02;
pub const failState: u16 = 0x100;

const Entry = struct {
    next: u16 = failState,
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
    var child: [MAXN][2]u32 = (@as([MAXN][2]u32, @splat(.{ NONE, NONE })));
    var symAt: [MAXN]u16 = (@as([MAXN]u16, @splat(0xFFFF)));
    var n: usize = 1; // node 0 = root

    for (0..256) |si| {
        const s = symTable[si];
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
        symAt[t] = @intCast(si);
    }

    // Phase 1: evaluate every (node, nibble) pair deterministically.
    var eNext: [MAXN][16]u32 = (@as([MAXN][16]u32, @splat((@as([16]u32, @splat(NONE))))));
    var eFlags: [MAXN][16]u8 = (@as([MAXN][16]u8, @splat((@as([16]u8, @splat(0))))));
    var eSym: [MAXN][16]u8 = (@as([MAXN][16]u8, @splat((@as([16]u8, @splat(0))))));

    // EOS-path chain nodes at depths 1..7 (legal pure-padding stops).
    var eosChain: [8]u32 = @splat(0); // [d] = node after d ones from root
    {
        var w: u32 = 0;
        var d: usize = 1;
        while (d <= 7) : (d += 1) {
            if (child[w][1] == NONE) {
                child[w][1] = @intCast(n);
                n += 1;
            }
            w = child[w][1];
            eosChain[d] = w;
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
                if (symAt[w] != 0xFFFF) {
                    emitted = symAt[w];
                    break;
                }
            }

            if (failed) continue; // stays failure

            if (emitted != 0xFFFF) {
                const r: usize = 4 - consumed;
                var allOnes = true;
                var w2: u32 = 0;
                for (0..r) |k| {
                    // Remainder occupies the low r bits of the nibble,
                    // MSB first.
                    const sh: u3 = @intCast(r - 1 - k);
                    const b = (@as(usize, nibi) >> sh) & 1;
                    if (b == 0) allOnes = false;
                    if (child[w2][b] == NONE) {
                        child[w2][b] = @intCast(n);
                        n += 1;
                    }
                    w2 = child[w2][b];
                }
                eNext[node][nibi] = w2;
                eFlags[node][nibi] =
                    FLAG_SYM | if (allOnes) FLAG_ACCEPTED else 0;
                eSym[node][nibi] = @intCast(emitted);
            } else {
                eNext[node][nibi] = w;
                // Legal stop without an emission: the walked path is an
                // all-ones run landing on the EOS chain at depth <= 7
                // (padding may span nibble boundaries inside the final
                // byte). Depth >= 8 means the stream contains 8+ EOS MSB
                // bits, which RFC 7541 treats as a decoded EOS -> error.
                if ((@as(usize, nibi) & 0xF) == 0xF) {
                    var d: usize = 1;
                    while (d <= 7) : (d += 1) {
                        if (w == eosChain[d]) {
                            eFlags[node][nibi] |= FLAG_ACCEPTED;
                            break;
                        }
                    }
                }
            }
        }
    }

    // Phase 2: flatten via BFS over reachable states.
    var finalIds: [MAXN]u16 = (@as([MAXN]u16, @splat(0xFFFF)));
    var queue: [MAXN]u32 = undefined;
    var qh: usize = 0;
    var qt: usize = 0;
    var out: [256][16]Entry = (@as([256][16]Entry, @splat((@as([16]Entry, @splat(.{}))))));
    var nOut: usize = 1;

    finalIds[0] = 0;
    queue[qt] = 0;
    qt += 1;

    while (qh < qt) {
        const t = queue[qh];
        qh += 1;
        const fid = finalIds[t];
        for (0..16) |nibi| {
            const target = eNext[t][nibi];
            if (target == NONE) continue;
            if (finalIds[target] == 0xFFFF) {
                if (nOut >= failState) {
                    @compileError("Huffman DFA exceeds 254 states");
                }
                finalIds[target] = @intCast(nOut);
                queue[qt] = target;
                qt += 1;
                nOut += 1;
            }
            out[fid][nibi] = .{
                .next = finalIds[target],
                .flags = eFlags[t][nibi],
                .sym = eSym[t][nibi],
            };
        }
    }

    return out;
}

const decodeTable = buildAutomaton();

/// Number of reachable DFA states (diagnostics).
pub const dfaStateCount: usize = blk: {
    @setEvalBranchQuota(1_000_000);
    var seen = (@as([256]bool, @splat(false)));
    var queue: [512]u16 = @splat(0);
    var qh: usize = 0;
    var qt: usize = 1;
    var count: usize = 0;
    while (qh < qt) {
        const s = queue[qh];
        qh += 1;
        if (seen[s]) continue;
        seen[s] = true;
        count += 1;
        for (decodeTable[s]) |e| {
            if (e.next != failState and !seen[e.next] and qt < queue.len) {
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
    emittedAny: bool = false,

    pub fn init() Decoder {
        return .{};
    }

    /// Feeds compressed bytes, appending decoded symbols to out[*outPos..].
    pub fn feed(self: *Decoder, out: []u8, outPos: *usize, data: []const u8) Error!void {
        for (data) |byte| {
            inline for ([_]u3{ 4, 0 }) |shift| {
                const nib: u4 = @truncate(byte >> shift);
                const e = decodeTable[self.state][nib];
                if (e.next == failState) return Error.InvalidHuffmanCode;
                self.accepted = e.flags & FLAG_ACCEPTED != 0;
                if (e.flags & FLAG_SYM != 0) {
                    if (outPos.* >= out.len) return Error.BufferTooSmall;
                    out[outPos.*] = e.sym;
                    outPos.* += 1;
                    self.emittedAny = true;
                }
                self.state = e.next;
            }
        }
    }

    /// Validates stream termination. Empty input is valid per RFC 7541.
    pub fn finish(self: *const Decoder) Error!void {
        if (self.emittedAny and !self.accepted) return Error.InvalidHuffmanCode;
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
    try std.testing.expectEqual(@as(u8, 5), symTable['a'].len);
    try std.testing.expectEqual(@as(u32, 0b00011 << 27), symTable['a'].code);
    try std.testing.expectEqual(@as(u8, 5), symTable['0'].len);
    var maxLen: u8 = 0;
    for (symTable) |s| maxLen = @max(maxLen, s.len);
    try std.testing.expectEqual(@as(u8, 30), maxLen);
}

test "dfa fits in u8 state space" {
    try std.testing.expect(dfaStateCount <= 254);
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
    var decBuf: [512]u8 = undefined;
    for (samples) |s| {
        const n = try encode(&buf, s);
        try std.testing.expect(n <= maxEncodedLen(s.len));
        const m = try decode(&decBuf, buf[0..n]);
        try std.testing.expectEqualStrings(s, decBuf[0..m]);
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
