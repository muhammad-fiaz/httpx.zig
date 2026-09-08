# OpenAPI Specification

HTTPX provides automatic OpenAPI 3.1.0 document generation directly from registered routes, type schemas, and metadata declarations.

## Route Registration & Metadata

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // Register OpenAPI specification endpoint
    server.openapi("/openapi.json", .{
        .title = "Inventory API",
        .version = "1.0.0",
        .description = "Automated OpenAPI generation with HTTPX",
    });

    // Mount Swagger UI, ReDoc, and Scalar
    server.swagger_ui("/docs", .{ .spec_url = "/openapi.json" });
    server.redoc("/redoc", .{ .spec_url = "/openapi.json" });
    server.scalar("/scalar", .{ .spec_url = "/openapi.json" });

    server.get("/api/items", struct {
        fn handle(ctx: *httpx.Context) !void {
            try ctx.json(&.{
                .{ .id = 1, .name = "Widget" },
                .{ .id = 2, .name = "Gadget" },
            });
        }
    }.handle);

    try server.run();
}
```

## Canonical JSON Specification

Visiting `http://localhost:8080/openapi.json` returns valid OpenAPI 3.1.0 JSON containing:
* `openapi`: `"3.1.0"`
* `info`: Title, version, description
* `paths`: Discovered routes, methods, and parameter schemas
* `components`: Reusable schemas and security definitions

## Related

* [Web: Documentation UIs](/web/documentation-ui)
* [Guide: OpenAPI](/guide/openapi)
* [Example: OpenAPI](/examples/openapi)
