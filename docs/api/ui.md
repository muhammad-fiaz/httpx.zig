# Documentation UI API

The documentation UI integration is exposed through `httpx.docs` and the
server's `Config.docs` field.

## Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Master switch for all documentation routes |
| `title` | `[]const u8` | `"HTTPX API"` | Page and document title |
| `version` | `[]const u8` | `"0.2.0"` | OpenAPI document version |
| `description` | `[]const u8` | See source default | OpenAPI document description |
| `openapi` | `OpenApiConfig` | `.{}` | OpenAPI JSON route |
| `swagger` | `SwaggerConfig` | `.{}` | Swagger UI route and title |
| `redoc` | `RedocConfig` | `.{}` | ReDoc route and title |
| `scalar` | `ScalarConfig` | `.{}` | Scalar route and title |
| `graphiql` | `GraphiQLConfig` | `.{}` | GraphiQL route, title, and GraphQL endpoint |

Each UI configuration has an `enabled` flag, a `route`, and a `title`.
`GraphiQLConfig` also has `graphqlEndpoint`, defaulting to `/graphql`.

## Mounting

```zig
try httpx.docs.mount(allocator, &router, .{
    .title = "Users API",
    .swagger = .{ .route = "/docs" },
}, null);
```

The mount registers the OpenAPI document, enabled UI pages, and the bundled
asset paths required by those pages.

See the individual [Swagger UI](/guide/swagger-ui), [ReDoc](/guide/redoc),
[Scalar](/guide/scalar), and [GraphiQL](/guide/graphiql) guides for route and
asset behavior.
