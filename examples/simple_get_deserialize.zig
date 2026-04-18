//! Simple GET Request + JSON Deserialization Example
//!
//! Default mode is offline-safe and parses an embedded JSON payload so
//! it does not hang in restricted environments.
//! Set HTTPX_EXAMPLE_ONLINE=1 to run a live request against httpbin.

const std = @import("std");
const httpx = @import("httpx");

const HttpbinResponse = struct {
    args: std.json.Value,
    headers: Headers,
    origin: []const u8,
    url: []const u8,

    const Headers = struct {
        Accept: ?[]const u8 = null,
        Host: ?[]const u8 = null,
        @"User-Agent": ?[]const u8 = null,
        @"X-Amzn-Trace-Id": ?[]const u8 = null,
    };
};

const offline_sample_json =
    \\{
    \\  "args": {},
    \\  "headers": {
    \\    "Accept": "application/json",
    \\    "Host": "example.local",
    \\    "User-Agent": "httpx.zig/offline-demo",
    \\    "X-Amzn-Trace-Id": "Root=1-offline-demo"
    \\  },
    \\  "origin": "127.0.0.1",
    \\  "url": "https://httpbin.org/get"
    \\}
;

fn shouldUseLiveNetwork(environ: std.process.Environ, allocator: std.mem.Allocator) bool {
    const value = environ.getAlloc(allocator, "HTTPX_EXAMPLE_ONLINE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.InvalidWtf8 => return false,
        else => return false,
    };
    defer allocator.free(value);

    return std.mem.eql(u8, value, "1");
}

fn parseAndPrint(body: []const u8, allocator: std.mem.Allocator) void {
    const parsed = std.json.parseFromSlice(HttpbinResponse, allocator, body, .{}) catch |err| {
        std.debug.print("JSON parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    const data = parsed.value;

    std.debug.print("\nDeserialized response:\n", .{});
    std.debug.print("  origin:       {s}\n", .{data.origin});
    std.debug.print("  url:          {s}\n", .{data.url});
    std.debug.print("  User-Agent:   {s}\n", .{data.headers.@"User-Agent" orelse "(missing)"});
    std.debug.print("  Host:         {s}\n", .{data.headers.Host orelse "(missing)"});
    std.debug.print("  Accept:       {s}\n", .{data.headers.Accept orelse "(missing)"});
    std.debug.print("  X-Amzn-Trace: {s}\n", .{data.headers.@"X-Amzn-Trace-Id" orelse "(missing)"});
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const live_mode = shouldUseLiveNetwork(init.minimal.environ, allocator);

    std.debug.print("=== Simple GET Request + JSON Deserialization ===\n\n", .{});

    if (!live_mode) {
        std.debug.print("Offline-safe mode: parsing embedded sample payload.\n", .{});
        parseAndPrint(offline_sample_json, allocator);
        std.debug.print("\nSet HTTPX_EXAMPLE_ONLINE=1 to run a live request.\n", .{});
        return;
    }

    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry());

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    std.debug.print("Making GET request to https://httpbin.org/get...\n", .{});

    var response = client.request(.GET, "https://httpbin.org/get", .{
        .timeout_ms = 5_000,
        .headers = &.{
            .{ "Accept", "application/json" },
        },
    }) catch |err| {
        std.debug.print("Request failed: {s}\n", .{@errorName(err)});
        std.debug.print("Falling back to embedded sample payload.\n", .{});
        parseAndPrint(offline_sample_json, allocator);
        return;
    };
    defer response.deinit();

    std.debug.print("\nResponse Status: {d} {s}\n", .{ response.status.code, response.status.phrase });

    if (response.text()) |body| {
        parseAndPrint(body, allocator);
    } else {
        std.debug.print("(no body)\n", .{});
    }
}
