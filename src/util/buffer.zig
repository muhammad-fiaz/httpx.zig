//! Buffer Utilities for httpx.zig
//!
//! Provides high-performance buffer implementations for HTTP message handling:
//!
//! - `Buffer`: Growable dynamic buffer for building messages
//! - `RingBuffer`: Circular buffer for streaming data
//! - `FixedBuffer`: Stack-allocated fixed-size buffer

const std = @import("std");
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

/// Circular buffer for streaming data with fixed capacity.
pub const RingBuffer = struct {
    allocator: Allocator,
    data: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,

    const Self = @This();

    /// Creates a new ring buffer with the specified capacity.
    pub fn init(allocator: Allocator, capacity: usize) !Self {
        return .{
            .allocator = allocator,
            .data = try allocator.alloc(u8, capacity),
        };
    }

    /// Releases the buffer memory.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Writes bytes to the buffer, returning the number written.
    pub fn writeBytes(self: *Self, bytes: []const u8) !usize {
        const space = self.data.len - self.count;
        const to_write = @min(bytes.len, space);

        for (bytes[0..to_write]) |byte| {
            self.data[self.write_pos] = byte;
            self.write_pos = (self.write_pos + 1) % self.data.len;
            self.count += 1;
        }

        return to_write;
    }

    /// Reads bytes from the buffer into the provided slice.
    pub fn readBytes(self: *Self, buffer: []u8) usize {
        const to_read = @min(buffer.len, self.count);

        for (buffer[0..to_read]) |*b| {
            b.* = self.data[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.data.len;
            self.count -= 1;
        }

        return to_read;
    }

    /// Returns the number of bytes available to read.
    pub fn getAvailable(self: *const Self) usize {
        return self.count;
    }

    /// Returns the total buffer capacity.
    pub fn getCapacity(self: *const Self) usize {
        return self.data.len;
    }

    /// Returns the amount of free space in the buffer.
    pub fn getFreeSpace(self: *const Self) usize {
        return self.data.len - self.count;
    }

    /// Returns true if the buffer is empty.
    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }

    /// Returns true if the buffer is full.
    pub fn isFull(self: *const Self) bool {
        return self.count == self.data.len;
    }

    /// Clears all data from the buffer.
    pub fn clear(self: *Self) void {
        self.read_pos = 0;
        self.write_pos = 0;
        self.count = 0;
    }
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

test "RingBuffer operations" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 8);
    defer ring.deinit();

    _ = try ring.writeBytes("hello");
    try std.testing.expectEqual(@as(usize, 5), ring.getAvailable());

    var out: [10]u8 = undefined;
    const n = ring.readBytes(&out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "RingBuffer wraparound" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 4);
    defer ring.deinit();

    _ = try ring.writeBytes("ab");
    var out: [2]u8 = undefined;
    _ = ring.readBytes(&out);
    _ = try ring.writeBytes("cdef");

    try std.testing.expectEqual(@as(usize, 4), ring.getAvailable());
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
