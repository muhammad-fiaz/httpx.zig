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
const builtin = @import("builtin");
const tcp = @import("../sockets/tcp.zig");
const address_mod = @import("address.zig");

/// Options controlling the connectivity probe.
pub const ConnectivityOptions = struct {
    /// Milliseconds to wait for each TCP connect attempt.
    /// Default is 3 000 ms — fast enough for interactive use, long enough for
    /// slow mobile links.
    timeout_ms: u32 = 3_000,

    /// Maximum number of probe targets to attempt before returning false.
    /// Stops as soon as one succeeds.  Setting 1 is fastest but less reliable.
    max_probes: u8 = 4,
};

/// Result returned by `checkConnectivity`.
pub const ConnectivityResult = struct {
    /// True when at least one probe endpoint was reachable.
    online: bool,
    /// Address family that succeeded, or null when offline.
    family: ?address_mod.Family,
    /// Latency of the first successful probe in milliseconds.
    latency_ms: ?u32,
    /// The endpoint IP that succeeded, zero-terminated ASCII, or empty.
    endpoint: [46]u8 = [_]u8{0} ** 46,
    endpoint_len: u8 = 0,

    /// Slice of the successful endpoint string.
    pub fn endpointStr(self: *const ConnectivityResult) []const u8 {
        return self.endpoint[0..self.endpoint_len];
    }
};

/// Well-known public probe endpoints (IP, port, family).
const Probe = struct {
    ip: []const u8,
    port: u16,
    family: address_mod.Family,
};

const probes: []const Probe = &.{
    .{ .ip = "1.1.1.1", .port = 53, .family = .ip4 }, // Cloudflare v4
    .{ .ip = "8.8.8.8", .port = 53, .family = .ip4 }, // Google v4
    .{ .ip = "2606:4700:4700::1111", .port = 53, .family = .ip6 }, // Cloudflare v6
    .{ .ip = "2001:4860:4860::8888", .port = 53, .family = .ip6 }, // Google v6
};

/// Parse a dotted-decimal IPv4 or a colon-hex IPv6 literal into an Address.
fn parseIpLiteral(ip: []const u8, port: u16, family: address_mod.Family) ?address_mod.Address {
    var addr = address_mod.Address{ .family = family, .port = port };
    switch (family) {
        .ip4 => {
            var octets: [4]u8 = undefined;
            var i: usize = 0;
            var idx: u8 = 0;
            while (i < ip.len and idx < 4) {
                var n: u8 = 0;
                while (i < ip.len and ip[i] != '.') : (i += 1) {
                    if (ip[i] < '0' or ip[i] > '9') return null;
                    n = n *% 10 +% (ip[i] - '0');
                }
                octets[idx] = n;
                idx += 1;
                if (i < ip.len and ip[i] == '.') i += 1;
            }
            if (idx != 4) return null;
            addr.bytes[0..4].* = octets;
        },
        .ip6 => {
            // Use std.Io.net.Ip6Address parsing (Zig 0.16 API).
            const parsed = std.Io.net.Ip6Address.parse(ip, port) catch return null;
            addr.bytes = parsed.bytes;
        },
    }
    return addr;
}

const clock = @import("../common/clock.zig");

/// Probe a single endpoint. Returns the latency in ms on success, or null.
fn probeOne(io: std.Io, probe: Probe, timeout_ms: u32) ?u32 {
    _ = timeout_ms; // We rely on the OS default connect timeout for now.
    const addr = parseIpLiteral(probe.ip, probe.port, probe.family) orelse return null;
    const t0 = clock.millisNow();
    const sock = tcp.connectAddress(io, &addr) catch return null;
    sock.close();
    const elapsed = clock.millisNow() - t0;
    return @intCast(@max(0, elapsed));
}

/// Check whether the internet is reachable.
///
/// Tries up to `opts.max_probes` well-known public endpoints in order,
/// stopping as soon as one succeeds.  Returns a `ConnectivityResult` with
/// `.online = true` and latency information.
///
/// This function is allocation-free and safe to call from any context.
pub fn checkConnectivity(io: std.Io, opts: ConnectivityOptions) ConnectivityResult {
    const limit = @min(opts.max_probes, @as(u8, @intCast(probes.len)));
    for (probes[0..limit]) |probe| {
        if (probeOne(io, probe, opts.timeout_ms)) |lat| {
            var result = ConnectivityResult{
                .online = true,
                .family = probe.family,
                .latency_ms = lat,
            };
            const ep_len = @min(probe.ip.len, result.endpoint.len);
            @memcpy(result.endpoint[0..ep_len], probe.ip[0..ep_len]);
            result.endpoint_len = @intCast(ep_len);
            return result;
        }
    }
    return ConnectivityResult{ .online = false, .family = null, .latency_ms = null };
}

/// Convenience wrapper — returns true if any probe succeeded.
pub fn isOnline(io: std.Io) bool {
    return checkConnectivity(io, .{}).online;
}
