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
fn getUser(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
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

## Compile-Time Route Validation

When routes and their patterns are known at compile time, `httpx.zig` validates them at **comptime** using Zig's type system:

```zig
const staticRoutes = [_]httpx.router.RouteDecl{
    .{ .method = .GET, .path = "/", .name = "home", .handler = homeHandler },
    .{ .method = .GET, .path = "/users", .name = "users_list", .handler = listUsers },
    .{ .method = .GET, .path = "/users/{id:int}", .name = "user_detail", .handler = getUser },
    .{ .method = .POST, .path = "/users", .handler = createUser },
    .{ .method = .GET, .path = "/files/{path:path}", .name = "files", .handler = fileHandler },
};

// Validates all routes at comptime and registers into the active router:
try server.registerStatic(&staticRoutes);
```

### Detected Conflicts:
- **Duplicate static routes**: Same HTTP method and identical path (e.g. two `GET /users`).
- **Shape collisions**: Parameter routes with ambiguous matching (e.g. `GET /users/{id}` vs `GET /users/{name}` produce identical shape `/users/{}`).
- **Wildcard collisions**: Overlapping catch-alls (e.g. `GET /files/*a` vs `GET /files/*b`).
- **Duplicate route names**: Routes sharing the same `.name` identifier for URL reversing.
- **Structural errors**: Missing leading `/`, unclosed `{...}`, empty parameter names `{}`, or misplaced catch-alls before trailing segments.

Any violation produces an actionable **`@compileError`** identifying the conflicting routes at build time.

### Runtime Route Table Registration

Dynamic routes discovered at runtime use `registerRouteTable(&routes)`, applying the identical validation logic and returning structured `RouteError.DuplicateRoute`, `RouteError.DuplicateName`, or `RouteError.InvalidPattern` without corrupting the active route table.

## File-Based Routing Conventions

`httpx.Server` serves file-based websites through its `.site` option. File
discovery, routing, and template rendering are owned by the server itself;
the filesystem directory (development) or an explicit embedded-file
manifest (production) is declared once:

```zig
var server = try httpx.Server.init(allocator, io, .{
    .site = .{ .filesystem = "dist" },
});
```

- **Static & nested**: `about/team.html` -> `/about/team`.
- **Index files**: `index.html` -> `/`, `blog/index.html` -> `/blog`.
- **Dynamic segments**: `users/[id].html` -> `/users/{id}`, `users/[id:int].html` -> `/users/{id:int}`.
- **Catch-all segments**: `files/[...path].html` -> `/files/*path`.
- **Route groups**: Directories enclosed in parentheses `(group)` organize code without altering URLs (e.g. `(marketing)/pricing.html` -> `/pricing`).
- **Ignored files & components**: Directories or files starting with `_` or `.` (e.g. `_components/card.html`, `.git/`) and layout files (`layout.html`, `_layout.html`) are excluded from page routes.
- **Validation**: All discovered file patterns pass the exact same pattern validation as code-based routes.

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

## Trailing slashes and policies

Configured via authoritative `httpx.router.TrailingSlash`:
- `.serveBoth` (default): Lenient matching accepts both `/path` and `/path/`.
- `.redirectSlash`: Permanent 301 redirect to canonical trailing slash `/path/`.
- `.redirectNoSlash`: Permanent 301 redirect to canonical non-slash `/path`.
- `.strict`: Strict exact-match policy (returns 404 on trailing slash mismatch).

Shared across code-based routing, file-based routing, and website serving.

## Typed REST Endpoints with `Server`

`httpx.Server` registers routes with the path first and an optional `.{}` options
literal second. Typed handlers return `httpx.router.Result(T)`; raw handlers return
`httpx.router.Response` and use the same verbs and metadata fields:

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
defer server.deinit();

try server.get("/users/{id:int}", .{ .handler = getUser, .summary = "Get user by ID", .tags = &.{"users"} });
try server.post("/users", .{ .handler = createUser, .summary = "Create user", .tags = &.{"users"} });
try server.put("/users/{id:int}", .{ .handler = updateUser }); // quoted JSON keys live on the struct
try server.delete("/users/{id:int}", .{ .handler = deleteUser });

// Raw handler: same lowercase verbs, no schema derivation.
try server.get("/health", .{ .handler = healthCheck, .summary = "Liveness" });
try server.use(httpx.middleware.cors);

server.run();
```

Handler signatures are `(*Context)` or `(*Context, RequestType)`, returning
`!httpx.router.Result(T)` — a plain struct literal, no constructor:

```zig
const User = struct {
    id: u64,
    @"user-name": []const u8,
    @"@context": []const u8,
};

fn getUser(ctx: *httpx.router.Context) !httpx.router.Result(User) {
    const id = ctx.paramUint("id") orelse return error.BadRequest;
    return .{ .body = .{
        .id = id,
        .@"user-name" = "alice",
        .@"@context" = "https://schema.org",
    } };
}

fn createUser(_: *httpx.router.Context, body: CreateUserRequest) !httpx.router.Result(User) {
    return .{ .status = .created, .body = .{
        .id = 101,
        .@"user-name" = body.name,
        .@"@context" = "https://schema.org",
    } };
}

fn deleteUser(_: *httpx.router.Context) !httpx.router.Result(void) {
    return .{ .status = .noContent };
}
```

Every option is optional; only what you state is used:

```zig
.{ .handler = createUser, .operationId = "createUser",
   .summary = "...", .description = "...", .tags = &.{"users"},
   .deprecated = false, .security = &.{},
   .params = &.{
       .{ .name = "id", .in = .path, .required = true, .schema = httpx.rest.schemaOf(u64) },
       .{ .name = "expand", .in = .query, .schema = httpx.rest.schemaOf(bool) },
   },
   .responses = &.{
       .{ .status = 200, .description = "User found", .schema = httpx.rest.schemaOf(User) },
       .{ .status = 404, .description = "User not found" },
   },
   .request = .{ .content = .json, .description = "User payload" },
   .internal = false,
   .mediaType = "application/vnd.api+json" }
```

JSON keys that are not Zig identifiers are declared with quoted identifiers on
the request and response structs, so `user-name`, `@context`, `Content-Type`,
and `123user` are decoded and encoded directly. See
[JSON typed structs](/api/data#typed-structs) for details.

## OpenAPI

Typed converters feed OpenAPI generation automatically: `/users/{id:int}`
emits `{id, in: path, required: true, schema: {type: integer}}` unless
`.params` documents the parameter explicitly. `.responses` replaces the
response derived from the return type, `.request` documents the JSON body, and
`.internal = true` keeps infrastructure routes out of the document.

## WebSocket and SSE

WebSocket (`/ws/{roomId}`) and SSE endpoints are plain router routes —
no separate routing engine exists.

