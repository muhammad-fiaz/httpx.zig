# Response Handling

The `httpx.router.Response` object is returned by value from client operations. The caller owns the response and must call `defer response.deinit();`.

```zig
var response = try client.get("https://httpbun.com/json", .{});
defer response.deinit();

std.debug.print("Status code: {d}\n", .{response.status});
```

## Typed JSON Deserialization

Parse response bodies directly into Zig structs:

```zig
const User = struct {
    name: []const u8,
    role: []const u8,
};

const user = try response.json(User);
```

Use quoted identifiers when JSON keys differ from ordinary Zig names:

```zig
const User = struct {
    @"user-name": []const u8,
    @"@context": []const u8,
};

const user = try response.json(User);
```

For dynamic shapes use `response.jsonValue()` and read keys from the returned
object. All decoded values are owned by the response and released by
`response.deinit()`. See [JSON typed structs](/api/data#typed-structs).

## Header Inspection

Headers are queried case-insensitively:

```zig
if (response.header("Content-Type")) |ct| {
    std.debug.print("Content-Type: {s}\n", .{ct});
}
```

## HTML & DOM Parsing

HTML responses can be parsed into a DOM document tree:

```zig
var doc = try response.html();
defer doc.deinit();

if (doc.query("h1")) |h1| {
    std.debug.print("Heading: {s}\n", .{h1.text()});
}
```
