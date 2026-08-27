//! Cookie jar: stores Set-Cookie values and injects Cookie headers.
//!
//! Thread-safe, bounded, with domain/path matching.

const std = @import("std");
const clock = @import("../common/clock.zig");
const Allocator = std.mem.Allocator;
const sync = @import("../common/sync.zig");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires_ms: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .lax,

    pub const SameSite = enum { strict, lax, none };
};

pub const Jar = struct {
    allocator: Allocator,
    cookies: std.ArrayList(CookieEntry),
    mu: sync.Spinlock = .{},
    max_cookies: usize = 4096,

    const CookieEntry = struct {
        name: []const u8,
        value: []const u8,
        domain: []const u8,
        path: []const u8,
        expires_ms: ?i64,
        secure: bool,
        http_only: bool,
        same_site: Cookie.SameSite,
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
    pub fn setFromHeader(self: *Jar, set_cookie: []const u8, request_host: []const u8) void {
        var name: ?[]const u8 = null;
        var value: ?[]const u8 = null;
        var domain: ?[]const u8 = null;
        var path: ?[]const u8 = "/";
        var expires_ms: ?i64 = null;
        var secure = false;
        var http_only = false;
        var same_site: Cookie.SameSite = .lax;

        var iter = std.mem.splitScalar(u8, set_cookie, ';');
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
                http_only = true;
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "domain=")) {
                domain = std.mem.trim(u8, trimmed[7..], "\" ");
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "path=")) {
                path = std.mem.trim(u8, trimmed[5..], "\" ");
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "max-age=")) {
                const secs = std.fmt.parseInt(i64, trimmed[8..], 10) catch continue;
                expires_ms = clock.millisNow() + (secs * 1000);
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "expires=")) {
                // HTTP-date parsing handled via static_files.parseHttpDate.
                if (@import("../web/static_files/serve.zig").parseHttpDate(trimmed[8..])) |secs| {
                    expires_ms = secs * 1000;
                }
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=strict")) {
                same_site = .strict;
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=none")) {
                same_site = .none;
            } else if (std.ascii.eqlIgnoreCase(trimmed, "samesite=lax")) {
                same_site = .lax;
            }
        }

        const n = name orelse return;
        const v = value orelse "";
        const d = domain orelse request_host;
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
        if (self.cookies.items.len >= self.max_cookies) return;

        self.cookies.append(self.allocator, .{
            .name = self.allocator.dupe(u8, n) catch return,
            .value = self.allocator.dupe(u8, v) catch return,
            .domain = self.allocator.dupe(u8, d) catch return,
            .path = self.allocator.dupe(u8, p) catch return,
            .expires_ms = expires_ms,
            .secure = secure,
            .http_only = http_only,
            .same_site = same_site,
        }) catch return;
    }

    /// Build a "Cookie: name=value; name2=value2" header for the given host/path.
    pub fn cookieHeader(self: *Jar, host: []const u8, path: []const u8, buf: []u8) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const now = clock.millisNow();
        var pos: usize = 0;
        var wrote = false;
        for (self.cookies.items) |c| {
            if (c.expires_ms) |exp| {
                if (now >= exp) continue;
            }
            if (!domainMatches(host, c.domain)) continue;
            if (!pathMatches(path, c.path)) continue;
            if (c.secure) continue; // skip Secure cookies for plain HTTP
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
            if (c.expires_ms) |exp| {
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

fn domainMatches(host: []const u8, domain_in: []const u8) bool {
    // RFC 6265 §5.1.2: a leading dot is ignored for matching purposes.
    const domain = if (domain_in.len > 0 and domain_in[0] == '.') domain_in[1..] else domain_in;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    return host.len > domain.len and
        std.ascii.endsWithIgnoreCase(host, domain) and
        host[host.len - domain.len - 1] == '.';
}

fn pathMatches(request_path: []const u8, cookie_path: []const u8) bool {
    if (std.mem.eql(u8, request_path, cookie_path)) return true;
    if (std.mem.startsWith(u8, request_path, cookie_path)) {
        if (cookie_path.len == 0 or cookie_path[cookie_path.len - 1] == '/') return true;
        if (request_path.len > cookie_path.len and request_path[cookie_path.len] == '/') return true;
    }
    return false;
}

test "cookie jar set and get" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("session=abc123; Path=/; HttpOnly; SameSite=Lax", "example.com");
    var buf: [1024]u8 = undefined;
    const h = jar.cookieHeader("example.com", "/api", &buf);
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("session=abc123", h.?);
}

test "cookie jar domain matching" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("a=1; Domain=.example.com; Path=/", "example.com");
    var buf: [1024]u8 = undefined;
    // Should match subdomain.
    const h1 = jar.cookieHeader("sub.example.com", "/", &buf);
    try std.testing.expect(h1 != null);
    // Should not match different domain.
    const h2 = jar.cookieHeader("evil.com", "/", &buf);
    try std.testing.expect(h2 == null);
}

test "cookie jar expiry" {
    var jar = Jar.init(std.testing.allocator);
    defer jar.deinit();
    jar.setFromHeader("t=1; Max-Age=0", "example.com");
    // Max-Age=0 means expires immediately (now - 0 = now).
    jar.purgeExpired();
    var buf: [1024]u8 = undefined;
    const h = jar.cookieHeader("example.com", "/", &buf);
    try std.testing.expect(h == null);
}
