# HTML Templates & View Rendering

HTTPX ships a Jinja-compatible template engine (`httpx.templates.Engine`)
with HTML autoescaping to prevent Cross-Site Scripting (XSS). Templates are
tokenized with a Tree-sitter grammar (expressions, statements, comments),
compiled to an AST, and rendered in a separate cached pass over that AST.
Tree-sitter stays internal: user code only ever imports `httpx`.

## Template Syntax

### Variables and expressions

```html
<h1>{{ title }}</h1>
<p>Welcome, {{ user.name }} ({{ user.role }})</p>
<p>{{ items[0] }} costs {{ price * quantity }}</p>
<p>{{ user.age >= 18 }} {{ greeting ~ "!" }}</p>
```

Expressions support literals (strings, numbers, booleans, `null`/`none`,
lists, tuples `(1, 2)`, dicts), property access (`user.name`), index
access (`items[0]`, `user["name"]`), chained access, calls with positional
and keyword arguments, filters (with positional and `key=value` args),
tests, arithmetic (`+ - * / // % **`), comparisons
(`== != > >= < <=`), membership (`in`, `not in`), identity tests (`is`,
`is not`), logic (`and or not`), concatenation (`~`), parentheses,
ternary (`x if cond else y`), and calls.

Operator precedence follows Jinja/Python: `or` < `and` < `not` <
comparisons/`in`/`is` < `~` < `+ -` < `* / // %` < `**` (right-associative,
tighter than unary minus, so `-2**2 == -4` and `2**3**2 == 512`).

### Conditionals

```html
{% if showAdmin %}
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
`loop.last`, `loop.length`, `loop.revindex`, `loop.revindex0`,
`loop.depth`, and `loop.depth0` are available. `{% break %}` and
`{% continue %}` control loop flow. `{% for i in range(3) %}` iterates a
generated sequence. An `{% else %}` branch renders when the loop is empty:

```html
{% for user in users %}
  <p>{{ user.name }}</p>
{% else %}
  <p>No users.</p>
{% endfor %}
```

Loops filter inline (`{% for x in items if x.active %}`), destructure
(`{% for key, value in pairs %}`, `{% for a, b, c in rows %}`,
`{% for (k, v) in pairs %}`), iterate maps by key and strings by
character, and recurse:

```html
{% for node in tree recursive %}
  {{ node.name }}
  {% if node.kids %}<ul>{{ loop(node.kids) }}</ul>{% endif %}
{% endfor %}
```

Map helpers compose with loops: `{% for k, v in user.items() %}`.

### Variables and assignment

```html
{% set greeting = "Hello, " ~ user.name %}
<p>{{ greeting }}</p>
{% set a, b = 1, 2 %}
```

`{% set a, b = pair %}` unpacks tuples/lists pairwise.

### Inheritance and partials

```html
{% extends "base.html" %}
{% block content %}<p>Page body</p>{% endblock %}
{% include "partials/nav.html" %}
```

`super()` chains through every inheritance level. Includes support
`ignore missing`, `with`/`without context`, and computed paths:

```html
{% include "sidebar.html" ignore missing %}
{% include "ads.html" without context %}
{% include layout_name %}
```

### Imports

```html
{% import "forms.html" as forms %}
{% from "forms.html" import input as textInput %}
{{ forms.input("name") }}
```

Imported macros are isolated from template data by default; add
`with context` to share it (`{% import "m.html" as m with context %}`).

### Macros

```html
{% macro input(name, value="") %}
  <input name="{{ name }}" value="{{ value }}">
{% endmacro %}

{{ input("username")|safe }}
{{ input("role", value="admin")|safe }}
```

Macro output is escaped like any other expression; mark trusted markup
with `|safe`. Macros accept positional, defaulted, and keyword
arguments, plus `*args`/`**kwargs` collectors (with `varargs`/`kwargs`
visible inside). Same-template macros cannot see template variables
(Jinja isolation); `caller()` powers call blocks, including declared
caller parameters:

```html
{% macro wrap(cls) %}<section class="{{ cls }}">{{ caller() }}</section>{% endmacro %}
{% call(item) wrap("wide") %}<p>{{ item }}</p>{% endcall %}
```

### Filter, with, and autoescape blocks

```html
{% filter upper %}shout this{% endfilter %}
{% with total = price * qty %}{{ total }}{% endwith %}
{% autoescape false %}{{ trusted_html }}{% endautoescape %}
```

`{% apply %}` is accepted as an alias of `{% filter %}`. `{% with %}`
creates a scoped block; assignments vanish afterwards.

### Filters

```html
{{ name|trim|upper }}
{{ nickname|default("anonymous") }}
{{ tags|join(", ") }} ({{ tags|length }})
{{ bio|striptags|truncate(80) }}
{{ description|replace("old", "new") }}
{{ users|map(attribute="name")|join(", ") }}
{{ users|selectattr("age", ">", 18)|length }}
{{ data|tojson }}
```

Builtins: `abs attr batch capitalize center default dictsort escape
filesizeformat first float forceescape format groupby indent int join
last length list lower map max min pprint random reject rejectattr
replace reverse round safe select selectattr slice sort string striptags
sum title tojson trim truncate unique upper urlencode wordcount wordwrap
xmlattr` (plus `e d len count` aliases). Filter arguments may be
positional or keyword (`truncate(30, killwords=true)`). Register custom
filters once on the engine:

```zig
fn shout(alloc: std.mem.Allocator, v: httpx.templates.Value, args: []const httpx.templates.Value, kwargs: []const httpx.templates.FilterKwarg) anyerror!httpx.templates.Value {
    _ = args;
    _ = kwargs;
    const s = try alloc.dupe(u8, v.string);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = s };
}
try engine.registerFilter("shout", shout);
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
(`{%- ... -%}`, <code v-pre>{{- ... -}}</code>, `{#- ... -#}`). A dash
separated by space is not control: <code v-pre>{{ -x }}</code> keeps its
unary minus.

