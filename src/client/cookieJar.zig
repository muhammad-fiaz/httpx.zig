//! Cookie jar: stores Set-Cookie values and injects Cookie headers.
//!
//! Thread-safe, bounded, with domain/path matching. Implements the core
//! cookie storage and retrieval semantics from RFC 6265 Section 4, including
//! domain matching (Section 5.1.3), path matching (Section 5.1.4), cookie
//! expiry via Max-Age and Expires directives, and Secure/HttpOnly flags.
//!
//! References:
//!   - RFC 6265 — HTTP State Management (Cookie mechanism)
//!   - RFC 6265 Section 4.1.1 — Set-Cookie Syntax
//!   - RFC 6265 Section 4.2.1 — Cookie Header Syntax
//!   - RFC 6265 Section 5.1.3 — Domain Matching
//!   - RFC 6265 Section 5.1.4 — Path Matching
//!   - RFC 6265 Section 5.2.6 — SameSite Attribute
//!   - RFC 7230 Section 4.1.1 — Connection: close

const std = @import("std");
const clock = @import("../common/clock.zig");
const Allocator = std.mem.Allocator;
const sync = @import("../common/sync.zig");
const parseMod = @import("../common/parse.zig");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expiresMs: ?i64 = null,
    secure: bool = false,
    httpOnly: bool = false,
    sameSite: SameSite = .lax,

    pub const SameSite = enum { strict, lax, none };
};

