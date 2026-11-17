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

Documentation routes are an explicit opt-in mounted on a router with
`httpx.docs.mount`. The server does not import or mount these interfaces by
default, which keeps their embedded UI assets out of applications that do not
use them. Each interface has `enabled`, `route`, and `title` fields plus
explicit, typed vendor options. Every option is a typed field with a declared
default; there is no string-based passthrough.

Each UI bundle is imported only in the compile-time branch that mounts that
interface. A ReleaseSmall measurement with Zig 0.17.0 on Windows x86_64 built
consumers that initialize `Server` and mount one docs configuration:

| Configuration | Executable size |
|---|---:|
| Documentation disabled | 680,448 bytes |
| OpenAPI JSON only | 766,464 bytes |
| Swagger UI only | 2,945,536 bytes |
| ReDoc only | 3,111,424 bytes |
| Scalar only | 5,797,888 bytes |
| GraphiQL only | 8,241,152 bytes |

Binary scans found the unique JavaScript bundle marker only in its matching
single-UI build; the OpenAPI-only and docs-disabled builds contained none of
the four bundle markers. These are representative executable sizes, not a
stable ABI or a promise about other targets or optimization modes.

OpenAPI generation and its JSON route can also be disabled independently. If
a UI remains enabled in that configuration, provide its configured OpenAPI
route from the application; Httpx skips generating an unused spec.

## Options

```zig
var server = try httpx.Server.init(allocator, io, .{});
try httpx.docs.mount(&server, .{
    .title = "My API",
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
});
defer httpx.docs.unmount(&server);
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
