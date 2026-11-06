# GraphQL Guide

HTTPX features full-featured GraphQL support including AST parsing, document validation, schema compilation with the full type system, execution engine, introspection, and unified client-side execution.

## Client Query Execution

GraphQL operations use the standard HTTPX client. A string query is sent with
`client.graphql`; typed and string-based variables are both accepted:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const query =
        \\query GetUser($id: ID!) {
        \\  user(id: $id) {
        \\    name
        \\    email
        \\  }
        \\}
    ;

    var response = try client.graphql(
        "https://api.example.com/graphql",
        query,
        .{ .id = "usr_101" },
        .{},
    );
    defer response.deinit();

    const UserResult = struct {
        user: struct {
            name: []const u8,
            email: []const u8,
        },
    };
    const payload = try response.json(httpx.graphql.Payload(UserResult));
    if (payload.data) |data| {
        std.debug.print("User: {s} <{s}>\n", .{ data.user.name, data.user.email });
    }
    if (payload.errors) |errors| {
        for (errors) |err| std.debug.print("error: {s}\n", .{err.message});
    }
}
```

`variables` may also be a raw JSON string (`"{\"id\":\"usr_101\"}"`), and the
response body stays available untyped through `response.text()` and
`response.jsonValue()`.

---

## Server GraphQL Integration

Every GraphQL type kind is declared explicitly and reported by introspection:
objects (`Type`/`Object`), scalars, enums (`Enum`), input objects (`Input`),
interfaces (`Interface`), and unions (`Union`). Fields and arguments accept
`.list`, `.nonNull`, and `.default`, and objects opt into interfaces with
`implements(...)`.

```zig
const Scalar = httpx.graphql.Scalar;

const RoleEnum = httpx.graphql.Enum("Role", &.{ "ADMIN", "USER" });
const UserFilter = httpx.graphql.Input("UserFilter", .{ .role = RoleEnum });

const User = struct { id: []const u8, name: []const u8, role: Role };
const UserType = httpx.graphql.Type("User", .{
    .id = Scalar.id,
    .name = Scalar.string,
    .role = RoleEnum,
});

const QueryType = httpx.graphql.Query(.{
    .users = .{
        .type = UserType,
        .list = true,
        .args = .{
            .filter = UserFilter,
            .limit = .{ .type = Scalar.int, .default = "10" },
        },
        .resolve = getUsers,
    },
});
```

Mount the schema on the server and enable the bundled GraphiQL UI through the
docs configuration; the server owns the mount and tears it down in `deinit`:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .enableDocs = true,
    .docs = .{
        .graphiql = .{
            .enabled = true,
            .route = "/graphiql",
            .graphqlEndpoint = "/graphql",
            .title = "HTTPX GraphQL Explorer",
            .defaultQuery = "{ me { id name role } }",
            .editorTheme = "vs-dark",
        },
    },
});
defer server.deinit();

const schema = httpx.graphql.Schema.init(allocator, io, .{
    .query = QueryType,
    .types = &.{UserType},
    .enums = &.{RoleEnum},
    .inputs = &.{UserFilter},
});
try server.graphql(schema, .{ .endpoint = "/graphql" });

server.run();
```

## Related

* [Web: GraphQL](/web/graphql)
* [Web: Documentation UIs](/web/documentation-ui)
* [Example: GraphQL Server](/examples/graphql-server)
