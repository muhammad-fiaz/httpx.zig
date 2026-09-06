# Router API

The Router provides method-based route registration, parameterized path matching, wildcard matching, and prefixed route groups.

## Overview

- Static path matching, for example `/users`.
- Parameter matching with `:name`, for example `/users/:id`.
- Wildcard catch-all matching with `*`, for example `/static/*`.
- Route groups that prepend a common path prefix.

## Route Registration

```zig
try server.get("/", homePage);
try server.get("/users", listUsers);
try server.get("/users/:id", getUser);
try server.post("/users", createUser);
```

### Router Methods

| Method | Description |
|--------|-------------|
| `get(path, handler)` | Register a GET route |
| `post(path, handler)` | Register a POST route |
| `put(path, handler)` | Register a PUT route |
| `delete(path, handler)` | Register a DELETE route |
| `del(path, handler)` | Alias for DELETE |
| `patch(path, handler)` | Register a PATCH route |
| `head(path, handler)` | Register a HEAD route |
| `options(path, handler)` | Register an OPTIONS route |
| `trace(path, handler)` | Register a TRACE route |
| `connect(path, handler)` | Register a CONNECT route |
| `add(method, path, handler)` | Register any method explicitly |

## Parameterized Paths

- Use `:name` for single-segment parameters.
- Use `*` for wildcard catch-all matching.

```zig
try server.get("/users/:id", getUser);
try server.get("/static/*", staticHandler);
```

## Route Groups

Use groups to avoid repeating a common prefix.

```zig
var api = server.router.group("/api/v1");
try api.get("/users", listUsers);      // /api/v1/users
try api.post("/users", createUser);    // /api/v1/users
try api.patch("/users/:id", patchUser); // /api/v1/users/:id
try api.trace("/diag", diagnostics);   // /api/v1/diag
```

RouteGroup exposes the same method helpers as Router: `get/post/put/delete/del/patch/head/options/trace/connect` plus `add`.

## Allowed Methods

When a route path exists for multiple methods, you can query which methods are valid for a concrete path:

```zig
var methods: [16]httpx.Method = undefined;
const n = server.router.allowedMethods("/users/42", &methods);
_ = n;
```

## Middleware Note

Middleware is configured at the Server level via `server.use(...)` and runs before route handlers.

## See Also

- [Server API](/api/server)
- [Middleware API](/api/middleware)

