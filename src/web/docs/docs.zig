//! Built-in API documentation: OpenAPI generation + Swagger UI / ReDoc / Scalar.
//!
//! Quick start:
//! ```zig
//! var router = httpx.Router.init(allocator);
//! try router.get("/hello", hello);
//! try httpx.docs.mount(allocator, &router, .{}, .{ .title = "My API" });
//! // GET /openapi.json  -> OpenAPI 3.1 document
//! // GET /docs          -> Swagger UI (local assets, no CDN)
//! // GET /redoc         -> ReDoc (local assets)
//! // GET /scalar        -> Scalar (opt-in via config)
//! ```

pub const openapi = @import("../openapi/spec.zig");
pub const ui = @import("ui.zig");
pub const assets = @import("assets.zig");

pub const Config = ui.Config;
pub const Info = openapi.Info;
pub const mount = ui.mount;
pub const unmount = ui.unmount;

test {
    _ = assets;
    _ = openapi;
    _ = ui;
}
