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
const dbg = @import("../util/debug.zig");

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
            .open => {
                self.state = .half_closed_local;
                dbg.log("STREAM", "stream {d} -> half_closed_local (sent END_STREAM)", .{self.id});
            },
            .half_closed_remote => {
                self.state = .closed;
                dbg.log("STREAM", "stream {d} -> closed (sent END_STREAM)", .{self.id});
            },
            else => {},
        }
    }

    /// Transitions state after receiving END_STREAM.
    pub fn receiveEndStream(self: *Self) void {
        self.end_stream_received = true;
        switch (self.state) {
            .open => {
                self.state = .half_closed_remote;
                dbg.log("STREAM", "stream {d} -> half_closed_remote (recv END_STREAM)", .{self.id});
            },
            .half_closed_local => {
                self.state = .closed;
                dbg.log("STREAM", "stream {d} -> closed (recv END_STREAM)", .{self.id});
            },
            else => {},
        }
    }

    /// Opens the stream (transitions from idle to open).
    pub fn open(self: *Self) !void {
        dbg.entry("STREAM", "Stream.open");
        if (self.state != .idle) return error.InvalidStreamState;
        self.state = .open;
        dbg.log("STREAM", "stream {d} -> open", .{self.id});
    }

    /// Closes the stream due to RST_STREAM or error.
    pub fn reset(self: *Self) void {
        dbg.entry("STREAM", "Stream.reset");
        self.state = .closed;
        dbg.log("STREAM", "stream {d} -> closed (reset)", .{self.id});
    }

    /// Updates the send window by delta (can be negative for data sent).
    pub fn updateSendWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.send_window) + delta;
        if (new_window > std.math.maxInt(i32)) return error.FlowControlError;
        if (new_window < std.math.minInt(i32)) return error.FlowControlError;
        self.send_window = @intCast(new_window);
    }

    /// Updates the receive window by delta.
    pub fn updateRecvWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.recv_window) + delta;
        if (new_window > std.math.maxInt(i32)) return error.FlowControlError;
        if (new_window < std.math.minInt(i32)) return error.FlowControlError;
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

    /// Maximum concurrent streams allowed (from peer SETTINGS).
    max_concurrent_streams: u32 = 100,

    /// Peer's connection settings for enforcement.
    peer_settings: http.Http2Connection.Http2ConnectionSettings = .{},

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

    /// Checks if a new stream can be opened within the concurrent streams limit.
    pub fn canOpenStream(self: *const Self) bool {
        return self.activeStreamCount() < self.max_concurrent_streams;
    }

    /// Validates that a frame's payload length does not exceed the peer's max frame size.
    pub fn validateFrameSize(self: *const Self, frame_length: usize) !void {
        if (frame_length > self.peer_settings.max_frame_size) return error.FrameTooLarge;
    }

    /// Applies peer settings and enforces INITIAL_WINDOW_SIZE delta on all streams.
    pub fn applyPeerSettings(self: *Self, new_settings: http.Http2Connection.Http2ConnectionSettings) !void {
        const old_window = self.peer_settings.initial_window_size;
        self.peer_settings = new_settings;
        self.max_concurrent_streams = new_settings.max_concurrent_streams;
        if (new_settings.initial_window_size != old_window) {
            try self.applyInitialWindowSizeChange(old_window, new_settings.initial_window_size);
        }
    }

    /// Updates connection-level send window.
    pub fn updateConnectionSendWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.connection_send_window) + delta;
        if (new_window > std.math.maxInt(i32)) return error.FlowControlError;
        if (new_window < std.math.minInt(i32)) return error.FlowControlError;
        self.connection_send_window = @intCast(new_window);
    }

    /// Updates connection-level receive window.
    pub fn updateConnectionRecvWindow(self: *Self, delta: i32) !void {
        const new_window = @as(i64, self.connection_recv_window) + delta;
        if (new_window > std.math.maxInt(i32)) return error.FlowControlError;
        if (new_window < std.math.minInt(i32)) return error.FlowControlError;
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

/// Builds a HEADERS frame with optional CONTINUATION frames for sending.
///
/// If the HPACK-encoded header block fits in a single frame (size <= max_frame_size - 9),
/// returns a single complete HEADERS frame with END_HEADERS set.
///
/// If it exceeds max_frame_size - 9, splits across a HEADERS frame (without END_HEADERS)
/// followed by one or more CONTINUATION frames, with the final one having END_HEADERS.
///
/// Returns a flat buffer of complete HTTP/2 frames (9-byte headers + payloads)
/// ready to be written to the wire with a single write call.
pub fn buildHeadersAndContinuations(
    stream_manager: *StreamManager,
    stream_id: u31,
    headers: []const hpack.HeaderEntry,
    priority: ?StreamPriority,
    max_frame_size: u32,
    end_stream: bool,
    allocator: Allocator,
) ![]u8 {
    // Build the priority block (5 bytes if present)
    var priority_payload = std.ArrayList(u8).empty;
    defer priority_payload.deinit(allocator);

    if (priority) |p| {
        var dep: u32 = p.dependency;
        if (p.exclusive) dep |= 0x80000000;
        try priority_payload.append(allocator, @intCast((dep >> 24) & 0xFF));
        try priority_payload.append(allocator, @intCast((dep >> 16) & 0xFF));
        try priority_payload.append(allocator, @intCast((dep >> 8) & 0xFF));
        try priority_payload.append(allocator, @intCast(dep & 0xFF));
        try priority_payload.append(allocator, p.weight -% 1);
    }

    // HPACK-encode the headers
    const encoded_headers = try hpack.encodeHeaders(&stream_manager.hpack_ctx, headers, allocator);
    defer allocator.free(encoded_headers);

    // max_fragment_size accounts for potential priority block overhead in the first frame,
    // ensuring no frame payload exceeds max_frame_size.
    const max_fragment_size: usize = if (max_frame_size > 9) @intCast(max_frame_size - 9) else 0;

    // If the HPACK-encoded header block fits in one frame, send as single HEADERS frame
    if (encoded_headers.len <= max_fragment_size) {
        var flags: u8 = 0x04; // END_HEADERS
        if (end_stream) flags |= 0x01; // END_STREAM

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        const total_payload_len = priority_payload.items.len + encoded_headers.len;
        const frame_header = http.Http2FrameHeader{
            .length = @intCast(total_payload_len),
            .frame_type = .headers,
            .flags = flags,
            .stream_id = stream_id,
        };
        const hdr = frame_header.serialize();
        try result.appendSlice(allocator, &hdr);
        try result.appendSlice(allocator, priority_payload.items);
        try result.appendSlice(allocator, encoded_headers);

        return try result.toOwnedSlice(allocator);
    }

    // CONTINUATION required: build full payload then split across frames
    var full_payload = std.ArrayList(u8).empty;
    defer full_payload.deinit(allocator);
    try full_payload.appendSlice(allocator, priority_payload.items);
    try full_payload.appendSlice(allocator, encoded_headers);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    // First frame: HEADERS without END_HEADERS, with first chunk of payload
    const first_chunk_len = @min(full_payload.items.len, max_fragment_size);
    {
        const first_flags: u8 = if (end_stream) 0x01 else 0; // END_STREAM only, no END_HEADERS
        const frame_header = http.Http2FrameHeader{
            .length = @intCast(first_chunk_len),
            .frame_type = .headers,
            .flags = first_flags,
            .stream_id = stream_id,
        };
        const hdr = frame_header.serialize();
        try result.appendSlice(allocator, &hdr);
        try result.appendSlice(allocator, full_payload.items[0..first_chunk_len]);
    }

    // CONTINUATION frames for remaining payload
    var offset = first_chunk_len;
    while (offset < full_payload.items.len) {
        const chunk_len = @min(full_payload.items.len - offset, max_fragment_size);
        const is_last = (offset + chunk_len) == full_payload.items.len;
        const cont_flags: u8 = if (is_last) 0x04 else 0; // END_HEADERS on last CONTINUATION

        const frame_header = http.Http2FrameHeader{
            .length = @intCast(chunk_len),
            .frame_type = .continuation,
            .flags = cont_flags,
            .stream_id = stream_id,
        };
        const hdr = frame_header.serialize();
        try result.appendSlice(allocator, &hdr);
        try result.appendSlice(allocator, full_payload.items[offset .. offset + chunk_len]);

        offset += chunk_len;
    }

    return try result.toOwnedSlice(allocator);
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
    if (pad_length > payload.len - offset) return error.InvalidFrame;
    const header_block_len = payload.len - offset - pad_length;

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

/// Builds a complete GOAWAY frame (header + payload) ready to write.
pub fn buildGoawayFrame(
    last_stream_id: u31,
    error_code: http.Http2ErrorCode,
    debug_data: ?[]const u8,
    allocator: Allocator,
) ![]u8 {
    const payload = try buildGoawayPayload(last_stream_id, error_code, debug_data, allocator);
    defer allocator.free(payload);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const header = http.Http2FrameHeader{
        .length = @intCast(payload.len),
        .frame_type = .goaway,
        .flags = 0,
        .stream_id = 0,
    };
    const raw = header.serialize();
    try out.appendSlice(allocator, &raw);
    if (payload.len > 0) {
        try out.appendSlice(allocator, payload);
    }
    return try out.toOwnedSlice(allocator);
}

/// Builds a complete RST_STREAM frame (header + payload) ready to write.
pub fn buildRstStreamFrame(
    stream_id: u31,
    error_code: http.Http2ErrorCode,
) [13]u8 {
    const payload = buildRstStreamPayload(error_code);
    const header = http.Http2FrameHeader{
        .length = 4,
        .frame_type = .rst_stream,
        .flags = 0,
        .stream_id = stream_id,
    };
    const raw = header.serialize();
    var frame: [13]u8 = undefined;
    @memcpy(frame[0..9], &raw);
    @memcpy(frame[9..13], &payload);
    return frame;
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

test "canOpenStream respects max_concurrent_streams" {
    const allocator = std.testing.allocator;
    var manager = StreamManager.init(allocator, true);
    defer manager.deinit();

    manager.max_concurrent_streams = 2;
    try std.testing.expect(manager.canOpenStream());

    const s1 = try manager.createStream();
    try s1.open();
    try std.testing.expect(manager.canOpenStream());

    const s2 = try manager.createStream();
    try s2.open();
    try std.testing.expect(!manager.canOpenStream());
}

test "validateFrameSize catches oversized frames" {
    const allocator = std.testing.allocator;
    var manager = StreamManager.init(allocator, true);
    defer manager.deinit();

    manager.peer_settings.max_frame_size = 16384;
    try manager.validateFrameSize(16384);
    try std.testing.expectError(error.FrameTooLarge, manager.validateFrameSize(16385));
}

test "applyPeerSettings updates max_concurrent_streams and window size" {
    const allocator = std.testing.allocator;
    var manager = StreamManager.init(allocator, true);
    defer manager.deinit();

    // Create a stream so we can check its send_window
    const stream = try manager.createStream();
    try std.testing.expectEqual(@as(i32, 65535), stream.send_window);

    // Apply new settings with different initial_window_size
    const new_settings = http.Http2Connection.Http2ConnectionSettings{
        .max_concurrent_streams = 50,
        .initial_window_size = 32768,
        .max_frame_size = 16384,
    };
    try manager.applyPeerSettings(new_settings);

    try std.testing.expectEqual(@as(u32, 50), manager.max_concurrent_streams);
    try std.testing.expectEqual(@as(u32, 32768), manager.peer_settings.initial_window_size);
    // Stream send_window should be adjusted: 65535 + (32768 - 65535) = 32768
    try std.testing.expectEqual(@as(i32, 32768), stream.send_window);
}

test "buildGoawayFrame produces correct wire format" {
    const allocator = std.testing.allocator;
    const frame = try buildGoawayFrame(5, .no_error, "debug info", allocator);
    defer allocator.free(frame);

    // 9-byte frame header + 4 (last_stream_id) + 4 (error_code) + 10 (debug_data) = 27
    try std.testing.expectEqual(@as(usize, 27), frame.len);

    // Parse the frame header
    const header = http.Http2FrameHeader.parse(frame[0..9].*);
    try std.testing.expectEqual(@as(u24, 18), header.length);
    try std.testing.expectEqual(http.Http2FrameType.goaway, header.frame_type);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);

    // Parse the GOAWAY payload directly from frame bytes
    const payload = frame[9..];
    const last_stream_id: u31 = @intCast(
        (@as(u32, payload[0] & 0x7F) << 24) |
            (@as(u32, payload[1]) << 16) |
            (@as(u32, payload[2]) << 8) |
            payload[3],
    );
    try std.testing.expectEqual(@as(u31, 5), last_stream_id);

    const error_code: http.Http2ErrorCode = @enumFromInt(
        (@as(u32, payload[4]) << 24) |
            (@as(u32, payload[5]) << 16) |
            (@as(u32, payload[6]) << 8) |
            payload[7],
    );
    try std.testing.expectEqual(http.Http2ErrorCode.no_error, error_code);
    try std.testing.expectEqualStrings("debug info", payload[8..]);
}

test "buildRstStreamFrame produces correct wire format" {
    const frame = buildRstStreamFrame(3, .cancel);

    // 13 bytes total: 9-byte header + 4-byte error code
    try std.testing.expectEqual(@as(usize, 13), frame.len);

    const header = http.Http2FrameHeader.parse(frame[0..9].*);
    try std.testing.expectEqual(@as(u24, 4), header.length);
    try std.testing.expectEqual(http.Http2FrameType.rst_stream, header.frame_type);
    try std.testing.expectEqual(@as(u31, 3), header.stream_id);

    const error_code = try parseRstStreamPayload(frame[9..13]);
    try std.testing.expectEqual(http.Http2ErrorCode.cancel, error_code);
}
