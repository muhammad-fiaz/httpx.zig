//! HTTP/2 Stream Management for httpx.zig
//!
//! Implements RFC 7540 - Hypertext Transfer Protocol Version 2 (HTTP/2)
//!
//! Features:
//! - Stream state machine (idle, open, half-closed, closed)
//! - Stream prioritization and dependency handling
//! - Flow control (connection and stream level)
//! - Stream multiplexing support
//! - WINDOW_UPDATE frame handling
//! - RST_STREAM handling

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const http = @import("http.zig");
const hpack = @import("hpack.zig");

/// HTTP/2 Stream States as per RFC 7540 Section 5.1
pub const StreamState = enum {
    /// Stream has not been opened yet. Reserved stream IDs are in this state.
    idle,
    /// Reserved stream created by sending or receiving PUSH_PROMISE.
    reserved_local,
    /// Reserved stream created by peer's PUSH_PROMISE.
    reserved_remote,
    /// Stream is open for sending and receiving.
    open,
    /// Stream is half-closed (local): we cannot send, but can receive.
    half_closed_local,
    /// Stream is half-closed (remote): peer cannot send, but can receive.
    half_closed_remote,
    /// Stream is fully closed.
    closed,
};

/// Priority information for a stream.
pub const StreamPriority = struct {
    /// The stream this stream depends on (0 for root).
    dependency: u31 = 0,
    /// Relative weight (1-256).
    weight: u8 = 16,
    /// Exclusive dependency flag.
    exclusive: bool = false,
};

/// Represents an HTTP/2 stream.
pub const Stream = struct {
    id: u31,
    state: StreamState = .idle,
    priority: StreamPriority = .{},

    /// Local send window (how much we can send).
    send_window: i32 = 65535,
    /// Local receive window (how much peer can send to us).
    recv_window: i32 = 65535,

    /// Buffered data waiting to be sent (when send_window is insufficient).
    send_buffer: std.ArrayList(u8) = .empty,
    /// Buffered received data.
    recv_buffer: std.ArrayList(u8) = .empty,

    /// Whether we've sent END_STREAM.
    end_stream_sent: bool = false,
    /// Whether we've received END_STREAM.
    end_stream_received: bool = false,

    /// Request headers (decoded).
    request_headers: ?[]hpack.DecodedHeader = null,
    /// Response headers (decoded).
    response_headers: ?[]hpack.DecodedHeader = null,

    const Self = @This();

    pub fn init(id: u31) Self {
        return .{ .id = id };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.send_buffer.deinit(allocator);
        self.recv_buffer.deinit(allocator);
        if (self.request_headers) |headers| {
            for (headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(headers);
        }
        if (self.response_headers) |headers| {
            for (headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(headers);
        }
    }

    /// Checks if sending data is allowed in current state.
    pub fn canSend(self: *const Self) bool {
        return switch (self.state) {
            .open, .half_closed_remote => true,
            else => false,
        };
    }

    /// Checks if receiving data is allowed in current state.
    pub fn canReceive(self: *const Self) bool {
        return switch (self.state) {
            .open, .half_closed_local => true,
            else => false,
        };
    }

    /// Transitions state after sending END_STREAM.
    pub fn sendEndStream(self: *Self) void {
        self.end_stream_sent = true;
        switch (self.state) {
            .open => self.state = .half_closed_local,
            .half_closed_remote => self.state = .closed,
            else => {},
        }
    }

    /// Transitions state after receiving END_STREAM.
    pub fn receiveEndStream(self: *Self) void {
        self.end_stream_received = true;
        switch (self.state) {
            .open => self.state = .half_closed_remote,
            .half_closed_local => self.state = .closed,
            else => {},
        }
    }

    /// Opens the stream (transitions from idle to open).
    pub fn open(self: *Self) !void {
        if (self.state != .idle) return error.InvalidStreamState;
        self.state = .open;
    }

    /// Closes the stream due to RST_STREAM or error.
    pub fn reset(self: *Self) void {
        self.state = .closed;
    }

    /// Updates the send window by delta (can be negative for data sent).
    pub fn updateSendWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.send_window) + delta;
        if (new_window > 2147483647) return error.FlowControlError;
        self.send_window = @intCast(new_window);
    }

    /// Updates the receive window by delta.
    pub fn updateRecvWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.recv_window) + delta;
        if (new_window > 2147483647) return error.FlowControlError;
        self.recv_window = @intCast(new_window);
    }
};

