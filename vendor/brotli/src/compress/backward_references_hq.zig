//! High-quality Zopfli backward references (Quality 10 and 11).
//!
//! Implements graph-based dynamic programming path search (Zopfli shortest path)
//! and iterative cost modeling to find globally optimal LZ77 command sequences.

const std = @import("std");
const fast_log = @import("fast_log.zig");
const hlmq = @import("hash_longest_match_quickly.zig");
const Command = hlmq.Command;
const h2bt = @import("hash_to_binary_tree.zig");
const BackwardMatch = h2bt.BackwardMatch;
const literal_cost_mod = @import("literal_cost.zig");

pub const BROTLI_MAX_EFFECTIVE_DISTANCE_ALPHABET_SIZE: usize = 544;
pub const kInfinity: f32 = 1.7e38;

pub const kDistanceCacheIndex = [16]u32{
    0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1,
};
pub const kDistanceCacheOffset = [16]i32{
    0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3,
};

pub const ZopfliNode = struct {
    length: u32 = 1,
    distance: u32 = 0,
    dcode_insert_length: u32 = 0,
    u: CostUnion = .{ .cost = kInfinity },

    pub const CostUnion = extern union {
        cost: f32,
        next: u32,
        shortcut: u32,
    };

    pub inline fn copyLength(self: *const ZopfliNode) u32 {
        return self.length & 0x1FFFFFF;
    }

    pub inline fn lengthCode(self: *const ZopfliNode) u32 {
        const modifier = self.length >> 25;
        return self.copyLength() + 9 - modifier;
    }

    pub inline fn copyDistance(self: *const ZopfliNode) u32 {
        return self.distance;
    }

    pub inline fn distanceCode(self: *const ZopfliNode) u32 {
        const short_code = self.dcode_insert_length >> 27;
        return if (short_code == 0)
            self.copyDistance() + 16 - 1
        else
            short_code - 1;
    }

    pub inline fn commandLength(self: *const ZopfliNode) u32 {
        return self.copyLength() + (self.dcode_insert_length & 0x7FFFFFF);
    }
};

pub fn initZopfliNodes(array: []ZopfliNode) void {
    const stub = ZopfliNode{
        .length = 1,
        .distance = 0,
        .dcode_insert_length = 0,
        .u = .{ .cost = kInfinity },
    };
    @memset(array, stub);
}

