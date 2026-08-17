//! Buffer Utilities for httpx.zig
//!
//! Provides high-performance buffer implementations for HTTP message handling:
//!
//! - `Buffer`: Growable dynamic buffer for building messages
//! - `FixedBuffer`: Stack-allocated fixed-size buffer

const std = @import("std");
const dbg = @import("debug.zig");
const Allocator = std.mem.Allocator;

/// Growable buffer for building HTTP messages.
pub const Buffer = struct {
    allocator: Allocator,
    data: []u8,
    len: usize = 0,
    capacity: usize,

    const Self = @This();

    /// Creates a new buffer with the specified initial capacity.
    pub fn init(allocator: Allocator, initial_capacity: usize) !Self {
        dbg.entry("BUF", "Buffer.init");
        defer dbg.exit("BUF", "Buffer.init");
        const data = try allocator.alloc(u8, initial_capacity);
        return .{
            .allocator = allocator,
            .data = data,
            .capacity = initial_capacity,
        };
    }

    /// Releases the buffer memory.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Appends bytes to the buffer, growing if necessary.
    pub fn append(self: *Self, bytes: []const u8) !void {
        try self.ensureCapacity(self.len + bytes.len);
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Appends a single byte to the buffer.
    pub fn appendByte(self: *Self, byte: u8) !void {
        try self.ensureCapacity(self.len + 1);
        self.data[self.len] = byte;
        self.len += 1;
    }

    /// Ensures the buffer has at least the specified capacity.
    fn ensureCapacity(self: *Self, needed: usize) !void {
        if (needed <= self.capacity) return;

        var new_capacity = self.capacity;
        while (new_capacity < needed) {
            new_capacity = new_capacity * 2;
        }

        self.data = try self.allocator.realloc(self.data, new_capacity);
        self.capacity = new_capacity;
    }

    /// Returns the current buffer contents.
    pub fn slice(self: *const Self) []const u8 {
        return self.data[0..self.len];
    }

    /// Clears the buffer without freeing memory.
    pub fn clear(self: *Self) void {
        self.len = 0;
    }

    /// Returns ownership of the buffer contents and resets the buffer.
    pub fn toOwnedSlice(self: *Self) ![]u8 {
        const result = try self.allocator.dupe(u8, self.data[0..self.len]);
        self.clear();
        return result;
    }

    /// Returns a writer interface for the buffer.
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub const Writer = struct {
        context: *Self,

        pub fn write(self: Writer, bytes: []const u8) error{OutOfMemory}!usize {
            self.context.append(bytes) catch return error.OutOfMemory;
            return bytes.len;
        }

        pub fn writeAll(self: Writer, bytes: []const u8) error{OutOfMemory}!void {
            _ = try self.write(bytes);
        }

        pub fn writeByte(self: Writer, byte: u8) error{OutOfMemory}!void {
            self.context.appendByte(byte) catch return error.OutOfMemory;
        }

        pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
            var buf: [4096]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
            try self.writeAll(text);
        }
    };
};

/// Fixed-size buffer for stack allocation without heap usage.
pub fn FixedBuffer(comptime size: usize) type {
    return struct {
        data: [size]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Appends bytes to the buffer.
        pub fn append(self: *Self, bytes: []const u8) !void {
            if (self.len + bytes.len > size) return error.BufferOverflow;
            @memcpy(self.data[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        /// Appends a single byte.
        pub fn appendByte(self: *Self, byte: u8) !void {
            if (self.len >= size) return error.BufferOverflow;
            self.data[self.len] = byte;
            self.len += 1;
        }

        /// Returns the current buffer contents.
        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }

        /// Clears the buffer.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Returns the remaining capacity.
        pub fn remaining(self: *const Self) usize {
            return size - self.len;
        }
    };
}

test "Buffer operations" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 16);
    defer buf.deinit();

    try buf.append("Hello");
    try buf.append(" ");
    try buf.append("World");

    try std.testing.expectEqualStrings("Hello World", buf.slice());
}

test "Buffer growth" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 4);
    defer buf.deinit();

    try buf.append("12345678901234567890");
    try std.testing.expectEqual(@as(usize, 20), buf.len);
    try std.testing.expect(buf.capacity >= 20);
}

test "FixedBuffer operations" {
    var buf = FixedBuffer(32){};

    try buf.append("test");
    try std.testing.expectEqualStrings("test", buf.slice());
    try std.testing.expectEqual(@as(usize, 28), buf.remaining());
}

test "FixedBuffer overflow" {
    var buf = FixedBuffer(4){};

    try buf.append("test");
    try std.testing.expectError(error.BufferOverflow, buf.append("x"));
}
