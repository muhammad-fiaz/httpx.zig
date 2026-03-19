//! Simplified API Aliases Demo
//!
//! Demonstrates top-level and client-level alias helpers for concise client code.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simplified API Aliases Demo ===\n\n", .{});

    // Top-level fetch alias (creates and deinitializes a temporary client).
    var resp_a = try httpx.fetch(allocator, "https://httpbin.org/get");
    defer resp_a.deinit();
    std.debug.print("fetch status: {d}\n", .{resp_a.status.code});

    // Top-level send alias with explicit method and options.
    var resp_b = try httpx.send(allocator, .GET, "https://httpbin.org/headers", .{});
    defer resp_b.deinit();
    std.debug.print("send status: {d}\n", .{resp_b.status.code});

    // Client aliases.
    var client: httpx.HttpClient = httpx.HttpClient.init(allocator);
    defer client.deinit();

    var resp_c = try client.fetch("https://httpbin.org/anything", .{});
    defer resp_c.deinit();
    std.debug.print("client.fetch status: {d}\n", .{resp_c.status.code});

    var resp_d = try client.options("https://httpbin.org/get", .{});
    defer resp_d.deinit();
    std.debug.print("client.options status: {d}\n", .{resp_d.status.code});
}
