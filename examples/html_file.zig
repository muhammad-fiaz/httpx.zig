//! Example: Parsing HTML files from disk with HTTPX
//!
//! Demonstrates:
//! 1. Creating a temporary HTML template file
//! 2. Reading and parsing the HTML file into a DOM Document
//! 3. Inspecting the parsed hierarchy
//!
//! Run with: `zig build run-html-file`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> HTTPX HTML File Parsing Demo\n\n", .{});

    const file_path = "sample_test_doc.html";
    const sample_html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Offline Document</title></head>
        \\<body>
        \\  <h1>Offline Header</h1>
        \\  <p class="description">Loaded from local filesystem.</p>
        \\</body>
        \\</html>
    ;

    try httpx.static.files.writeFile(file_path, sample_html);
    defer {
        const cwd = std.Io.Dir.cwd();
        const io = std.Io.Threaded.global_single_threaded.io();
        cwd.deleteFile(io, file_path) catch {};
    }

    // Read file bytes
    const cwd = std.Io.Dir.cwd();
    const io = std.Io.Threaded.global_single_threaded.io();
    const file_bytes = try cwd.readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(file_bytes);

    var p = httpx.Parser.init(allocator, .{});
    var doc = try p.parseHtml(file_bytes);
    defer doc.deinit();

    const title = try doc.title();
    std.debug.print("Loaded Title: {s}\n", .{title});

    if (try doc.selectFirst("h1")) |h1| {
        const h1_text = try h1.text();
        std.debug.print("H1 Text: {s}\n", .{h1_text});
    }

    std.debug.print("\nHTML file parsing verification successful.\n", .{});
}
