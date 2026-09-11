# Routing

The `httpx.zig` server provides a fast framework-grade router: patterns
compile once at registration (segments, converters, specificity), and
matching borrows path slices with no per-request parsing. One matcher
serves HTTP, WebSocket, and SSE routes.

## Basic Routing

Routes are registered on the `Server` with verb helpers, or on a
`Router` with full options:

```zig
try server.get("/", indexHandler);
try server.post("/users", createUserHandler);
try server.router.get("/users/{id:int}", getUserHandler, .{
    .name = "user",
});
```

## Canonical syntax

One grammar — `{...}` only (no `:id` legacy form):

```zig
/users                // static
/users/{id}           // generic parameter (one segment)
/users/{id:int}       // typed parameter
/blog/{slug:slug}     // slug
/files/{path:path}    // catch-all (remaining segments, must be last)
```

Converters: `str` (default) | `string` | `int` | `uint` | `float` |
`bool` | `uuid` | `slug` | `path`. Unknown converters, empty names,
duplicate names, and misplaced catch-alls fail at registration.

## Typed parameters

Converters validate at match time, so more specific routes win
deterministically and handlers get real types:

```zig
fn getUser(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.paramInt("id") orelse return ctx.textStatus(400, "bad id");
    // ...use id: i64...
}

// Optional struct binding (Level 2) — plain param() stays simple:
const Params = struct { userId: u64, postId: u64 };
const p = try ctx.bindParams(Params); // MissingParam / InvalidParamValue
```

`paramInt`, `paramUint`, `paramFloat`, `paramBool` are available;
`uuid`/`slug` validate and return the borrowed string. Optional struct
fields (`?u64`, defaulted fields) tolerate missing parameters.

## Slugs and catch-all paths

```zig
try server.router.get("/blog/{slug:slug}", postHandler, .{});
// matches /blog/hello-world, rejects /blog/Hello-World, /blog/-lead

try server.router.get("/files/{path:path}", fileHandler, .{});
// matches /files/a.txt and /files/docs/api/v1/index.html
```

## Nested routes and groups

```zig
const api = server.router.group("/api", .{});
const users = api.group("/users", .{});
try users.get("/", listUsers, .{});
try users.get("/{id:int}", getUser, .{});
// → /api/users and /api/users/{id:int}; parent params stay visible.
```

Groups share a prefix (and optional middleware) without string
concatenation. `router.mount("/admin", &adminRouter, .{})` merges
another router's methods, names, metadata, and parameters.

## Named routes and reversing

```zig
try server.router.get("/users/{id:int}", getUser, .{ .name = "user" });
const url = try server.router.url("user", .{ .id = 42 }); // "/users/42"
defer allocator.free(url);
```

Missing, unknown, or invalid values are errors — never silent bad URLs.

## Conflicts and priority

- `/users/{id}` vs `/users/{name}` → registration error (`DuplicateRoute`).
- `/users/me` (static) beats `/users/{id:int}` (typed) beats
  `/users/{name}` (generic) beats `/files/*rest` (wildcard).
- Equal-specificity ties keep the first registered route (documented;
  prefer unambiguous patterns).

## 404 vs 405

A path matching no route returns 404. A path matching another method
returns **405 with an `Allow` header** (e.g. `Allow: GET, POST`).
`OPTIONS` without an explicit route returns `204` + `Allow`.
`HEAD` falls back to the `GET` handler (transports strip the body).

## Middleware

Order is deterministic: router middleware → route middleware → handler.

```zig
try server.use(loggingMw);                                   // router-wide
try server.router.get("/m", handler, .{ .middleware = &.{authMw} }); // route-level
```

## Query parameters

Path and query stay separate: `/users/42?page=2` gives `param("id")`
plus `queryParam("page")`. Never put query strings in patterns.

## Trailing slashes and normalization

Matching is lenient: `/users` and `/users/` (even `//users//`) match the
same pattern. Query strings and fragments are stripped before matching.

## OpenAPI

Typed converters feed OpenAPI generation automatically: `/users/{id:int}`
emits `{id, in: path, required: true, schema: {type: integer}}` unless
`meta.params` documents the parameter explicitly.

## WebSocket and SSE

WebSocket (`/ws/{roomId}`) and SSE endpoints are plain router routes —
no separate routing engine exists.
