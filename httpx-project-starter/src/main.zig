const std = @import("std");
const httpx = @import("httpx");

fn printSection(title: []const u8) void {
    std.debug.print("\n=== {s} ===\n", .{title});
}

fn printPreview(body_opt: ?[]const u8, max_len: usize) void {
    const body = body_opt orelse {
        std.debug.print("<empty response body>\n", .{});
        return;
    };

    const n = @min(max_len, body.len);
    std.debug.print("{s}\n", .{body[0..n]});
    if (body.len > n) {
        std.debug.print("[... truncated, total {d} bytes ...]\n", .{body.len});
    }
}

fn runRequestedFlow(client: *httpx.Client) !void {
    printSection("Requested Flow (GET + POST + Cookie Helpers)");

    // Simple GET request
    var response = try client.get("https://note.kaykraft.org/assets/media/html/iching.html", .{});
    defer response.deinit();

    if (response.ok()) {
        std.debug.print("Response: {s}\n", .{response.text() orelse ""});
    }

    // POST with JSON
    var post_response = try client.post("https://httpbin.org/post", .{
        .json = "{\"name\": \"John\"}",
    });
    defer post_response.deinit();

    std.debug.print("POST status: {d}\n", .{post_response.status.code});
    printPreview(post_response.text(), 280);

    // Cookie jar helpers
    try client.setCookie("session", "abc123");
    _ = client.getCookie("session");
    std.debug.print("Cookie count: {d}\n", .{client.cookieCount()});
}

fn runCustomHeadersExample(client: *httpx.Client) !void {
    printSection("Extra Example: GET With Custom Headers");

    const custom_headers = [_][2][]const u8{
        .{ "Accept", "application/json" },
        .{ "X-Demo-App", "httpx-all-in-one" },
        .{ "X-From", "httpx-project-starter" },
    };

    var response = try client.get("https://httpbin.org/headers", .{
        .headers = custom_headers[0..],
        .timeout_ms = 20_000,
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status.code});
    printPreview(response.text(), 320);
}

fn runMethodAliasesExample(client: *httpx.Client) !void {
    printSection("Extra Example: Client Method Aliases");

    var fetch_response = try client.fetch("https://httpbin.org/get", .{});
    defer fetch_response.deinit();
    std.debug.print("client.fetch status: {d}\n", .{fetch_response.status.code});

    var options_response = try client.options("https://httpbin.org/get", .{});
    defer options_response.deinit();
    std.debug.print("client.options status: {d}\n", .{options_response.status.code});

    var delete_response = try client.del("https://httpbin.org/delete", .{});
    defer delete_response.deinit();
    std.debug.print("client.del status: {d}\n", .{delete_response.status.code});
}

fn runTopLevelConvenienceExample(allocator: std.mem.Allocator) !void {
    printSection("Extra Example: Top-Level Convenience APIs");

    var fetch_response = try httpx.fetch(allocator, "https://httpbin.org/get");
    defer fetch_response.deinit();
    std.debug.print("httpx.fetch status: {d}\n", .{fetch_response.status.code});

    var post_json_response = try httpx.postJson(allocator, "https://httpbin.org/post", "{\"demo\": true}");
    defer post_json_response.deinit();
    std.debug.print("httpx.postJson status: {d}\n", .{post_json_response.status.code});
}

fn runRequestSerializationExample(allocator: std.mem.Allocator) !void {
    printSection("Extra Example: Build + Serialize Request");

    var request = try httpx.Request.init(allocator, .POST, "https://api.example.com/v1/items");
    defer request.deinit();

    try request.setJson("{\"id\": 1, \"name\": \"sample\"}");
    try request.headers.set(httpx.HeaderName.ACCEPT, "application/json");

    const wire = try httpx.formatRequest(&request, allocator);
    defer allocator.free(wire);

    std.debug.print("{s}\n", .{wire});
}

fn runConnectionPoolExample(allocator: std.mem.Allocator) void {
    printSection("Extra Example: Connection Pool Configuration");

    var pool = httpx.pool.ConnectionPool.initWithConfig(allocator, .{
        .max_connections = 20,
        .max_per_host = 5,
        .idle_timeout_ms = 60_000,
        .max_requests_per_connection = 1000,
    });
    defer pool.deinit();

    std.debug.print(
        "Pool config: max={d}, per_host={d}, idle_timeout_ms={d}, max_requests_per_conn={d}\n",
        .{ pool.config.max_connections, pool.config.max_per_host, pool.config.idle_timeout_ms, pool.config.max_requests_per_connection },
    );
    std.debug.print(
        "Pool stats: total={d}, active={d}, idle={d}\n",
        .{ pool.totalCount(), pool.activeCount(), pool.idleCount() },
    );
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("httpx-project-starter all-in-one sample\n", .{});
    std.debug.print("Each section runs independently and reports its own errors.\n", .{});

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    runRequestedFlow(&client) catch |err| {
        std.debug.print("Requested flow error: {s}\n", .{@errorName(err)});
    };

    runCustomHeadersExample(&client) catch |err| {
        std.debug.print("Custom headers example error: {s}\n", .{@errorName(err)});
    };

    runMethodAliasesExample(&client) catch |err| {
        std.debug.print("Method aliases example error: {s}\n", .{@errorName(err)});
    };

    runTopLevelConvenienceExample(allocator) catch |err| {
        std.debug.print("Top-level convenience example error: {s}\n", .{@errorName(err)});
    };

    runRequestSerializationExample(allocator) catch |err| {
        std.debug.print("Request serialization example error: {s}\n", .{@errorName(err)});
    };

    runConnectionPoolExample(allocator);

    printSection("Completed");
    std.debug.print("Done.\n", .{});
}
