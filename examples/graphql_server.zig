//! Example: GraphQL Server with GraphiQL 5.3.0 Explorer
//!
//! Demonstrates:
//! - Defining GraphQL Object Types and Resolvers
//! - Mounting GraphQL schema endpoint at `/graphql`
//! - Mounting built-in self-contained offline GraphiQL UI at `/graphiql`
//! - Serving REST / OpenAPI endpoints and GraphQL simultaneously

const std = @import("std");
const httpx = @import("httpx");

const UserType = httpx.graphql.ObjectTypeDef{
    .name = "User",
    .description = "A system user account",
    .fields = &.{
        .{ .name = "id", .type_name = "ID", .description = "Unique user identifier" },
        .{ .name = "name", .type_name = "String", .description = "Full user display name" },
        .{ .name = "email", .type_name = "String", .description = "Primary email address" },
        .{ .name = "role", .type_name = "String", .description = "Security role" },
    },
};

const resolvers = struct {
    pub fn getMe(ctx: httpx.graphql.ResolverContext) anyerror!std.json.Value {
        return ctx.value(.{
            .id = "usr_101",
            .name = "Muhammad Fiaz",
            .email = "contact@muhammadfiaz.com",
            .role = "administrator",
        });
    }

    pub fn getUsers(ctx: httpx.graphql.ResolverContext) anyerror!std.json.Value {
        return ctx.value(&[_]struct {
            id: []const u8,
            name: []const u8,
            email: []const u8,
            role: []const u8,
        }{
            .{ .id = "1", .name = "Alice Cooper", .email = "alice@example.com", .role = "engineer" },
            .{ .id = "2", .name = "Bob Dylan", .email = "bob@example.com", .role = "designer" },
        });
    }
};

const QueryType = httpx.graphql.ObjectTypeDef{
    .name = "Query",
    .description = "Root queries",
    .fields = &.{
        .{ .name = "me", .type_name = "User", .description = "Current authenticated user", .resolver = resolvers.getMe },
        .{ .name = "users", .type_name = "User", .is_list = true, .description = "List all users in organization", .resolver = resolvers.getUsers },
    },
};

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{
        .message = "Hello from httpx! Visit /graphiql, /docs, /redoc, or /scalar",
        .status = "operational",
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = true,
        .docs = .{
            .title = "HTTPX GraphQL & REST API",
            .version = "0.2.0",
            .description = "Full-featured native HTTP server with OpenAPI & GraphiQL 5.3.0 documentation.",
            .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
            .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
            .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar Reference" },
            .graphiql = .{ .enabled = true, .route = "/graphiql", .graphql_endpoint = "/graphql", .title = "GraphiQL IDE" },
        },
        .logging = .{
            .enabled = true,
            .color = .never,
            .requests = false,
        },
        .max_connections = 5,
    });
    defer server.deinit();

    // Setup REST route
    try server.get("/", helloHandler);

    // Setup GraphQL schema and mount endpoint
    const schema = httpx.graphql.Schema.init(allocator, .{
        .query = QueryType,
        .types = &.{UserType},
        .enable_introspection = true,
    });
    try httpx.graphql.mount(&server.router, schema, .{ .endpoint = "/graphql" });

    const port = server.localPort();
    std.debug.print("GraphQL server listening on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_root = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(url_root);
    std.debug.print("GET / -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    var gql_buf: [128]u8 = undefined;
    const url_graphql = try std.fmt.bufPrint(&gql_buf, "http://127.0.0.1:{d}/graphql", .{port});
    var gql_res = try client.graphql(url_graphql, "{ me { id name email role } }", null, .{});
    std.debug.print("POST /graphql -> status={d}, body={s}\n", .{ gql_res.status, gql_res.body });
    gql_res.deinit();

    server.requestShutdown();
    t.join();
    httpx.docs.unmount();
    std.debug.print("GraphQL server and client verification completed successfully.\n", .{});
}
