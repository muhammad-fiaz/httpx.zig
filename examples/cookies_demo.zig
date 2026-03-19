//! Cookie Jar Demo
//!
//! Demonstrates storing, reading, and attaching cookies with the httpx client.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Cookie Jar Demo ===\n\n", .{});

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    try client.setCookie("session", "abc123");
    try client.setCookie("theme", "dark");

    std.debug.print("Cookie session: {s}\n", .{client.getCookie("session") orelse "<missing>"});
    std.debug.print("Cookie theme: {s}\n", .{client.getCookie("theme") orelse "<missing>"});

    const removed = client.removeCookie("theme");
    std.debug.print("Removed theme cookie: {}\n", .{removed});

    // Build and serialize a request to demonstrate attached cookies.
    var req = try httpx.Request.init(allocator, .GET, "https://example.com/account");
    defer req.deinit();

    if (client.getCookie("session")) |session| {
        var cookie_buf = std.ArrayListUnmanaged(u8){};
        defer cookie_buf.deinit(allocator);
        const writer = cookie_buf.writer(allocator);
        try writer.print("session={s}", .{session});
        try req.headers.set(httpx.HeaderName.COOKIE, cookie_buf.items);
    }

    const wire = try httpx.formatRequest(&req, allocator);
    defer allocator.free(wire);

    std.debug.print("\nSerialized request with Cookie header:\n{s}\n", .{wire});

    client.clearCookies();
    std.debug.print(
        "Cookies cleared (session present? {}):\n",
        .{client.getCookie("session") != null},
    );
}
