//! IO Utilities for httpx.zig
//!
//! Centralizes:
//! - `defaultIo()`:    single-threaded std.Io for test contexts
//! - `threadIo()`:     real thread-safe std.Io for multi-threaded code
//! - `sleepMs()`:      sleep helper that uses the canonical IO
//! - `AnyReader` / `AnyWriter`: type-erased streaming adapters

const std = @import("std");
const builtin = @import("builtin");

/// Returns the appropriate `std.Io` for the current execution context.
///
/// - In tests: `std.testing.io` (single-threaded, deterministic)
/// - Otherwise: `std.Io.Threaded.global_single_threaded.io()`
///
/// Use this for single-threaded test code. For code that spawns real OS
/// threads (executors, thread pools), use `threadIo()` instead.
pub inline fn defaultIo() std.Io {
    return if (builtin.is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

/// Returns a real thread-safe `std.Io` suitable for multi-threaded code.
///
/// - In tests: `std.testing.io` (a real `Io.Threaded`, safe from any thread)
/// - Otherwise: `std.Io.Threaded.global_single_threaded.io()`
pub inline fn threadIo() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    }
    return std.Io.Threaded.global_single_threaded.io();
}

/// Sleeps for `ms` milliseconds using the canonical IO.
///
/// `ms` is `i64` to match `std.Io.Duration.fromMilliseconds`.
/// Errors from `std.Io.sleep` are silently ignored (non-critical).
pub fn sleepMsI(ms: i64) void {
    const io = defaultIo();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

/// Sleeps for `ms` milliseconds using the canonical IO.
///
/// `ms` is `u64`. Values larger than `i64.max` are clamped.
pub fn sleepMs(ms: u64) void {
    const clamped: i64 = @intCast(@min(ms, @as(u64, @intCast(std.math.maxInt(i64)))));
    sleepMsI(clamped);
}

/// A type-erased reader compatible with any `*anyopaque` backed source.
pub const AnyReader = struct {
    context: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,

    pub fn read(self: AnyReader, buffer: []u8) anyerror!usize {
        return self.readFn(self.context, buffer);
    }

    pub fn readByte(self: AnyReader) anyerror!u8 {
        var one: [1]u8 = undefined;
        const n = try self.read(one[0..]);
        if (n == 0) return error.EndOfStream;
        return one[0];
    }

    pub fn readNoEof(self: AnyReader, out: []u8) anyerror!void {
        var read_count: usize = 0;
        while (read_count < out.len) {
            const n = try self.read(out[read_count..]);
            if (n == 0) return error.EndOfStream;
            read_count += n;
        }
    }
};

/// A type-erased writer compatible with any `*anyopaque` backed sink.
pub const AnyWriter = struct {
    context: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!usize,

    pub fn write(self: AnyWriter, data: []const u8) anyerror!usize {
        return self.writeFn(self.context, data);
    }

    pub fn writeAll(self: AnyWriter, data: []const u8) anyerror!void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try self.write(data[sent..]);
            if (n == 0) return error.WriteFailed;
            sent += n;
        }
    }

    pub fn print(self: AnyWriter, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

test "defaultIo returns a valid Io" {
    const io = defaultIo();
    _ = io; // compile + no panic
}

test "sleepMs zero does not panic" {
    sleepMs(0);
    sleepMsI(0);
}
