# ReDoc

ReDoc presents the generated OpenAPI document as a readable, schema-focused
reference with a navigable endpoint tree.

## Default route

The default route is `/redoc`. The page loads the generated
`/openapi.json` document and serves the bundled ReDoc script and related
assets beneath the configured route.

## Configure ReDoc

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .redoc = .{
            .enabled = true,
            .route = "/reference",
            .title = "Users API Reference",
        },
    },
});
defer server.deinit();
```

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Register the page and its assets |
| `route` | `[]const u8` | `"/redoc"` | Page and asset prefix |
| `title` | `[]const u8` | `"ReDoc"` | HTML document title |

ReDoc is read-only. Use Swagger UI when interactive request execution is
required.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
