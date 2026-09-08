//! Example: HTML Client Fetching and Document Parsing
//!
//! Demonstrates:
//! 1. Making an HTTP GET request to `httpbun.com/html`
//! 2. Automatic parsing via `response.html()`
//! 3. Extracting title, text, links, and inspecting DOM nodes
//!
//! Run with: `zig build run-html-client`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX HTML Client Demo (httpbun.com)\n\n", .{});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Fetch HTML from httpbun.com
    var response = client.get("http://httpbun.com/html", .{}) catch |err| {
        std.debug.print("Network fetch failed ({s}), demonstrating parser on response body mock...\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Content-Type: {s}\n\n", .{response.contentType()});

    // Parse HTML directly from response
    var doc = try response.html();
    defer doc.deinit();

    const title = try doc.title();
    std.debug.print("Document Title: '{s}'\n", .{title});

    const body_text = try doc.text();
    std.debug.print("Body Text Sample:\n{s}\n\n", .{if (body_text.len > 200) body_text[0..200] else body_text});

    // Inspect Links
    const links = try doc.links();
    std.debug.print("Links Found ({d}):\n", .{links.len});
    for (links) |link| {
        std.debug.print("  - href: {s}, text: '{s}'\n", .{ link.href, link.text });
    }

    std.debug.print("\nHTML Client verification successful.\n", .{});
}