pub const ZopfliCostModel = struct {
    cost_cmd_: [704]f32 = @splat(0),
    cost_dist_: []f32,
    distance_histogram_size: u32,
    literal_costs_: []f32,
    min_cost_cmd_: f32 = 0,
    num_bytes_: usize,
    literal_histograms: [3 * 256]usize = @splat(0),

    pub fn init(allocator: std.mem.Allocator, alphabet_size_limit: u32, num_bytes: usize) !ZopfliCostModel {
        const literal_costs = try allocator.alloc(f32, num_bytes + 2);
        errdefer allocator.free(literal_costs);
        const cost_dist = try allocator.alloc(f32, alphabet_size_limit);
        errdefer allocator.free(cost_dist);

        return .{
            .cost_dist_ = cost_dist,
            .distance_histogram_size = alphabet_size_limit,
            .literal_costs_ = literal_costs,
            .num_bytes_ = num_bytes,
        };
    }

    pub fn deinit(self: *ZopfliCostModel, allocator: std.mem.Allocator) void {
        allocator.free(self.literal_costs_);
        allocator.free(self.cost_dist_);
    }

    fn setCost(histogram: []const u32, literal_histogram: bool, cost: []f32) void {
        var sum: usize = 0;
        for (histogram) |c| sum += c;
        const log2sum: f32 = @floatCast(fast_log.fastLog2(sum));
        var missing_symbol_sum = sum;
        if (!literal_histogram) {
            for (histogram) |c| {
                if (c == 0) missing_symbol_sum += 1;
            }
        }
        const missing_symbol_cost: f32 = @floatCast(fast_log.fastLog2(missing_symbol_sum) + 2.0);
        for (histogram, 0..) |count, i| {
            if (count == 0) {
                cost[i] = missing_symbol_cost;
                continue;
            }
            cost[i] = log2sum - @as(f32, @floatCast(fast_log.fastLog2(count)));
            if (cost[i] < 1.0) cost[i] = 1.0;
        }
    }

    pub fn setFromCommands(
        self: *ZopfliCostModel,
        position: usize,
        ringbuffer: []const u8,
        ringbuffer_mask: usize,
        commands: []const Command,
        last_insert_len: usize,
    ) void {
        var pos = position - last_insert_len;
        var min_cost_cmd: f32 = kInfinity;
        var histogram_literal: [256]u32 = @splat(0);
        var histogram_cmd: [704]u32 = @splat(0);
        var histogram_dist: [BROTLI_MAX_EFFECTIVE_DISTANCE_ALPHABET_SIZE]u32 = @splat(0);
        var cost_literal: [256]f32 = undefined;

        for (commands) |cmd| {
            const inslength = cmd.insert_len_;
            const copylength = cmd.copyLen();
            const distcode = cmd.dist_prefix_ & 0x3FF;
            const cmdcode = cmd.cmd_prefix_;

            histogram_cmd[cmdcode] += 1;
            if (cmdcode >= 128) histogram_dist[distcode] += 1;

            var j: usize = 0;
            while (j < inslength) : (j += 1) {
                histogram_literal[ringbuffer[(pos + j) & ringbuffer_mask]] += 1;
            }
            pos += inslength + copylength;
        }

        setCost(&histogram_literal, true, &cost_literal);
        setCost(&histogram_cmd, false, &self.cost_cmd_);
        setCost(histogram_dist[0..self.distance_histogram_size], false, self.cost_dist_);

        for (self.cost_cmd_) |c| {
            min_cost_cmd = @min(min_cost_cmd, c);
        }
        self.min_cost_cmd_ = min_cost_cmd;

        var literal_carry: f32 = 0.0;
        self.literal_costs_[0] = 0.0;
        for (0..self.num_bytes_) |i| {
            literal_carry += cost_literal[ringbuffer[(position + i) & ringbuffer_mask]];
            self.literal_costs_[i + 1] = self.literal_costs_[i] + literal_carry;
            literal_carry -= (self.literal_costs_[i + 1] - self.literal_costs_[i]);
        }
    }

    pub fn setFromLiteralCosts(
        self: *ZopfliCostModel,
        position: usize,
        ringbuffer: []const u8,
        ringbuffer_mask: usize,
    ) void {
        literal_cost_mod.estimateBitCostsForLiterals(
            position,
            self.num_bytes_,
            ringbuffer_mask,
            ringbuffer,
            &self.literal_histograms,
            self.literal_costs_[1 .. self.num_bytes_ + 1],
        );
        self.literal_costs_[0] = 0.0;
        var literal_carry: f32 = 0.0;
        for (0..self.num_bytes_) |i| {
            literal_carry += self.literal_costs_[i + 1];
            self.literal_costs_[i + 1] = self.literal_costs_[i] + literal_carry;
            literal_carry -= (self.literal_costs_[i + 1] - self.literal_costs_[i]);
        }
        for (0..704) |i| {
            self.cost_cmd_[i] = @floatCast(fast_log.fastLog2(11 + @as(u32, @intCast(i))));
        }
        for (0..self.distance_histogram_size) |i| {
            self.cost_dist_[i] = @floatCast(fast_log.fastLog2(20 + @as(u32, @intCast(i))));
        }
        self.min_cost_cmd_ = @floatCast(fast_log.fastLog2(11));
    }

    pub inline fn getCommandCost(self: *const ZopfliCostModel, cmdcode: u16) f32 {
        return self.cost_cmd_[cmdcode];
    }

    pub inline fn getDistanceCost(self: *const ZopfliCostModel, distcode: usize) f32 {
        return self.cost_dist_[distcode];
    }

    pub inline fn getLiteralCosts(self: *const ZopfliCostModel, from: usize, to: usize) f32 {
        return self.literal_costs_[to] - self.literal_costs_[from];
    }

    pub inline fn getMinCostCmd(self: *const ZopfliCostModel) f32 {
        return self.min_cost_cmd_;
    }
};

inline fn updateZopfliNode(
    nodes: []ZopfliNode,
    pos: usize,
    start_pos: usize,
    len: usize,
    len_code: usize,
    dist: usize,
    short_code: usize,
    cost: f32,
) void {
    const next = &nodes[pos + len];
    next.length = @intCast(len | ((len + 9 - len_code) << 25));
    next.distance = @intCast(dist);
    next.dcode_insert_length = @intCast((short_code << 27) | (pos - start_pos));
    next.u.cost = cost;
}

