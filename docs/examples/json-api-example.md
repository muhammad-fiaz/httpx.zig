# JSON API Example

Demonstrates the simplified JSON client API for fetching and parsing typed JSON responses, plus server-side JSON handling with `ctx.jsonBody()` and `ctx.json()`.

## Overview

This example covers:
1. **Top-level `getJson`** — fetch + parse in one call
2. **`Client.getJson`** — reusable client with typed parsing
3. **`postJsonAndParse`** — POST JSON and parse response
4. **`Response.jsonBorrowed`** — manual fetch then parse
5. **Server-side JSON** — `ctx.jsonBody()` + `ctx.json()`

## Source Code

```zig
const std = @import("std");
const httpx = @import("httpx");

const ApiUser = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

const ApiResponse = struct {
    ok: bool,
    message: []const u8,
};

const HttpBunGet = struct {
    origin: []const u8,
    url: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Top-level getJson: fetch + parse in one call
    var result = httpx.getJson(HttpBunGet, "http://httpbun.com/get?name=Alice", .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("getJson failed: {}\n", .{err});
        return;
    };
    defer result.response.deinit();
    std.debug.print("origin={s}\n", .{result.value.origin});

    // 2. Client.getJson: reusable client
    var client = httpx.Client.init(allocator);
    defer client.deinit();

    var client_result = client.getJson(HttpBunGet, "http://httpbun.com/get?name=Bob", .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Client.getJson failed: {}\n", .{err});
        return;
    };
    defer client_result.response.deinit();
    std.debug.print("origin={s}\n", .{client_result.value.origin});

    // 3. postJsonAndParse: POST JSON and parse response
    var post_result = httpx.postJsonAndParse(HttpBunPost, "http://httpbun.com/post",
        \\{"name":"Charlie"}
    , .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("postJsonAndParse failed: {}\n", .{err});
        return;
    };
    defer post_result.response.deinit();
    std.debug.print("origin={s}\n", .{post_result.value.origin});

    // 4. Response.jsonBorrowed: manual fetch then parse
    var response = httpx.get("http://httpbun.com/get?name=Dave", .{}) catch |err| {
        std.debug.print("GET failed: {}\n", .{err});
        return;
    };
    defer response.deinit();

    const parsed = response.jsonBorrowed(HttpBunGet, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("jsonBorrowed failed: {}\n", .{err});
        return;
    };
    std.debug.print("origin={s}\n", .{parsed.origin});
}
```

## Server-Side JSON

```zig
fn createUserHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (!ctx.isJson()) {
        return ctx.status(415).json(.{ .ok = false, .message = "Content-Type must be application/json" });
    }

    var parsed = ctx.jsonBody(ApiUser, .{ .ignore_unknown_fields = true }) catch {
        return ctx.status(400).json(.{ .ok = false, .message = "Invalid JSON" });
    };
    defer parsed.deinit();

    // parsed.value is a typed ApiUser struct
    return ctx.json(.{ .ok = true, .message = "Created user" });
}
```

## Run

```bash
zig build run-all-json_api_example
```
