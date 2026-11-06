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
            .theme = "default",
            .darkMode = false,
            .hideDownloadButton = true,
            .showSidebar = true,
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
| `theme` | `[]const u8` | `"default"` | `default`, `alternate`, `moon`, `purple`, `solarized`, … |
| `darkMode` | `bool` | `false` | Force the dark palette |
| `hideModels` | `bool` | `false` | Hide the models section |
| `hideDownloadButton` | `bool` | `false` | Hide the download button |
| `hideTestRequestButton` | `bool` | `false` | Hide the “Test request” button |
| `isEditable` | `bool` | `false` | Allow editing the OpenAPI document |
| `showSidebar` | `bool` | `true` | Show the sidebar navigation |
| `rawConfiguration` | `?[]const u8` | `null` | Extra configuration as a JSON object, merged last |

The options are written into the page's `data-configuration` JSON on the
`#api-reference` element, which is how `standalone.js` reads its
configuration. `rawConfiguration` covers options that are not modeled as
fields:

```zig
.scalar = .{
    .route = "/reference",
    .rawConfiguration = "{\"withDefaultFonts\":false,\"defaultOpenAllTags\":true}",
},
```

Raw keys are merged last and must form a JSON object, otherwise the mount
returns `error.InvalidOptionsJson`.

Scalar reads the same `/openapi.json` document as Swagger UI and ReDoc.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
