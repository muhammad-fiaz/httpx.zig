# HTML Templates & View Rendering

HTTPX supports clean server-side HTML rendering with safe escaping to prevent Cross-Site Scripting (XSS).

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

## Related

* [Web: HTML & DOM](/web/html)
* [Security: Overview](/security/overview)
