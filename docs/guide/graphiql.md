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
            .headers = .{ .authorization = "Bearer token" },
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
| `headers` | `GraphiQLHeaders` | `.{}` | Request headers; flat `authorization`/`cookie`/`accept` fields plus `custom` |
| `shouldPersistHeaders` | `bool` | `false` | Persist headers across reloads |
| `inputValueDeprecation` | `bool` | `false` | Show input-value deprecations |
| `schemaDescription` | `bool` | `false` | Show schema descriptions |
| `docExplorerOpen` | `bool` | `false` | Open the documentation explorer |
| `isHeadersEditorEnabled` | `bool` | `true` | Enable the headers editor |

The page calls `window.renderGraphiQL(element, options)` with exactly these
options; the bundled wrapper sends every request to `graphqlEndpoint` with the
configured headers merged over `Content-Type: application/json`:

```zig
.graphiql = .{
    .route = "/graphiql",
    .graphqlEndpoint = "/graphql",
    .editorTheme = "vs-dark",
    .headers = .{ .authorization = "Bearer token" },
},
```

GraphiQL does not create a GraphQL endpoint. Register the endpoint separately
with the GraphQL server integration before opening the interface.

## Related documentation

- [Documentation UI API](/api/ui)
- [GraphQL guide](/guide/graphql)
- [GraphQL web API](/web/graphql)
