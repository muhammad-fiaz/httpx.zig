# Request Construction & Options

All client operations in HTTPX follow the **URL-first** signature pattern:

```zig
const response = try client.get("https://httpbun.com/get", .{});
defer response.deinit();
```

## Options Structure

Options are passed as the second argument:

- `headers`: Slice of `.{ .name = "...", .value = "..." }`
- `query`: Key-value query parameters appended to the URL
- `body`: Raw byte slice or string
- `json`: Arbitrary Zig struct serialized to JSON
- `timeout`: Per-request timeout in milliseconds
- `cookies`: Array of cookies to include
- `auth`: Basic or Bearer authentication configuration

## Sending JSON

```zig
const payload = .{ .name = "Alice", .role = "Admin" };
var res = try client.post("https://httpbun.com/post", .{
    .json = payload,
});
defer res.deinit();
```

## Custom Headers & Query Parameters

```zig
var res = try client.get("https://httpbun.com/headers", .{
    .headers = &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-Api-Key", .value = "secret" },
    },
    .query = &.{
        .{ .name = "page", .value = "1" },
        .{ .name = "limit", .value = "25" },
    },
});
defer res.deinit();
```
