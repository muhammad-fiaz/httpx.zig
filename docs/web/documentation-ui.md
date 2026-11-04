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
fields. GraphiQL also has `graphqlEndpoint`.

```zig
var server = try httpx.Server.init(allocator, io, .{
    .enableDocs = true,
    .docs = .{
        .swagger = .{ .route = "/docs" },
        .redoc = .{ .route = "/redoc" },
        .scalar = .{ .route = "/reference" },
        .graphiql = .{ .route = "/graphiql", .graphqlEndpoint = "/graphql" },
    },
});
defer server.deinit();
```

The bundles are served locally and do not require a CDN. See the
[Documentation UI API](/api/ui) for configuration types and the individual
guides for each interface.
