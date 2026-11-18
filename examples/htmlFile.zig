//! Parsing an HTML file from disk.
//!
//! Writes a small document with the HTTPX filesystem utilities, reads it back,
//! and parses it with the unified `httpx.parsing` entry point.
//!
//! Run with: `zig build run-html-file`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const filePath = "sample_test_doc.html";
    const sampleHtml =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Offline Document</title></head>
        \\<body>
        \\  <h1>Offline Header</h1>
        \\  <p class="description">Loaded from the local filesystem.</p>
        \\</body>
        \\</html>
    ;

    try httpx.fs.writeFile(filePath, sampleHtml);
    defer httpx.fs.deleteFile(filePath) catch {};

    const fileBytes = try httpx.fs.readFileAlloc(allocator, filePath);
    defer allocator.free(fileBytes);

    var doc = try httpx.parsing.init(allocator, io, .{}).parseHtml(fileBytes);
    defer doc.deinit();

    std.debug.print("Title: {s}\n", .{try doc.title()});

    if (try doc.selectFirst("h1")) |h1| {
        std.debug.print("Heading: {s}\n", .{try h1.text()});
    }
}
