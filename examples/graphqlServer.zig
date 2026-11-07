//! Example: GraphQL Server with the GraphiQL IDE
//!
//! Demonstrates:
//! - The full type system: objects, enums, input objects, arguments, lists
//! - Typed resolvers with a shared `httpx.graphql.Context`
//! - One `httpx.Server.init(allocator, io, …)` owning the listener, router,
//!   and GraphQL mount
//! - REST routes through `server.get(...)`
//! - GraphQL mounted with `server.graphql(.{ ... })`, torn down by `deinit`
//! - Every documentation UI from the single `.docs` config, all served offline
//! - String queries with typed client decoding via `httpx.graphql.Payload(T)`

const std = @import("std");
const httpx = @import("httpx");

const Scalar = httpx.graphql.Scalar;

/// Single source of truth for the GraphQL route: the mounted endpoint and the
/// GraphiQL UI both read it, so the two can never drift apart.
const graphqlEndpoint = "/graphql";

/// Enum type: resolvers return the Zig enum and the engine emits tag names.
const Role = enum { ADMIN, USER };
const RoleEnum = httpx.graphql.Enum("Role", Role);

/// User payload returned by resolvers.
const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    role: Role,
};

const UserType = httpx.graphql.Type("User", .{
    .id = Scalar.id,
    .name = Scalar.string,
    .email = Scalar.string,
    .role = RoleEnum,
});

/// Input object type used by the `users` field arguments.
const UserFilter = httpx.graphql.Input("UserFilter", .{
    .role = RoleEnum,
});

/// Typed argument struct: decoded from the GraphQL arguments object.
const UsersArgs = struct {
    filter: ?struct { role: ?Role = null } = null,
    limit: u16 = 10,
};

const resolvers = struct {
    pub fn getMe(ctx: *httpx.graphql.Context) !User {
        _ = ctx;
        return .{
            .id = "usr_101",
            .name = "Example User",
            .email = "user@example.com",
            .role = .ADMIN,
        };
    }

    pub fn getUsers(ctx: *httpx.graphql.Context, args: UsersArgs) ![]const User {
        _ = ctx;
        // Arguments arrive typed: `filter.role` is the Role enum, not a string.
        const wanted = if (args.filter) |f| f.role orelse .USER else .USER;
        _ = args.limit;
        return switch (wanted) {
            .ADMIN => &.{
                .{ .id = "1", .name = "Alice Cooper", .email = "alice@example.com", .role = .ADMIN },
            },
            .USER => &.{
                .{ .id = "2", .name = "Bob Dylan", .email = "bob@example.com", .role = .USER },
            },
        };
    }
};

const QueryRoot = httpx.graphql.Query(.{
    .me = .{ .type = UserType, .description = "Current authenticated user", .resolve = resolvers.getMe },
    .users = .{
        .type = UserType,
        .list = true,
        .description = "List users, filtered by role",
        .args = .{
            .filter = UserFilter,
            .limit = .{ .type = Scalar.int, .default = "10" },
        },
        .resolve = resolvers.getUsers,
    },
});

fn statusHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .@"server-name" = httpx.name, .@"uptime-seconds" = 42 });
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
            .graphiql = .{
                .enabled = true,
                .route = "/graphiql",
                .graphqlEndpoint = graphqlEndpoint,
                .title = "GraphiQL IDE",
                // Pre-fill the editor and use a dark Monaco theme.
                .defaultQuery = "{ me { id name role } }",
                .editorTheme = "vs-dark",
            },
        },
        .logging = .{},
        .maxConnections = 5,
    });
    defer server.deinit();

    // Raw route on the same server.
    try server.get("/", helloHandler);

    // REST endpoint next to GraphQL. Quoted JSON keys are exact field names.
    try server.get("/api/status", .{
        .handler = statusHandler,
        .summary = "Typed status report",
        .tags = &.{"system"},
    });

    // GraphQL schema and endpoint in one literal. Every declared type
    // reaches introspection, so GraphiQL / ReDoc / Scalar render them.
    // The mount is owned by the server and removed by `server.deinit()`.
    try server.graphql(.{
        .query = QueryRoot,
        .types = &.{UserType},
        .enums = &.{RoleEnum},
        .inputs = &.{UserFilter},
        .introspection = true,
        .endpoint = graphqlEndpoint,
    });

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
    defer res.deinit();
    std.debug.print("GET / -> status={d}, body={s}\n", .{ res.status, res.body });

    var gqlBuf: [128]u8 = undefined;
    const urlGraphql = try std.fmt.bufPrint(&gqlBuf, "http://127.0.0.1:{d}" ++ graphqlEndpoint, .{port});
    var statusBuf: [160]u8 = undefined;
    const urlStatus = try std.fmt.bufPrint(&statusBuf, "http://127.0.0.1:{d}/api/status", .{port});
    var statusRes = try client.get(urlStatus, .{});
    defer statusRes.deinit();
    std.debug.print("GET /api/status -> status={d}, body={s}\n", .{ statusRes.status, statusRes.body });

    // String query against the typed schema; the response is decoded into a
    // typed envelope that declares only the fields this query selected.
    const query =
        "{ me { id name role } users(filter: { role: ADMIN }, limit: 2) { id name role } }";
    var gqlRes = try client.graphql(urlGraphql, query, null, .{});
    defer gqlRes.deinit();
    std.debug.print("POST /graphql -> status={d}, body={s}\n", .{ gqlRes.status, gqlRes.body });

    const MeQuery = struct {
        me: struct { id: []const u8, name: []const u8, role: []const u8 },
    };
    const payload = try gqlRes.json(httpx.graphql.Payload(MeQuery));
    if (payload.data) |data| {
        std.debug.print("typed me -> id={s} name={s} role={s}\n", .{ data.me.id, data.me.name, data.me.role });
    }

    server.requestShutdown();
    t.join();
    std.debug.print("GraphQL server and client verification completed successfully.\n", .{});
}
