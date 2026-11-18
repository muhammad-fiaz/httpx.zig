//! Internet reachability checks.
//!
//! A check performs a TCP connect to one or more configurable endpoints and
//! stops at the first success. A completed TCP handshake proves that the
//! endpoint's address and port are reachable from this host. It does **not**
//! prove that arbitrary internet services are usable: a firewall, captive
//! portal, proxy requirement, IPv4/IPv6 routing difference or an outage of the
//! chosen endpoint can all change the result.
//!
//! Default endpoints
//! -----------------
//! `defaultEndpoints` targets port 53 (DNS over TCP) on the public resolvers
//! run by Cloudflare and Google, first IPv4 then IPv6. Port 53/TCP needs no TLS
//! or HTTP exchange and is commonly reachable even where HTTP egress is
//! filtered. These are only defaults: pass textual endpoints to `checkHosts`
//! when you need a check against infrastructure you control. The defaults are
//! not contacted by tests or by merely building the library.
//!
//! Semantics
//! ---------
//!   - `timeoutMs` is the budget for **each** endpoint attempt, not for the
//!     whole call. The worst case is `timeoutMs * maxProbes` milliseconds.
//!   - `timeoutMs == 0` means "no time to connect": the check returns offline
//!     immediately without touching the network. It never means "wait
//!     forever". The schema accepts zero for this documented meaning.
//!   - `maxProbes == 0` or an empty endpoint list returns offline.
//!   - Attempts run sequentially, in caller order, and stop on first success.
//!   - `latencyMs` is TCP connection-establishment time only (no TLS, no HTTP).
//!   - The function is synchronous and blocks the calling thread for up to the
//!     documented worst case. It allocates nothing and keeps no global state,
//!     so concurrent calls are safe, but each call blocks its own thread.
//!
//! References:
//!   - RFC 7766 — DNS Transport over TCP
//!   - RFC 9110 Section 9.2.2 — Idempotent Methods (connect-only health checks)

const std = @import("std");
const addressMod = @import("address.zig");
const z = @import("zigantic");
const clock = @import("../common/clock.zig");
const tcp = @import("../sockets/tcp.zig");

/// Default per-endpoint connect timeout, in milliseconds.
pub const defaultTimeoutMs: u32 = 3_000;
/// Default maximum number of endpoints attempted per check.
pub const defaultMaxProbes: u8 = 4;

/// Upper bound accepted by the schema. Sixty seconds per endpoint is well past
/// any useful reachability check and keeps `timeoutMs * maxProbes` bounded.
const maxTimeoutMs: u32 = 60_000;
/// Upper bound accepted by the schema for `maxProbes`.
const maxProbeCount: u8 = 16;

/// Options controlling a connectivity check.
///
/// `timeoutMs` is the per-endpoint connect budget in milliseconds and
/// `maxProbes` is the number of endpoints to attempt. Both have documented
/// defaults above and are validated by the schema when options are decoded.
const ConnectivityOptionsSchema = z.objectOf(.{
    .timeoutMs = z.withDefault(z.integer(u32, .{ .max = maxTimeoutMs }), defaultTimeoutMs),
    .maxProbes = z.withDefault(z.integer(u8, .{ .max = maxProbeCount }), defaultMaxProbes),
}, .{});
pub const ConnectivityOptions = ConnectivityOptionsSchema.Value;

/// Result returned by `check` and `checkHosts`.
///
/// The value owns no heap memory and borrows nothing: `endpoint` is an inline
/// fixed buffer, so the result is safe to return by value and needs no deinit.
pub const ConnectivityResult = struct {
    /// True when at least one endpoint completed a TCP handshake.
    reachable: bool,
    /// Address family of the endpoint that succeeded, or null when offline.
    family: ?addressMod.Family,
    /// TCP handshake time of the successful endpoint in milliseconds, or null.
    latencyMs: ?u32,
    /// Text form of the successful endpoint IP (no port), zero-terminated
    /// ASCII, or empty when offline.
    endpoint: [46]u8 = (@as([46]u8, @splat(0))),
    /// Number of bytes used in `endpoint`.
    endpointLen: u8 = 0,

    /// True when at least one endpoint completed a TCP handshake.
    ///
    /// This is the only supported way to read the boolean outcome, so result
    /// handling reads like the client API: `if (result.isOnline())`.
    pub fn isOnline(self: *const ConnectivityResult) bool {
        return self.reachable;
    }

    /// Slice of the successful endpoint string.
    pub fn endpointStr(self: *const ConnectivityResult) []const u8 {
        return self.endpoint[0..self.endpointLen];
    }
};

