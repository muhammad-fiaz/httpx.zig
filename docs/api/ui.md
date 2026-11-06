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

Each UI struct has `enabled`, `route`, and `title`, the explicit vendor options
listed below, and a raw JSON passthrough that is merged last, so any option the
bundled version supports is reachable without a library change. Options are
serialized into the page as JSON; `<`, `>`, and `&` are escaped inside inline
scripts, and invalid raw JSON fails the mount with `error.InvalidOptionsJson`.

## Swagger UI options (`SwaggerConfig`)

| Field | Type | Default | Swagger UI option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/docs"` | — |
| `title` | `[]const u8` | `"Swagger UI"` | HTML document title |
| `docExpansion` | `DocExpansion` | `.list` | `docExpansion` (`list`, `full`, `none`) |
| `deepLinking` | `bool` | `true` | `deepLinking` |
| `displayOperationId` | `bool` | `false` | `displayOperationId` |
| `displayRequestDuration` | `bool` | `false` | `displayRequestDuration` |
| `filter` | `bool` | `false` | `filter` |
| `persistAuthorization` | `bool` | `false` | `persistAuthorization` |
| `tryItOutEnabled` | `bool` | `false` | `tryItOutEnabled` |
| `defaultModelsExpandDepth` | `i32` | `1` | `defaultModelsExpandDepth` |
| `oauth2RedirectUrl` | `?[]const u8` | `null` | `oauth2RedirectUrl`; defaults to `{route}/oauth2-redirect.html` |
| `rawOptions` | `?[]const u8` | `null` | Extra options as a JSON object, merged last |

## ReDoc options (`RedocConfig`)

| Field | Type | Default | ReDoc option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/redoc"` | — |
| `title` | `[]const u8` | `"ReDoc"` | HTML document title |
| `hideHostname` | `bool` | `false` | `hideHostname` |
| `hideDownloadButton` | `bool` | `false` | `hideDownloadButton` |
| `hideFab` | `bool` | `false` | `hideFab` |
| `expandResponses` | `[]const u8` | `""` | `expandResponses`, e.g. `"200,201"` |
| `pathInMiddlePanel` | `bool` | `false` | `pathInMiddlePanel` |
| `requiredPropsFirst` | `bool` | `false` | `requiredPropsFirst` |
| `sortPropsAlphabetically` | `bool` | `false` | `sortPropsAlphabetically` |
| `noAutoAuth` | `bool` | `false` | `noAutoAuth` |
| `disableSearch` | `bool` | `false` | `disableSearch` |
| `rawOptions` | `?[]const u8` | `null` | Extra options as a JSON object, merged last |

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
| `isEditable` | `bool` | `false` | `isEditable` |
| `showSidebar` | `bool` | `true` | `showSidebar` |
| `rawConfiguration` | `?[]const u8` | `null` | Extra configuration as a JSON object, merged last |

## GraphiQL options (`GraphiQLConfig`)

| Field | Type | Default | GraphiQL option |
|---|---|---|---|
| `enabled` | `bool` | `true` | — |
| `route` | `[]const u8` | `"/graphiql"` | — |
| `graphqlEndpoint` | `[]const u8` | `"/graphql"` | Request endpoint |
| `title` | `[]const u8` | `"GraphiQL IDE"` | HTML document title |
| `defaultQuery` | `[]const u8` | `""` | Query pre-filled in the editor |
| `editorTheme` | `[]const u8` | `""` | Monaco theme, e.g. `"vs-dark"` |
| `headers` | `[]const u8` | `""` | Extra request headers as a JSON object |
| `rawOptions` | `?[]const u8` | `null` | Extra options as a JSON object, merged last |

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
    },
    .redoc = .{
        .enabled = true,
        .route = "/redoc",
        .title = "ReDoc",
        .hideDownloadButton = true,
        .requiredPropsFirst = true,
        .expandResponses = "200,201",
    },
    .scalar = .{
        .enabled = true,
        .route = "/scalar",
        .title = "Scalar API Reference",
        .theme = "default",
        .darkMode = false,
        .hideDownloadButton = true,
        .showSidebar = true,
    },
    .graphiql = .{
        .enabled = true,
        .route = "/graphiql",
        .graphqlEndpoint = "/graphql",
        .title = "GraphiQL IDE",
        .defaultQuery = "{ __typename }",
        .editorTheme = "vs-dark",
        .headers = "{\"Authorization\":\"Bearer token\"}",
    },
}, null);
```

The mount registers the OpenAPI document first, then the enabled UI pages
(`/docs`, `/redoc`, `/scalar`, `/graphiql`), plus the bundled asset paths
required by those pages. All assets are embedded and served offline; the
pages never reference a CDN.

## Raw options

Use the raw passthrough for options that are not modeled as fields:

```zig
.swagger = .{
    .route = "/docs",
    .rawOptions = "{\"displayRequestDuration\":true,\"maxDisplayedTags\":5}",
},
.scalar = .{
    .route = "/scalar",
    .rawConfiguration = "{\"withDefaultFonts\":false}",
},
```

Raw keys are merged after the typed fields, so they win on conflict. They must
be a JSON object; anything else makes the mount return
`error.InvalidOptionsJson`.

See the individual [Swagger UI](/guide/swagger-ui), [ReDoc](/guide/redoc),
[Scalar](/guide/scalar), and [GraphiQL](/guide/graphiql) guides for route and
asset behavior.
