# Request Construction & Ergonomics

HTTPX provides two primary usage styles for client requests:

1. **Stateful `Client`**: Persistent connection pooling, TLS session resumption, and DNS caching across requests.
2. **Fluent `RequestBuilder`**: Method-chained request assembly for headers, queries, authentication, and timeouts.

---

## 1. Initialized Client & Standard Methods

Initialize a client once and reuse it across requests:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .timeoutMs = 10_000,
        .followRedirects = true,
        .maxRedirects = 5,
        .dnsCache = .{ .enable = true, .ttlMs = 60_000 },
    });
    defer client.deinit();

    // GET
    var res = try client.get("https://httpbun.com/get", .{});
    defer res.deinit();

    // POST with serialized JSON
    const User = struct { name: []const u8, role: []const u8 };
    var postRes = try client.postJson("https://httpbun.com/post", User{
        .name = "Alice",
        .role = "engineer",
    }, .{});
    defer postRes.deinit();
}
```

---

## 2. Request Options & HTTP Methods

Initialize a client once and reuse it across requests:

```zig
var client = httpx.Client.init(allocator, io, .{
    .timeoutMs = 10_000,
    .followRedirects = true,
    .maxRedirects = 5,
    .dnsCache = .{ .enable = true, .ttlMs = 60_000 },
});
defer client.deinit();

// Standard HTTP verbs (URL first, options second)
var getRes = try client.get("https://httpbun.com/get", .{});
defer getRes.deinit();

var headRes = try client.head("https://httpbun.com/head", .{});
defer headRes.deinit();

var postRes = try client.post("https://httpbun.com/post", .{
    .body = "raw data payload",
});
defer postRes.deinit();

var jsonRes = try client.postJson("https://httpbun.com/post", .{ .id = 42 }, .{});
defer jsonRes.deinit();

var putRes = try client.put("https://httpbun.com/put", .{ .body = "updated" });
defer putRes.deinit();

var patchRes = try client.patch("https://httpbun.com/patch", .{ .body = "partial" });
defer patchRes.deinit();

var delRes = try client.delete("https://httpbun.com/delete", .{});
defer delRes.deinit();

var optRes = try client.options("https://httpbun.com/options", .{});
defer optRes.deinit();
```

---

## 3. Fluent `RequestBuilder`

For advanced request assembly:

```zig
var builder = client.requestBuilder(.POST, "https://httpbun.com/post");
defer builder.deinit();

_ = try builder.header("X-Custom-Header", "Value123");
_ = try builder.headers(&.{
    .{ .name = "Accept", .value = "application/json" },
});
_ = try builder.query("page", "2");
_ = builder.timeoutMs(5000);
_ = builder.bearerAuth("bearer-jwt-token");
_ = try builder.json(.{ .user = "Alice", .active = true });

var response = try builder.send();
defer response.deinit();
```

To submit URL-encoded forms with the builder:

```zig
var formBuilder = client.postBuilder("https://httpbun.com/post");
defer formBuilder.deinit();

_ = try formBuilder.form("username=admin&password=secretpassword");
var formRes = try formBuilder.send();
defer formRes.deinit();
```

---

## 4. Streaming Uploads

Stream request payloads without buffering the entire body into memory:

```zig
var reader = httpx.SliceReader.init("streamed-chunk-data");
var streamRes = try client.requestStream("https://httpbun.com/post", .{
    .method = .POST,
    .bodySource = reader.source(),
});
defer streamRes.deinit();
```

