# Documentation UI API

The documentation UI integration is exposed through `httpx.docs` and the
server's `Config.docs` field.

## Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Master switch for all documentation routes |
| `title` | `[]const u8` | `"HTTPX API"` | Page and document title |
| `version` | `[]const u8` | `httpx.version` | OpenAPI document version |
| `description` | `[]const u8` | See source default | OpenAPI document description |
| `openapi` | `OpenApiConfig` | `.{}` | OpenAPI JSON route |
| `swagger` | `SwaggerConfig` | `.{}` | Swagger UI route and options |
| `redoc` | `RedocConfig` | `.{}` | ReDoc route and options |
| `scalar` | `ScalarConfig` | `.{}` | Scalar route and options |
| `graphiql` | `GraphiQLConfig` | `.{}` | GraphiQL route, endpoint, and options |

Every UI struct has `enabled`, `route`, and `title`, plus explicit, typed
options. Options are serialized into the page as JSON; `<`, `>`, and `&` are
escaped inside inline scripts. There is no string-based option passthrough.

## Swagger UI options (`SwaggerConfig`)

| Field | Type | Default | Swagger UI option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/docs"` | — |
| `title` | `[]const u8` | `"Swagger UI"` | HTML document title |
| `docExpansion` | `DocExpansion` | `.list` | `docExpansion` (`list`, `full`, `none`) |
| `defaultModelRendering` | `DefaultModelRendering` | `.example` | `defaultModelRendering` (`example`, `model`) |
| `defaultModelsExpandDepth` | `i32` | `1` | `defaultModelsExpandDepth` |
| `defaultModelExpandDepth` | `i32` | `1` | `defaultModelExpandDepth` |
| `deepLinking` | `bool` | `true` | `deepLinking` |
| `displayOperationId` | `bool` | `false` | `displayOperationId` |
| `displayRequestDuration` | `bool` | `false` | `displayRequestDuration` |
| `filter` | `bool` | `false` | `filter` |
| `persistAuthorization` | `bool` | `false` | `persistAuthorization` |
| `tryItOutEnabled` | `bool` | `false` | `tryItOutEnabled` |
| `showExtensions` | `bool` | `false` | `showExtensions` |
| `showCommonExtensions` | `bool` | `false` | `showCommonExtensions` |
| `showMutatedRequest` | `bool` | `true` | `showMutatedRequest` |
| `withCredentials` | `bool` | `false` | `withCredentials` |
| `useUnsafeMarkdown` | `bool` | `false` | `useUnsafeMarkdown` |
| `requestSnippetsEnabled` | `bool` | `false` | `requestSnippetsEnabled` |
| `maxDisplayedTags` | `?i32` | `null` | `maxDisplayedTags`; null shows all tags |
| `validatorUrl` | `?[]const u8` | `null` | `validatorUrl`; null disables validation |
| `supportedSubmitMethods` | `[]const SubmitMethod` | `&.{}` | `supportedSubmitMethods`; empty enables every method |
| `oauth2RedirectUrl` | `?[]const u8` | `null` | `oauth2RedirectUrl`; defaults to `{route}/oauth2-redirect.html` |

`SubmitMethod` is `enum { get, put, post, delete, options, head, patch, trace }`.

## ReDoc options (`RedocConfig`)

| Field | Type | Default | ReDoc option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/redoc"` | — |
| `title` | `[]const u8` | `"ReDoc"` | HTML document title |
| `hideHostname` | `bool` | `false` | `hideHostname` |
| `hideDownloadButton` | `bool` | `false` | `hideDownloadButton` |
| `hideFab` | `bool` | `false` | `hideFab` |
| `hideLoading` | `bool` | `false` | `hideLoading` |
| `hideLogo` | `bool` | `false` | `hideLogo` |
| `hideSecuritySection` | `bool` | `false` | `hideSecuritySection` |
| `expandResponses` | `[]const u8` | `""` | `expandResponses`, e.g. `"200,201"` |
| `pathInMiddlePanel` | `bool` | `false` | `pathInMiddlePanel` |
| `requiredPropsFirst` | `bool` | `false` | `requiredPropsFirst` |
| `sortPropsAlphabetically` | `bool` | `false` | `sortPropsAlphabetically` |
| `sortEnumValuesAlphabetically` | `bool` | `false` | `sortEnumValuesAlphabetically` |
| `noAutoAuth` | `bool` | `false` | `noAutoAuth` |
| `disableSearch` | `bool` | `false` | `disableSearch` |
| `nativeScrollbars` | `bool` | `false` | `nativeScrollbars` |
| `onlyRequiredInSamples` | `bool` | `false` | `onlyRequiredInSamples` |
| `menuToggle` | `bool` | `false` | `menuToggle` |
| `jsonSampleExpandLevel` | `i32` | `2` | `jsonSampleExpandLevel` |
| `generatedPayloadSamplesMaxDepth` | `i32` | `10` | `generatedPayloadSamplesMaxDepth` |
| `scrollYOffset` | `?i32` | `null` | `scrollYOffset`; null uses the vendor default |