fn ip4Endpoint(comptime octets: [4]u8, comptime port: u16) addressMod.Address {
    var bytes = @as([16]u8, @splat(0));
    bytes[0..4].* = octets;
    return .{ .family = .ip4, .bytes = bytes, .port = port };
}

fn ip6Endpoint(comptime octets: [16]u8, comptime port: u16) addressMod.Address {
    return .{ .family = .ip6, .bytes = octets, .port = port };
}

/// Public, documented default endpoints: Cloudflare and Google DNS over TCP,
/// IPv4 first so an IPv4-only host succeeds without an IPv6 timeout, then IPv6
/// so an IPv6-only host is covered. Replace them with `checkHosts`.
pub const defaultEndpoints = [_]addressMod.Address{
    ip4Endpoint(.{ 1, 1, 1, 1 }, 53), // Cloudflare 1.1.1.1
    ip4Endpoint(.{ 8, 8, 8, 8 }, 53), // Google 8.8.8.8
    ip6Endpoint(.{ 0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x11 }, 53), // 2606:4700:4700::1111
    ip6Endpoint(.{ 0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x88 }, 53), // 2001:4860:4860::8888
};

fn offlineResult() ConnectivityResult {
    return .{ .reachable = false, .family = null, .latencyMs = null };
}

/// One endpoint attempt. Returns null when the handshake fails for any reason.
fn attempt(io: std.Io, endpoint: addressMod.Address, timeoutMs: u32) ?ConnectivityResult {
    if (endpoint.port == 0) return null;
    const latency = tcp.connectAddressTimed(io, &endpoint, timeoutMs) catch return null;

    var result = ConnectivityResult{
        .reachable = true,
        .family = endpoint.family,
        .latencyMs = latency,
    };
    const text = endpoint.formatBuf(result.endpoint[0..]);
    const len = @min(text.len, result.endpoint.len);
    result.endpointLen = @intCast(len);
    return result;
}

/// Internal address-list checker.
///
/// Kept private so the public surface stays small: applications use `check`
/// (documented defaults) or `checkHosts` (textual IP endpoints). Endpoints are
/// tried in order, up to `opts.maxProbes`, and the first completed TCP
/// handshake wins. Each attempt receives `opts.timeoutMs`; see the module docs
/// for the full timeout contract. `endpoints` is borrowed and never modified.
fn checkAddresses(io: std.Io, endpoints: []const addressMod.Address, opts: ConnectivityOptions) ConnectivityResult {
    // Zero budget means "no time to connect"; do not touch the network.
    if (opts.timeoutMs == 0 or opts.maxProbes == 0 or endpoints.len == 0) return offlineResult();

    const limit = @min(@as(usize, opts.maxProbes), endpoints.len);
    for (endpoints[0..limit]) |endpoint| {
        if (attempt(io, endpoint, opts.timeoutMs)) |result| return result;
    }
    return offlineResult();
}

/// Check reachability of textual IP endpoints such as `"1.1.1.1:53"` or
/// `"[2606:4700:4700::1111]:53"`.
///
/// This is the high-level form for application code: entries are IP literals
/// with an explicit port, so callers do not need to know the internal
/// `address.Address` layout. Malformed entries, hostnames (no DNS is performed
/// here), and entries without a port are skipped rather than rewritten, so a
/// later valid entry can still succeed. The first `opts.maxProbes` entries are
/// considered; use `check` for the documented public defaults.
pub fn checkHosts(io: std.Io, hosts: []const []const u8, opts: ConnectivityOptions) ConnectivityResult {
    if (opts.timeoutMs == 0 or opts.maxProbes == 0 or hosts.len == 0) return offlineResult();

    const limit = @min(@as(usize, opts.maxProbes), hosts.len);
    for (hosts[0..limit]) |host| {
        const parsed = addressMod.Address.parse(host, 0) catch continue;
        if (parsed.port == 0) continue;
        var endpoint = addressMod.Address.parseIp(parsed.addr) catch continue;
        endpoint.port = parsed.port;
        if (attempt(io, endpoint, opts.timeoutMs)) |result| return result;
    }
    return offlineResult();
}

