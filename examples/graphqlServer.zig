//! Example: GraphQL Server with the GraphiQL IDE
//!
//! Demonstrates:
//! - Defining GraphQL types from Zig structs with scalar kinds
//! - Typed resolvers with a shared `httpx.graphql.Context`
//! - One `httpx.Server.init(allocator, io, …)` owning listener, router, docs
//! - Typed REST routes through `server.rest()` (no router poking)
//! - GraphQL mounted with `server.graphql(schema, …)`, torn down by `deinit`
//! - `httpx.Client.init(allocator, io, …)` for the verification requests

const std = @import("std");
const httpx = @import("httpx");

const Scalar = httpx.graphql.Scalar;

/// Single source of truth for the GraphQL route: the mounted endpoint and the
/// GraphiQL UI both read it, so the two can never drift apart.
const graphqlEndpoint = "/graphql";

// Struct-based type: fields map one-to-one onto the Zig struct.
const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    role: []const u8,
};

const UserType = httpx.graphql.Type("User", .{
    .id = Scalar.id,
    .name = Scalar.string,
    .email = Scalar.string,
    .role = Scalar.string,
});

const resolvers = struct {
    pub fn getMe(ctx: *httpx.graphql.Context) !User {
        _ = ctx;
        return .{
            .id = "usr_101",
            .name = "Example User",
            .email = "user@example.com",
            .role = "administrator",
        };
    }

    pub fn getUsers(ctx: *httpx.graphql.Context) ![]const User {
        _ = ctx;
        return &.{
            .{ .id = "1", .name = "Alice Cooper", .email = "alice@example.com", .role = "engineer" },
            .{ .id = "2", .name = "Bob Dylan", .email = "bob@example.com", .role = "designer" },
        };
    }

    // Loose (untyped) resolvers are also supported: `Context` by value with
    // a `std.json.Value` result. Both styles share the same `Context`.
    pub fn getServerName(ctx: httpx.graphql.Context) !std.json.Value {
        return ctx.value(httpx.name);
    }
};

const QueryRoot = httpx.graphql.Query(.{
    .serverName = .{ .type = Scalar.string, .resolve = resolvers.getServerName },
    .me = .{ .type = UserType, .description = "Current authenticated user", .resolve = resolvers.getMe },
    .users = .{ .type = UserType, .list = true, .description = "List all users in organization", .resolve = resolvers.getUsers },
});

// A typed REST endpoint next to GraphQL: `httpx.Schema(T)` results plus a key
// map, so wire keys that are not Zig identifiers work here too.
const StatusResponse = struct {
    server_name: []const u8,
    uptime_s: u64,
};

const StatusSchema = httpx.json.Schema(StatusResponse, .{
    .server_name = "server-name",
    .uptime_s = "uptime-seconds",
});

fn statusHandler(_: *httpx.router.Context) !httpx.Schema(StatusResponse) {
    return httpx.Schema(StatusResponse).ok(.{
        .server_name = httpx.name,
        .uptime_s = 42,
    });
}

fn helloHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{
        .message = "Hello from httpx! Visit /graphiql, /docs, /redoc, or /scalar",
        .status = "operational",
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // One init owns the listener, router, docs, and GraphQL mount. Every
    // option lives in this single `.{}` literal.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = true,
        .docs = .{
            .title = "HTTPX GraphQL & REST API",
            .version = httpx.version,
            .description = "Full-featured native HTTP server with OpenAPI documentation.",
            .openapi = .{ .enabled = true, .route = "/openapi.json" },
            .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
            .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
            .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar Reference" },
            .graphiql = .{ .enabled = true, .route = "/graphiql", .graphqlEndpoint = graphqlEndpoint, .title = "GraphiQL IDE" },
        },
        .logging = .{},
        .maxConnections = 5,
    });
    defer server.deinit();

    // Raw route on the same server.
    try server.get("/", helloHandler);

    // Typed REST route (auto-documented, renamed JSON keys). The controller
    // reuses the server's allocator and io instead of being handed a router.
    var rest = server.rest();
    try rest.get("/api/status", .{
        .handler = statusHandler,
        .summary = "Typed status report",
        .tags = &.{"system"},
        .schema = StatusSchema,
    });

    // GraphQL schema and endpoint. The mount is owned by the server and
    // removed by `server.deinit()`.
    const schema = httpx.graphql.Schema.init(allocator, io, .{
        .query = QueryRoot,
        .types = &.{UserType},
        .enableIntrospection = true,
    });
    try server.graphql(schema, .{ .endpoint = graphqlEndpoint });

    const port = server.localPort();
    std.debug.print("GraphQL server listening on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [128]u8 = undefined;
    const urlRoot = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(urlRoot, .{});
    std.debug.print("GET / -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    var gqlBuf: [128]u8 = undefined;
    const urlGraphql = try std.fmt.bufPrint(&gqlBuf, "http://127.0.0.1:{d}" ++ graphqlEndpoint, .{port});
    var statusBuf: [160]u8 = undefined;
    const urlStatus = try std.fmt.bufPrint(&statusBuf, "http://127.0.0.1:{d}/api/status", .{port});
    var statusRes = try client.get(urlStatus, .{});
    std.debug.print("GET /api/status -> status={d}, body={s}\n", .{ statusRes.status, statusRes.body });
    statusRes.deinit();

    var gqlRes = try client.graphql(urlGraphql, "{ me { id name email role } }", null, .{});
    std.debug.print("POST /graphql -> status={d}, body={s}\n", .{ gqlRes.status, gqlRes.body });
    gqlRes.deinit();

    server.requestShutdown();
    t.join();
    std.debug.print("GraphQL server and client verification completed successfully.\n", .{});
}