pub const PosData = struct {
    pos: usize = 0,
    distance_cache: [4]i32 = .{ 4, 11, 15, 16 },
    costdiff: f32 = 0,
    cost: f32 = 0,
};

pub const StartPosQueue = struct {
    q_: [8]PosData = undefined,
    idx_: usize = 0,

    pub inline fn init() StartPosQueue {
        return .{};
    }

    pub inline fn size(self: *const StartPosQueue) usize {
        return @min(self.idx_, 8);
    }

    pub fn push(self: *StartPosQueue, posdata: *const PosData) void {
        var offset = (~self.idx_) & 7;
        self.idx_ += 1;
        const len = self.size();
        self.q_[offset] = posdata.*;
        var i: usize = 1;
        while (i < len) : (i += 1) {
            if (self.q_[offset & 7].costdiff > self.q_[(offset + 1) & 7].costdiff) {
                const tmp = self.q_[offset & 7];
                self.q_[offset & 7] = self.q_[(offset + 1) & 7];
                self.q_[(offset + 1) & 7] = tmp;
            }
            offset += 1;
        }
    }

    pub inline fn at(self: *const StartPosQueue, k: usize) *const PosData {
        return &self.q_[(k -% self.idx_) & 7];
    }
};

fn computeMinimumCopyLength(
    start_cost: f32,
    nodes: []const ZopfliNode,
    num_bytes: usize,
    pos: usize,
) usize {
    var min_cost = start_cost;
    var len: usize = 2;
    var next_len_bucket: usize = 4;
    var next_len_offset: usize = 10;
    while (pos + len <= num_bytes and nodes[pos + len].u.cost <= min_cost) {
        len += 1;
        if (len == next_len_offset) {
            min_cost += 1.0;
            next_len_offset += next_len_bucket;
            next_len_bucket *= 2;
        }
    }
    return len;
}

fn computeDistanceShortcut(
    block_start: usize,
    pos: usize,
    max_backward_limit: usize,
    gap: usize,
    nodes: []const ZopfliNode,
) u32 {
    const c_len = nodes[pos].copyLength();
    const i_len = nodes[pos].dcode_insert_length & 0x7FFFFFF;
    const dist = nodes[pos].copyDistance();
    if (pos == 0) {
        return 0;
    } else if (dist + c_len <= block_start + pos + gap and
        dist <= max_backward_limit + gap and
        nodes[pos].distanceCode() > 0)
    {
        return @intCast(pos);
    } else {
        return nodes[pos - c_len - i_len].u.shortcut;
    }
}

fn computeDistanceCache(
    pos: usize,
    starting_dist_cache: []const i32,
    nodes: []const ZopfliNode,
    dist_cache: []i32,
) void {
    var idx: usize = 0;
    var p: usize = nodes[pos].u.shortcut;
    while (idx < 4 and p > 0) {
        const i_len = nodes[p].dcode_insert_length & 0x7FFFFFF;
        const c_len = nodes[p].copyLength();
        const dist = nodes[p].copyDistance();
        dist_cache[idx] = @intCast(dist);
        idx += 1;
        p = nodes[p - c_len - i_len].u.shortcut;
    }
    var s_idx: usize = 0;
    while (idx < 4) : (idx += 1) {
        dist_cache[idx] = starting_dist_cache[s_idx];
        s_idx += 1;
    }
}

fn evaluateNode(
    block_start: usize,
    pos: usize,
    max_backward_limit: usize,
    gap: usize,
    starting_dist_cache: []const i32,
    model: *const ZopfliCostModel,
    queue: *StartPosQueue,
    nodes: []ZopfliNode,
) void {
    const node_cost = nodes[pos].u.cost;
    nodes[pos].u.shortcut = computeDistanceShortcut(block_start, pos, max_backward_limit, gap, nodes);
    if (node_cost <= model.getLiteralCosts(0, pos)) {
        var posdata: PosData = undefined;
        posdata.pos = pos;
        posdata.cost = node_cost;
        posdata.costdiff = node_cost - model.getLiteralCosts(0, pos);
        computeDistanceCache(pos, starting_dist_cache, nodes, &posdata.distance_cache);
        queue.push(&posdata);
    }
}

