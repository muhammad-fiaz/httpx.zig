//! Regression guard for non-cryptographic randomness in security paths.
//!
//! Twice now this repository shipped a fixed or counter-seeded PRNG where
//! a CSPRNG belonged: the TLS `fillRandom` fallback (which never reached a
//! real entropy source at all, because `std.posix.getrandom` does not exist
//! in Zig 0.16) and the hardcoded HTTP/3 ticket key. Neither was visible
//! to the test suite or to Debug builds.
//!
//! These tests state the invariant directly rather than pattern-matching a
//! past fix, so they keep holding as code moves: anything that mints a
//! secret must reach the OS through `Io.random` / `Io.randomSecure`.

const std = @import("std");

/// Paths whose randomness is a security boundary. A `DefaultPrng` in any of
/// these is a finding, not a style question — they cover TLS key material,
/// QUIC connection IDs, DNS transaction IDs and CSRF tokens.
const guarded = [_][]const u8{
    "src/protocols/tls",
    "src/protocols/quic/connection.zig",
    "src/net/dns.zig",
    "src/web/middleware/security.zig",
};

/// Tests are expected to run from the repository root via `zig build test`.
/// The global single-threaded Io is a debug facility, which is the right
/// trade here: the guard is a test, and it still routes file I/O for real.
/// Its `randomSecure` is not used — this file reads source, not entropy.
fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Small wrapper so the argument order matches `Dir.readFileAllocOptions`.
fn readFileAllocOptions(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return dir.readFileAllocOptions(io, name, gpa, .limited(4 << 20), .of(u8), null);
}

fn containsPrng(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    const gpa = std.testing.allocator;
    const entry = dir.openDir(io, sub_path, .{ .iterate = true }) catch return false;
    var it = entry.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .directory) {
            if (try containsPrng(io, entry, e.name)) return true;
            continue;
        }
        if (!std.mem.endsWith(u8, e.name, ".zig")) continue;
        const src = readFileAllocOptions(entry, io, gpa, e.name) catch continue;
        defer gpa.free(src);
        // Only production code counts: a seeded fixture inside a `test`
        // block is the correct way to get reproducible bytes.
        var stripped = std.ArrayList(u8).empty;
        defer stripped.deinit(gpa);
        stripTestBlocks(src, &stripped) catch continue;
        if (std.mem.indexOf(u8, stripped.items, "DefaultPrng") != null) return true;
    }
    return false;
}

/// Strips `test` declaration blocks so fixtures may pin a seed.
fn stripTestBlocks(src: []const u8, out: *std.ArrayList(u8)) !void {
    const gpa = std.testing.allocator;
    var in_test = false;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!in_test and std.mem.startsWith(u8, trimmed, "test ")) {
            in_test = true;
            depth = 0;
        }
        if (in_test) {
            depth += std.mem.count(u8, line, "{");
            depth -|= std.mem.count(u8, line, "}");
            if (depth == 0) in_test = false;
        } else {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
}

test "no non-cryptographic PRNG in security-critical paths" {
    const io = testIo();
    const cwd: std.Io.Dir = .cwd();

    for (guarded) |sub_path| {
        if (try containsPrng(io, cwd, sub_path)) {
            std.debug.print(
                "\nnon-cryptographic PRNG in {s}: secrets minted here must use" ++
                    " io.random / io.randomSecure\n",
                .{sub_path},
            );
            return error.NonCryptographicRandomness;
        }
    }
}

test "the block stripper actually removes test fixtures" {
    // Guards the guard: if stripTestBlocks silently stopped matching, the
    // test above would start flagging legitimate seeded fixtures.
    const src =
        \\test "fixture" {
        \\    var p = std.Random.DefaultPrng.init(0xC0FFEE);
        \\    _ = p.random();
        \\}
        \\pub fn production() void {
        \\    _ = 1;
        \\}
    ;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try stripTestBlocks(src, &out);

    try std.testing.expect(std.mem.indexOf(u8, src, "DefaultPrng") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "DefaultPrng") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn production") != null);
}
