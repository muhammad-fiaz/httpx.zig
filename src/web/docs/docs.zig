//! Built-in API documentation: OpenAPI generation + Swagger UI / ReDoc / Scalar.
//!
//! Quick start (every UI explicitly enabled):
//! ```zig
//! var router = httpx.Router.init(allocator);
//! try router.get("/hello", hello, .{});
//! try httpx.docs.mount(allocator, &router, .{
//!     .enabled = true,
//!     .title = "My API",
//!     .version = httpx.version,
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
//!     .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
//!     .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar API Reference" },
//!     .graphiql = .{ .enabled = true, .route = "/graphiql", .graphqlEndpoint = "/graphql", .title = "GraphiQL IDE" },
//! }, .{ .title = "My API" });
//! // GET /openapi.json  -> OpenAPI 3.1 document
//! // GET /docs          -> Swagger UI (local assets, no CDN)
//! // GET /redoc         -> ReDoc (local assets, ES module)
//! // GET /scalar        -> Scalar (local assets)
//! // GET /graphiql      -> GraphiQL IDE (local Monaco assets)
//! ```

pub const openapi = @import("../openApi/openApiSpec.zig");
pub const ui = @import("ui.zig");
pub const assets = @import("assets.zig");

pub const Config = ui.Config;
pub const Info = openapi.Info;
pub const mount = ui.mount;
pub const unmount = ui.unmount;
pub const unmountRouter = ui.unmountRouter;

test {
    _ = assets;
    _ = openapi;
    _ = ui;
}
