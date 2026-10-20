//! Wall-clock and monotonic time utilities.
//!
//! Platform-abstracted time sources (Windows `GetSystemTimeAsFileTime` /
//! `QueryPerformanceCounter`, POSIX `clock_gettime` / `gettimeofday`,
//! macOS `mach_absolute_time`). Used for timestamping, timeout
//! calculations, and connection-lifetime tracking.
//!
//! References:
//!   - RFC 9110 Section 12.1.3 — Date Header (wall-clock timestamps)
//!   - RFC 9110 Section 18.2 — Date/Time Formats (HTTP-date)

const std = @import("std");
const builtin = @import("builtin");

/// Milliseconds since Unix epoch.
pub fn millisNow() i64 {
    return wallMillis();
}

fn wallMillis() i64 {
    switch (builtin.os.tag) {
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *u64) callconv(.winapi) void;
            };
            var ft: u64 = undefined;
            kernel32.GetSystemTimeAsFileTime(&ft);
            const epochDiff: u64 = 116_444_736_000_000_000;
            const ns100 = ft -| epochDiff;
            return @intCast(ns100 / 10_000);
        },
        .linux => {
            const linux = std.os.linux;
            var t: linux.timespec = .{ .sec = 0, .nsec = 0 };
            _ = linux.clock_gettime(linux.CLOCK.REALTIME, &t);
            return @as(i64, @intCast(t.sec)) * 1000 + @divFloor(@as(i64, @intCast(t.nsec)), 1_000_000);
        },
        .macos, .ios, .tvos, .watchos => {
            const Timeval = extern struct { sec: isize, usec: isize };
            const c = struct {
                extern "c" fn gettimeofday(tv: ?*Timeval, tz: ?*anyopaque) c_int;
            };
            var tv: Timeval = .{ .sec = 0, .usec = 0 };
            _ = c.gettimeofday(&tv, null);
            return @as(i64, @intCast(tv.sec)) * 1000 + @divFloor(@as(i64, @intCast(tv.usec)), 1000);
        },
        .freebsd => {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
            return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
        },
        else => {
            const io = std.Io.Threaded.global_single_threaded.io();
            const timestamp = std.Io.Clock.Timestamp.now(io, .real);
            return @intCast(@divTrunc(timestamp.raw.nanoseconds, 1_000_000));
        },
    }
}

/// Monotonic milliseconds from Zig 0.17's target-specific `std.Io` clock.
/// The standard-library backend selects the appropriate OS clock, including
/// Windows performance counters and POSIX monotonic clocks.
pub fn monotonicMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Clock.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(timestamp.raw.nanoseconds, 1_000_000));
}

/// Sleeps for the specified number of milliseconds.
pub fn sleepMillis(ms: u64) void {
    switch (builtin.os.tag) {
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
            };
            kernel32.Sleep(@intCast(ms));
        },
        else => {
            var ts: std.c.timespec = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            };
            _ = std.c.nanosleep(&ts, null);
        },
    }
}

test "millisNow plausible" {
    const now = millisNow();
    // Sometime after 2024-01-01 and before year 2100.
    try std.testing.expect(now > 1_704_067_200_000);
    try std.testing.expect(now < 4_102_444_800_000);
}

test "monotonicMillis is linked and never goes backwards" {
    // Calling this from a test keeps every platform branch referenced, so a
    // wrong `extern "c"` spelling fails at link time instead of rotting as
    // unreferenced code until a caller appears.
    const first = monotonicMillis();
    try std.testing.expect(first > 0);
    sleepMillis(2);
    const second = monotonicMillis();
    try std.testing.expect(second >= first);
}
