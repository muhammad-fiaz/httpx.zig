# Constructors and Options

Httpx.zig uses explicit allocators and `std.Io`. Configuration is passed as a
Zig struct literal. Use `.{}` when the type's documented defaults are wanted;
set only the fields that need to change.

Every initializer and mount accepts a partial literal and completes it into
the full config type: omitted fields take their declared defaults, nested
`.{}` configs are expanded recursively, an unknown field is a compile error,
and omitting a required field (one with no default) is a compile error. A
named anonymous literal works as well as an inline one:

```zig
const cfg = .{ .port = 0, .docs = .{ .swagger = .{ .route = "/api-docs" } } };
var server = try httpx.Server.init(allocator, io, cfg); // full Config
```

## Primary constructors

| API | Constructor | Default form |
|---|---|---|
| HTTP client | `httpx.Client.init(allocator, io, options)` | `httpx.Client.init(allocator, io, .{})` |
| HTTP server | `httpx.Server.init(allocator, io, options)` | `httpx.Server.init(allocator, io, .{})` |
| Document parser | `httpx.parsing.init(allocator, options)` | `httpx.parsing.init(allocator, .{})` |
| Connection pool | `httpx.client.pool.init(allocator, io, options)` | `...init(allocator, io, .{})` |
| Cookie jar | `httpx.client.jar.init(allocator, io)` | no options |
| Worker pool | `httpx.concurrency.Pool.init(allocator, io, options)` | pass the pool config |
| Bounded queue | `httpx.concurrency.Queue.init(allocator, io, capacity)` | capacity is required |

Every initialized value must be released with its matching `deinit()` unless
the API explicitly documents borrowed ownership.

## Client configuration

```zig
var client = httpx.Client.init(allocator, io, .{
    .timeoutMs = 10_000,
    .followRedirects = true,
    .maxRetries = 2,
    .pool = .{},
    .dnsCache = .{},
    .tls = null,
    .proxy = null,
});
defer client.deinit();
```

Client requests also take an options struct. An empty request is valid:

```zig
var response = try client.get("https://example.com/", .{});
defer response.deinit();

var jsonResponse = try client.post("https://example.com/users", .{
    .json = .{ .name = "Ada" },
});
defer jsonResponse.deinit();
```

Use the grouped parsing APIs for parsed responses:

```zig
var html = try client.html.fetch("https://example.com/", .{});
defer html.deinit();
```

See the [Client API](/api/client), [Request API](/api/request), and
[Parsing API](/api/parsing) for complete fields and return types.

## Server configuration

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 8080,
    .enableDocs = true,
});
defer server.deinit();
```

Server routes, middleware, TLS, limits, templates, static files, and
documentation UIs are configured through the same final struct literal. See
the [Server API](/api/server) and [Router API](/api/router).

## Feature entry points

| Source area | Public entry point | Reference |
|---|---|---|
| `src/client` | `httpx.Client`, `httpx.client.*` | [Client](/api/client), [Pool](/api/pool), [Downloads](/api/downloads) |
| `src/common` | `httpx.common`, `httpx.headers`, `httpx.uri`, `httpx.errors` | [Core](/api/core), [Headers](/api/headers), [Utilities](/api/utils) |
| `src/compression` | `httpx.compression` | [Compression](/api/compression) |
| `src/concurrency` | `httpx.concurrency` | [Concurrency](/api/concurrency) |
| `src/net` | `httpx.net`, `httpx.tcp`, `httpx.udp` | [Network](/api/net), [DNS](/api/dns) |
| `src/parsing` | `httpx.parsing` | [Parsing](/api/parsing) |
| `src/protocols` | `httpx.http1`, `httpx.http2`, `httpx.http3`, `httpx.quic`, `httpx.tls`, `httpx.protocols.ftp` | [Protocols](/api/protocol), [TLS](/api/tls), [FTP](/api/ftp) |
| `src/server` | `httpx.Server` | [Server](/api/server) |
| `src/web` | `httpx.web`, `httpx.router`, `httpx.middleware`, `httpx.docs` | [Router](/api/router), [Middleware](/api/middleware), [Documentation UI](/api/ui) |
| `src/utils` | `httpx.fs`, `httpx.mime` | [Utilities](/api/utils) |

The source tree also contains internal protocol engines and platform
backends. They are reachable only through the documented namespaces above;
their internal structs are not required for normal client or server use.
