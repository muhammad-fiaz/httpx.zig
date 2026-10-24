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

fn htmlHandler(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return .{
        .status = 200,
        .body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Httpx HTML Client Test</title></head>
        \\<body>
        \\  <h1>Welcome to Local HTML Test</h1>
        \\  <p>Testing response.html() parsing end-to-end.</p>
        \\  <a href="/about">About Us</a>
        \\  <a href="/docs">Documentation</a>
        \\</body>
        \\</html>
        ,
        .contentType = "text/html; charset=utf-8",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX HTML Client Demo (local loopback)\n\n", .{});

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    });
    defer server.deinit();
    try server.router.add(.GET, "/html", htmlHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/html", .{port});

    // Fetch HTML from local server
    var response = try client.get(url, .{});
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Content-Type: {s}\n\n", .{response.contentType()});

    // Parse HTML directly from response
    var doc = try response.html();
    defer doc.deinit();

    const title = try doc.title();
    std.debug.print("Document Title: '{s}'\n", .{title});

    const bodyText = try doc.text();
    std.debug.print("Body Text Sample:\n{s}\n\n", .{if (bodyText.len > 200) bodyText[0..200] else bodyText});

    // Inspect Links
    const links = try doc.links();
    std.debug.print("Links Found ({d}):\n", .{links.len});
    for (links) |link| {
        std.debug.print("  - href: {s}, text: '{s}'\n", .{ link.href, link.text });
    }

    std.debug.print("\nHTML Client verification successful.\n", .{});
}
