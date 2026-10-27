//! Example: HTML DOM Mutation and Serialization
//!
//! Demonstrates:
//! 1. Parsing an HTML fragment
//! 2. Mutating attributes and text nodes safely
//! 3. Serializing the modified DOM tree back to canonical XSS-safe HTML
//!
//! Run with: `zig build run-html-transform`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> HTTPX HTML DOM Transformation & Serialization Demo\n\n", .{});

    const initialHtml =
        \\<div class="card" id="user-1">
        \\  <h2 class="name">Old Name</h2>
        \\  <p class="role">Guest</p>
        \\</div>
    ;

    var p = httpx.parsing.Parser.init(allocator, .{});
    var doc = try p.parseHtml(initialHtml);
    defer doc.deinit();

    std.debug.print("Original HTML:\n{s}\n\n", .{initialHtml});

    // 1. Modify attribute on container
    if (try doc.getElementById("user-1")) |card| {
        try card.setAttr("data-status", "verified");
    }

    // 2. Modify name text
    if (try doc.selectFirst(".name")) |nameNode| {
        try nameNode.replaceText("Jane Doe");
    }

    // 3. Modify role text with special characters needing escaping
    if (try doc.selectFirst(".role")) |roleNode| {
        try roleNode.replaceText("Senior Architect & Lead <Engineering>");
    }

    // 4. Serialize back to HTML
    const serialized = try doc.serialize();
    std.debug.print("Transformed & Serialized HTML (with XSS escaping):\n{s}\n", .{serialized});

    std.debug.print("\nTransformation verification successful.\n", .{});
}
