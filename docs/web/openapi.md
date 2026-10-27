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

    var server = try httpx.Server.init(allocator, io, .{
        .port = 8080,
        .enableDocs = true,
        .docs = .{
            .title = "Inventory API",
            .version = "1.0.0",
            .description = "Automated OpenAPI generation with HTTPX",
        },
    });
    defer server.deinit();

    try server.get("/api/items", itemsHandler);

    server.run();
}

fn itemsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.renderJson(.{
        .items = [_]struct { id: u32, name: []const u8 }{
            .{ .id = 1, .name = "Widget" },
            .{ .id = 2, .name = "Gadget" },
        },
    });
}
```

## Canonical JSON Specification

Visiting `http://localhost:8080/openapi.json` returns OpenAPI 3.1.0 JSON containing:
* `openapi`: `"3.1.0"`
* `info`: Title, version, description
* `paths`: Discovered routes, methods, parameters, request bodies, and responses
* Per-operation `security` requirements when route metadata declares them

## Related

* [Web: Documentation UIs](/web/documentation-ui)
* [Guide: OpenAPI](/guide/openapi)
* [Example: OpenAPI](/examples/openapi)