/// Manages all streams for an HTTP/2 connection.
pub const StreamManager = struct {
    allocator: Allocator,
    streams: std.AutoHashMapUnmanaged(u31, Stream) = .{},

    /// Next stream ID to use for client-initiated streams (odd numbers).
    next_client_stream_id: u31 = 1,
    /// Next stream ID to use for server-initiated streams (even numbers).
    next_server_stream_id: u31 = 2,

    /// Whether this is a client (initiates odd stream IDs) or server (even).
    is_client: bool = true,

    /// Connection-level send window.
    connection_send_window: i32 = 65535,
    /// Connection-level receive window.
    connection_recv_window: i32 = 65535,

    /// Maximum concurrent streams allowed (from SETTINGS).
    max_concurrent_streams: u32 = 100,

    /// HPACK encoder/decoder context.
    hpack_ctx: hpack.HpackContext,

    const Self = @This();

    pub fn init(allocator: Allocator, is_client: bool) Self {
        return .{
            .allocator = allocator,
            .is_client = is_client,
            .hpack_ctx = hpack.HpackContext.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.streams.deinit(self.allocator);
        self.hpack_ctx.deinit();
    }

    /// Creates a new stream with the next available ID.
    pub fn createStream(self: *Self) !*Stream {
        const id = if (self.is_client) blk: {
            const id = self.next_client_stream_id;
            self.next_client_stream_id += 2;
            break :blk id;
        } else blk: {
            const id = self.next_server_stream_id;
            self.next_server_stream_id += 2;
            break :blk id;
        };

        try self.streams.put(self.allocator, id, Stream.init(id));
        return self.streams.getPtr(id).?;
    }

    /// Gets an existing stream by ID.
    pub fn getStream(self: *Self, id: u31) ?*Stream {
        return self.streams.getPtr(id);
    }

    /// Gets or creates a stream (for handling incoming frames).
    pub fn getOrCreateStream(self: *Self, id: u31) !*Stream {
        if (self.streams.getPtr(id)) |stream| {
            return stream;
        }

        // Validate stream ID based on initiator
        const is_client_stream = (id % 2 == 1);
        if (self.is_client and is_client_stream) {
            return error.InvalidStreamId; // Server cannot create client streams
        }
        if (!self.is_client and !is_client_stream) {
            return error.InvalidStreamId; // Client cannot create server streams
        }

        try self.streams.put(self.allocator, id, Stream.init(id));
        return self.streams.getPtr(id).?;
    }

    /// Removes a closed stream.
    pub fn removeStream(self: *Self, id: u31) void {
        if (self.streams.fetchRemove(id)) |kv| {
            var stream = kv.value;
            stream.deinit(self.allocator);
        }
    }

    /// Counts currently open streams.
    pub fn activeStreamCount(self: *const Self) usize {
        var count: usize = 0;
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.state;
            if (state != .idle and state != .closed) {
                count += 1;
            }
        }
        return count;
    }

    /// Updates connection-level send window.
    pub fn updateConnectionSendWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.connection_send_window) + delta;
        if (new_window > 2147483647) return error.FlowControlError;
        self.connection_send_window = @intCast(new_window);
    }

    /// Updates connection-level receive window.
    pub fn updateConnectionRecvWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.connection_recv_window) + delta;
        if (new_window > 2147483647) return error.FlowControlError;
        self.connection_recv_window = @intCast(new_window);
    }

    /// Applies initial window size change from SETTINGS to all streams.
    pub fn applyInitialWindowSizeChange(self: *Self, old_size: u32, new_size: u32) !void {
        const delta = @as(i32, @intCast(new_size)) - @as(i32, @intCast(old_size));
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            try entry.value_ptr.updateSendWindow(delta);
        }
    }
};

/// Builds a HEADERS frame payload with optional priority.
pub fn buildHeadersFramePayload(
    stream_manager: *StreamManager,
    headers: []const hpack.HeaderEntry,
    priority: ?StreamPriority,
    allocator: Allocator,
) !struct { payload: []u8, flags: u8 } {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var flags: u8 = 0;

    // Optional priority block (5 bytes)
    if (priority) |p| {
        flags |= 0x20; // PRIORITY flag

        var dep: u32 = p.dependency;
        if (p.exclusive) dep |= 0x80000000;

        try out.append(allocator, @intCast((dep >> 24) & 0xFF));
        try out.append(allocator, @intCast((dep >> 16) & 0xFF));
        try out.append(allocator, @intCast((dep >> 8) & 0xFF));
        try out.append(allocator, @intCast(dep & 0xFF));
        try out.append(allocator, p.weight -% 1); // Weight is 1-256, encoded as 0-255
    }

    // HPACK-encoded headers
    const encoded_headers = try hpack.encodeHeaders(&stream_manager.hpack_ctx, headers, allocator);
    defer allocator.free(encoded_headers);
    try out.appendSlice(allocator, encoded_headers);

    // END_HEADERS flag (we don't use CONTINUATION for now)
    flags |= 0x04;

    return .{ .payload = try out.toOwnedSlice(allocator), .flags = flags };
}

