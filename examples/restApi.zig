const std = @import("std");
const httpx = @import("httpx");

pub const stdOptions: std.Options = .{
    .unexpectedErrorTracing = false,
};

const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
};

const UserResponse = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
};

const MessageResponse = struct {
    message: []const u8,
};

fn createUser(
    _: *httpx.router.Context,
    request: CreateUserRequest,
) !httpx.ApiResult(UserResponse) {
    return httpx.ApiResult(UserResponse).created(.{
        .id = 101,
        .name = request.name,
        .email = request.email,
    });
}

fn getUser(
    ctx: *httpx.router.Context,
) !httpx.ApiResult(UserResponse) {
    const id = ctx.paramUint("id") orelse 1;
    return httpx.ApiResult(UserResponse).ok(.{
        .id = id,
        .name = "hari",
        .email = "hello@example.com",
    });
}

fn ping(
    _: *httpx.router.Context,
) !httpx.ApiResult(MessageResponse) {
    return httpx.ApiResult(MessageResponse).ok(.{
        .message = "pong",
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=== Starting Zig-Native REST & OpenAPI Demo App ===\n", .{});

    var app = try httpx.App.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false, // We customize via app.docs() below
    });
    defer app.deinit();

    // Register typed REST endpoints
    try app.restPost("/users", createUser, .{
        .operationId = "createUser",
        .summary = "Create a new user",
        .tags = &.{"users"},
    });

    try app.restGet("/users/{id:int}", getUser, .{
        .operationId = "getUser",
        .summary = "Retrieve user by id",
        .tags = &.{"users"},
    });

    try app.restGet("/ping", ping, .{
        .operationId = "ping",
        .summary = "Service health ping",
        .tags = &.{"system"},
    });

    // Mount unified documentation UIs serving local assets
    try app.docs(.{
        .title = "Modern HTTPX REST API",
        .version = "1.0.0",
        .description = "Type-safe REST framework with automated OpenAPI 3.1 documentation.",
        .openapi = .{ .enabled = true, .route = "/openapi.json" },
        .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
        .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
        .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar Reference" },
        .graphiql = .{ .enabled = false },
    });

    const port = app.getServer().localPort();
    std.debug.print("REST API & Documentation Server listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("  OpenAPI Spec: http://127.0.0.1:{d}/openapi.json\n", .{port});
    std.debug.print("  Swagger UI:   http://127.0.0.1:{d}/docs\n", .{port});
    std.debug.print("  ReDoc:        http://127.0.0.1:{d}/redoc\n", .{port});
    std.debug.print("  Scalar:       http://127.0.0.1:{d}/scalar\n", .{port});

    // Run background server thread for client verification
    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const srvThread = try std.Thread.spawn(.{}, ServerThread.run, .{app.getServer()});

    // Run client verification against the typed endpoints
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;

    // 1. Test POST /users with typed struct
    const postUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users", .{port});
    var postResp = try client.postJson(postUrl, CreateUserRequest{
        .name = "Example Developer",
        .email = "dev@example.com",
    }, .{});
    defer postResp.deinit();

    std.debug.print("POST /users status: {d}, body: {s}\n", .{ postResp.status, postResp.body });

    // 2. Test GET /users/42
    const getUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users/42", .{port});
    var getResp = try client.get(getUrl, .{});
    defer getResp.deinit();

    const user = try getResp.json(UserResponse);
    std.debug.print("GET /users/42 parsed: id={d}, name={s}, email={s}\n", .{ user.id, user.name, user.email });

    // 3. Test GET /openapi.json
    const specUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/openapi.json", .{port});
    var specResp = try client.get(specUrl, .{});
    defer specResp.deinit();
    std.debug.print("GET /openapi.json size: {d} bytes\n", .{specResp.body.len});

    app.getServer().requestShutdown();
    srvThread.join();

    std.debug.print("=== REST Demo Completed Successfully ===\n", .{});
}
