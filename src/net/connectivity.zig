//! Internet connectivity probing.
//!
//! Checks whether an internet connection is available by attempting a TCP
//! connection to well-known, highly-available public endpoints.  The probe
//! deliberately targets port 53 (DNS/TCP) on Cloudflare (1.1.1.1) and Google
//! (8.8.8.8) because:
//!
//!   - These servers are among the most reliable hosts on the internet.
//!   - Port 53/TCP is open and reachable even from networks that block HTTP.
//!   - No TLS handshake or HTTP exchange is needed; a bare TCP connect suffices.
//!   - IPv4 and IPv6 are both probed (1.1.1.1 / 2606:4700:4700::1111).
//!
//! References:
//!   - RFC 7766 — DNS Transport over TCP
//!   - Cloudflare 1.1.1.1 public resolver: https://1.1.1.1
//!   - Google 8.8.8.8 public resolver: https://dns.google

const std = @import("std");
const addressMod = @import("address.zig");

/// Options controlling the connectivity probe.
pub const ConnectivityOptions = struct {
    /// Milliseconds to wait for each TCP connect attempt.
    /// Default is 3 000 ms — fast enough for interactive use, long enough for
    /// slow mobile links.
    timeoutMs: u32 = 3_000,

    /// Maximum number of probe targets to attempt before returning false.
    /// Stops as soon as one succeeds.  Setting 1 is fastest but less reliable.
    maxProbes: u8 = 4,
};

/// Result returned by `checkConnectivity`.
pub const ConnectivityResult = struct {
    /// True when at least one probe endpoint was reachable.
    online: bool,
    /// Address family that succeeded, or null when offline.
    family: ?addressMod.Family,
    /// Latency of the first successful probe in milliseconds.
    latencyMs: ?u32,
    /// The endpoint IP that succeeded, zero-terminated ASCII, or empty.
    endpoint: [46]u8 = (@as([46]u8, @splat(0))),
    endpointLen: u8 = 0,

    /// Slice of the successful endpoint string.
    pub fn endpointStr(self: *const ConnectivityResult) []const u8 {
        return self.endpoint[0..self.endpointLen];
    }
};

/// Well-known public probe endpoints (IP, port, family).
const Probe = struct {
    ip: []const u8,
    port: u16,
    family: addressMod.Family,
};

const probes: []const Probe = &.{
    .{ .ip = "1.1.1.1", .port = 53, .family = .ip4 }, // Cloudflare v4
    .{ .ip = "8.8.8.8", .port = 53, .family = .ip4 }, // Google v4
    .{ .ip = "2606:4700:4700::1111", .port = 53, .family = .ip6 }, // Cloudflare v6
    .{ .ip = "2001:4860:4860::8888", .port = 53, .family = .ip6 }, // Google v6
};

/// Parse a dotted-decimal IPv4 or a colon-hex IPv6 literal into an Address.
fn parseIpLiteral(ip: []const u8, port: u16, family: addressMod.Family) ?addressMod.Address {
    const scratch = addressMod.Address{ .family = family, .port = port };
    var addr = scratch.parseIp(ip) catch return null;
    if (addr.family != family) return null;
    addr.port = port;
    return addr;
}

const clock = @import("../common/clock.zig");

/// Probe a single endpoint. Returns the latency in ms on success, or null.
fn probeOne(io: std.Io, probe: Probe, timeoutMs: u32) ?u32 {
    const addr = parseIpLiteral(probe.ip, probe.port, probe.family) orelse return null;
    const t0 = clock.monotonicMillis(io);
    const builtin = @import("builtin");
    const timeout: std.Io.Timeout = if (builtin.os.tag == .windows)
        .none
    else
        .{
            .duration = .{
                .raw = .fromMilliseconds(timeoutMs),
                .clock = .awake,
            },
        };
    const stream = addr.toStd(null).connect(io, .{
        .mode = .stream,
        .timeout = timeout,
    }) catch return null;
    stream.close(io);
    const elapsed = clock.monotonicMillis(io) - t0;
    return @intCast(@max(0, elapsed));
}

test "connectivity probe literals reject malformed input" {
    try std.testing.expect(parseIpLiteral("999.1.1.1", 53, .ip4) == null);
    try std.testing.expect(parseIpLiteral("1.2.3", 53, .ip4) == null);
    try std.testing.expect(parseIpLiteral("1.2.3.4.5", 53, .ip4) == null);
    const v4 = parseIpLiteral("1.1.1.1", 53, .ip4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, v4.bytes[0..4]);
    const v6 = parseIpLiteral("2606:4700:4700::1111", 53, .ip6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 53), v6.port);
}

/// Check whether the internet is reachable.
///
/// Tries up to `opts.maxProbes` well-known public endpoints in order,
/// stopping as soon as one succeeds.  Returns a `ConnectivityResult` with
/// `.online = true` and latency information.
///
/// This function is allocation-free and safe to call from any context.
pub fn checkConnectivity(io: std.Io, opts: ConnectivityOptions) ConnectivityResult {
    const limit = @min(opts.maxProbes, @as(u8, @intCast(probes.len)));
    for (probes[0..limit]) |probe| {
        if (probeOne(io, probe, opts.timeoutMs)) |lat| {
            var result = ConnectivityResult{
                .online = true,
                .family = probe.family,
                .latencyMs = lat,
            };
            const epLen = @min(probe.ip.len, result.endpoint.len);
            @memcpy(result.endpoint[0..epLen], probe.ip[0..epLen]);
            result.endpointLen = @intCast(epLen);
            return result;
        }
    }
    return ConnectivityResult{ .online = false, .family = null, .latencyMs = null };
}

/// Convenience wrapper — returns true if any probe succeeded.
pub fn isOnline(io: std.Io) bool {
    return checkConnectivity(io, .{}).online;
}
