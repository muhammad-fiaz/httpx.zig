# Routing

The `httpx.zig` server uses an intuitive, pattern-based routing mechanism.

## Basic Routing

Routes are defined on the `Server` instance using method helpers (`get`, `post`, etc.) or the generic `route` method.

```zig
var server = httpx.Server.init(allocator);

// Basic GET route
try server.get("/", indexHandler);

// POST route
try server.post("/users", createUserHandler);

// Generic route
try server.route(.PUT, "/users/1", updateUserHandler);
```

## Handling Requests

Handlers receive a `*Context` which provides access to the request and response builder.

```zig
fn indexHandler(ctx: *httpx.Context) !httpx.Response {
    return ctx.text("Hello World!");
}

fn createUserHandler(ctx: *httpx.Context) !httpx.Response {
    // Access request body
    if (ctx.request.body) |body| {
        // ... process body
    }
    return ctx.status(201).json(.{ .id = 123 });
}
```

## Path Parameters

Routes can contain dynamic parameters prefixed with `:`.

```zig
// Define route with parameter
try server.get("/users/:id", getUserHandler);

// Access parameter in handler
fn getUserHandler(ctx: *httpx.Context) !httpx.Response {
    const id = ctx.param("id") orelse return ctx.status(400).text("Missing ID");
    
    // ... fetch user by id ...
    
    return ctx.json(.{ .id = id, .name = "User" });
}
```
