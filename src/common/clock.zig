//! Wall-clock milliseconds since Unix epoch (std.time lost its clock fns).

const std = @import("std");
const builtin = @import("builtin");

/// Milliseconds since Unix epoch. Monotonic-enough for timeouts/expiry.
pub fn millisNow() i64 {
    switch (builtin.os.tag) {
        .windows => {
            // FILETIME: 100ns intervals since 1601-01-01 UTC.
            const kernel32 = struct {
                extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *u64) callconv(.winapi) void;
            };
            var ft: u64 = undefined;
            kernel32.GetSystemTimeAsFileTime(&ft);
            const epoch_diff: u64 = 116_444_736_000_000_000; // 1601 -> 1970 in 100ns
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
            const Timeval = extern struct {
                sec: isize,
                usec: isize,
            };
            const c = struct {
                extern "c" fn gettimeofday(tv: ?*Timeval, tz: ?*anyopaque) c_int;
            };
            var tv: Timeval = .{ .sec = 0, .usec = 0 };
            _ = c.gettimeofday(&tv, null);
            return @as(i64, @intCast(tv.sec)) * 1000 + @divFloor(@as(i64, @intCast(tv.usec)), 1000);
        },
        else => return 0,
    }
}

test "millisNow plausible" {
    const now = millisNow();
    // Sometime after 2024-01-01 and before year 2100.
    try std.testing.expect(now > 1_704_067_200_000);
    try std.testing.expect(now < 4_102_444_800_000);
}
