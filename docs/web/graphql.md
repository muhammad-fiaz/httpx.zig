# GraphQL Integration

HTTPX incorporates a high-performance GraphQL implementation in native Zig, including an AST parser, document validator, schema builder, execution engine, and introspection.

## Server Schema & Execution

Define GraphQL query types and register resolvers:

```zig
const std = @import("std");
const httpx = @import("httpx");

Define GraphQL object types with resolvers, build a schema, and mount it.
`mount` registers `GET`/`POST`/`OPTIONS` on the endpoint (default
`/graphql`); the GraphiQL IDE is served by the docs mount
(`enableDocs`, route `/graphiql`):

```zig
const std = @import("std");
const httpx = @import("httpx");

const resolvers = struct {
    pub fn getMe(ctx: httpx.graphql.ResolverContext) anyerror!std.json.Value {
        return ctx.value(.{ .id = "usr_101", .name = "Muhammad Fiaz" });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    const QueryType = httpx.graphql.ObjectTypeDef{
        .name = "Query",
        .fields = &.{
            .{ .name = "me", .typeName = "User", .resolver = resolvers.getMe },
        },
    };
    const schema = httpx.graphql.Schema.init(allocator, .{ .query = QueryType });
    try httpx.graphql.mount(&server.router, schema, .{ .endpoint = "/graphql" });
    defer httpx.graphql.unmount(&server.router, .{ .endpoint = "/graphql" });

    try server.run();
}
```

See `examples/graphql_server.zig` (`zig build run-graphql-server`) for the
complete runnable version with queries, variables, and verification.

## Client Execution & Typed Responses

Execute queries from the HTTPX client and decode typed responses using Zig structs:

```zig
const query =
    \\query GetProduct($id: ID!) {
    \\  product(id: $id) {
    \\    name
    \\    price
    \\  }
    \\}
;

const response = try client.post("https://api.example.com/graphql", .{
    .json = .{
        .query = query,
        .variables = .{ .id = "prod_987" },
    },
});
defer response.deinit();

const ProductResponse = struct {
    data: struct {
        product: struct {
            name: []const u8,
            price: f64,
        },
    },
};
const parsed = try response.json(ProductResponse);
```

## Related

* [Web: Documentation UIs](/web/documentation-ui)
* [Guide: GraphQL](/guide/graphql)
* [Example: GraphQL Server](/examples/graphql-server)
