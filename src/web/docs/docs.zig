//! Built-in API documentation: OpenAPI generation + Swagger UI / ReDoc / Scalar / GraphiQL.
//!
//! Quick start (every UI explicitly enabled):
//! ```zig
//! var server = try httpx.Server.init(allocator, io, .{});
//! try server.get("/hello", hello, .{});
//! var docs = httpx.docs.init(allocator, io, &server.router);
//! try docs.mount(.{
//!     .enabled = true,
//!     .title = "My API",
//!     .version = httpx.version,
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
//!     .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
//!     .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar API Reference" },
//!     .graphiql = .{ .enabled = true, .route = "/graphiql", .graphqlEndpoint = "/graphql", .title = "GraphiQL IDE" },
//! });
//! defer docs.deinit();
//! // GET /openapi.json  -> OpenAPI 3.1 document
//! // GET /docs          -> Swagger UI (local assets, no CDN)
//! // GET /redoc         -> ReDoc (local assets, ES module)
//! // GET /scalar        -> Scalar (local assets)
//! // GET /graphiql      -> GraphiQL IDE (local Monaco assets)
//! ```

pub const openapi = @import("../openApi/spec.zig");
const ui = @import("ui.zig");

pub const Config = ui.Config;
pub const ConfigSchema = ui.ConfigSchema;
pub const Docs = ui.Docs;
/// Creates an owned documentation mount. Equivalent to `Docs.init`, exposed
/// at the namespace root so call sites read `httpx.docs.init(...)`.
pub const init = ui.Docs.init;

test {
    _ = openapi;
    _ = ui;
}
