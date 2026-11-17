//! Built-in API documentation: OpenAPI generation + Swagger UI / ReDoc / Scalar.
//!
//! Quick start (every UI explicitly enabled):
//! ```zig
//! var server = try httpx.Server.init(allocator, io, .{});
//! try server.get("/hello", hello, .{});
//! try httpx.docs.mount(&server, .{
//!     .enabled = true,
//!     .title = "My API",
//!     .version = httpx.version,
//!     .openapi = .{ .enabled = true, .route = "/openapi.json" },
//!     .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
//!     .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
//!     .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar API Reference" },
//!     .graphiql = .{ .enabled = true, .route = "/graphiql", .graphqlEndpoint = "/graphql", .title = "GraphiQL IDE" },
//! });
//! defer httpx.docs.unmount(&server);
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
pub const mount = ui.mount;
pub const unmount = ui.unmount;
pub const unmountAll = ui.unmountAll;

test {
    _ = @import("assets.zig");
    _ = openapi;
    _ = ui;
}