/// Check whether the internet is reachable by TCP using the documented
/// `defaultEndpoints`.
///
/// Tries up to `opts.maxProbes` default endpoints in order and stops at the
/// first success. Use `checkHosts` to check infrastructure you control
/// instead of the public defaults, and `client.checkConnectivity` /
/// `client.checkHosts` to reuse a client's I/O backend.
///
/// This function performs blocking network I/O. It does not allocate heap
/// memory, but it is not safe to call from a signal handler. See the module
/// docs for timeout and error semantics.
pub fn check(io: std.Io, opts: ConnectivityOptions) ConnectivityResult {
    return checkAddresses(io, &defaultEndpoints, opts);
}

/// Convenience wrapper: true when any default endpoint completed a TCP
/// handshake (equivalent to `check(io, .{}).isOnline()`).
pub fn isOnline(io: std.Io) bool {
    return check(io, .{}).isOnline();
}

// Tests
//
// Every test below uses loopback or documentation-only addresses. None of
// them contacts Cloudflare, Google, or any other external service.

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Binds an ephemeral loopback port, records it, then closes the listener so a
/// connect to it is deterministically refused.
fn closedLoopback(io: std.Io, family: addressMod.Family) !addressMod.Address {
    const bindAddr = switch (family) {
        .ip4 => addressMod.Address.loopback4(0),
        .ip6 => addressMod.Address.loopback6(0),
    };
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = bindAddr });
    const result = switch (family) {
        .ip4 => addressMod.Address.loopback4(listener.localPort()),
        .ip6 => addressMod.Address.loopback6(listener.localPort()),
    };
    listener.close(io);
    return result;
}

test "options expose the documented defaults" {
    const opts = ConnectivityOptions{};
    try std.testing.expectEqual(defaultTimeoutMs, opts.timeoutMs);
    try std.testing.expectEqual(defaultMaxProbes, opts.maxProbes);
    try std.testing.expect(defaultTimeoutMs >= 1 and defaultTimeoutMs <= maxTimeoutMs);
    try std.testing.expect(defaultMaxProbes >= 1 and defaultMaxProbes <= maxProbeCount);
}

test "zero timeout means offline without network I/O" {
    const io = testIo();
    const started = clock.monotonicMillis(io);
    const result = check(io, .{ .timeoutMs = 0 });
    const elapsed = clock.monotonicMillis(io) - started;

    try std.testing.expect(!result.isOnline());
    try std.testing.expect(result.family == null);
    try std.testing.expect(result.latencyMs == null);
    try std.testing.expectEqualStrings("", result.endpointStr());
    try std.testing.expect(elapsed < 1_000);
}

test "zero maxProbes and empty endpoint lists return offline" {
    const io = testIo();
    try std.testing.expect(!check(io, .{ .maxProbes = 0 }).isOnline());
    try std.testing.expect(!checkAddresses(io, &.{}, .{}).isOnline());
}

