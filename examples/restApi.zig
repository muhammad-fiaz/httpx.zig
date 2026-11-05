//! Typed REST API with OpenAPI documentation.
//!
//! Demonstrates the whole explicit surface:
//!
//! * lowercase verb registration — `app.post("/users", .{ .handler, … })`
//! * `httpx.Schema(T).result(.{ .status, .body })` responses
//! * Single-document JSON media types on input (standard and any valid `+json` type)
//! * JSON keys that are not valid Zig identifiers via a `.names` map
//! * raw `HandlerFn` routes through the same lowercase verbs
//! * Swagger UI / ReDoc / Scalar / OpenAPI 3.1 output

const std = @import("std");
const httpx = @import("httpx");

pub const stdOptions: std.Options = .{
    .unexpectedErrorTracing = false,
};

// Explicit request and response types

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

/// Wire keys that are not valid Zig identifiers.
const wireNames = .{
    .user_name = "user-name",
    .contact = "@contact",
};

const UserWire = struct {
    user_name: []const u8,
    contact: []const u8,
};

// Handlers: (ctx) or (ctx, body) -> !httpx.Schema(T)

fn createUser(_: *httpx.router.Context, req: CreateUserRequest) !httpx.Schema(UserResponse) {
    return httpx.Schema(UserResponse).result(.{
        .status = .created,
        .body = .{ .id = 101, .name = req.name, .email = req.email },
    });
}

fn getUser(ctx: *httpx.router.Context) !httpx.Schema(UserResponse) {
    const id = ctx.paramUint("id") orelse 1;
    return httpx.Schema(UserResponse).ok(.{
        .id = id,
        .name = "hari",
        .email = "hello@example.com",
    });
}

fn ping(_: *httpx.router.Context) !httpx.Schema(MessageResponse) {
    return httpx.Schema(MessageResponse).ok(.{ .message = "pong" });
}

/// Uses wire keys `user-name` and `@contact` on both the request and response.
fn updateUser(_: *httpx.router.Context, req: UserWire) !httpx.Schema(UserWire) {
    return httpx.Schema(UserWire).result(.{
        .status = .accepted,
        .body = .{ .user_name = req.user_name, .contact = req.contact },
    });
}

fn deleteUser(_: *httpx.router.Context) !httpx.Schema(void) {
    return httpx.Schema(void).noContent();
}

/// A plain handler for the raw `HandlerFn` surface.
fn rawHealth(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .contentType = "application/json; charset=utf-8",
        .body = "{\"status\":\"ok\"}",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=== HTTPX typed REST + OpenAPI demo ===\n", .{});

    var app = try httpx.App.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false, // documentation is mounted explicitly below
    });
    defer app.deinit();

    try app.post("/users", .{
        .handler = createUser,
        .operationId = "createUser",
        .summary = "Create a new user",
        .tags = &.{"users"},
    });

    try app.get("/users/{id:int}", .{
        .handler = getUser,
        .operationId = "getUser",
        .summary = "Retrieve a user by ID",
        .tags = &.{"users"},
    });

    try app.put("/users/{id:int}", .{
        .handler = updateUser,
        .operationId = "updateUser",
        .summary = "Update a user (wire keys: user-name, @contact)",
        .tags = &.{"users"},
        .names = wireNames,
    });

    try app.delete("/users/{id:int}", .{
        .handler = deleteUser,
        .operationId = "deleteUser",
        .summary = "Delete a user",
        .tags = &.{"users"},
    });

    try app.get("/ping", .{
        .handler = ping,
        .operationId = "ping",
        .summary = "Service health ping",
        .tags = &.{"system"},
    });

    // Raw handler route: same lowercase verb, no typed schema derivation.
    try app.get("/raw/health", .{
        .handler = rawHealth,
        .summary = "Raw handler route",
        .tags = &.{"system"},
    });

    try app.docs(.{
        .title = "HTTPX Typed REST API",
        .version = "1.0.0",
        .description = "Explicit, typed REST endpoints with automated OpenAPI 3.1 documentation.",
        .openapi = .{ .enabled = true, .route = "/openapi.json" },
        .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
        .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
        .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar Reference" },
        .graphiql = .{ .enabled = false },
    });

    const port = app.getServer().localPort();
    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("  OpenAPI: http://127.0.0.1:{d}/openapi.json\n", .{port});
    std.debug.print("  Swagger: http://127.0.0.1:{d}/docs\n", .{port});
    std.debug.print("  ReDoc:   http://127.0.0.1:{d}/redoc\n", .{port});
    std.debug.print("  Scalar:  http://127.0.0.1:{d}/scalar\n", .{port});

    const Runner = struct {
        fn run(server: *httpx.Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{app.getServer()});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [160]u8 = undefined;

    // 1. Typed struct body -> 201 Created.
    const postUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users", .{port});
    var postResp = try client.post(postUrl, .{
        .json = CreateUserRequest{ .name = "Example Developer", .email = "dev@example.com" },
    });
    defer postResp.deinit();
    std.debug.print("POST /users -> {d} {s}\n", .{ postResp.status, postResp.body });

    // 2. Response decoding into an explicit struct.
    const getUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users/42", .{port});
    var getResp = try client.get(getUrl, .{});
    defer getResp.deinit();
    const user = try getResp.json(UserResponse);
    std.debug.print("GET /users/42 -> id={d} name={s}\n", .{ user.id, user.name });

    // 3. Renamed JSON keys plus a vendor JSON media type on input.
    const putUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users/42", .{port});
    var putResp = try client.put(putUrl, .{
        .body = "{\"user-name\":\"hari\",\"@contact\":\"hari@example.com\"}",
        .contentType = "application/vnd.api+json",
    });
    defer putResp.deinit();
    std.debug.print("PUT /users/42 (vnd.api+json) -> {d} {s}\n", .{ putResp.status, putResp.body });

    // 4. A non-JSON content type is refused instead of guessed at.
    var mediaResp = try client.put(putUrl, .{
        .body = "user-name=hari",
        .contentType = "text/plain",
    });
    defer mediaResp.deinit();
    std.debug.print("PUT /users/42 (text/plain) -> {d} {s}\n", .{ mediaResp.status, mediaResp.body });

    // 5. DELETE -> 204 No Content.
    const deleteUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/users/42", .{port});
    var deleteResp = try client.delete(deleteUrl, .{});
    defer deleteResp.deinit();
    std.debug.print("DELETE /users/42 -> {d}\n", .{deleteResp.status});

    // 6. Raw handler route: explicit method, plain Response.
    const rawUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/raw/health", .{port});
    var rawResp = try client.get(rawUrl, .{});
    defer rawResp.deinit();
    std.debug.print("GET /raw/health -> {d} {s}\n", .{ rawResp.status, rawResp.body });

    // 7. The generated OpenAPI document contains the typed schema.
    const specUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/openapi.json", .{port});
    var specResp = try client.get(specUrl, .{});
    defer specResp.deinit();
    std.debug.print("GET /openapi.json -> {d} ({d} bytes, renamed key documented: {})\n", .{
        specResp.status,
        specResp.body.len,
        std.mem.indexOf(u8, specResp.body, "user-name") != null,
    });

    app.getServer().requestShutdown();
    thread.join();

    std.debug.print("=== demo completed ===\n", .{});
}
