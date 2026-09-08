# Routing

The `httpx.zig` server provides a fast, zero-allocation radix-style pattern matching router with static precedence, dynamic parameters, and catch-all wildcards.

## Basic Routing

Routes are registered directly on the `Server` instance using HTTP verb methods (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`) or the generic `add` method.

```zig
const io = std.Io.Threaded.global_single_threaded.io();
var server = try httpx.Server.init(allocator, io, .{
    .host = "0.0.0.0",
    .port = 8080,
});
defer server.deinit();

// HTTP verb helpers
try server.get("/", indexHandler);
try server.post("/users", createUserHandler);

// Custom or generic HTTP methods
try server.add(.PUT, "/users/{id}", updateUserHandler);
```

## Handling Requests

Handlers receive a `*httpx.Context` which provides access to the request attributes, headers, URL parameters, body, and response builders. Handlers can allocate temporary memory freely from `ctx.allocator` (which is reset per-request by the server).

```zig
fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.text("Hello World!");
}

fn createUserHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    // Deserialize JSON request body into a typed struct
    const UserPayload = struct { name: []const u8, email: []const u8 };
    const user = try ctx.json(UserPayload);

    // Return JSON response with status code 201 Created
    return ctx.renderJsonStatus(201, .{
        .status = "created",
        .name = user.name,
    });
}
```

## Path Parameters and Wildcards

Parameters are enclosed in `{}` curly brackets:

```zig
// Route with dynamic path parameters
try server.get("/users/{id}", getUserHandler);
try server.get("/users/{id}/posts/{post_id}", userPostHandler);

// Access parameter in handler
fn getUserHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.param("id") orelse return ctx.textStatus(400, "Missing ID");
    return ctx.renderJson(.{ .id = id, .name = "Alice" });
}

// Wildcards match remaining segments and must be at the end of the pattern
try server.get("/static/*filepath", staticHandler);

fn staticHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const filepath = ctx.param("filepath") orelse "";
    return ctx.text(filepath);
}
```

## Precedence and Routing Rules

The router evaluates patterns based on specificity score:
1. **Static / Literal segments** (`/users/me`) have highest priority.
2. **Parameter segments** (`/users/{id}`) have intermediate priority.
3. **Wildcard segments** (`/users/*rest`) match any remaining path components.

