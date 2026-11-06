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
            .defaultQuery = "{ me { id name } }",
            .editorTheme = "vs-dark",
            .headers = "{\"Authorization\":\"Bearer token\"}",
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
| `defaultQuery` | `[]const u8` | `""` | Query pre-filled in the editor |
| `editorTheme` | `[]const u8` | `""` | Monaco theme, e.g. `"vs-dark"` |
| `headers` | `[]const u8` | `""` | Extra request headers as a JSON object string |
| `rawOptions` | `?[]const u8` | `null` | Extra options as a JSON object, merged last |

The page calls `window.renderGraphiQL(element, options)` with exactly these
options; the bundled wrapper sends every request to `graphqlEndpoint` with the
configured headers merged over `Content-Type: application/json`.
`rawOptions` is merged last:

```zig
.graphiql = .{
    .route = "/graphiql",
    .graphqlEndpoint = "/graphql",
    .rawOptions = "{\"editorTheme\":\"vs-dark\"}",
},
```

Raw keys and `headers` must form JSON objects, otherwise the mount returns
`error.InvalidOptionsJson`.

GraphiQL does not create a GraphQL endpoint. Register the endpoint separately
with the GraphQL server integration before opening the interface.

## Related documentation

- [Documentation UI API](/api/ui)
- [GraphQL guide](/guide/graphql)
- [GraphQL web API](/web/graphql)