fn updateNodes(
    num_bytes: usize,
    block_start: usize,
    pos: usize,
    ringbuffer: []const u8,
    ringbuffer_mask: usize,
    quality: u32,
    num_direct_distance_codes: usize,
    distance_postfix_bits: usize,
    max_backward_limit: usize,
    starting_dist_cache: []const i32,
    matches: []const BackwardMatch,
    model: *const ZopfliCostModel,
    queue: *StartPosQueue,
    nodes: []ZopfliNode,
) usize {
    const cur_ix = block_start + pos;
    const cur_ix_masked = cur_ix & ringbuffer_mask;
    const max_distance = @min(cur_ix, max_backward_limit);
    const dictionary_start = @min(cur_ix, max_backward_limit);
    const max_len = num_bytes - pos;
    const max_zopfli_len: usize = if (quality <= 10) 150 else 325;
    const max_iters: usize = if (quality <= 10) 1 else 5;
    var result: usize = 0;
    const gap: usize = 0; // no compound dict attached

    evaluateNode(block_start, pos, max_backward_limit, gap, starting_dist_cache, model, queue, nodes);

    const min_len = blk: {
        const posdata = queue.at(0);
        const min_cost = posdata.cost + model.getMinCostCmd() + model.getLiteralCosts(posdata.pos, pos);
        break :blk computeMinimumCopyLength(min_cost, nodes, num_bytes, pos);
    };

    var k: usize = 0;
    while (k < max_iters and k < queue.size()) : (k += 1) {
        const posdata = queue.at(k);
        const start = posdata.pos;
        const inscode = hlmq.getInsertLengthCode(pos - start);
        const start_costdiff = posdata.costdiff;
        const base_cost = start_costdiff + @as(f32, @floatFromInt(hlmq.kBrotliInsExtra[inscode])) +
            model.getLiteralCosts(0, pos);

        var best_len = min_len - 1;
        var j: usize = 0;
        while (j < 16 and best_len < max_len) : (j += 1) {
            const idx = kDistanceCacheIndex[j];
            const dist_val = @as(i64, posdata.distance_cache[idx]) + kDistanceCacheOffset[j];
            if (dist_val <= 0) continue;
            const backward: usize = @intCast(dist_val);
            const prev_ix = cur_ix -% backward;
            var len: usize = 0;
            if (cur_ix_masked + best_len > ringbuffer_mask) break;
            const continuation = ringbuffer[cur_ix_masked + best_len];
            if (backward > dictionary_start + gap) continue;
            if (backward <= max_distance) {
                if (prev_ix >= cur_ix) continue;
                const prev_masked = prev_ix & ringbuffer_mask;
                if (prev_masked + best_len > ringbuffer_mask or continuation != ringbuffer[prev_masked + best_len]) {
                    continue;
                }
                len = h2bt.findMatchLengthWithLimit(ringbuffer[prev_masked..], ringbuffer[cur_ix_masked..], max_len);
            } else {
                continue;
            }

            const dist_cost = base_cost + model.getDistanceCost(j);
            var l = best_len + 1;
            while (l <= len) : (l += 1) {
                const copycode = hlmq.getCopyLengthCode(l);
                const cmdcode = hlmq.combineLengthCodes(inscode, copycode, j == 0);
                const cost = (if (cmdcode < 128) base_cost else dist_cost) +
                    @as(f32, @floatFromInt(hlmq.kBrotliCopyExtra[copycode])) +
                    model.getCommandCost(cmdcode);
                if (cost < nodes[pos + l].u.cost) {
                    updateZopfliNode(nodes, pos, start, l, l, backward, j + 1, cost);
                    result = @max(result, l);
                }
                best_len = l;
            }
        }

        if (k >= 2) continue;

        var len = min_len;
        for (matches) |match| {
            const dist = match.distance;
            const is_dictionary_match = (dist > dictionary_start + gap);
            const dist_code = dist + 16 - 1;
            var dist_symbol: u16 = undefined;
            var distextra: u32 = undefined;
            hlmq.prefixEncodeCopyDistance(
                dist_code,
                num_direct_distance_codes,
                distance_postfix_bits,
                &dist_symbol,
                &distextra,
            );
            const distnumextra = dist_symbol >> 10;
            const dist_cost = base_cost + @as(f32, @floatFromInt(distnumextra)) +
                model.getDistanceCost(dist_symbol & 0x3FF);

            const max_match_len = match.length();
            if (len < max_match_len and (is_dictionary_match or max_match_len > max_zopfli_len)) {
                len = max_match_len;
            }
            while (len <= max_match_len) : (len += 1) {
                const len_code = if (is_dictionary_match) match.lengthCode() else len;
                const copycode = hlmq.getCopyLengthCode(len_code);
                const cmdcode = hlmq.combineLengthCodes(inscode, copycode, false);
                const cost = dist_cost + @as(f32, @floatFromInt(hlmq.kBrotliCopyExtra[copycode])) +
                    model.getCommandCost(cmdcode);
                if (cost < nodes[pos + len].u.cost) {
                    updateZopfliNode(nodes, pos, start, len, len_code, dist, 0, cost);
                    result = @max(result, len);
                }
            }
        }
    }
    return result;
}