/// Parses a HEADERS frame payload.
pub fn parseHeadersFramePayload(
    stream_manager: *StreamManager,
    payload: []const u8,
    flags: u8,
    allocator: Allocator,
) !struct { headers: []hpack.DecodedHeader, priority: ?StreamPriority } {
    var offset: usize = 0;
    var priority: ?StreamPriority = null;

    // Check for PADDED flag (0x08)
    var pad_length: usize = 0;
    if (flags & 0x08 != 0) {
        if (payload.len < 1) return error.InvalidFrame;
        pad_length = payload[0];
        offset += 1;
    }

    // Check for PRIORITY flag (0x20)
    if (flags & 0x20 != 0) {
        if (payload.len < offset + 5) return error.InvalidFrame;
        const dep_raw = (@as(u32, payload[offset]) << 24) |
            (@as(u32, payload[offset + 1]) << 16) |
            (@as(u32, payload[offset + 2]) << 8) |
            payload[offset + 3];
        priority = .{
            .exclusive = (dep_raw & 0x80000000) != 0,
            .dependency = @intCast(dep_raw & 0x7FFFFFFF),
            .weight = payload[offset + 4] +% 1,
        };
        offset += 5;
    }

    // Remaining is HPACK block (minus padding)
    const header_block_len = payload.len - offset - pad_length;
    if (header_block_len > payload.len - offset) return error.InvalidFrame;

    const headers = try hpack.decodeHeaders(
        &stream_manager.hpack_ctx,
        payload[offset .. offset + header_block_len],
        allocator,
    );

    return .{ .headers = headers, .priority = priority };
}

/// Builds a DATA frame payload.
pub fn buildDataFramePayload(data: []const u8, allocator: Allocator) ![]u8 {
    return allocator.dupe(u8, data);
}

/// Builds a WINDOW_UPDATE frame payload.
pub fn buildWindowUpdatePayload(increment: u31) [4]u8 {
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((increment >> 24) & 0x7F);
    buf[1] = @intCast((increment >> 16) & 0xFF);
    buf[2] = @intCast((increment >> 8) & 0xFF);
    buf[3] = @intCast(increment & 0xFF);
    return buf;
}

/// Parses a WINDOW_UPDATE frame payload.
pub fn parseWindowUpdatePayload(payload: []const u8) !u31 {
    if (payload.len != 4) return error.InvalidFrame;
    const increment = (@as(u32, payload[0] & 0x7F) << 24) |
        (@as(u32, payload[1]) << 16) |
        (@as(u32, payload[2]) << 8) |
        payload[3];
    if (increment == 0) return error.ProtocolError; // WINDOW_UPDATE with 0 is protocol error
    return @intCast(increment);
}

/// Builds an RST_STREAM frame payload.
pub fn buildRstStreamPayload(error_code: http.Http2ErrorCode) [4]u8 {
    const code = @intFromEnum(error_code);
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((code >> 24) & 0xFF);
    buf[1] = @intCast((code >> 16) & 0xFF);
    buf[2] = @intCast((code >> 8) & 0xFF);
    buf[3] = @intCast(code & 0xFF);
    return buf;
}

/// Parses an RST_STREAM frame payload.
pub fn parseRstStreamPayload(payload: []const u8) !http.Http2ErrorCode {
    if (payload.len != 4) return error.InvalidFrame;
    const code = (@as(u32, payload[0]) << 24) |
        (@as(u32, payload[1]) << 16) |
        (@as(u32, payload[2]) << 8) |
        payload[3];
    return @enumFromInt(code);
}

/// Builds a PRIORITY frame payload.
pub fn buildPriorityPayload(priority: StreamPriority) [5]u8 {
    var buf: [5]u8 = undefined;
    var dep: u32 = priority.dependency;
    if (priority.exclusive) dep |= 0x80000000;
    buf[0] = @intCast((dep >> 24) & 0xFF);
    buf[1] = @intCast((dep >> 16) & 0xFF);
    buf[2] = @intCast((dep >> 8) & 0xFF);
    buf[3] = @intCast(dep & 0xFF);
    buf[4] = priority.weight -% 1;
    return buf;
}

/// Parses a PRIORITY frame payload.
pub fn parsePriorityPayload(payload: []const u8) !StreamPriority {
    if (payload.len != 5) return error.InvalidFrame;
    const dep_raw = (@as(u32, payload[0]) << 24) |
        (@as(u32, payload[1]) << 16) |
        (@as(u32, payload[2]) << 8) |
        payload[3];
    return .{
        .exclusive = (dep_raw & 0x80000000) != 0,
        .dependency = @intCast(dep_raw & 0x7FFFFFFF),
        .weight = payload[4] +% 1,
    };
}

