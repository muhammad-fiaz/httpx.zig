//! HTTP/2 stream state machine (RFC 9113 section 5.1).
//!
//! States and the legal frame transitions, with nghttp2's stricter
//! treatment: frames that arrive in an invalid state generally escalate
//! to connection errors (STREAM_CLOSED / PROTOCOL_ERROR), matching
//! production behavior.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ErrorCode = enum(u32) {
    no_error = 0x00,
    protocol_error = 0x01,
    internal_error = 0x02,
    flow_control_error = 0x03,
    settings_timeout = 0x04,
    stream_closed = 0x05,
    frame_size_error = 0x06,
    refused_stream = 0x07,
    cancel = 0x08,
    compression_error = 0x09,
    connect_error = 0x0a,
    enhance_your_calm = 0x0b,
    inadequate_security = 0x0c,
    http11Required = 0x0d,
    _,

    pub fn name(self: ErrorCode) []const u8 {
        return switch (self) {
            .protocol_error => "PROTOCOL_ERROR",
            .stream_closed => "STREAM_CLOSED",
            .frame_size_error => "FRAME_SIZE_ERROR",
            .flow_control_error => "FLOW_CONTROL_ERROR",
            .refused_stream => "REFUSED_STREAM",
            .compression_error => "COMPRESSION_ERROR",
            else => @tagName(self),
        };
    }
};

pub const State = enum {
    idle,
    reservedLocal,
    reservedRemote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,

    pub fn isActive(self: State) bool {
        return switch (self) {
            .open, .half_closed_local, .half_closed_remote => true,
            else => false,
        };
    }

    /// May we send DATA on this stream?
    pub fn canSendData(self: State) bool {
        return self == .open or self == .half_closed_remote;
    }

    /// May we send HEADERS (request/response/trailers)?
    /// half_closed_remote allows the response side of an exchange.
    pub fn canSendHeaders(self: State) bool {
        return switch (self) {
            .idle, .reservedLocal, .open, .half_closed_remote => true,
            else => false,
        };
    }

    /// May we receive DATA?
    pub fn canRecvData(self: State) bool {
        return self == .open or self == .half_closed_local;
    }

    /// May we receive HEADERS (trailers included)?
    pub fn canRecvHeaders(self: State) bool {
        return switch (self) {
            .idle, .reservedRemote, .open => true,
            else => false,
        };
    }
};

pub const DEFAULT_WINDOW_SIZE: i32 = 65535;
pub const MAX_WINDOW_DELTA: i32 = 0x7FFFFFFF;

