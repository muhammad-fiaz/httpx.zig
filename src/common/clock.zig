//! Wall-clock milliseconds since Unix epoch (std.time lost its clock fns).

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
            const epoch_diff: u64 = 116_444_736_000_000_000;
            const ns100 = ft -| epoch_diff;
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
            const c = struct {
                extern "c" fn mach_absolute_time() u64;
                extern "c" fn mach_timebase_info(info: *TimebaseInfo) c_int;
                const TimebaseInfo = extern struct { numer: u32, denom: u32 };
            };
            var info: c.TimebaseInfo = .{ .numer = 0, .denom = 0 };
            _ = c.mach_timebase_info(&info);
            const t = c.mach_absolute_time();
            if (info.denom == 0) return wallMillis();
            const nanos = t *% @as(u64, info.numer) / @as(u64, info.denom);
            return @intCast(nanos / 1_000_000);
        },
        else => return wallMillis(),
    }
}

test "millisNow plausible" {
    const now = millisNow();
    // Sometime after 2024-01-01 and before year 2100.
    try std.testing.expect(now > 1_704_067_200_000);
    try std.testing.expect(now < 4_102_444_800_000);
}