fn computeShortestPathFromNodes(num_bytes: usize, nodes: []ZopfliNode) usize {
    var index = num_bytes;
    var num_commands: usize = 0;
    while ((nodes[index].dcode_insert_length & 0x7FFFFFF) == 0 and nodes[index].length == 1) : (index -= 1) {}
    nodes[index].u.next = std.math.maxInt(u32);
    while (index != 0) {
        const len = nodes[index].commandLength();
        index -= len;
        nodes[index].u.next = @intCast(len);
        num_commands += 1;
    }
    return num_commands;
}

pub fn zopfliCreateCommands(
    num_bytes: usize,
    block_start: usize,
    nodes: []const ZopfliNode,
    dist_cache: []i32,
    last_insert_len: *usize,
    num_direct_distance_codes: usize,
    distance_postfix_bits: usize,
    lgwin: u5,
    commands: []Command,
    num_commands: *usize,
    num_literals: *usize,
) void {
    const max_backward_limit = (@as(usize, 1) << lgwin) - 16;
    var pos: usize = 0;
    var offset = nodes[0].u.next;
    var i: usize = 0;
    const gap: usize = 0;

    while (offset != std.math.maxInt(u32)) : (i += 1) {
        const next = &nodes[pos + offset];
        const copy_length = next.copyLength();
        var insert_length: usize = next.dcode_insert_length & 0x7FFFFFF;
        pos += insert_length;
        offset = next.u.next;
        if (i == 0) {
            insert_length += last_insert_len.*;
            last_insert_len.* = 0;
        }
        {
            const distance = next.copyDistance();
            const len_code = next.lengthCode();
            const dictionary_start = @min(block_start + pos, max_backward_limit);
            const is_dictionary = (distance > dictionary_start + gap);
            const dist_code = next.distanceCode();
            commands[num_commands.* + i].init(
                insert_length,
                copy_length,
                @as(i32, @intCast(len_code)) - @as(i32, @intCast(copy_length)),
                dist_code,
                num_direct_distance_codes,
                distance_postfix_bits,
            );

            if (!is_dictionary and dist_code > 0) {
                dist_cache[3] = dist_cache[2];
                dist_cache[2] = dist_cache[1];
                dist_cache[1] = dist_cache[0];
                dist_cache[0] = @intCast(distance);
            }
        }

        num_literals.* += insert_length;
        pos += copy_length;
    }
    num_commands.* += i;
    last_insert_len.* += num_bytes - pos;
}

