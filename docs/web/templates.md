# HTML Templates & View Rendering

HTTPX ships a Flask/Jinja-style template engine (`httpx.templates.Engine`,
also available as `httpx.Templates`) with HTML autoescaping to prevent
Cross-Site Scripting (XSS). Templates are tokenized with a Tree-sitter
grammar (expressions, statements, comments) and compiled to an AST;
rendering is a separate cached pass over that AST.

## Template Syntax

### Variables and expressions

```html
<h1>{{ title }}</h1>
<p>Welcome, {{ user.name }} ({{ user.role }})</p>
<p>{{ items[0] }} costs {{ price * quantity }}</p>
<p>{{ user.age >= 18 }} {{ greeting ~ "!" }}</p>
```

Expressions support literals (strings, numbers, booleans, `null`/`none`,
lists, dicts), property access (`user.name`), index access (`items[0]`,
`user["name"]`), arithmetic (`+ - * / // %`), comparisons
(`== != > >= < <=`), membership (`in`), logic (`and or not`),
parentheses, ternary (`x if cond else y`), and calls.

### Conditionals

```html
{% if show_admin %}
  <p>Admin panel</p>
{% elif is_member %}
  <p>Member view</p>
{% else %}
  <p>Guest view</p>
{% endif %}
```

### Loops

```html
<ul>
{% for item in items %}
  <li>#{{ loop.index }}: {{ item }}</li>
  {% if loop.last %}<hr>{% endif %}
{% endfor %}
</ul>
```

Inside a loop, `loop.index` (1-based), `loop.index0`, `loop.first`,
`loop.last`, and `loop.length` are available. `{% break %}` and
`{% continue %}` control loop flow. `{% for i in range(3) %}` iterates a
generated sequence.

### Variables and assignment

```html
{% set greeting = "Hello, " ~ user.name %}
<p>{{ greeting }}</p>
```

### Inheritance and Partials

```html
{% extends "base.html" %}
{% block content %}<p>Page body</p>{% endblock %}
{% include "partials/nav.html" %}
```

### Macros

```html
{% macro input(name, value="") %}
  <input name="{{ name }}" value="{{ value }}">
{% endmacro %}

{{ input("username")|safe }}
{{ input("role", value="admin")|safe }}
```

Macro output is escaped like any other expression; mark trusted markup
with `|safe`.

### Filters

```html
{{ name|trim|upper }}
{{ nickname|default("anonymous") }}
{{ tags|join(", ") }} ({{ tags|length }})
{{ bio|striptags|truncate(80) }}
{{ description|replace("old", "new") }}
```

Builtins: `upper lower trim capitalize title escape safe default length
join first last replace truncate striptags int float string abs round`
(plus `e d len count` aliases). Register custom filters once on the
engine:

```zig
try engine.registerFilter("shout", myFilterFn);
```

### Whitespace control

```html
<ul>
  {%- for item in items -%}
    <li>{{ item }}</li>
  {%- endfor -%}
</ul>
```

A `-` adjacent to a delimiter strips surrounding whitespace
(`{%- ... -%}`, `{{- ... -}}`, `{#- ... -#}`).

### Tests

```html
{% if user is defined %}...{% endif %}
{% if value is none %}...{% endif %}
{% if name is string and age is number %}...{% endif %}
{% if items is sequence and user is mapping %}...{% endif %}
```

Available tests: `defined undefined none string number boolean sequence
mapping callable`, plus `is not` negation (`{% if x is not none %}`).

### Undefined values

Missing variables render empty and are falsy:

```html
{{ missing }}          <!-- renders empty -->
{{ missing.name }}     <!-- renders empty, never crashes -->
{{ missing|default("anonymous") }}
```

Enable strict mode to fail loudly instead (`.strictUndefined = true` in
the engine config): rendering an undefined value returns
`error.UnknownVariable`. `|default(...)` still rescues missing values
because the filter runs before the strict check.

### Trusted Raw HTML

Values are escaped by default. Bypass escaping only for trusted markup with
`templates.raw(...)`:

```zig
templates.raw("<small>&copy; 2026 HTTPX</small>")
```

or the `|safe` filter for values already known safe:

```jinja
{{ trusted_html|safe }}
```

### Raw blocks

```html
{% raw %}
  {{ this is emitted literally }}
{% endraw %}
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
                .contentType = "text/html; charset=utf-8",
            };
        }
    };
    try server.get("/profile", ProfileHandler.handle);

    server.run();
}
```

## Security: HTML Escaping

Template variables are HTML-escaped by default (`&` → `&amp;`, `<` → `&lt;`,
`>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`). Bypass escaping only for
trusted markup with `templates.raw(...)` (see above).

### Set blocks, call blocks, and super

```html
{% set card %}<div class="card">{{ body }}</div>{% endset %}
{{ card }}

{% macro wrap(cls) %}<section class="{{ cls }}">{{ caller() }}</section>{% endmacro %}
{% call wrap("wide") %}<p>Content</p>{% endcall %}

{% extends "base.html" %}
{% block content %}{{ super() }}<p>More</p>{% endblock %}
```

`{% set name %}...{% endset %}` captures rendered markup (safe HTML).
`{% call %}` renders its body and exposes it as `caller()` inside the
macro. `{{ super() }}` renders the overridden parent block.

### Custom filters and globals

```zig
fn shout(_: ?*const anyopaque, alloc: std.mem.Allocator, v: httpx.templates.Value, args: []const httpx.templates.Value) anyerror!httpx.templates.Value {
    _ = args;
    const s = try alloc.dupe(u8, v.string);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = s };
}
try engine.registerFilter("shout", shout);

fn urlFor(router_ptr: ?*const anyopaque, alloc: std.mem.Allocator, args: []const httpx.templates.Value, kwargs: []const httpx.templates.GlobalKwarg) anyerror!httpx.templates.Value {
    const router: *httpx.Router = @ptrCast(@alignCast(@constCast(router_ptr.?)));
    const route_name = args[0].string;
    const url = try router.url(route_name, .{ .id = 42 });
    defer router.allocator.free(url);
    return .{ .string = try alloc.dupe(u8, url) };
}
try engine.addGlobal("url_for", urlFor, router_ptr);
```

```jinja
<a href="{{ url_for("user-profile", id=user.id) }}">Profile</a>
```

One mechanism covers both: `registerFilter` for `value|name` pipelines,
`addGlobal` for `name(args)` callables. Macros and `range()` resolve
before globals.

### Inheritance cycles and error locations

Cyclic `{% extends %}` chains fail with `error.CircularInheritance`.
Syntax errors carry `template:line:column` locations, e.g.
`templates/index.html:14:5: unexpected endif`.

## Engine Configuration and Caching

```zig
var engine = try httpx.templates.Engine.init(allocator, io, .{
    .directory = "templates",
    .enableCache = true,
});
defer engine.deinit();

// Render a template file with data into any writer
var list = std.ArrayList(u8).empty;
defer list.deinit(allocator);
var lw = httpx.templates.renderer.ListWriter{ .list = &list, .allocator = allocator };
try engine.render("index.html", .{ .title = "Hello" }, &lw);

// Or render an in-memory string
try engine.renderString("<h1>{{ title }}</h1>", .{ .title = "Hello" }, &lw);
```

Compiled templates are cached in memory (`enableCache`). Template loading
resolves safe relative paths only, blocking directory traversal outside the
template directory. Pair with the file watcher and `engine.invalidate(path)`
for hot reload during development.

## Related

* [Web: HTML & DOM](/web/html)
* [Security: Overview](/security/overview)