### Tests

```html
{% if user is defined %}...{% endif %}
{% if value is none %}...{% endif %}
{% if name is string and age is number %}...{% endif %}
{% if items is sequence and user is mapping %}...{% endif %}
{% if n is divisibleby(3) %}...{% endif %}
{% if id is in(allowed) %}...{% endif %}
```

Available tests: `defined undefined none true false boolean integer
float number string lower upper sequence mapping iterable callable
escaped odd even divisibleby eq equalto ne lt le gt ge sameas in`, plus
`is not` negation (`{% if x is not none %}`). Tests taking arguments use
call syntax as shown above.

### Undefined values

Missing variables render empty and are falsy:

```html
{{ missing }}          <!-- renders empty -->
{{ missing.name }}     <!-- renders empty, never crashes -->
{{ missing|default("anonymous") }}
```

Enable strict mode to fail loudly instead (`.strictUndefined = true` in
the engine config): missing output, conditions, iterations, and
arithmetic operands return `error.UnknownVariable`. `|default(...)` and
`is defined` keep working because they resolve before the strict check.

### Trusted raw HTML

Values are escaped by default. Bypass escaping only for trusted markup with
`templates.raw(...)`:

```zig
templates.raw("<small>&copy; 2026 HTTPX</small>")
```

or the `|safe` filter for values already known safe:

```jinja
{{ trusted_html|safe }}
```

`escape` leaves already-safe markup untouched (Jinja `Markup`
semantics); `forceescape` escapes even safe values.

### Raw blocks

```html
{% raw %}
  {{ this is emitted literally }}
{% endraw %}
```

## Server view handler

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    const ProfileHandler = struct {
        fn handle(_: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
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

## Security: HTML escaping

Template variables are HTML-escaped by default (`&` → `&amp;`, `<` → `&lt;`,
`>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`). Bypass escaping only for
trusted markup with `templates.raw(...)` (see above). Rendered output is
capped (`.maxOutputBytes`, default 64 MiB), macro nesting is bounded
(`.maxMacroDepth`), and `range()` sequences are capped
(`.maxRangeItems`).

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
macro. <code v-pre>{{ super() }}</code> renders the overridden parent block,
chaining through every inheritance level.

### Custom filters and globals

```zig
fn shout(alloc: std.mem.Allocator, v: httpx.templates.Value, args: []const httpx.templates.Value, kwargs: []const httpx.templates.FilterKwarg) anyerror!httpx.templates.Value {
    _ = args;
    _ = kwargs;
    const s = try alloc.dupe(u8, v.string);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = s };
}
try engine.registerFilter("shout", shout);

fn urlFor(_: ?*const anyopaque, alloc: std.mem.Allocator, args: []const httpx.templates.Value, kwargs: []const httpx.templates.GlobalKwarg) anyerror!httpx.templates.Value {
    _ = alloc;
    // args[0] is the route name; kwargs carry route params (id=42, ...).
    var out = std.ArrayList(u8).empty;
    // ... resolve against your router ...
    return .{ .string = try out.toOwnedSlice(alloc) };
}
try engine.addGlobal("url_for", urlFor, null);
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
`templates/index.html:14:5: unexpected endif`. Runtime failures are
recorded on `engine.lastError` with the failing node's location.

## Engine configuration and caching

```zig
var engine = try httpx.templates.Engine.init(allocator, io, .{
    .directory = "templates",
    .enableCache = true,
    .strictUndefined = true,
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

Compiled templates are cached in memory (`enableCache`). Cached renders
are safe under concurrent load, and invalidating a template evicts its
dependents without freeing ASTs under in-flight renders. Template
loading resolves safe relative paths only, blocking directory traversal
outside the template directory. Pair with the file watcher and
`engine.invalidate(path)` for hot reload during development.

## Compatibility notes

The language tracks Jinja (3.x) semantics: expression precedence,
filters, tests, loop metadata, macro scoping (macros are isolated from
template data unless imported `with context`), `super()` chains,
whitespace control, and autoescaping. Deliberate boundaries:

* `{% extends %}` paths must be string literals (no dynamic parents).
* `{% include %}` accepts a literal path or a context expression.
* Zig values convert structurally (structs, slices, arrays, optionals);
  Zig functions are not callable from templates — expose behavior
  through `addGlobal` instead.
* `{% do %}` and `{% trans %}` are not implemented.
* `format` supports `%s %d %i %u %f %c %x %X %o %%` with width,
  precision, and flags; `%e/%g` reject explicit precision.

## Related

* [Web: HTML & DOM](/web/html)
* [Security: Overview](/security/overview)