/// Builds a GOAWAY frame payload.
pub fn buildGoawayPayload(last_stream_id: u31, error_code: http.Http2ErrorCode, debug_data: ?[]const u8, allocator: Allocator) ![]u8 {
    const code = @intFromEnum(error_code);
    const debug_len = if (debug_data) |d| d.len else 0;
    const payload = try allocator.alloc(u8, 8 + debug_len);
    errdefer allocator.free(payload);

    payload[0] = @intCast((last_stream_id >> 24) & 0x7F);
    payload[1] = @intCast((last_stream_id >> 16) & 0xFF);
    payload[2] = @intCast((last_stream_id >> 8) & 0xFF);
    payload[3] = @intCast(last_stream_id & 0xFF);
    payload[4] = @intCast((code >> 24) & 0xFF);
    payload[5] = @intCast((code >> 16) & 0xFF);
    payload[6] = @intCast((code >> 8) & 0xFF);
    payload[7] = @intCast(code & 0xFF);

    if (debug_data) |d| {
        @memcpy(payload[8..], d);
    }

    return payload;
}

/// Parses a GOAWAY frame payload.
pub fn parseGoawayPayload(payload: []const u8, allocator: Allocator) !struct {
    last_stream_id: u31,
    error_code: http.Http2ErrorCode,
    debug_data: ?[]u8,
} {
    if (payload.len < 8) return error.InvalidFrame;

    const last_stream_id: u31 = @intCast(
        (@as(u32, payload[0] & 0x7F) << 24) |
            (@as(u32, payload[1]) << 16) |
            (@as(u32, payload[2]) << 8) |
            payload[3],
    );
    const error_code: http.Http2ErrorCode = @enumFromInt(
        (@as(u32, payload[4]) << 24) |
            (@as(u32, payload[5]) << 16) |
            (@as(u32, payload[6]) << 8) |
            payload[7],
    );

    const debug_data = if (payload.len > 8)
        try allocator.dupe(u8, payload[8..])
    else
        null;

    return .{
        .last_stream_id = last_stream_id,
        .error_code = error_code,
        .debug_data = debug_data,
    };
}

/// Builds a PING frame payload.
pub fn buildPingPayload(opaque_data: [8]u8) [8]u8 {
    return opaque_data;
}

test "Stream state transitions" {
    const allocator = std.testing.allocator;
    var stream = Stream.init(1);
    defer stream.deinit(allocator);

    try stream.open();
    try std.testing.expectEqual(StreamState.open, stream.state);

    stream.sendEndStream();
    try std.testing.expectEqual(StreamState.half_closed_local, stream.state);

    stream.receiveEndStream();
    try std.testing.expectEqual(StreamState.closed, stream.state);
}

test "Stream manager create and get" {
    const allocator = std.testing.allocator;
    var manager = StreamManager.init(allocator, true);
    defer manager.deinit();

    const stream1 = try manager.createStream();
    try std.testing.expectEqual(@as(u31, 1), stream1.id);

    const stream2 = try manager.createStream();
    try std.testing.expectEqual(@as(u31, 3), stream2.id);

    const got = manager.getStream(1).?;
    try std.testing.expectEqual(@as(u31, 1), got.id);
}

test "Flow control window update" {
    const allocator = std.testing.allocator;
    var stream = Stream.init(1);
    defer stream.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 65535), stream.send_window);

    try stream.updateSendWindow(-1000);
    try std.testing.expectEqual(@as(i32, 64535), stream.send_window);

    try stream.updateSendWindow(500);
    try std.testing.expectEqual(@as(i32, 65035), stream.send_window);
}

test "WINDOW_UPDATE payload" {
    const payload = buildWindowUpdatePayload(32768);
    const increment = try parseWindowUpdatePayload(&payload);
    try std.testing.expectEqual(@as(u31, 32768), increment);
}

test "RST_STREAM payload" {
    const payload = buildRstStreamPayload(.cancel);
    const error_code = try parseRstStreamPayload(&payload);
    try std.testing.expectEqual(http.Http2ErrorCode.cancel, error_code);
}

test "PRIORITY payload" {
    const priority = StreamPriority{
        .dependency = 5,
        .weight = 128,
        .exclusive = true,
    };
    const payload = buildPriorityPayload(priority);
    const parsed = try parsePriorityPayload(&payload);

    try std.testing.expectEqual(priority.dependency, parsed.dependency);
    try std.testing.expectEqual(priority.weight, parsed.weight);
    try std.testing.expectEqual(priority.exclusive, parsed.exclusive);
}
