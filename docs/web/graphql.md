# GraphQL Integration

HTTPX incorporates a high-performance GraphQL implementation in native Zig, including an AST parser, document validator, schema builder, execution engine, and introspection.

## Server Schema & Execution

Define GraphQL query types and register resolvers:

```zig
const std = @import("std");
const httpx = @import("httpx");

// Define schema resolvers and execution handler
fn handleGraphQL(ctx: *httpx.Context) !void {
    const body = ctx.body() orelse {
        ctx.status(400);
        return;
    };

    // Execute query against compiled schema
    const result = try httpx.graphql.execute(ctx.allocator, schema, body);
    defer ctx.allocator.free(result);

    ctx.header("Content-Type", "application/json");
    try ctx.text(result);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    server.post("/graphql", handleGraphQL);
    server.graphiql("/graphiql", .{ .endpoint = "/graphql" });

    try server.run();
}
```

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
