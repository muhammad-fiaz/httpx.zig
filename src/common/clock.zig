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

const io = std.Io.Threaded.global_single_threaded.io();

/// Milliseconds since Unix epoch.
pub fn millisNow() i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

/// Monotonic milliseconds from Zig 0.17's target-specific `std.Io` clock.
/// The standard-library backend selects the appropriate OS clock, including
/// Windows performance counters and POSIX monotonic clocks.
pub fn monotonicMillis() i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

/// Sleeps for the specified number of milliseconds.
///
/// The global single-threaded `Io` implementation does not support
/// cancellation, so the only possible error is unreachable here.
pub fn sleepMillis(ms: u64) void {
    const duration = std.Io.Duration.fromMilliseconds(std.math.cast(i64, ms) orelse return);
    std.Io.sleep(io, duration, .awake) catch {};
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
