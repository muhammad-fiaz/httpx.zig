//! Request and response customization example
//!
//! Demonstrates request builders, request/response helpers, response accessors,
//! and server-side request inspection with headers, query params, JSON, and redirects.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();

    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

fn inspectHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .method = ctx.request.method.toString(),
        .path = ctx.request.uri.path,
        .query = ctx.request.uri.query orelse "",
        .accept_json = ctx.request.acceptsJson(),
        .is_json = ctx.request.isJsonContent(),
        .is_form = ctx.request.isFormContent(),
        .feature_header = ctx.header("X-Feature") orelse "",
        .authorization = ctx.authorization() orelse "",
        .body = ctx.request.body orelse "",
    });
}

fn renderHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html("<h1>request/response customization</h1>");
}

fn redirectHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.redirect("/render", 302);
}

const InspectResponse = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    accept_json: bool,
    is_json: bool,
    is_form: bool,
    feature_header: []const u8,
    authorization: []const u8,
    body: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Request/Response Customization Example ===\n\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.post("/inspect", inspectHandler);
    try server.get("/render", renderHandler);
    try server.get("/redirect", redirectHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(50);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const inspect_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/inspect", .{port});
    defer allocator.free(inspect_url);

    const render_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/render", .{port});
    defer allocator.free(render_url);

    const redirect_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/redirect", .{port});
    defer allocator.free(redirect_url);

    var direct_request = try httpx.Request.init(allocator, .GET, inspect_url);
    defer direct_request.deinit();
    try direct_request.setHeader("X-Feature", "enabled");
    try direct_request.addQueryParams(&.{.{ "mode", "direct" }});
    try direct_request.setBearerAuth("demo-token");
    const direct_serialized = try direct_request.toSlice(allocator);
    defer allocator.free(direct_serialized);
    std.debug.print("Direct request:\n{s}\n", .{direct_serialized});

    var builder = httpx.RequestBuilder.init(allocator);
    defer builder.deinit();
    _ = builder.setMethod(.POST).setUrl(inspect_url).setVersion(.HTTP_2);
    _ = try builder.addHeader("Accept", "application/json");
    _ = try builder.addHeader("X-Feature", "builder");
    _ = try builder.setJsonBody("{\"from\":\"builder\"}");

    var built_request = try builder.build();
    defer built_request.deinit();
    const built_serialized = try built_request.toSlice(allocator);
    defer allocator.free(built_serialized);
    std.debug.print("Built request:\n{s}\n", .{built_serialized});

    const inspect_options = httpx.RequestOptions.defaults()
        .withHeaders(&.{
            .{ "Accept", "application/json" },
            .{ "X-Feature", "client" },
        })
        .withQueryParams(&.{.{ "mode", "client" }})
        .withJson("{\"from\":\"client\"}")
        .withBearerToken("demo-token");

    var inspect_response = try client.post(inspect_url, inspect_options);
    defer inspect_response.deinit();

    const parsed_inspect = try inspect_response.json(InspectResponse, .{});
    defer parsed_inspect.deinit();
    const inspect_data = parsed_inspect.value;
    std.debug.print("Inspect response: method={s} path={s} query={s} accept_json={} is_json={} header={s}\n", .{
        inspect_data.method,
        inspect_data.path,
        inspect_data.query,
        inspect_data.accept_json,
        inspect_data.is_json,
        inspect_data.feature_header,
    });
    std.debug.print("Inspect response content-type: {s}\n", .{inspect_response.contentType().?});
    std.debug.print("Inspect response content-length: {d}\n", .{inspect_response.contentLength().?});

    var render_response = try client.get(render_url, .{});
    defer render_response.deinit();
    std.debug.print("Render response content-type: {s}\n", .{render_response.contentType().?});
    std.debug.print("Render response body: {s}\n", .{render_response.text().?});

    var redirect_response = try client.get(redirect_url, httpx.RequestOptions.defaults().withFollowRedirects(false));
    defer redirect_response.deinit();
    std.debug.print("Redirect? {} location={s}\n", .{
        redirect_response.isRedirect(),
        redirect_response.location().?,
    });

    server.stop();
    server_thread.join();
}