pub fn createZopfliBackwardReferences(
    allocator: std.mem.Allocator,
    num_bytes: usize,
    position: usize,
    ringbuffer: []const u8,
    ringbuffer_mask: usize,
    quality: u32,
    lgwin: u5,
    num_direct_distance_codes: usize,
    distance_postfix_bits: usize,
    alphabet_size_limit: u32,
    max_distance: usize,
    hasher: *h2bt.HashToBinaryTree(17, 64, 128),
    dist_cache: []i32,
    last_insert_len: *usize,
    commands: []Command,
    num_commands: *usize,
    num_literals: *usize,
) !void {
    const nodes = try allocator.alloc(ZopfliNode, num_bytes + 1);
    defer allocator.free(nodes);
    initZopfliNodes(nodes);

    var matches: [2 * (h2bt.MAX_NUM_MATCHES_H10 + 64)]BackwardMatch = undefined;
    const store_end = if (num_bytes >= hasher.storeLookahead())
        position + num_bytes - hasher.storeLookahead() + 1
    else
        position;

    var model = try ZopfliCostModel.init(allocator, alphabet_size_limit, num_bytes);
    defer model.deinit(allocator);

    nodes[0].length = 0;
    nodes[0].u.cost = 0;
    model.setFromLiteralCosts(position, ringbuffer, ringbuffer_mask);

    var queue = StartPosQueue.init();
    const max_backward_limit = (@as(usize, 1) << lgwin) - 16;
    const max_zopfli_len: usize = if (quality <= 10) 150 else 325;
    const gap: usize = 0;

    var i: usize = 0;
    while (i + 3 < num_bytes) : (i += 1) {
        const pos = position + i;
        const cur_max_distance = @min(pos, max_backward_limit);
        const dictionary_start = @min(pos, max_backward_limit);
        const num_found_matches = hasher.findAllMatches(
            ringbuffer,
            ringbuffer_mask,
            pos,
            num_bytes - i,
            cur_max_distance,
            dictionary_start + gap,
            max_distance,
            quality,
            &matches,
        );

        var cur_matches = matches[0..num_found_matches];
        if (num_found_matches > 0 and cur_matches[num_found_matches - 1].length() > max_zopfli_len) {
            matches[0] = cur_matches[num_found_matches - 1];
            cur_matches = matches[0..1];
        }

        var skip = updateNodes(
            num_bytes,
            position,
            i,
            ringbuffer,
            ringbuffer_mask,
            quality,
            num_direct_distance_codes,
            distance_postfix_bits,
            max_backward_limit,
            dist_cache,
            cur_matches,
            &model,
            &queue,
            nodes,
        );
        if (skip < 16384) skip = 0;
        if (cur_matches.len == 1 and cur_matches[0].length() > max_zopfli_len) {
            skip = @max(cur_matches[0].length(), skip);
        }
        if (skip > 1) {
            hasher.storeRange(ringbuffer, ringbuffer_mask, pos + 1, @min(pos + skip, store_end));
            skip -= 1;
            while (skip > 0) : (skip -= 1) {
                i += 1;
                if (i + 3 >= num_bytes) break;
                evaluateNode(position, i, max_backward_limit, gap, dist_cache, &model, &queue, nodes);
            }
        }
    }

    _ = computeShortestPathFromNodes(num_bytes, nodes);
    zopfliCreateCommands(
        num_bytes,
        position,
        nodes,
        dist_cache,
        last_insert_len,
        num_direct_distance_codes,
        distance_postfix_bits,
        lgwin,
        commands,
        num_commands,
        num_literals,
    );
}

fn zopfliIterate(
    num_bytes: usize,
    position: usize,
    ringbuffer: []const u8,
    ringbuffer_mask: usize,
    quality: u32,
    num_direct_distance_codes: usize,
    distance_postfix_bits: usize,
    lgwin: u5,
    dist_cache: []const i32,
    model: *const ZopfliCostModel,
    num_matches: []const u32,
    matches: []const BackwardMatch,
    nodes: []ZopfliNode,
) usize {
    const max_backward_limit = (@as(usize, 1) << lgwin) - 16;
    const max_zopfli_len: usize = if (quality <= 10) 150 else 325;
    var queue = StartPosQueue.init();
    var cur_match_pos: usize = 0;
    nodes[0].length = 0;
    nodes[0].u.cost = 0;
    const gap: usize = 0;

    var i: usize = 0;
    while (i + 3 < num_bytes) : (i += 1) {
        const n_m = num_matches[i];
        var skip = updateNodes(
            num_bytes,
            position,
            i,
            ringbuffer,
            ringbuffer_mask,
            quality,
            num_direct_distance_codes,
            distance_postfix_bits,
            max_backward_limit,
            dist_cache,
            matches[cur_match_pos .. cur_match_pos + n_m],
            model,
            &queue,
            nodes,
        );
        if (skip < 16384) skip = 0;
        cur_match_pos += n_m;
        if (n_m == 1 and matches[cur_match_pos - 1].length() > max_zopfli_len) {
            skip = @max(matches[cur_match_pos - 1].length(), skip);
        }
        if (skip > 1) {
            skip -= 1;
            while (skip > 0) : (skip -= 1) {
                i += 1;
                if (i + 3 >= num_bytes) break;
                evaluateNode(position, i, max_backward_limit, gap, dist_cache, model, &queue, nodes);
                cur_match_pos += num_matches[i];
            }
        }
    }
    return computeShortestPathFromNodes(num_bytes, nodes);
}

