//! Browser-side live reload.
//!
//! The browser half of the watcher. The server announces changes over a
//! Server-Sent Events stream and this is the client that acts on it, so hot,
//! warm and cold reloads all behave the same way whether the page came from
//! the static file handler, the site generator, or a plain `Context.html`
//! handler.
//!
//! The stream carries two payloads, matching `ReloadStrategy`:
//!
//!   * `hotReload` - only stylesheets changed. The existing `<link>` elements
//!     get a cache-busting query so the sheet is refetched in place, and no
//!     script state is lost.
//!   * `reload` - anything else (templates, HTML, config, sources). The
//!     document is reloaded so the server re-renders it.
//!
//! Two rules keep this from fighting itself:
//!
//!   * The first event after a connect is ignored. The server publishes the
//!     current event id immediately on connect, and acting on it would
//!     reload the page once per connect.
//!   * `onerror` never reloads. `EventSource` reconnects on its own, so
//!     reloading there loops forever while the server is down.

const std = @import("std");

/// Marks an injected script so a second injection is a no-op.
pub const marker = "httpx-live-reload";

/// The client script, subscribed to `sseUrl`.
pub fn liveReloadScript(allocator: std.mem.Allocator, sseUrl: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<script id="{s}">(function() {{
        \\  var lastId = null;
        \\  var es = new EventSource("{s}");
        \\  es.onmessage = function(e) {{
        \\    var id = e.lastEventId || null;
        \\    if (id === null || id === lastId) return;
        \\    var first = (lastId === null);
        \\    lastId = id;
        \\    if (first) return;
        \\    if (e.data === "hotReload") {{
        \\      var links = document.querySelectorAll('link[rel="stylesheet"]');
        \\      for (var i = 0; i < links.length; i++) {{
        \\        var url = new URL(links[i].href, window.location.href);
        \\        url.searchParams.set('_httpx_t', Date.now());
        \\        links[i].href = url.href;
        \\      }}
        \\    }} else {{
        \\      location.reload();
        \\    }}
        \\  }};
        \\}})();</script>
    , .{ marker, sseUrl });
}

/// True when `body` already carries the client script.
pub fn isInjected(body: []const u8) bool {
    return std.mem.indexOf(u8, body, marker) != null;
}

/// Returns `body` with the client script appended, or unchanged when it is
/// already there. The script goes just before `</body>` so it does not
/// invalidate any preceding relative-URL resolution.
pub fn inject(allocator: std.mem.Allocator, body: []const u8, sseUrl: []const u8) ![]const u8 {
    if (isInjected(body)) return body;
    const script = try liveReloadScript(allocator, sseUrl);
    defer allocator.free(script);
    if (std.mem.indexOf(u8, body, "</body>")) |at| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ body[0..at], script, body[at..] });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ body, script });
}

test "script subscribes to the configured endpoint" {
    const a = std.testing.allocator;
    const script = try liveReloadScript(a, "/__httpx_liveReload");
    defer a.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "new EventSource(\"/__httpx_liveReload\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "hotReload") != null);
    try std.testing.expect(isInjected(script));
}

test "injection places the script before the closing body tag" {
    const a = std.testing.allocator;
    const injected = try inject(a, "<html><body><h1>hi</h1></body></html>", "/sse");
    defer a.free(injected);

    const scriptAt = std.mem.indexOf(u8, injected, marker).?;
    const bodyEnd = std.mem.indexOf(u8, injected, "</body>").?;
    try std.testing.expect(scriptAt < bodyEnd);
    try std.testing.expect(std.mem.startsWith(u8, injected, "<html><body><h1>hi</h1>"));
}

test "injection appends when there is no body tag" {
    const a = std.testing.allocator;
    const injected = try inject(a, "<h1>fragment</h1>", "/sse");
    defer a.free(injected);

    try std.testing.expect(std.mem.startsWith(u8, injected, "<h1>fragment</h1>"));
    try std.testing.expect(isInjected(injected));
}

test "injection is idempotent" {
    const a = std.testing.allocator;
    const once = try inject(a, "<html></html>", "/sse");
    defer a.free(once);
    const twice = try inject(a, once, "/sse");

    // Same slice, not a second copy: the second call must not allocate.
    try std.testing.expectEqual(once, twice);
}
