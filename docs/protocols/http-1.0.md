# HTTP/1.0 Protocol

RFC 1945 defines the foundational HTTP/1.0 protocol. HTTP/1.0 uses single-shot TCP connections where the server signals EOF by closing the connection.

## Key Characteristics

* **Connection Closure**: Connections close after each response by default; persistent Keep-Alive requires non-standard headers.
* **No Chunked Encoding**: Body framing relies entirely on the `Content-Length` header or closing the socket.
* **Optional Host Header**: Virtual hosting was not standardized in RFC 1945, though HTTPX transmits it for server compatibility.
* **No Pipeline**: Requests cannot be queued or pipelined on the same connection.

## Wire Request Example

```http
GET /index.html HTTP/1.0

Host: legacy.example.com

Connection: close



```

## Client Usage

```zig
const res = try client.get("http://legacy-host.lan/", .{
    .httpVersion = .http10,
});
defer res.deinit();

std.debug.print("Status: {d}\n", .{res.status});
```

## Related

* [Protocol: HTTP/1.1](/protocols/http-1.1)
* [Guide: Requests](/guide/requests)
