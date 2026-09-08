# GraphQL Guide

HTTPX features full-featured GraphQL support including AST parsing, document validation, schema compilation, execution engine, introspection, and unified client-side execution.

## Client Query Execution

GraphQL operations use the standard HTTPX client with the unified `.graphql` option:

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
        \\query GetUser($id: Int!) {
        \\  user(id: $id) {
        \\    name
        \\    email
        \\  }
        \\}
    ;

    const response = try client.post("https://api.example.com/graphql", .{
        .json = .{
            .query = query,
            .variables = .{ .id = 101 },
        },
    });
    defer response.deinit();

    const UserResult = struct {
        data: struct {
            user: struct {
                name: []const u8,
                email: []const u8,
            },
        },
    };
    const parsed = try response.json(UserResult);
    std.debug.print("User: {s} <{s}>\n", .{ parsed.data.user.name, parsed.data.user.email });
}
```

---

## Server GraphQL Integration

HTTPX allows you to attach a GraphQL execution handler and serve GraphiQL interactive IDE:

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
defer server.deinit();

// GraphQL execution endpoint
server.post("/graphql", graphqlHandler);

// Interactive GraphiQL IDE
server.graphiql("/graphiql", .{
    .endpoint = "/graphql",
    .title = "HTTPX GraphQL Explorer",
});

try server.run();
```

## Related

* [Web: GraphQL](/web/graphql)
* [Web: Documentation UIs](/web/documentation-ui)
* [Example: GraphQL Server](/examples/graphql-server)
