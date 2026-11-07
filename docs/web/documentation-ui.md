# Documentation UIs

Httpx.zig serves four local documentation interfaces from the embedded
`src/assets` bundles:

| Interface | Default route | Guide |
|---|---|---|
| Swagger UI | `/docs` | [Swagger UI](/guide/swagger-ui) |
| ReDoc | `/redoc` | [ReDoc](/guide/redoc) |
| Scalar | `/scalar` | [Scalar](/guide/scalar) |
| GraphiQL | `/graphiql` | [GraphiQL](/guide/graphiql) |

Swagger UI, ReDoc, and Scalar read the generated `/openapi.json` document.
GraphiQL uses the configured GraphQL endpoint.

## Shared configuration

Documentation routes are enabled by `Server.Config.enableDocs` and configured
with `Server.Config.docs`. Each interface has `enabled`, `route`, and `title`
fields plus explicit, typed vendor options. Every option is a typed field with
a declared default; there is no string-based passthrough.

## Options

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .swagger = .{
            .route = "/docs",
            .docExpansion = .full,
            .deepLinking = true,
            .displayRequestDuration = true,
            .filter = true,
            .persistAuthorization = true,
            .tryItOutEnabled = true,
            .defaultModelsExpandDepth = 2,
        },
        .redoc = .{
            .route = "/redoc",
            .hideDownloadButton = true,
            .requiredPropsFirst = true,
            .expandResponses = "200,201",
        },
        .scalar = .{
            .route = "/reference",
            .theme = "default",
            .darkMode = false,
            .hideDownloadButton = true,
            .showSidebar = true,
        },
        .graphiql = .{
            .route = "/graphiql",
            .graphqlEndpoint = "/graphql",
            .defaultQuery = "{ __typename }",
            .editorTheme = "vs-dark",
            .headers = .{ .authorization = "Bearer token" },
        },
    },
});
defer server.deinit();
```

| Interface | Modeled options |
|---|---|
| Swagger UI | `docExpansion`, `defaultModelRendering`, `defaultModelsExpandDepth`, `defaultModelExpandDepth`, `deepLinking`, `displayOperationId`, `displayRequestDuration`, `filter`, `persistAuthorization`, `tryItOutEnabled`, `showExtensions`, `showCommonExtensions`, `showMutatedRequest`, `withCredentials`, `useUnsafeMarkdown`, `requestSnippetsEnabled`, `maxDisplayedTags`, `validatorUrl`, `supportedSubmitMethods`, `oauth2RedirectUrl` |
| ReDoc | `hideHostname`, `hideDownloadButton`, `hideFab`, `hideLoading`, `hideLogo`, `hideSecuritySection`, `expandResponses`, `pathInMiddlePanel`, `requiredPropsFirst`, `sortPropsAlphabetically`, `sortEnumValuesAlphabetically`, `noAutoAuth`, `disableSearch`, `nativeScrollbars`, `onlyRequiredInSamples`, `menuToggle`, `jsonSampleExpandLevel`, `generatedPayloadSamplesMaxDepth`, `scrollYOffset` |
| Scalar | `theme`, `darkMode`, `hideModels`, `hideDownloadButton`, `hideTestRequestButton`, `hideClientButton`, `isEditable`, `showSidebar`, `showDeveloperTools`, `defaultOpenAllTags`, `telemetry`, `persistAuth`, `withDefaultFonts`, `searchHotKey`, `proxyUrl`, `customCss` |
| GraphiQL | `graphqlEndpoint`, `defaultQuery`, `editorTheme`, `headers`, `shouldPersistHeaders`, `inputValueDeprecation`, `schemaDescription`, `docExplorerOpen`, `isHeadersEditorEnabled` |

Options are emitted into each page as JSON, so every value reaches the bundled
UI rather than staying a dead field.

The bundles are served locally and do not require a CDN. See the
[Documentation UI API](/api/ui) for configuration types and the individual
guides for each interface.
