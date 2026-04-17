//! Simplified API Aliases Demo
//!
//! Demonstrates top-level and client-level alias helpers for concise client code.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simplified API Aliases Demo ===\n\n", .{});

    // Top-level fetch alias (creates and deinitializes a temporary client).
    if (httpx.fetch(allocator, "https://httpbin.org/get")) |resp_a| {
        var response = resp_a;
        defer response.deinit();
        std.debug.print("fetch status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("fetch error: {s}\n", .{@errorName(err)});
    }

    // Top-level send alias with explicit method and options.
    if (httpx.send(allocator, .GET, "https://httpbin.org/headers", .{})) |resp_b| {
        var response = resp_b;
        defer response.deinit();
        std.debug.print("send status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("send error: {s}\n", .{@errorName(err)});
    }

    // Client aliases.
    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withPoolLimits(32, 8);

    var client: httpx.HttpClient = httpx.HttpClient.initWithConfig(allocator, client_config);
    defer client.deinit();

    if (client.fetch("https://httpbin.org/anything", .{})) |resp_c| {
        var response = resp_c;
        defer response.deinit();
        std.debug.print("client.fetch status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("client.fetch error: {s}\n", .{@errorName(err)});
    }

    if (client.options("https://httpbin.org/get", .{})) |resp_d| {
        var response = resp_d;
        defer response.deinit();
        std.debug.print("client.options status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("client.options error: {s}\n", .{@errorName(err)});
    }

    if (client.del("https://httpbin.org/delete", .{})) |resp_e| {
        var response = resp_e;
        defer response.deinit();
        std.debug.print("client.del status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("client.del error: {s}\n", .{@errorName(err)});
    }

    if (client.opts("https://httpbin.org/get", .{})) |resp_f| {
        var response = resp_f;
        defer response.deinit();
        std.debug.print("client.opts status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("client.opts error: {s}\n", .{@errorName(err)});
    }

    if (httpx.trace(allocator, "https://httpbin.org/trace", .{})) |resp_g| {
        var response = resp_g;
        defer response.deinit();
        std.debug.print("trace status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("trace error: {s}\n", .{@errorName(err)});
    }

    if (client.connect("https://httpbin.org/anything", .{})) |resp_h| {
        var response = resp_h;
        defer response.deinit();
        std.debug.print("client.connect status: {d}\n", .{response.status.code});
    } else |err| {
        std.debug.print("client.connect error: {s}\n", .{@errorName(err)});
    }
}
