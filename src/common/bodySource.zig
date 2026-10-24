//! Streaming request body producer interface for HTTP/1.1, HTTP/2, and HTTP/3.
//!
//! Provides a bounded-memory, zero-allocation pull interface for incremental
//! streaming request uploads from arbitrary readers, buffers, files, or custom
//! producers, with flow control backpressure, cancellation awareness,
//! content-length validation, and optional trailers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Header = @import("headers.zig").Header;

pub const BodySource = struct {
    ptr: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
    contentLength: ?u64 = null,
    trailersFn: ?*const fn (ctx: *anyopaque, a: Allocator) anyerror!?[]const Header = null,
    resetFn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    closeFn: ?*const fn (ctx: *anyopaque) void = null,

    /// Pull up to `buf.len` bytes from the body producer. Returns 0 on EOF.
    pub fn read(self: BodySource, buf: []u8) anyerror!usize {
        if (buf.len == 0) return 0;
        return self.readFn(self.ptr, buf);
    }

    /// Pull trailing headers after the body has completed (read returned 0).
    pub fn getTrailers(self: BodySource, a: Allocator) anyerror!?[]const Header {
        if (self.trailersFn) |f| {
            return f(self.ptr, a);
        }
        return null;
    }

    /// Attempt to reset the stream back to its beginning for replay.
    pub fn reset(self: BodySource) anyerror!void {
        if (self.resetFn) |f| {
            return f(self.ptr);
        }
        return error.CannotResetStream;
    }

    /// Whether this source can safely be rewound and replayed.
    pub fn canReset(self: BodySource) bool {
        return self.resetFn != null;
    }

    /// Close the producer and release associated resources if applicable.
    pub fn close(self: BodySource) void {
        if (self.closeFn) |f| {
            f(self.ptr);
        }
    }

    /// Create an empty BodySource.
    pub fn empty() BodySource {
        const Empty = struct {
            var dummy: u8 = 0;
            fn read(_: *anyopaque, _: []u8) anyerror!usize {
                return 0;
            }
            fn reset(_: *anyopaque) anyerror!void {}
        };
        return .{
            .ptr = &Empty.dummy,
            .readFn = Empty.read,
            .contentLength = 0,
            .trailersFn = null,
            .resetFn = Empty.reset,
            .closeFn = null,
        };
    }

    /// Wrap any pointer with a `read(buf: []u8) anyerror!usize` method.
    pub fn fromReader(readerPtr: anytype, contentLength: ?u64) BodySource {
        const PtrType = @TypeOf(readerPtr);
        const ChildType = switch (@typeInfo(PtrType)) {
            .pointer => |p| p.child,
            else => @compileError("readerPtr must be a pointer"),
        };
        const ReaderWrapper = struct {
            fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
                const self: *ChildType = @ptrCast(@alignCast(ctx));
                return self.read(buf);
            }
        };
        return .{
            .ptr = readerPtr,
            .readFn = ReaderWrapper.read,
            .contentLength = contentLength,
            .trailersFn = null,
            .resetFn = null,
            .closeFn = null,
        };
    }
};

/// Slice-backed body producer for streaming known-length byte buffers
/// incrementally without copying the buffer.
pub const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) SliceReader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.data.len) return 0;
        const available = self.data.len - self.pos;
        const toCopy = @min(available, buf.len);
        @memcpy(buf[0..toCopy], self.data[self.pos .. self.pos + toCopy]);
        self.pos += toCopy;
        return toCopy;
    }

    pub fn reset(ctx: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.pos = 0;
    }

    pub fn source(self: *SliceReader) BodySource {
        return .{
            .ptr = self,
            .readFn = read,
            .contentLength = self.data.len,
            .trailersFn = null,
            .resetFn = reset,
            .closeFn = null,
        };
    }
};

/// Custom callback-backed body producer.
pub const CallbackReader = struct {
    ctx: *anyopaque,
    readCb: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
    contentLength: ?u64 = null,
    trailersCb: ?*const fn (ctx: *anyopaque, a: Allocator) anyerror!?[]const Header = null,
    resetCb: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    closeCb: ?*const fn (ctx: *anyopaque) void = null,

    pub fn source(self: *CallbackReader) BodySource {
        return .{
            .ptr = self.ctx,
            .readFn = self.readCb,
            .contentLength = self.contentLength,
            .trailersFn = self.trailersCb,
            .resetFn = self.resetCb,
            .closeFn = self.closeCb,
        };
    }
};

test "bodySource sliceReader incremental reading" {
    var sr = SliceReader.init("Hello, world! Streaming test.");
    const bs = sr.source();
    try std.testing.expectEqual(@as(?u64, 29), bs.contentLength);

    var buf: [8]u8 = undefined;
    const n1 = try bs.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n1);
    try std.testing.expectEqualStrings("Hello, w", buf[0..n1]);

    const n2 = try bs.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n2);
    try std.testing.expectEqualStrings("orld! St", buf[0..n2]);

    var rest: [64]u8 = undefined;
    const n3 = try bs.read(&rest);
    try std.testing.expectEqual(@as(usize, 13), n3);
    try std.testing.expectEqualStrings("reaming test.", rest[0..n3]);

    const n4 = try bs.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n4);

    // Test rewind & replay
    try std.testing.expect(bs.canReset());
    try bs.reset();
    const n5 = try bs.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n5);
    try std.testing.expectEqualStrings("Hello, w", buf[0..n5]);
}

test "bodySource empty" {
    const bs = BodySource.empty();
    try std.testing.expectEqual(@as(?u64, 0), bs.contentLength);
    var buf: [16]u8 = undefined;
    const n = try bs.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
    const trailers = try bs.getTrailers(std.testing.allocator);
    try std.testing.expect(trailers == null);
    try std.testing.expect(bs.canReset());
    try bs.reset();
}
