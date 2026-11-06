# Swagger UI

Swagger UI provides an interactive OpenAPI explorer with parameter inputs and
“Try it out” request execution.

## Default route

The default route is `/docs`. It loads the generated `/openapi.json`
document and serves the bundled JavaScript, CSS, favicon, and OAuth redirect
assets beneath `/docs`.

## Configure Swagger UI

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .swagger = .{
            .enabled = true,
            .route = "/api/docs",
            .title = "Users API - Swagger",
            .docExpansion = .full,
            .deepLinking = true,
            .displayRequestDuration = true,
            .filter = true,
            .persistAuthorization = true,
            .tryItOutEnabled = true,
            .defaultModelsExpandDepth = 2,
        },
    },
});
defer server.deinit();
```

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Register the page and its assets |
| `route` | `[]const u8` | `"/docs"` | Page and asset prefix |
| `title` | `[]const u8` | `"Swagger UI"` | HTML document title |
| `docExpansion` | `DocExpansion` | `.list` | `list`, `full`, or `none` |
| `deepLinking` | `bool` | `true` | Update the URL with the active operation |
| `displayOperationId` | `bool` | `false` | Show `operationId` values |
| `displayRequestDuration` | `bool` | `false` | Show request timings |
| `filter` | `bool` | `false` | Show the operation filter box |
| `persistAuthorization` | `bool` | `false` | Keep auth data across reloads |
| `tryItOutEnabled` | `bool` | `false` | Expand “Try it out” by default |
| `defaultModelsExpandDepth` | `i32` | `1` | Model section depth; `-1` hides it |
| `oauth2RedirectUrl` | `?[]const u8` | `null` | Redirect URL; defaults to `{route}/oauth2-redirect.html` |
| `rawOptions` | `?[]const u8` | `null` | Extra options as a JSON object, merged last |

Every field is serialized into the page's `SwaggerUIBundle` options object, so
it reaches the bundled UI. `rawOptions` covers vendor options that are not
modeled as fields:

```zig
.swagger = .{
    .route = "/docs",
    .rawOptions = "{\"maxDisplayedTags\":5,\"displayRequestDuration\":true}",
},
```

Raw keys are merged last and must form a JSON object, otherwise the mount
returns `error.InvalidOptionsJson`.

The route must not conflict with an existing router route. Mounting reports a
duplicate route error instead of replacing an application route.

## Document operations

Swagger UI displays operations from the OpenAPI document. Add route metadata
with `httpx.router.metadata` before mounting the documentation routes.

```zig
const meta = httpx.router.metadata;
const User = meta.Schema{ .object = &.{
    .{ .name = "id", .schema = &meta.schemas.integer },
    .{ .name = "name", .schema = &meta.schemas.string },
} };
```

```zig
try server.router.post("/users", createUser, .{
    .meta = .{
        .summary = "Create user",
        .tags = &.{"users"},
        .request = .{ .content = .json, .schema = &User },
        .responses = &.{
            .{ .status = 201, .description = "Created", .schema = &User },
        },
    },
});
```

Mount documentation after registering application routes so the generated
spec contains those routes.

## Related documentation

- [Documentation UI API](/api/ui)
- [OpenAPI guide](/guide/openapi)