## Scalar options (`ScalarConfig`)

| Field | Type | Default | Scalar option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/scalar"` | — |
| `title` | `[]const u8` | `"Scalar API Reference"` | HTML document title |
| `theme` | `[]const u8` | `"default"` | `theme` (`default`, `alternate`, `moon`, `purple`, `solarized`, …) |
| `darkMode` | `bool` | `false` | `darkMode` |
| `hideModels` | `bool` | `false` | `hideModels` |
| `hideDownloadButton` | `bool` | `false` | `hideDownloadButton` |
| `hideTestRequestButton` | `bool` | `false` | `hideTestRequestButton` |
| `hideClientButton` | `bool` | `false` | `hideClientButton` |
| `isEditable` | `bool` | `false` | `isEditable` |
| `showSidebar` | `bool` | `true` | `showSidebar` |
| `showDeveloperTools` | `bool` | `false` | `showDeveloperTools` |
| `defaultOpenAllTags` | `bool` | `false` | `defaultOpenAllTags` |
| `telemetry` | `bool` | `true` | `telemetry` |
| `persistAuth` | `bool` | `false` | `persistAuth` |
| `withDefaultFonts` | `bool` | `true` | `withDefaultFonts` |
| `searchHotKey` | `[]const u8` | `"k"` | `searchHotKey` |
| `proxyUrl` | `[]const u8` | `""` | `proxyUrl`; empty omits the option |
| `customCss` | `[]const u8` | `""` | `customCss`; empty omits the option |

## GraphiQL options (`GraphiQLConfig`)

| Field | Type | Default | GraphiQL option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/graphiql"` | — |
| `graphqlEndpoint` | `[]const u8` | `"/graphql"` | Request endpoint |
| `title` | `[]const u8` | `"GraphiQL IDE"` | HTML document title |
| `defaultQuery` | `[]const u8` | `""` | Query pre-filled in the editor |
| `editorTheme` | `[]const u8` | `""` | Monaco theme, e.g. `"vs-dark"` |
| `headers` | `GraphiQLHeaders` | `.{}` | Request headers; flat `authorization`/`cookie`/`accept` fields plus `custom` |
| `shouldPersistHeaders` | `bool` | `false` | `shouldPersistHeaders` |
| `inputValueDeprecation` | `bool` | `false` | `inputValueDeprecation` |
| `schemaDescription` | `bool` | `false` | `schemaDescription` |
| `docExplorerOpen` | `bool` | `false` | `docExplorerOpen` |
| `isHeadersEditorEnabled` | `bool` | `true` | `isHeadersEditorEnabled` |

## Mounting

```zig
// Full explicit configuration: every UI is enabled with its own route and
// every option is set, so nothing depends on a hidden default.
try httpx.docs.mount(allocator, &router, .{
    .enabled = true,
    .title = "Quick Start API",
    .version = httpx.version,
    .description = "REST, GraphQL, and OpenAPI in one app",
    .openapi = .{ .enabled = true, .route = "/openapi.json" },
    .swagger = .{
        .enabled = true,
        .route = "/docs",
        .title = "Swagger UI",
        .docExpansion = .full,
        .deepLinking = true,
        .displayRequestDuration = true,
        .filter = true,
        .persistAuthorization = true,
        .tryItOutEnabled = true,
        .defaultModelsExpandDepth = 2,
        .maxDisplayedTags = 10,
        .supportedSubmitMethods = &.{ .get, .post, .put, .patch, .delete },
    },
    .redoc = .{
        .enabled = true,
        .route = "/redoc",
        .title = "ReDoc",
        .hideDownloadButton = true,
        .requiredPropsFirst = true,
        .expandResponses = "200,201",
        .jsonSampleExpandLevel = 3,
    },
    .scalar = .{
        .enabled = true,
        .route = "/scalar",
        .title = "Scalar API Reference",
        .theme = "default",
        .darkMode = false,
        .hideDownloadButton = true,
        .showSidebar = true,
        .defaultOpenAllTags = true,
    },
    .graphiql = .{
        .enabled = true,
        .route = "/graphiql",
        .graphqlEndpoint = "/graphql",
        .title = "GraphiQL IDE",
        .defaultQuery = "{ __typename }",
        .editorTheme = "vs-dark",
        .headers = .{ .authorization = "Bearer token" },
        .docExplorerOpen = true,
    },
}, null);
```

The mount registers the OpenAPI document first, then the enabled UI pages
(`/docs`, `/redoc`, `/scalar`, `/graphiql`), plus the bundled asset paths
required by those pages. All assets are embedded and served offline; the
pages never reference a CDN.

See the individual [Swagger UI](/guide/swagger-ui), [ReDoc](/guide/redoc),
[Scalar](/guide/scalar), and [GraphiQL](/guide/graphiql) guides for route and
asset behavior.
