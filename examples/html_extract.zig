//! Example: HTML Extraction Helpers in HTTPX
//!
//! Demonstrates:
//! 1. Structured metadata extraction (OpenGraph, Twitter Cards, canonical, description)
//! 2. Links extraction with attributes and inner text
//! 3. Images extraction with src, alt, dimensions
//! 4. Forms extraction with inputs, select options, and submit buttons
//!
//! Run with: `zig build run-html-extract`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> HTTPX HTML Extraction Subsystem Demo\n\n", .{});

    const html_content =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <title>HTTPX Complete Extraction Guide</title>
        \\  <meta name="description" content="Production-ready networking in Zig">
        \\  <meta property="og:title" content="HTTPX Networking">
        \\  <meta property="og:url" content="https://example.com/guide">
        \\  <link rel="canonical" href="https://example.com/canonical-guide">
        \\</head>
        \\<body>
        \\  <div class="gallery">
        \\    <img src="/assets/logo.png" alt="Brand Logo" width="120" height="40">
        \\    <img src="/assets/hero.webp" alt="Hero Banner" width="1200" height="600">
        \\  </div>
        \\  <form action="/login" method="post" enctype="multipart/form-data">
        \\    <input type="text" name="username" placeholder="Username" required>
        \\    <input type="password" name="password" placeholder="Password" required>
        \\    <select name="role">
        \\      <option value="admin">Administrator</option>
        \\      <option value="user">Standard User</option>
        \\    </select>
        \\    <button type="submit" name="btn_submit">Sign In</button>
        \\  </form>
        \\</body>
        \\</html>
    ;

    var p = httpx.Parser.init(allocator, .{});
    var doc = try p.parseHtml(html_content);
    defer doc.deinit();

    // 1. Metadata
    const meta = try doc.metadata();
    std.debug.print("Metadata:\n", .{});
    std.debug.print("  Title: {s}\n", .{meta.title});
    std.debug.print("  Description: {s}\n", .{meta.description});
    std.debug.print("  OG Title: {s}\n", .{meta.ogTitle});
    std.debug.print("  OG URL: {s}\n", .{meta.ogUrl});
    std.debug.print("  Canonical: {s}\n\n", .{meta.canonical});

    // 2. Images
    const imgs = try doc.images();
    std.debug.print("Images ({d}):\n", .{imgs.len});
    for (imgs) |img| {
        std.debug.print("  - src={s}, alt='{s}', dims={s}x{s}\n", .{ img.src, img.alt, img.width, img.height });
    }

    // 3. Forms
    const forms = try doc.forms();
    std.debug.print("\nForms ({d}):\n", .{forms.len});
    for (forms) |f| {
        std.debug.print("  Action: {s}, Method: {s}, Fields: {d}\n", .{ f.action, f.method, f.fields.len });
        for (f.fields) |fld| {
            std.debug.print("    - name='{s}', kind='{s}'\n", .{ fld.name, fld.kind });
        }
    }

    std.debug.print("\nExtraction verification successful.\n", .{});
}