pub const Jar = struct {
    allocator: Allocator,
    cookies: std.ArrayList(CookieEntry),
    mu: sync.Spinlock = .{},
    maxCookies: usize = 4096,

    const CookieEntry = struct {
        name: []const u8,
        value: []const u8,
        domain: []const u8,
        path: []const u8,
        expiresMs: ?i64,
        secure: bool,
        httpOnly: bool,
        sameSite: Cookie.SameSite,
    };

    pub fn init(allocator: Allocator) Jar {
        return .{
            .allocator = allocator,
            .cookies = .empty,
        };
    }

    pub fn deinit(self: *Jar) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.cookies.items) |*c| {
            self.allocator.free(c.name);
            self.allocator.free(c.value);
            self.allocator.free(c.domain);
            self.allocator.free(c.path);
        }
        self.cookies.deinit(self.allocator);
    }

    /// Parse a Set-Cookie header and store the cookie.
    pub fn setFromHeader(self: *Jar, setCookie: []const u8, requestHost: []const u8) void {
        var name: ?[]const u8 = null;
        var value: ?[]const u8 = null;
        var domain: ?[]const u8 = null;
        var path: ?[]const u8 = "/";
        var expiresMs: ?i64 = null;
        var maxAgeExpiresMs: ?i64 = null;
        var secure = false;
        var httpOnly = false;
        var sameSite: Cookie.SameSite = .lax;
        const now = clock.millisNow();

        var it = parseMod.ParamIterator.init(setCookie);
        var first = true;
        while (it.next()) |param| {
            if (first) {
                first = false;
                name = param.key;
                value = param.value;
                continue;
            }
            if (parseMod.eqlIgnoreCase(param.key, "secure")) {
                secure = true;
            } else if (parseMod.eqlIgnoreCase(param.key, "httponly")) {
                httpOnly = true;
            } else if (parseMod.eqlIgnoreCase(param.key, "domain")) {
                domain = param.value;
            } else if (parseMod.eqlIgnoreCase(param.key, "path")) {
                path = param.value;
            } else if (parseMod.eqlIgnoreCase(param.key, "max-age")) {
                maxAgeExpiresMs = parseMaxAgeExpiry(param.value, now) orelse continue;
            } else if (parseMod.eqlIgnoreCase(param.key, "expires")) {
                if (parseMod.parseHttpDate(param.value)) |secs| {
                    expiresMs = secondsToMillisSaturated(secs);
                }
            } else if (parseMod.eqlIgnoreCase(param.key, "samesite")) {
                if (parseMod.eqlIgnoreCase(param.value, "strict")) {
                    sameSite = .strict;
                } else if (parseMod.eqlIgnoreCase(param.value, "none")) {
                    sameSite = .none;
                } else if (parseMod.eqlIgnoreCase(param.value, "lax")) {
                    sameSite = .lax;
                }
            }
        }

        const n = name orelse return;
        const v = value orelse "";
        const d = domain orelse requestHost;
        const p = path orelse "/";
        if (n.len == 0) return;
        for (n) |c| if (!parseMod.isTokenChar(c)) return;
        for (v) |c| if (c < 0x20 or c == 0x7f) return;
        if (maxAgeExpiresMs) |expiry| expiresMs = expiry;

        if (expiresMs) |expiry| {
            if (now >= expiry) {
                self.mu.lock();
                defer self.mu.unlock();
                var i: usize = 0;
                while (i < self.cookies.items.len) {
                    const c = &self.cookies.items[i];
                    if (std.mem.eql(u8, c.name, n) and std.mem.eql(u8, c.domain, d) and std.mem.eql(u8, c.path, p)) {
                        self.freeCookieFields(c.name, c.value, c.domain, c.path);
                        _ = self.cookies.swapRemove(i);
                        break;
                    }
                    i += 1;
                }
                return;
            }
        }

        // Allocate the replacement before taking the lock or removing the
        // previous cookie. A partial allocation failure leaves jar state intact.
        const ownedName = self.allocator.dupe(u8, n) catch return;
        const ownedValue = self.allocator.dupe(u8, v) catch {
            self.allocator.free(ownedName);
            return;
        };
        const ownedDomain = self.allocator.dupe(u8, d) catch {
            self.allocator.free(ownedName);
            self.allocator.free(ownedValue);
            return;
        };
        const ownedPath = self.allocator.dupe(u8, p) catch {
            self.allocator.free(ownedName);
            self.allocator.free(ownedValue);
            self.allocator.free(ownedDomain);
            return;
        };

        self.mu.lock();
        defer self.mu.unlock();

        const newCookie = CookieEntry{
            .name = ownedName,
            .value = ownedValue,
            .domain = ownedDomain,
            .path = ownedPath,
            .expiresMs = expiresMs,
            .secure = secure,
            .httpOnly = httpOnly,
            .sameSite = sameSite,
        };

        // Replace in place so an allocation failure cannot remove the old
        // cookie after the replacement has already been prepared.
        for (self.cookies.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.name, n) and std.mem.eql(u8, c.domain, d) and std.mem.eql(u8, c.path, p)) {
                self.freeCookieFields(c.name, c.value, c.domain, c.path);
                self.cookies.items[i] = newCookie;
                return;
            }
        }

        // Enforce limit.
        if (self.cookies.items.len >= self.maxCookies) {
            self.freeCookieFields(ownedName, ownedValue, ownedDomain, ownedPath);
            return;
        }

        self.cookies.append(self.allocator, newCookie) catch self.freeCookieFields(ownedName, ownedValue, ownedDomain, ownedPath);
    }

    fn freeCookieFields(self: *Jar, name: []const u8, value: []const u8, domain: []const u8, path: []const u8) void {
        self.allocator.free(name);
        self.allocator.free(value);
        self.allocator.free(domain);
        self.allocator.free(path);
    }

    /// Build a "Cookie: name=value; name2=value2" header for the given host/path.
    /// `secure` must be true when the connection uses TLS: Secure cookies
    /// are only emitted over encrypted transports (RFC 6265 Section 4.1).
    pub fn cookieHeader(self: *Jar, host: []const u8, path: []const u8, secure: bool, buf: []u8) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const now = clock.millisNow();
        var pos: usize = 0;
        var wrote = false;
        for (self.cookies.items) |c| {
            if (c.expiresMs) |exp| {
                if (now >= exp) continue;
            }
            if (!domainMatches(host, c.domain)) continue;
            if (!pathMatches(path, c.path)) continue;
            if (c.secure and !secure) continue; // Secure cookies need TLS
            const sep = if (wrote) "; " else "";
            const entry = std.fmt.bufPrint(buf[pos..], "{s}{s}={s}", .{ sep, c.name, c.value }) catch break;
            pos += entry.len;
            wrote = true;
        }
        if (!wrote) return null;
        return buf[0..pos];
    }

    /// Remove all expired cookies.
    pub fn purgeExpired(self: *Jar) void {
        self.mu.lock();
        defer self.mu.unlock();
        const now = clock.millisNow();
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const c = &self.cookies.items[i];
            if (c.expiresMs) |exp| {
                if (now >= exp) {
                    self.allocator.free(c.name);
                    self.allocator.free(c.value);
                    self.allocator.free(c.domain);
                    self.allocator.free(c.path);
                    _ = self.cookies.swapRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }
};

fn parseMaxAgeExpiry(value: []const u8, nowMs: i64) ?i64 {
    if (value.len == 0) return null;
    if (value[0] == '-') {
        const magnitude = parseMod.parseUint(u64, value[1..]) orelse return null;
        _ = magnitude;
        return nowMs;
    }
    const seconds = parseMod.parseUint(u64, value) orelse return null;
    if (seconds == 0) return nowMs;
    const now: u64 = @intCast(@max(nowMs, 0));
    const delta = std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    return @intCast(@min(now +| delta, std.math.maxInt(i64)));
}

fn secondsToMillisSaturated(seconds: i64) i64 {
    return std.math.mul(i64, seconds, 1000) catch if (seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn domainMatches(host: []const u8, domainIn: []const u8) bool {
    // RFC 6265 Section 5.1.2: a leading dot is ignored for matching purposes.
    const domain = if (domainIn.len > 0 and domainIn[0] == '.') domainIn[1..] else domainIn;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    return host.len > domain.len and
        std.ascii.endsWithIgnoreCase(host, domain) and
        host[host.len - domain.len - 1] == '.';
}

fn pathMatches(requestPath: []const u8, cookiePath: []const u8) bool {
    if (std.mem.eql(u8, requestPath, cookiePath)) return true;
    if (std.mem.startsWith(u8, requestPath, cookiePath)) {
        if (cookiePath.len == 0 or cookiePath[cookiePath.len - 1] == '/') return true;
        if (requestPath.len > cookiePath.len and requestPath[cookiePath.len] == '/') return true;
    }
    return false;
}

test "cookie jar set and get" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("session=abc123; Path=/; HttpOnly; SameSite=Lax", "example.com");
    var buf: [1024]u8 = undefined;
    const h = jar.cookieHeader("example.com", "/api", false, &buf);
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("session=abc123", h.?);
}

test "cookie jar domain matching" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("a=1; Domain=.example.com; Path=/", "example.com");
    var buf: [1024]u8 = undefined;
    // Should match subdomain.
    const h1 = jar.cookieHeader("sub.example.com", "/", false, &buf);
    try std.testing.expect(h1 != null);
    // Should not match different domain.
    const h2 = jar.cookieHeader("evil.com", "/", false, &buf);
    try std.testing.expect(h2 == null);
}

test "cookie jar expiry" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("t=1; Max-Age=0", "example.com");
    // Max-Age=0 means expires immediately (now - 0 = now).
    jar.purgeExpired();
    var buf: [1024]u8 = undefined;
    const h = jar.cookieHeader("example.com", "/", false, &buf);
    try std.testing.expect(h == null);
}

