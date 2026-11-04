# GraphiQL

GraphiQL provides an interactive GraphQL editor with schema introspection,
completion, variables, and query execution.

## Default route

The default route is `/graphiql`. The default GraphQL endpoint is
`/graphql`. GraphiQL’s bundled editor scripts and Monaco worker files are
served beneath the configured route.

## Configure GraphiQL

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .graphiql = .{
            .enabled = true,
            .route = "/explorer",
            .graphqlEndpoint = "/api/graphql",
            .title = "Users GraphQL",
        },
    },
});
defer server.deinit();
```

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Register the page and editor assets |
| `route` | `[]const u8` | `"/graphiql"` | Page and asset prefix |
| `graphqlEndpoint` | `[]const u8` | `"/graphql"` | Endpoint used by the editor |
| `title` | `[]const u8` | `"GraphiQL IDE"` | HTML document title |

GraphiQL does not create a GraphQL endpoint. Register the endpoint separately
with the GraphQL server integration before opening the interface.

## Related documentation

- [Documentation UI API](/api/ui)
- [GraphQL guide](/guide/graphql)
- [GraphQL web API](/web/graphql)
