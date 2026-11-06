# Scalar

Scalar provides a modern API reference interface backed by the generated
OpenAPI document. It includes search, schema navigation, and client code
samples.

## Default route

The default route is `/scalar`. Scalar’s bundled `standalone.js` is served
under the configured route.

## Configure Scalar

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .scalar = .{
            .enabled = true,
            .route = "/reference",
            .title = "Users API",
        },
    },
});
defer server.deinit();
```

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Register the page and bundle |
| `route` | `[]const u8` | `"/scalar"` | Page and asset prefix |
| `title` | `[]const u8` | `"Scalar API Reference"` | HTML document title |

Scalar reads the same `/openapi.json` document as Swagger UI and ReDoc.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
