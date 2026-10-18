//! Literal cost estimation for backward references (Q10/Q11).
//!
//! Computes sliding-window bit cost estimates for literals using UTF-8 context
//! models or byte-level fallbacks.

const std = @import("std");
const fast_log = @import("fast_log.zig");
const utf8_util = @import("utf8_util.zig");

fn utf8Position(last: usize, c: usize, clamp: usize) usize {
    if (c < 128) {
        return 0;
    } else if (c >= 192) {
        return @min(1, clamp);
    } else {
        if (last < 0xE0) {
            return 0;
        } else {
            return @min(2, clamp);
        }
    }
}

fn decideMultiByteStatsLevel(pos: usize, len: usize, mask: usize, data: []const u8) usize {
    var counts = [3]usize{ 0, 0, 0 };
    var max_utf8: usize = 1;
    var last_c: usize = 0;
    for (0..len) |i| {
        const c = data[(pos + i) & mask];
        counts[utf8Position(last_c, c, 2)] += 1;
        last_c = c;
    }
    if (counts[2] < 500) {
        max_utf8 = 1;
    }
    if (counts[1] + counts[2] < 25) {
        max_utf8 = 0;
    }
    return max_utf8;
}

fn estimateBitCostsForLiteralsUTF8(
    pos: usize,
    len: usize,
    mask: usize,
    data: []const u8,
    histogram: []usize,
    cost: []f32,
) void {
    const max_utf8 = decideMultiByteStatsLevel(pos, len, mask, data);
    const window_half: usize = 495;
    const in_window = @min(window_half, len);
    var in_window_utf8 = [3]usize{ 0, 0, 0 };
    @memset(histogram[0 .. 3 * 256], 0);

    {
        var last_c: usize = 0;
        var utf8_pos: usize = 0;
        for (0..in_window) |i| {
            const c = data[(pos + i) & mask];
            histogram[256 * utf8_pos + c] += 1;
            in_window_utf8[utf8_pos] += 1;
            utf8_pos = utf8Position(last_c, c, max_utf8);
            last_c = c;
        }
    }

    const prologue_length: usize = 2000;
    const multiplier: f64 = 0.35 / 2000.0;

    for (0..len) |i| {
        if (i >= window_half) {
            const c: usize = if (i < window_half + 1) 0 else data[(pos + i - window_half - 1) & mask];
            const last_c: usize = if (i < window_half + 2) 0 else data[(pos + i - window_half - 2) & mask];
            const utf8_pos2 = utf8Position(last_c, c, max_utf8);
            histogram[256 * utf8_pos2 + data[(pos + i - window_half) & mask]] -= 1;
            in_window_utf8[utf8_pos2] -= 1;
        }
        if (i + window_half < len) {
            const c = data[(pos + i + window_half - 1) & mask];
            const last_c = data[(pos + i + window_half - 2) & mask];
            const utf8_pos2 = utf8Position(last_c, c, max_utf8);
            histogram[256 * utf8_pos2 + data[(pos + i + window_half) & mask]] += 1;
            in_window_utf8[utf8_pos2] += 1;
        }
        {
            const c: usize = if (i < 1) 0 else data[(pos + i - 1) & mask];
            const last_c: usize = if (i < 2) 0 else data[(pos + i - 2) & mask];
            const utf8_pos = utf8Position(last_c, c, max_utf8);
            const masked_pos = (pos + i) & mask;
            var histo = histogram[256 * utf8_pos + data[masked_pos]];
            if (histo == 0) {
                histo = 1;
            }
            var lit_cost = fast_log.fastLog2(in_window_utf8[utf8_pos]) - fast_log.fastLog2(histo);
            lit_cost += 0.02905;
            if (lit_cost < 1.0) {
                lit_cost *= 0.5;
                lit_cost += 0.5;
            }
            if (i < prologue_length) {
                lit_cost += 0.35 + multiplier * @as(f64, @floatFromInt(i));
            }
            cost[i] = @floatCast(lit_cost);
        }
    }
}

pub fn estimateBitCostsForLiterals(
    pos: usize,
    len: usize,
    mask: usize,
    data: []const u8,
    histogram: []usize,
    cost: []f32,
) void {
    if (utf8_util.brotliIsMostlyUTF8(data, pos, mask, len, utf8_util.MIN_UTF8_RATIO)) {
        estimateBitCostsForLiteralsUTF8(pos, len, mask, data, histogram, cost);
        return;
    } else {
        const window_half: usize = 2000;
        var in_window: usize = @min(window_half, len);
        @memset(histogram[0..256], 0);

        for (0..in_window) |i| {
            histogram[data[(pos + i) & mask]] += 1;
        }

        for (0..len) |i| {
            if (i >= window_half) {
                histogram[data[(pos + i - window_half) & mask]] -= 1;
                in_window -= 1;
            }
            if (i + window_half < len) {
                histogram[data[(pos + i + window_half) & mask]] += 1;
                in_window += 1;
            }
            var histo = histogram[data[(pos + i) & mask]];
            if (histo == 0) {
                histo = 1;
            }
            var lit_cost = fast_log.fastLog2(in_window) - fast_log.fastLog2(histo);
            lit_cost += 0.029;
            if (lit_cost < 1.0) {
                lit_cost *= 0.5;
                lit_cost += 0.5;
            }
            cost[i] = @floatCast(lit_cost);
        }
    }
}
