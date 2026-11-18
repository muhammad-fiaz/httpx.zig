//! Type-erased byte-stream transport.
//!
//! `Stream` is the single vtable shared by protocol code that must run over
//! more than one substrate: plain TCP sockets, TLS server connections and TLS
//! client connections. The concrete transport owns its handle; `Stream` only
//! borrows it. Lifetime rules:
//!
//! - The `context` pointer must stay valid for every `Stream` call.
//! - `Stream` never closes, frees or resets the transport. Ownership stays
//!   with whoever created it (the HTTP connection worker, the WebSocket
//!   client, or the caller).
//! - Timeouts are advisory socket settings, exactly like
//!   `tcp.Socket.setReadTimeoutMs`.
//!
//! A stream is safe for one concurrent reader and one concurrent writer.
//! Multiple writers require external synchronization.

const std = @import("std");

pub const Stream = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, buf: []u8) anyerror!usize,
        writeAll: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
        setReadTimeoutMs: *const fn (context: *anyopaque, timeoutMs: u32) void,
        setWriteTimeoutMs: *const fn (context: *anyopaque, timeoutMs: u32) void,
        peerAddress: *const fn (context: *anyopaque) []const u8,
        isTls: *const fn (context: *anyopaque) bool,
    };

    /// Reads up to `buf.len` bytes. A partial read is normal; zero means EOF.
    pub fn read(self: Stream, buf: []u8) anyerror!usize {
        return self.vtable.read(self.context, buf);
    }

    /// Writes every byte or fails.
    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        return self.vtable.writeAll(self.context, bytes);
    }

    pub fn setReadTimeoutMs(self: Stream, timeoutMs: u32) void {
        self.vtable.setReadTimeoutMs(self.context, timeoutMs);
    }

    pub fn setWriteTimeoutMs(self: Stream, timeoutMs: u32) void {
        self.vtable.setWriteTimeoutMs(self.context, timeoutMs);
    }

    /// Peer IP text, or an empty slice when unavailable.
    pub fn peerAddress(self: Stream) []const u8 {
        return self.vtable.peerAddress(self.context);
    }

    pub fn isTls(self: Stream) bool {
        return self.vtable.isTls(self.context);
    }
};