/// One HTTP/2 stream with its flow-control windows.
pub const Stream = struct {
    id: u31,
    allocator: Allocator,
    state: State = .idle,

    // Flow control (RFC 9113 section 5.2)
    sendWindow: i64 = DEFAULT_WINDOW_SIZE,
    recvWindow: i64 = DEFAULT_WINDOW_SIZE,
    /// Bytes received but not yet credited back via WINDOW_UPDATE.
    recvPending: i64 = 0,

    endHeaders: bool = false,
    endStreamSent: bool = false,
    endStreamRecv: bool = false,
    resetByUs: bool = false,
    resetCode: u32 = 0,

    /// Assembled header block fragments (HEADERS + CONTINUATION chain).
    headerBlock: ?std.ArrayList(u8) = null,
    /// Reassembled DATA payload for buffered consumers.
    dataBuf: ?std.ArrayList(u8) = null,

    pub fn init(allocator: Allocator, id: u31) Stream {
        return .{ .id = id, .allocator = allocator };
    }

    pub fn deinit(self: *Stream) void {
        if (self.headerBlock) |*b| b.deinit(self.allocator);
        if (self.dataBuf) |*b| b.deinit(self.allocator);
    }

    // -- send-side transitions ------------------------------------------------

    pub fn onSendHeaders(self: *Stream, endStream: bool) error{InvalidState}!void {
        if (!self.state.canSendHeaders()) return error.InvalidState;
        if (self.endStreamSent) return error.InvalidState;
        switch (self.state) {
            .idle => self.state = if (endStream) State.half_closed_local else State.open,
            .reservedLocal => self.state = .half_closed_remote,
            .open => {
                if (endStream) self.state = .half_closed_local;
            },
            // Response/trailer headers on a half-closed(remote) stream do
            // not change our own direction; END_STREAM closes it.
            .half_closed_remote => {
                if (endStream) self.state = .closed;
            },
            else => return error.InvalidState,
        }
        if (endStream) self.endStreamSent = true;
    }

    pub fn onSendData(self: *Stream, endStream: bool) error{InvalidState}!void {
        if (!self.state.canSendData() or self.endStreamSent) return error.InvalidState;
        if (endStream) {
            // A sender that already received END_STREAM closes fully here
            // (mirrors onSendHeaders); otherwise it half-closes its side.
            // Getting this wrong leaks the stream (and, server-side, the
            // concurrency slot) forever.
            self.state = if (self.state == .half_closed_remote) .closed else .half_closed_local;
            self.endStreamSent = true;
        }
    }

    pub fn onSendRst(self: *Stream) void {
        self.resetByUs = true;
        self.state = .closed;
    }

    // -- receive-side transitions ---------------------------------------------

    pub const RecvError = error{
        StreamClosed, // -> connection STREAM_CLOSED per nghttp2 strictness
        ProtocolError,
    };

    pub fn onRecvHeaders(self: *Stream, endStream: bool) RecvError!void {
        switch (self.state) {
            .idle => {
                self.state = if (endStream) .half_closed_remote else .open;
                self.endStreamRecv = endStream;
            },
            .reservedRemote => {
                self.state = if (endStream) .closed else .half_closed_local;
                self.endStreamRecv = endStream;
            },
            .open => {
                if (endStream) {
                    self.state = .half_closed_remote;
                    self.endStreamRecv = true;
                }
            },
            .half_closed_local => {
                if (endStream) {
                    self.state = .closed;
                    self.endStreamRecv = true;
                }
                // Trailers without END_STREAM on a half-closed(local) stream:
                // legal (we may still be sending).
            },
            .half_closed_remote, .closed, .reservedLocal => return RecvError.StreamClosed,
        }
    }

    pub fn onRecvData(self: *Stream, endStream: bool) RecvError!void {
        switch (self.state) {
            .open => {
                if (endStream) {
                    self.state = .half_closed_remote;
                    self.endStreamRecv = true;
                }
            },
            .half_closed_local => {
                if (endStream) {
                    self.state = .closed;
                    self.endStreamRecv = true;
                }
            },
            .idle, .reservedLocal, .reservedRemote => return RecvError.ProtocolError,
            .half_closed_remote, .closed => return RecvError.StreamClosed,
        }
    }

    pub fn onRecvRst(self: *Stream) void {
        self.state = .closed;
    }

    /// WINDOW_UPDATE legality on this stream (increment validated by caller).
    pub fn canWindowUpdate(self: State) bool {
        return switch (self.state) {
            .idle, .closed => false,
            else => true,
        };
    }

    /// Flow-control credit accounting; returns false when overflow.
    pub fn creditSend(self: *Stream, n: i64) bool {
        self.sendWindow -= n;
        return self.sendWindow >= -MAX_WINDOW_DELTA;
    }

    pub fn consumeRecv(self: *Stream, n: i64) bool {
        self.recvWindow -= n;
        self.recvPending += n;
        // Overflow beyond -(2^31-1) is FLOW_CONTROL_ERROR at the receiver.
        return self.recvWindow >= -MAX_WINDOW_DELTA;
    }
};

test "state transitions open path" {
    var s = Stream.init(std.testing.allocator, 1);
    defer s.deinit();
    try std.testing.expectEqual(State.idle, s.state);

    try s.onSendHeaders(false);
    try std.testing.expectEqual(State.open, s.state);
    try s.onSendData(false);
    try std.testing.expectEqual(State.open, s.state);

    try s.onSendData(true);
    try std.testing.expectEqual(State.half_closed_local, s.state);

    try s.onRecvHeaders(true); // trailers w/ END_STREAM closes
    try std.testing.expectEqual(State.closed, s.state);
}

test "data after full close is StreamClosed" {
    var s = Stream.init(std.testing.allocator, 3);
    defer s.deinit();
    try s.onSendHeaders(true); // -> half_closed_local
    try std.testing.expectEqual(State.half_closed_local, s.state);
    // Receiving DATA (no END_STREAM) on half_closed_local is legal.
    try s.onRecvData(false);
    // Peer sends END_STREAM too: fully closed.
    try s.onRecvData(true);
    try std.testing.expectEqual(State.closed, s.state);
    // Anything after that is a stream error.
    try std.testing.expectError(error.StreamClosed, s.onRecvData(false));
}

test "recv on idle is protocol error" {
    var s = Stream.init(std.testing.allocator, 5);
    defer s.deinit();
    try std.testing.expectError(error.ProtocolError, s.onRecvData(false));
}
