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
| `hideClientButton` | `bool` | `false` | Hide the client button |
| `isEditable` | `bool` | `false` | Allow editing the OpenAPI document |
| `showSidebar` | `bool` | `true` | Show the sidebar navigation |
| `showDeveloperTools` | `bool` | `false` | Show developer tools |
| `defaultOpenAllTags` | `bool` | `false` | Expand every tag by default |
| `telemetry` | `bool` | `true` | Enable anonymous telemetry |
| `persistAuth` | `bool` | `false` | Persist authentication data |
| `withDefaultFonts` | `bool` | `true` | Load bundled default fonts |
| `searchHotKey` | `[]const u8` | `"k"` | Search hotkey |
| `proxyUrl` | `[]const u8` | `""` | Proxy URL for try-it-out requests |
| `customCss` | `[]const u8` | `""` | Custom CSS injected into the page |

The options are written into the page's `data-configuration` JSON on the
`#api-reference` element, which is how `standalone.js` reads its
configuration:

```zig
.scalar = .{
    .route = "/reference",
    .withDefaultFonts = false,
    .defaultOpenAllTags = true,
},
```

Scalar reads the same `/openapi.json` document as Swagger UI and ReDoc.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