pub fn createHqZopfliBackwardReferences(
    allocator: std.mem.Allocator,
    num_bytes: usize,
    position: usize,
    ringbuffer: []const u8,
    ringbuffer_mask: usize,
    quality: u32,
    lgwin: u5,
    num_direct_distance_codes: usize,
    distance_postfix_bits: usize,
    alphabet_size_limit: u32,
    max_distance: usize,
    hasher: *h2bt.HashToBinaryTree(17, 64, 128),
    dist_cache: []i32,
    last_insert_len: *usize,
    commands: []Command,
    num_commands: *usize,
    num_literals: *usize,
) !void {
    const max_backward_limit = (@as(usize, 1) << lgwin) - 16;
    const num_matches = try allocator.alloc(u32, num_bytes);
    defer allocator.free(num_matches);
    @memset(num_matches, 0);

    var matches_list = try std.ArrayList(BackwardMatch).initCapacity(allocator, 4 * num_bytes);
    defer matches_list.deinit(allocator);

    const store_end = if (num_bytes >= hasher.storeLookahead())
        position + num_bytes - hasher.storeLookahead() + 1
    else
        position;

    var cur_match_pos: usize = 0;
    const gap: usize = 0;

    var i: usize = 0;
    while (i + 3 < num_bytes) : (i += 1) {
        const pos = position + i;
        const cur_max_distance = @min(pos, max_backward_limit);
        const dictionary_start = @min(pos, max_backward_limit);
        const max_length = num_bytes - i;

        try matches_list.ensureUnusedCapacity(allocator, h2bt.MAX_NUM_MATCHES_H10 + 64);
        const start_idx = matches_list.items.len;
        matches_list.appendNTimesAssumeCapacity(BackwardMatch{}, h2bt.MAX_NUM_MATCHES_H10 + 64);

        const num_found_matches = hasher.findAllMatches(
            ringbuffer,
            ringbuffer_mask,
            pos,
            max_length,
            cur_max_distance,
            dictionary_start + gap,
            max_distance,
            quality,
            matches_list.items[start_idx..],
        );
        matches_list.shrinkRetainingCapacity(start_idx + num_found_matches);

        num_matches[i] = @intCast(num_found_matches);
        if (num_found_matches > 0) {
            const match_len = matches_list.items[matches_list.items.len - 1].length();
            if (match_len > 325) { // MAX_ZOPFLI_LEN_QUALITY_11
                const skip = match_len - 1;
                matches_list.items[cur_match_pos] = matches_list.items[matches_list.items.len - 1];
                cur_match_pos += 1;
                matches_list.shrinkRetainingCapacity(cur_match_pos);
                num_matches[i] = 1;
                hasher.storeRange(ringbuffer, ringbuffer_mask, pos + 1, @min(pos + match_len, store_end));
                @memset(num_matches[i + 1 .. @min(i + 1 + skip, num_bytes)], 0);
                i += skip;
            } else {
                cur_match_pos += num_found_matches;
            }
        }
    }

    const orig_num_literals = num_literals.*;
    const orig_last_insert_len = last_insert_len.*;
    var orig_dist_cache: [4]i32 = undefined;
    @memcpy(&orig_dist_cache, dist_cache[0..4]);
    const orig_num_commands = num_commands.*;

    const nodes = try allocator.alloc(ZopfliNode, num_bytes + 1);
    defer allocator.free(nodes);

    var model = try ZopfliCostModel.init(allocator, alphabet_size_limit, num_bytes);
    defer model.deinit(allocator);

    for (0..2) |iter| {
        initZopfliNodes(nodes);
        if (iter == 0) {
            model.setFromLiteralCosts(position, ringbuffer, ringbuffer_mask);
        } else {
            model.setFromCommands(
                position,
                ringbuffer,
                ringbuffer_mask,
                commands[orig_num_commands..num_commands.*],
                orig_last_insert_len,
            );
        }
        num_commands.* = orig_num_commands;
        num_literals.* = orig_num_literals;
        last_insert_len.* = orig_last_insert_len;
        @memcpy(dist_cache[0..4], &orig_dist_cache);

        _ = zopfliIterate(
            num_bytes,
            position,
            ringbuffer,
            ringbuffer_mask,
            quality,
            num_direct_distance_codes,
            distance_postfix_bits,
            lgwin,
            dist_cache,
            &model,
            num_matches,
            matches_list.items,
            nodes,
        );
        zopfliCreateCommands(
            num_bytes,
            position,
            nodes,
            dist_cache,
            last_insert_len,
            num_direct_distance_codes,
            distance_postfix_bits,
            lgwin,
            commands,
            num_commands,
            num_literals,
        );
    }
}
