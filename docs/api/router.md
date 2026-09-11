# Router API

The Router provides method-based route registration, typed parameters,
groups, mounting, named routes, URL reversing, and 404/405 dispatch —
one canonical matcher for HTTP, WebSocket, and SSE routes.

## Overview

- Static path matching, for example `/users`.
- Parameter matching with `{name}`, for example `/users/{id}`.
- Typed parameters, for example `/users/{id:int}`.
- Wildcard catch-all matching, for example `/static/{path:path}`.
- Route groups that prepend a common path prefix.

## Route Registration

```zig
try server.get("/", homePage);
try server.get("/users", listUsers);
try server.get("/users/{id:int}", getUser);
try server.post("/users", createUser);
```

### Router Methods

All router verb methods take `(path, handler, options)`:

| Method | Description |
|--------|-------------|
| `get(path, handler, .{})` | Register a GET route |
| `post(path, handler, .{})` | Register a POST route |
| `put(path, handler, .{})` | Register a PUT route |
| `delete(path, handler, .{})` | Register a DELETE route |
| `patch(path, handler, .{})` | Register a PATCH route |
| `head(path, handler, .{})` | Register a HEAD route |
| `options(path, handler, .{})` | Register an OPTIONS route |
| `add(method, path, handler, .{})` | Register any method explicitly |

Route options (`httpx.router.RouteOptions`): `.name` (reversing),
`.middleware` (route-level), `.meta` (OpenAPI), `.userData` /
`.deinitData` (handler state).

## Parameterized Paths

- Use `{name}` for single-segment parameters.
- Use `{name:converter}` for typed parameters (`int`, `uint`, `float`,
  `bool`, `uuid`, `slug`, `path`, `str`).
- Use `{path:path}` for wildcard catch-all matching.

```zig
try server.router.get("/users/{id:int}", getUser, .{});
try server.router.get("/static/{path:path}", staticHandler, .{});
```

## Route Groups

Use groups to avoid repeating a common prefix.

```zig
var api = server.router.group("/api/v1", .{});
try api.get("/users", listUsers, .{});      // /api/v1/users
try api.post("/users", createUser, .{});    // /api/v1/users
try api.patch("/users/{id:int}", patchUser, .{}); // /api/v1/users/{id:int}
```

Groups accept shared `.middleware`; `router.mount("/admin", &admin, .{})`
merges another router's routes, names, and metadata under a prefix.

## Named Routes and Reversing

```zig
try server.router.get("/users/{id:int}", getUser, .{ .name = "user" });
const url = try server.router.url("user", .{ .id = 42 }); // "/users/42"
defer allocator.free(url);
```

## Allowed Methods

When a path matches routes of other methods (the 405 case):

```zig
var methods: [9]httpx.Method = undefined;
const allowed = server.router.allowedMethods("/users/42", &methods);
// allowed: []httpx.Method, e.g. GET + POST
```

`dispatch` uses this automatically: unknown path → 404; known path with
a wrong method → 405 + `Allow` header; `OPTIONS` without an explicit
route → 204 + `Allow`.

## Middleware Note

Middleware runs router-wide (`server.use(...)`) first, then route-level
(`.{ .middleware = ... }`), then the handler. See [Middleware](/api/middleware).

## See Also

- [Routing Guide](/guide/routing)
- [Server API](/api/server)
- [Middleware API](/api/middleware)
