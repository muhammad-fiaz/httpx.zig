# HTML Templates & View Rendering

HTTPX ships a native template engine (`httpx.templates.Engine`, also
available as `httpx.Templates`) with HTML autoescaping to prevent
Cross-Site Scripting (XSS).

## Template Syntax

### Variables

```html
<h1>{{ title }}</h1>
<p>Welcome, {{ user.name }} ({{ user.role }})</p>
```

### Conditionals

```html
{% if show_admin %}
  <p>Admin panel</p>
{% else %}
  <p>Guest view</p>
{% endif %}
```

### Loops

```html
<ul>
{% for item in items %}
  <li>#{{ loop.index }}: {{ item }}</li>
{% endfor %}
</ul>
```

Inside a loop, `loop.index` (1-based), `loop.first`, `loop.last`, and
`loop.length` are available.

### Inheritance and Partials

```html
{% extends "base.html" %}
{% block content %}<p>Page body</p>{% endblock %}
{% include "partials/nav.html" %}
```

### Trusted Raw HTML

Values are escaped by default. Bypass escaping only for trusted markup with
`templates.raw(...)`:

```zig
templates.raw("<small>&copy; 2026 HTTPX</small>")
```

## Server View Handler

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

    const ProfileHandler = struct {
        fn handle(_: *httpx.Context) anyerror!httpx.Response {
            const username = "Jane Doe";
            var page_buf: [1024]u8 = undefined;
            const html_page = try std.fmt.bufPrint(&page_buf,
                \\<!DOCTYPE html>
                \\<html>
                \\<head><title>Profile</title></head>
                \\<body>
                \\  <h1>Welcome, {s}!</h1>
                \\</body>
                \\</html>
            , .{username});

            return .{
                .status = 200,
                .body = html_page,
                .content_type = "text/html; charset=utf-8",
            };
        }
    };
    try server.get("/profile", ProfileHandler.handle);

    server.run();
}
```

## Security: HTML Escaping

Always escape dynamic values injected into HTML templates using `httpx.html.escape`:

```zig
const untrusted_input = "<script>alert('xss')</script>";
const safe_escaped = try httpx.html.escape(allocator, untrusted_input);
defer allocator.free(safe_escaped);
// Produces: &lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;
```

## Engine Configuration and Caching

```zig
var engine = try httpx.templates.Engine.init(allocator, io, .{
    .directory = "templates",
    .enableCache = true,
});
defer engine.deinit();

// Render a template file with data
try engine.render("index.html", .{ .title = "Hello" }, &writer);

// Or render an in-memory string
try engine.renderString("<h1>{{ title }}</h1>", .{ .title = "Hello" }, &writer);
```

Compiled templates are cached in memory (`enableCache`). Template loading
resolves safe relative paths only, blocking directory traversal outside the
template directory. Pair with the file watcher and `engine.invalidate(path)`
for hot reload during development.

## Related

* [Web: HTML & DOM](/web/html)
* [Security: Overview](/security/overview)
* [CLI Reference](/reference/cli)
