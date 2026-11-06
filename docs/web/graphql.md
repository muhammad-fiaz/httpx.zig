# GraphQL Integration

HTTPX incorporates a high-performance GraphQL implementation in native Zig, including an AST parser, document validator, a schema builder with the full type system, an execution engine, and introspection.

## Type system

Every kind is declared explicitly, and every declared type reaches
introspection, so GraphiQL, ReDoc, and Scalar render the complete schema:

| Kind | Declaration |
|---|---|
| Object | `Type("User", .{ … })` (struct-driven) or `Object("User", &.{ … })` (string-named) |
| Scalar | `Scalar.string`, `.int`, `.float`, `.boolean`, `.id` |
| Enum | `Enum("Role", &.{ "ADMIN", "USER" })` |
| Input object | `Input("UserFilter", .{ .role = RoleEnum })` |
| Interface | `Interface("Node", .{ .id = Scalar.id })` |
| Union | `Union("SearchResult", &.{ UserType, ItemType })` |
| Modifiers | `.list = true`, `.nonNull = true` on a field or argument |

Objects opt into interfaces with `implements(Type(...), &.{Node})`. A field's
arguments are declared with `.args = .{ … }`; each argument may carry `.list`,
`.nonNull`, and a GraphQL `.default` literal.

```zig
const Scalar = httpx.graphql.Scalar;

const Role = enum { ADMIN, USER };
const RoleEnum = httpx.graphql.Enum("Role", &.{ "ADMIN", "USER" });

const UserFilter = httpx.graphql.Input("UserFilter", .{ .role = RoleEnum });
const Node = httpx.graphql.Interface("Node", .{ .id = Scalar.id });

const User = struct { id: []const u8, name: []const u8, role: Role };
const UserType = httpx.graphql.implements(
    httpx.graphql.Type("User", .{
        .id = Scalar.id,
        .name = Scalar.string,
        .role = RoleEnum,
    }),
    &.{Node},
);

/// Typed argument struct: decoded from the GraphQL arguments object.
const UsersArgs = struct {
    filter: ?struct { role: ?Role = null } = null,
    limit: u16 = 10,
};

const QueryRoot = httpx.graphql.Query(.{
    .users = .{
        .type = UserType,
        .list = true,
        .nonNull = true, // [User!]!
        .args = .{
            .filter = UserFilter,
            .limit = .{ .type = Scalar.int, .default = "10" },
        },
        .resolve = getUsers,
    },
});
```

Resolvers are `fn (*httpx.graphql.Context) !T` or
`fn (*httpx.graphql.Context, Args) !T`; the optional typed `Args` mirrors the
REST handler's body parameter. A resolver that returns a Zig enum emits the
tag name on the wire (`"ADMIN"`), never an ordinal.

## Server schema and execution

Build the schema with the same explicit allocator/`io`, then mount it on the
server. The server owns the mount and removes it in `deinit`; GraphiQL is
served by the documentation mount, which points at the same endpoint:

```zig
const std = @import("std");
const httpx = @import("httpx");

const graphqlEndpoint = "/graphql";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .port = 8080,
        .enableDocs = true,
        .docs = .{
            .graphiql = .{
                .enabled = true,
                .route = "/graphiql",
                .graphqlEndpoint = graphqlEndpoint,
                .title = "GraphiQL IDE",
                .defaultQuery = "{ me { id name role } }",
                .editorTheme = "vs-dark",
            },
        },
    });
    defer server.deinit();

    const schema = httpx.graphql.Schema.init(allocator, io, .{
        .query = QueryRoot,
        .types = &.{UserType},
        .enums = &.{RoleEnum},
        .inputs = &.{UserFilter},
        .interfaces = &.{Node},
        .enableIntrospection = true,
    });
    try server.graphql(schema, .{ .endpoint = graphqlEndpoint });

    server.run();
}
```

Types (`Type(...)`, `Object(...)`, `Enum(...)`, `Input(...)`,
`Interface(...)`, `Union(...)`, `Query(...)`, `Mutation(...)`) are built with
generic spec literals and must be declared at namespace scope.

## Introspection

`__schema { types { name kind } }` lists every scalar, object, enum, input
object, interface, and union. `__type(name: "User")` returns one type with its
fields, argument lists (including defaults), `interfaces`, `possibleTypes`,
`enumValues`, and `inputFields`. Field types are reported with correctly
nested `LIST` / `NON_NULL` wrappers, so `[User!]!`, `Role`, and
`UserFilter` all render exactly as declared in every bundled UI.

## Client execution and typed responses

A string query is executed with `Client.graphql`; the typed envelope declares
only the fields the query selected, and unknown response keys are ignored:

```zig
var response = try client.graphql(
    "https://api.example.com/graphql",
    "query { me { id name role } }",
    null,
    .{},
);
defer response.deinit();

const MeQuery = struct {
    me: struct { id: []const u8, name: []const u8, role: []const u8 },
};
const payload = try response.json(httpx.graphql.Payload(MeQuery));
if (payload.data) |data| {
    std.debug.print("{s} ({s})\n", .{ data.me.name, data.me.role });
}
if (payload.errors) |errors| {
    for (errors) |err| std.debug.print("error: {s}\n", .{err.message});
}
```

Variables may be a typed struct or a raw JSON string:

```zig
const vars = .{ .id = "usr_101" };
var typed = try client.graphql(url, query, vars, .{});
defer typed.deinit();

var raw = try client.graphql(url, query, "{\"id\":\"usr_101\"}", .{});
defer raw.deinit();

// Fully untyped: the body stays available as text or as a dynamic JSON value.
const value = try raw.jsonValue();
```

The same endpoint accepts the plain JSON form through the normal client, so
string-based REST-style calls work too:

```zig
var response = try client.post("https://api.example.com/graphql", .{
    .json = .{
        .query = "query GetUser($id: ID!) { user(id: $id) { name } }",
        .variables = .{ .id = "usr_101" },
        .operationName = "GetUser",
    },
});
defer response.deinit();
```

See `examples/graphqlServer.zig` (`zig build run-graphql-server`) for the
complete runnable version with an enum, an input object, arguments, and typed
client decoding.
