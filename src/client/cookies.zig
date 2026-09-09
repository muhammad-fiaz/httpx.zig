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
        var secure = false;
        var httpOnly = false;
        var sameSite: Cookie.SameSite = .lax;

        var iter = std.mem.splitScalar(u8, setCookie, ';');
        var first = true;
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            if (first) {
                first = false;
                if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                    name = std.mem.trim(u8, trimmed[0..eq], " \t");
                    value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(trimmed, "secure")) {
                secure = true;
            } else if (std.ascii.eqlIgnoreCase(trimmed, "httponly")) {
                httpOnly = true;
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "domain=")) {
                domain = std.mem.trim(u8, trimmed[7..], "\" ");
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "path=")) {
                path = std.mem.trim(u8, trimmed[5..], "\" ");
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "max-age=")) {
                const secs = std.fmt.parseInt(i64, trimmed[8..], 10) catch continue;
                expiresMs = clock.millisNow() + (secs * 1000);
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "expires=")) {
                // HTTP-date parsing handled via static_files.parseHttpDate.
                if (@import("../web/static_files/serve.zig").parseHttpDate(trimmed[8..])) |secs| {
                    expiresMs = secs * 1000;
                }
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=strict")) {
                sameSite = .strict;
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=none")) {
                sameSite = .none;
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=lax")) {
                sameSite = .lax;
            }
        }

        const n = name orelse return;
        const v = value orelse "";
        const d = domain orelse requestHost;
        const p = path orelse "/";

        self.mu.lock();
        defer self.mu.unlock();

        // Replace existing cookie with same name+domain+path.
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const c = &self.cookies.items[i];
            if (std.mem.eql(u8, c.name, n) and std.mem.eql(u8, c.domain, d) and std.mem.eql(u8, c.path, p)) {
                self.allocator.free(c.name);
                self.allocator.free(c.value);
                self.allocator.free(c.domain);
                self.allocator.free(c.path);
                _ = self.cookies.swapRemove(i);
                break;
            }
            i += 1;
        }

        // Enforce limit.
        if (self.cookies.items.len >= self.maxCookies) return;

        self.cookies.append(self.allocator, .{
            .name = self.allocator.dupe(u8, n) catch return,
            .value = self.allocator.dupe(u8, v) catch return,
            .domain = self.allocator.dupe(u8, d) catch return,
            .path = self.allocator.dupe(u8, p) catch return,
            .expiresMs = expiresMs,
            .secure = secure,
            .httpOnly = httpOnly,
            .sameSite = sameSite,
        }) catch return;
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
