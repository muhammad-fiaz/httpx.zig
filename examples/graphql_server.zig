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
    pub fn getMe(ctx: *httpx.graphql.ResolverContext) anyerror!std.json.Value {
        var map = std.json.ObjectMap.init(ctx.allocator, &.{}, &.{}) catch unreachable;
        try map.put(ctx.allocator, "id", .{ .string = "usr_101" });
        try map.put(ctx.allocator, "name", .{ .string = "Muhammad Fiaz" });
        try map.put(ctx.allocator, "email", .{ .string = "contact@muhammadfiaz.com" });
        try map.put(ctx.allocator, "role", .{ .string = "administrator" });
        return .{ .object = map };
    }

    pub fn getUsers(ctx: *httpx.graphql.ResolverContext) anyerror!std.json.Value {
        var list = std.json.Array.init(ctx.allocator);

        var usr1 = std.json.ObjectMap.init(ctx.allocator, &.{}, &.{}) catch unreachable;
        try usr1.put(ctx.allocator, "id", .{ .string = "1" });
        try usr1.put(ctx.allocator, "name", .{ .string = "Alice Cooper" });
        try usr1.put(ctx.allocator, "email", .{ .string = "alice@example.com" });
        try usr1.put(ctx.allocator, "role", .{ .string = "engineer" });
        try list.append(.{ .object = usr1 });

        var usr2 = std.json.ObjectMap.init(ctx.allocator, &.{}, &.{}) catch unreachable;
        try usr2.put(ctx.allocator, "id", .{ .string = "2" });
        try usr2.put(ctx.allocator, "name", .{ .string = "Bob Dylan" });
        try usr2.put(ctx.allocator, "email", .{ .string = "bob@example.com" });
        try usr2.put(ctx.allocator, "role", .{ .string = "designer" });
        try list.append(.{ .object = usr2 });

        return .{ .array = list };
    }
};

const QueryType = httpx.graphql.ObjectTypeDef{
    .name = "Query",
    .description = "Root queries",
    .fields = &.{
        .{ .name = "me", .type_name = "User", .description = "Current authenticated user", .resolver = &resolvers.getMe },
        .{ .name = "users", .type_name = "User", .is_list = true, .description = "List all users in organization", .resolver = &resolvers.getUsers },
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
        .port = 3000,
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
            .color = .always,
            .requests = true,
        },
        .max_connections = 10,
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

    std.debug.print(
        \\=====================================================
        \\ httpx Server with GraphiQL 5.3.0 running on http://127.0.0.1:3000
        \\ - GraphiQL 5.3.0 UI:  http://127.0.0.1:3000/graphiql
        \\ - GraphQL API:        http://127.0.0.1:3000/graphql
        \\ - Swagger UI:         http://127.0.0.1:3000/docs
        \\ - ReDoc UI:           http://127.0.0.1:3000/redoc
        \\ - Scalar UI:          http://127.0.0.1:3000/scalar
        \\ - OpenAPI Spec:       http://127.0.0.1:3000/openapi.json
        \\=====================================================
        \\
    , .{});

    server.run();
    httpx.docs.unmount();
}