test "cookie max-age overrides expires and accepts negative deletion values" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("session=old", "example.com");
    jar.setFromHeader("session=present; Expires=Sun, 01 Jan 2147483647 00:00:00 GMT; Max-Age=-1", "example.com");
    var buf: [128]u8 = undefined;
    try std.testing.expect(jar.cookieHeader("example.com", "/", false, &buf) == null);
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);

    jar.setFromHeader("session=present; Max-Age=9223372036854775807", "example.com");
    const header = jar.cookieHeader("example.com", "/", false, &buf);
    try std.testing.expect(header != null);
    try std.testing.expectEqualStrings("session=present", header.?);
}

test "cookie allocation failure preserves an existing replacement" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("session=old", "example.com");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    jar.allocator = failing.allocator();
    jar.setFromHeader("session=new", "example.com");
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expectEqualStrings("old", jar.cookies.items[0].value);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

test "secure cookies require TLS transport" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("s=topsecret; Path=/; Secure", "example.com");
    var buf: [1024]u8 = undefined;
    // Plain HTTP must not emit Secure cookies (RFC 6265 Section 4.1).
    try std.testing.expect(jar.cookieHeader("example.com", "/", false, &buf) == null);
    // TLS transport emits them.
    const h = jar.cookieHeader("example.com", "/", true, &buf);
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("s=topsecret", h.?);
}
