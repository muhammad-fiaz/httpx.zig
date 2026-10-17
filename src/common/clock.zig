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
        else => return std.time.milliTimestamp(),
    }
}

/// Monotonic milliseconds for timeouts (never goes backwards).
pub fn monotonicMillis() i64 {
    switch (builtin.os.tag) {
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *u64) callconv(.winapi) c_int;
                extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *u64) callconv(.winapi) c_int;
            };
            var c: u64 = 0;
            var f: u64 = 0;
            _ = kernel32.QueryPerformanceCounter(&c);
            _ = kernel32.QueryPerformanceFrequency(&f);
            if (f == 0) return wallMillis();
            return @intCast((c * 1000) / f);
        },
        .linux => {
            const linux = std.os.linux;
            var t: linux.timespec = .{ .sec = 0, .nsec = 0 };
            _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &t);
            return @as(i64, @intCast(t.sec)) * 1000 + @divFloor(@as(i64, @intCast(t.nsec)), 1_000_000);
        },
        .macos, .ios, .tvos, .watchos => {
            // Zig mangles `extern "c"` names literally, so the mach entry points
            // must be declared with their C spelling. Hand-rolled declarations
            // such as `machAbsoluteTime` link to `_machAbsoluteTime`, which does
            // not exist; these bindings resolve to the real symbols.
            var info: std.c.mach_timebase_info_data = undefined;
            if (std.c.mach_timebase_info(&info) != 0) return wallMillis();
            if (info.denom == 0) return wallMillis();
            const t = std.c.mach_absolute_time();
            const nanos = t *% @as(u64, info.numer) / @as(u64, info.denom);
            return @intCast(nanos / 1_000_000);
        },
        else => return wallMillis(),
    }
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
