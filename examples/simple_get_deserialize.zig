const std = @import("std");
const httpx = @import("httpx");

const HttpbinResponse = struct {
    args: std.json.Value,
    headers: Headers,
    origin: ?[]const u8 = null,
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
    \\  "url": "http://httpbun.com/get"
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

fn printResponse(data: HttpbinResponse) void {
    std.debug.print("  origin:       {s}\n", .{data.origin orelse "(missing)"});
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

    if (!live_mode) {
        const parsed = std.json.parseFromSlice(HttpbinResponse, allocator, offline_sample_json, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("JSON parse failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();
        printResponse(parsed.value);
        return;
    }

    const client_config = httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry());

    var client = httpx.Client.initWithConfig(allocator, client_config);
    defer client.deinit();

    var response = client.request(.GET, "http://httpbun.com/get", .{
        .timeout_ms = 5_000,
        .headers = &.{
            .{ "Accept", "application/json" },
        },
    }) catch |err| {
        std.debug.print("Request failed: {s}\n", .{@errorName(err)});
        const parsed = std.json.parseFromSlice(HttpbinResponse, allocator, offline_sample_json, .{ .ignore_unknown_fields = true }) catch |parse_err| {
            std.debug.print("JSON parse failed: {s}\n", .{@errorName(parse_err)});
            return;
        };
        defer parsed.deinit();
        printResponse(parsed.value);
        return;
    };
    defer response.deinit();

    std.debug.print("Response Status: {d} {s}\n", .{ response.status.code, response.status.phrase });

    const parsed = response.json(HttpbinResponse, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("JSON parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    printResponse(parsed.value);
}
