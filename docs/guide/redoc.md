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
            .hideDownloadButton = true,
            .requiredPropsFirst = true,
            .sortPropsAlphabetically = true,
            .expandResponses = "200,201",
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
| `hideHostname` | `bool` | `false` | Hide the API hostname |
| `hideDownloadButton` | `bool` | `false` | Hide the OpenAPI download button |
| `hideFab` | `bool` | `false` | Hide the floating action button |
| `hideLoading` | `bool` | `false` | Hide the loading indicator |
| `hideLogo` | `bool` | `false` | Hide the ReDoc logo |
| `hideSecuritySection` | `bool` | `false` | Hide the security section |
| `expandResponses` | `[]const u8` | `""` | Status codes expanded by default, e.g. `"200,201"` |
| `pathInMiddlePanel` | `bool` | `false` | Show the endpoint path in the middle panel |
| `requiredPropsFirst` | `bool` | `false` | List required properties first |
| `sortPropsAlphabetically` | `bool` | `false` | Sort properties alphabetically |
| `sortEnumValuesAlphabetically` | `bool` | `false` | Sort enum values alphabetically |
| `noAutoAuth` | `bool` | `false` | Disable automatic auth section |
| `disableSearch` | `bool` | `false` | Disable the search box |
| `nativeScrollbars` | `bool` | `false` | Use native scrollbars |
| `onlyRequiredInSamples` | `bool` | `false` | Show only required fields in samples |
| `menuToggle` | `bool` | `false` | Show the menu toggle |
| `jsonSampleExpandLevel` | `i32` | `2` | Default JSON sample depth |
| `generatedPayloadSamplesMaxDepth` | `i32` | `10` | Maximum generated sample depth |
| `scrollYOffset` | `?i32` | `null` | Scroll offset; null uses the vendor default |

Options are passed as the second argument of `init(specUrl, options, element)`:

```zig
.redoc = .{
    .route = "/reference",
    .hideDownloadButton = true,
    .jsonSampleExpandLevel = 3,
},
```

ReDoc is read-only. Use Swagger UI when interactive request execution is
required.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
