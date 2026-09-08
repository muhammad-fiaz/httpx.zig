//! Example: Streaming HTML Parsing via std.Io.Reader
//!
//! Demonstrates:
//! 1. Streaming HTML parsing from a chunked or streaming reader without loading unbounded data
//! 2. Bounded memory limits
//! 3. Extracting elements on the resulting document
//!
//! Run with: `zig build run-html-stream`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> HTTPX Streaming HTML Parser Demo\n\n", .{});

    const chunked_html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Streaming Page</title></head>
        \\<body>
        \\  <div class="stream-content">
        \\    <p>This document was streamed chunk by chunk via std.Io.Reader.</p>
        \\  </div>
        \\</body>
        \\</html>
    ;

    var reader = std.Io.Reader.fixed(chunked_html);

    var p = httpx.Parser.init(allocator, .{});
    // Parse stream with a 1 MB limit
    var doc = try p.parseStream(&reader, 1024 * 1024);
    defer doc.deinit();

    const title = try doc.title();
    std.debug.print("Document Title: '{s}'\n", .{title});

    if (try doc.selectFirst(".stream-content p")) |p_node| {
        const text = try p_node.text();
        std.debug.print("Stream Content Paragraph: '{s}'\n", .{text});
    }

    std.debug.print("\nStreaming HTML verification successful.\n", .{});
}
