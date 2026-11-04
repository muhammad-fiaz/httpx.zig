# Authentication API

Authentication helpers are available under `httpx.auth` and as request
options on `httpx.Client`.

## Client request authentication

```zig
var response = try client.get("https://api.example.com/profile", .{
    .bearerAuth = "token-value",
});
defer response.deinit();
```

```zig
var response = try client.get("https://api.example.com/admin", .{
    .basicAuth = "username:password",
});
defer response.deinit();
```

`bearerAuth` creates a Bearer `Authorization` value. `basicAuth` accepts a
`username:password` value and creates Basic authentication.

## Helper namespaces

| Namespace | Purpose |
|---|---|
| `httpx.auth.basic` | Basic authentication encoding and decoding helpers |
| `httpx.auth.bearer` | Bearer token parsing and validation helpers |

Use the request options for ordinary client calls. Use the helper namespaces
when an application needs to validate or construct credentials independently
of a request.

## Related documentation

- [Authentication guide](/guide/authentication)
- [Request API](/api/request)
- [Security overview](/security/overview)
