# Single-File Deployment (Embedded vs Filesystem Assets)

HTTPX serves static files, SPA bundles, and templates through one unified
asset system (`httpx.assets`) with two backing modes. Handler code is
identical in both modes: embedded registry hits resolve first, filesystem
second.

## Embedded Mode (.exe Carries Everything)

Register compile-time assets into the global registry at startup with
`@embedFile`, then serve normally. The produced `.exe` needs no asset
files next to it: zero disk I/O per request.

```zig
const index_html = @embedFile("static/index.html");

// Startup: logical web path -> embedded bytes (MIME auto-detected).
try httpx.assets.registerEmbedded(allocator, "index.html", index_html, null);
try httpx.assets.registerEmbedded(allocator, "greet.html", "<h1>Hello, {{ name }}!</h1>", null);

var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    // Keep the template engine alive even with no templates/ directory:
    // the loader consults the embedded registry first.
    .templates = .{ .enabled = true },
});

try server.static("/", "examples/static"); // served from memory
try server.get("/hello", hello);           // ctx.render("greet.html", ...) from memory
```

Build a release binary:

```bash
zig build -Doptimize=ReleaseFast
```

Full runnable demo: `zig build run-static-embedded`.

### Notes

- Registration keys are normalized web paths (`index.html`, `css/app.css`);
  leading slashes and backslashes are stripped.
- Each asset gets a deterministic SHA-256 ETag, so conditional requests
  keep working with zero extra code.
- `registerEmbedded` duplicates the key and ETag into the registry
  allocator: release them with `httpx.assets.globalStore(allocator).deinit()`
  on shutdown when running under a leak-checking allocator.
- The built-in docs UIs (Swagger, ReDoc, Scalar, GraphiQL) already ship
  embedded this way, so `/docs` works in a bare `.exe` too.

## Filesystem Mode (Development)

Serve straight from disk for live iteration. Pair with the file watcher and
browser live reload:

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
try server.static("/", "examples/static"); // ETag + conditional GET included
```

Full runnable demo: `zig build run-static-site`.

## Choosing a Mode

|                     | Embedded `.exe` | Filesystem |
| ------------------- | --------------- | ---------- |
| Deploy artifact     | One file        | Binary + asset tree |
| Disk I/O per hit    | None            | Per request (OS-cached) |
| Live iteration      | Rebuild         | Watcher + live reload |
| ETag / 304 support  | Yes (hash)      | Yes (mtime + size) |
| Handler API         | Identical       | Identical |

## Related

- [Static Files Guide](/guide/static-files)
- [HTML Templates](/web/templates)
- [CLI Reference](/reference/cli)