test "loopback listener is reported reachable" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    const endpoint = addressMod.Address.loopback4(@intCast(listener.localPort()));
    const result = checkAddresses(io, &.{endpoint}, .{ .timeoutMs = 2_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqual(addressMod.Family.ip4, result.family.?);
    try std.testing.expect(result.latencyMs != null);
    try std.testing.expectEqualStrings("127.0.0.1", result.endpointStr());
}

test "closed loopback port is reported offline" {
    const io = testIo();
    const started = clock.monotonicMillis(io);

    const endpoint = try closedLoopback(io, .ip4);
    const result = checkAddresses(io, &.{endpoint}, .{ .timeoutMs = 1_000 });

    try std.testing.expect(!result.isOnline());
    try std.testing.expect(result.family == null);
    try std.testing.expect(result.latencyMs == null);
    try std.testing.expect(clock.monotonicMillis(io) - started < 5_000);
}

test "documentation address attempt respects the budget and report shape" {
    const io = testIo();
    // RFC 5737 TEST-NET-1. Never routed on the public internet; some networks
    // (captive portals, transparent proxies) still accept the handshake, so
    // only budget and result consistency are asserted, not reachability.
    const endpoint = addressMod.Address{ .family = .ip4, .bytes = blk: {
        var bytes = @as([16]u8, @splat(0));
        bytes[0..4].* = .{ 192, 0, 2, 1 };
        break :blk bytes;
    }, .port = 81 };

    const started = clock.monotonicMillis(io);
    const result = checkAddresses(io, &.{endpoint}, .{ .timeoutMs = 100 });
    const elapsed = clock.monotonicMillis(io) - started;

    try std.testing.expect(elapsed < 3_000);
    if (result.isOnline()) {
        try std.testing.expectEqual(addressMod.Family.ip4, result.family.?);
        try std.testing.expect(result.latencyMs != null);
        try std.testing.expectEqual(@as(usize, "192.0.2.1".len), result.endpointStr().len);
    } else {
        try std.testing.expect(result.family == null);
        try std.testing.expect(result.latencyMs == null);
        try std.testing.expectEqualStrings("", result.endpointStr());
    }
}

test "endpoint order is preserved and later endpoints are tried" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    const reachable = addressMod.Address.loopback4(@intCast(listener.localPort()));
    const refused = try closedLoopback(io, .ip4);
    const result = checkAddresses(io, &.{ refused, reachable }, .{ .timeoutMs = 1_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqualStrings("127.0.0.1", result.endpointStr());
}

test "maxProbes limits how many endpoints are attempted" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    const reachable = addressMod.Address.loopback4(@intCast(listener.localPort()));
    // One attempt only, and it is the refused port, so the reachable second
    // endpoint must not be tried.
    const refused = try closedLoopback(io, .ip4);
    const result = checkAddresses(io, &.{ refused, reachable }, .{ .timeoutMs = 500, .maxProbes = 1 });

    try std.testing.expect(!result.isOnline());
}

test "zero-port endpoints are skipped without a syscall" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    const reachable = addressMod.Address.loopback4(@intCast(listener.localPort()));
    const result = checkAddresses(io, &.{ addressMod.Address.loopback4(0), reachable }, .{ .timeoutMs = 500 });

    try std.testing.expect(result.isOnline());
}

test "checkHosts accepts textual IP endpoints" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    var buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{listener.localPort()});
    const result = checkHosts(io, &.{host}, .{ .timeoutMs = 2_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqual(addressMod.Family.ip4, result.family.?);
    try std.testing.expectEqualStrings("127.0.0.1", result.endpointStr());
}

test "checkHosts skips malformed and hostname entries" {
    const io = testIo();
    var listener = try tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback4(0) });
    defer listener.close(io);

    var buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{listener.localPort()});
    // Malformed text, a missing port, and a hostname (no DNS is performed)
    // must all be skipped instead of consuming the check.
    const result = checkHosts(io, &.{ "not-an-ip:443", "127.0.0.1", "localhost:80", host }, .{ .timeoutMs = 2_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqualStrings("127.0.0.1", result.endpointStr());
}

test "checkHosts honors zero timeout without network I/O" {
    const io = testIo();
    const started = clock.monotonicMillis(io);
    const result = checkHosts(io, &.{"1.1.1.1:53"}, .{ .timeoutMs = 0 });

    try std.testing.expect(!result.isOnline());
    try std.testing.expect(clock.monotonicMillis(io) - started < 1_000);
}

test "checkHosts accepts bracketed IPv6 endpoints when available" {
    const io = testIo();
    var listener = tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback6(0) }) catch return;
    defer listener.close(io);

    var buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&buf, "[::1]:{d}", .{listener.localPort()});
    const result = checkHosts(io, &.{host}, .{ .timeoutMs = 2_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqual(addressMod.Family.ip6, result.family.?);
    try std.testing.expectEqualStrings("::1", result.endpointStr());
}

test "ipv6 loopback is reported reachable when available" {
    const io = testIo();
    var listener = tcp.Listener.init(std.testing.allocator, io, .{ .address = addressMod.Address.loopback6(0) }) catch return;
    defer listener.close(io);

    const endpoint = addressMod.Address.loopback6(@intCast(listener.localPort()));
    const result = checkAddresses(io, &.{endpoint}, .{ .timeoutMs = 2_000 });

    try std.testing.expect(result.isOnline());
    try std.testing.expectEqual(addressMod.Family.ip6, result.family.?);
    try std.testing.expectEqualStrings("::1", result.endpointStr());
}

test "connectAddressTimed rejects a zero timeout" {
    const io = testIo();
    const addr = addressMod.Address.loopback4(1);
    try std.testing.expectError(error.TimedOut, tcp.connectAddressTimed(io, &addr, 0));
}
