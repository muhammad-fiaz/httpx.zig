# Core API

The Core module contains the fundamental types used throughout the library, such as Requests, Responses, Headers, and URIs.

## Request

Represents an incoming (server) or outgoing (client) HTTP request.

### `httpx.Request`

Usually constructed via `RequestBuilder` or internally by the server.

- **Fields**:
  - `method`: `Method` enum (GET, POST, etc.)
  - `uri`: `Uri` struct
  - `headers`: `Headers` struct
  - `body`: `?[]const u8`

- **Selected methods**:
  - `setBody(body)`: Set request body and Content-Length.
  - `setJson(body)`: Set JSON body and Content-Type.
  - `addQueryParam(key, value)`: Append a percent-encoded query parameter.

### `httpx.RequestBuilder`

A fluent builder for creating requests.

```zig
var builder = httpx.RequestBuilder.init(allocator);
defer builder.deinit();

var req = try builder
    .setMethod(.POST)
    .setUrl("https://api.example.com/data")
    .addHeader("Authorization", "Bearer token")
    .setJsonBody("{\"foo\":\"bar\"}")
    .build();
defer req.deinit();
```

## Response

Represents an HTTP response.

### `httpx.Response`

- **Fields**:
  - `status`: `Status` struct (code and phrase)
  - `headers`: `Headers` struct
  - `body`: `?[]const u8`

- **Methods**:
  - `ok()`: Returns true if status is 2xx.
  - `isRedirect()`: Returns true if status is 3xx.
  - `isError()`: Returns true if status is 4xx or 5xx.
  - `json(T)`: Parses body as JSON.
  - `text()`: Returns body as string.
  - `redirect(status_code, location)`: Build redirect response with `Location` header.
  - `fromText(status_code, body)`: Build text response with headers.
  - `fromJson(status_code, value)`: Build JSON response with headers.

### `httpx.ResponseBuilder`

Used server-side to construct responses.

```zig
var builder = httpx.ResponseBuilder.init(allocator);
defer builder.deinit();

var resp = try builder
    .status(200)
    .header("Custom-Header", "Val")
    .json(.{ .success = true })
    .build();
```

## Headers

A wrapper around an insertion-ordered String HashMap (or list) for HTTP headers.

- **Methods**:
  - `get(name)`: Get first value.
  - `set(name, value)`: Set/Overwrite value.
  - `append(name, value)`: Append value (for multi-value headers).
  - `remove(name)`: Remove header.

## URI

`httpx.Uri` parses and serializes URIs (RFC 3986).

```zig
const uri = try httpx.Uri.parse("https://user:pass@example.com:8080/path?query=1");
```

- **Fields**:
  - `scheme`: `http` or `https`
  - `host`: Hostname or IP
  - `port`: Explicit port or null
  - `path`: Resource path
  - `query`: Query string
  - `fragment`: Fragment identifier
