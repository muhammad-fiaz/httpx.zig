# GraphQL Integration

HTTPX incorporates a high-performance GraphQL implementation in native Zig, including an AST parser, document validator, schema builder, execution engine, and introspection.

## Server Schema & Execution

Define types from Zig structs with scalar kinds and typed resolvers, build a
schema, and mount it. `mount` registers `GET`/`POST`/`OPTIONS` on the
endpoint (default `/graphql`); the GraphiQL IDE is served by the docs mount
(`enableDocs`, route `/graphiql`):

```zig
const std = @import("std");
const httpx = @import("httpx");
const Scalar = httpx.graphql.Scalar;

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
};

const QueryRoot = httpx.graphql.Query(.{
    .me = .{ .type = UserType, .resolver = resolvers.getMe },
});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    const schema = httpx.graphql.Schema.init(allocator, io, .{
        .query = QueryRoot,
        .types = &.{UserType},
        .enableIntrospection = true,
    });
    try server.graphql(schema, .{ .endpoint = "/graphql" });

    server.run();
}
```

Types (`Type(...)`, `Query(...)`, `Mutation(...)`) are built with generic
schema specs and must be declared at namespace scope. Resolver signatures are
`fn (*httpx.graphql.Context) !T` (typed optional second argument `Args` decode
field arguments, mirroring typed REST handlers' second parameter).

See `examples/graphqlServer.zig` (`zig build run-graphql-server`) for the
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

var response = try client.post("https://api.example.com/graphql", .{
    .json = .{
        .query = query,
        .variables = .{ .id = "prod_987" },
        .operationName = "GetProduct",
    },
});
defer response.deinit();
```

```zig
const Product = struct {
    name: []const u8,
    price: f64,
};

const ProductResponse = struct {
    product: Product,
};

const GraphQLResponse = struct {
    data: ProductResponse,
};

const graphResponse = try response.json(GraphQLResponse);
defer allocator.free(graphResponse.data.product.name);

const productName = graphResponse.data.product.name;
const productPrice = graphResponse.data.product.price;
```

Run this query with:
`zig build run-graphql-server` for a runnable demonstration against a local server.
