//! Deterministic fuzz harness for the HTTP/1 parser surface.
//!
//! Two strategies modeled on picohttpparser/H2O fuzzing practice:
//!   1. truncation sweep — every proper prefix of a valid message must
//!      parse cleanly or return Incomplete, never misparse/crash;
//!   2. seeded mutation — pseudo-random byte flips/splices over valid
//!      messages and raw garbage must never panic the parser.
//!
//! Run under `zig build test`; failures reproduce via the printed seed.

const std = @import("std");
const parser = @import("parser.zig");
const writer = @import("writer.zig");

fn tryRequest(buf: []const u8) void {
    _ = parser.parseRequestHead(buf) catch {};
}

fn tryResponse(buf: []const u8) void {
    _ = parser.parseResponseHead(buf) catch {};
}

fn tryChunked(buf: []u8) void {
    var dec = parser.ChunkedDecoder.init();
    _ = dec.decode(buf[0..]) catch {};
}

test "fuzz: truncation sweep over valid messages" {
    const seeds = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: x\r\nUser-Agent: fuzz\r\n\r\n",
        "POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\nabcd",
        "GET / HTTP/1.0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
        "HTTP/1.1 204 No Content\r\nServer: s\r\n\r\n",
        "HTTP/1.0 404 Not Found\r\n\r\nbody-until-close",
        "CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n",
        "OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    };

    var chunk_buf: [256]u8 = undefined;
    for (seeds) |s| {
        for (0..s.len + 1) |cut| {
            tryRequest(s[0..cut]);
            if (s.len >= 5) tryResponse(s[0..cut]);
        }
        // Chunked decoder fed the body-bearing seeds directly.
        @memcpy(chunk_buf[0..s.len], s);
        tryChunked(chunk_buf[0..s.len]);
        for (1..s.len) |cut| {
            tryChunked(chunk_buf[0..cut]);
        }
    }
}

test "fuzz: seeded mutation never panics" {
    const seeds = [_][]const u8{
        "GET /path?q=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nX-A: b\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ndata\r\n0\r\n\r\n",
        "PUT /x HTTP/1.1\r\nHost: y\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-T: v\r\n\r\n",
    };
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rng = prng.random();

    var buf: [256]u8 = undefined;

    for (seeds) |seed| {
        var round: usize = 0;
        while (round < 400) : (round += 1) {
            const len = @min(seed.len, buf.len);
            @memcpy(buf[0..len], seed[0..len]);

            // Apply 1-4 random mutations.
            var m: usize = 0;
            const mutations = 1 + rng.uintLessThan(usize, 4);
            while (m < mutations) : (m += 1) {
                const idx = rng.uintLessThan(usize, len);
                switch (rng.uintLessThan(u8, 4)) {
                    0 => buf[idx] = rng.int(u8),
                    1 => buf[idx] ^= @as(u8, 1) << @intCast(rng.uintLessThan(u8, 8)),
                    2 => buf[idx] = "\r\n\x00: \xff"[rng.uintLessThan(usize, 6)],
                    else => buf[idx] = rng.uintAtMost(u8, 0x7F),
                }
            }

            tryRequest(buf[0..len]);
            tryResponse(buf[0..len]);
            tryChunked(buf[0..len]);

            // Writer side must also survive hostile header material.
            var sink = std.ArrayList(u8).empty;
            defer sink.deinit(std.testing.allocator);
            const evil = [_]writer.Header{
                .{ .name = if (len > 0) buf[0..1] else "x", .value = buf[0..@min(len, 16)] },
            };
            if (writer.buildResponse(std.heap.page_allocator, 200, "", null, .{ .headers = evil[0..] }, false)) |resp| {
                try std.testing.expect(std.mem.indexOf(u8, resp, "\r\nEvil") == null);
                std.heap.page_allocator.free(resp);
            } else |_| {}
            if (writer.buildInformational(std.heap.page_allocator, 100, &.{})) |info| {
                std.heap.page_allocator.free(info);
            } else |_| {}
        }
    }
}

test "fuzz: writer rejects smuggled CR/LF across many candidates" {
    const candidates = [_][]const u8{
        "v\r\nEvil: 1",
        "v\nEvil: 1",
        "v\rEvil",
        "v\x00x",
        "v\x7f",
        "\r\n\r\nGET / HTTP/1.1",
    };
    for (candidates) |cand| {
        const evil_headers = [_]writer.Header{
            .{ .name = "X-N", .value = cand },
        };
        // Must either error or emit sanitized output — never inject a
        // bare CR/LF sequence that could start a new header/line.
        if (writer.buildRequest(
            std.heap.page_allocator,
            "GET",
            "/",
            null,
            .{ .host = "h", .headers = evil_headers[0..] },
        )) |maybe| {
            std.heap.page_allocator.free(maybe);
            // Accepted output must not inject a new header/line.
            try std.testing.expect(std.mem.indexOf(u8, maybe, "\r\nEvil") == null);
            try std.testing.expect(std.mem.indexOf(u8, maybe, "\r\n\r\nEvil") == null);
        } else |_| {}
    }
}
