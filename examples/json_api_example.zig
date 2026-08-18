const std = @import("std");
const httpx = @import("httpx");

const ApiUser = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

const ApiResponse = struct {
    ok: bool,
    message: []const u8,
};

const HttpBunGet = struct {
    origin: []const u8,
    url: []const u8,
};

const HttpBunPost = struct {
    origin: []const u8,
    url: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        var result = httpx.getJson(HttpBunGet, "http://httpbun.com/get?name=Alice&email=alice@test.com&age=30", .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("getJson failed: {}\n", .{err});
            return;
        };
        defer result.response.deinit();

        std.debug.print("  origin={s} url={s}\n\n", .{ result.value.origin, result.value.url });
    }

    {
        var client = httpx.Client.init(allocator);
        defer client.deinit();

        var result = client.getJson(HttpBunGet, "http://httpbun.com/get?name=Bob&email=bob@test.com&age=25", .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("Client.getJson failed: {}\n", .{err});
            return;
        };
        defer result.response.deinit();

        std.debug.print("  origin={s} url={s}\n\n", .{ result.value.origin, result.value.url });
    }

    {
        const req_body =
            \\{"name":"Charlie","email":"charlie@test.com","age":35}
        ;
        var result = httpx.postJsonAndParse(HttpBunPost, "http://httpbun.com/post", req_body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("postJsonAndParse failed: {}\n", .{err});
            return;
        };
        defer result.response.deinit();

        std.debug.print("  origin={s} url={s}\n\n", .{ result.value.origin, result.value.url });
    }

    {
        var response = httpx.get("http://httpbun.com/get?name=Dave&email=dave@test.com&age=40", .{
            .headers = &.{.{ "Accept", "application/json" }},
        }) catch |err| {
            std.debug.print("GET failed: {}\n", .{err});
            return;
        };
        defer response.deinit();

        const resp = response.jsonBorrowed(HttpBunGet, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("Response.jsonBorrowed failed: {}\n", .{err});
            return;
        };
        std.debug.print("  origin={s} url={s}\n\n", .{ resp.origin, resp.url });
    }

    {
        var server = httpx.Server.initWithConfig(allocator, .{
            .port = 0,
            .port_conflict = .fail,
        });
        defer server.deinit();

        try server.post("/api/users", createUserHandler);
        try server.get("/api/health", healthHandler);

        const server_thread = try server.listenInBackground();
        defer {
            server.stop();
            server_thread.join();
        }

        sleepMs(50);
        const port = server.listeningPort();
        const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
        defer allocator.free(base_url);

        const post_url = try std.fmt.allocPrint(allocator, "{s}/api/users", .{base_url});
        defer allocator.free(post_url);

        const user_json =
            \\{"name":"Eve","email":"eve@test.com","age":28}
        ;
        var post_result = httpx.postJsonAndParse(ApiResponse, post_url, user_json, .{}) catch |err| {
            std.debug.print("POST to local server failed: {}\n", .{err});
            return;
        };
        defer post_result.response.deinit();
        std.debug.print("  POST response: ok={} message={s}\n", .{ post_result.value.ok, post_result.value.message });

        const health_url = try std.fmt.allocPrint(allocator, "{s}/api/health", .{base_url});
        defer allocator.free(health_url);

        var get_result = httpx.getJson(ApiResponse, health_url, .{}) catch |err| {
            std.debug.print("GET /api/health failed: {}\n", .{err});
            return;
        };
        defer get_result.response.deinit();
        std.debug.print("  GET response: ok={} message={s}\n\n", .{ get_result.value.ok, get_result.value.message });
    }
}

fn createUserHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (!ctx.isJson()) {
        return ctx.status(415).json(.{ .ok = false, .message = "Content-Type must be application/json" });
    }

    var parsed = ctx.jsonBody(ApiUser, .{ .ignore_unknown_fields = true }) catch {
        return ctx.status(400).json(.{ .ok = false, .message = "Invalid JSON" });
    };
    defer parsed.deinit();

    _ = parsed.value;
    return ctx.json(.{ .ok = true, .message = "Created user" });
}

fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .ok = true, .message = "healthy" });
}

fn sleepMs(ms: i64) void {
    const io = httpx.defaultIo();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}
