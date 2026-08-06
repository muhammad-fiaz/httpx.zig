//! Session Store Example
//!
//! Demonstrates httpx.zig's in-memory session management:
//! - Creating sessions with random IDs
//! - Setting and getting session data
//! - Session expiry and eviction
//! - Session deletion
//! - Integration with an HTTP server for login/logout flow

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    return (try listener.getLocalAddress()).getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Session Store Example ===\n\n", .{});

    // 1. Basic create / set / get
    std.debug.print("--- Basic CRUD ---\n", .{});

    var store = httpx.SessionStore.init(allocator, .{
        .ttl_ms = 60_000,
        .cookie_name = "sid",
    });
    defer store.deinit();

    const sid = try store.create();
    std.debug.print("Session ID (hex): {s}...\n", .{sid[0..16]});

    try store.set(&sid, "user_id", "42");
    try store.set(&sid, "role", "admin");
    try store.set(&sid, "username", "alice");

    const user_id = store.get(&sid, "user_id").?;
    defer allocator.free(user_id);
    const role = store.get(&sid, "role").?;
    defer allocator.free(role);
    const username = store.get(&sid, "username").?;
    defer allocator.free(username);
    std.debug.print("user_id:  {s}\n", .{user_id});
    std.debug.print("role:     {s}\n", .{role});
    std.debug.print("username: {s}\n", .{username});
    std.debug.print("exists:   {}\n", .{store.exists(&sid)});
    std.debug.print("count:    {d}\n\n", .{store.count()});

    // Overwrite a value
    try store.set(&sid, "role", "superadmin");
    const updated_role = store.get(&sid, "role").?;
    defer allocator.free(updated_role);
    std.debug.print("role (updated): {s}\n\n", .{updated_role});

    // 2. Multiple sessions
    std.debug.print("--- Multiple Sessions ---\n", .{});

    const sid2 = try store.create();
    try store.set(&sid2, "user_id", "99");
    const sid3 = try store.create();
    try store.set(&sid3, "user_id", "7");

    std.debug.print("Total sessions: {d}\n", .{store.count()});

    // 3. Delete
    std.debug.print("\n--- Delete ---\n", .{});
    store.delete(&sid2);
    std.debug.print("After delete - count: {d}\n", .{store.count()});
    std.debug.print("sid2 exists: {}\n\n", .{store.exists(&sid2)});

    // 4. Expiry
    std.debug.print("--- Expiry ---\n", .{});

    var short_store = httpx.SessionStore.init(allocator, .{ .ttl_ms = 50 });
    defer short_store.deinit();

    const short_sid = try short_store.create();
    try short_store.set(&short_sid, "temp", "value");
    std.debug.print("Before expiry - exists: {}\n", .{short_store.exists(&short_sid)});

    sleepMs(100); // wait for TTL to pass

    std.debug.print("After expiry  - exists: {}\n", .{short_store.exists(&short_sid)});
    const expired_val = short_store.get(&short_sid, "temp");
    if (expired_val) |v| {
        defer allocator.free(v);
        std.debug.print("After expiry  - get:    {s}\n", .{v});
    } else {
        std.debug.print("After expiry  - get:    null\n", .{});
    }

    _ = short_store.create() catch {};
    _ = short_store.create() catch {};
    sleepMs(100);
    const evicted = short_store.evictExpired();
    std.debug.print("Evicted {d} expired sessions\n\n", .{evicted});

    // 5. Server integration (login/profile/logout)
    std.debug.print("--- Server Integration ---\n", .{});

    const port = try pickFreeTcpPort();

    // Shared session store accessible by handlers via global
    const Globals = struct {
        var session_store: *httpx.SessionStore = undefined;
        var alloc: std.mem.Allocator = undefined;
    };
    Globals.session_store = &store;
    Globals.alloc = allocator;

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.post("/login", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            const new_sid = Globals.session_store.create() catch return ctx.status(500).text("error");
            Globals.session_store.set(&new_sid, "user", "alice") catch {};
            const cookie = try std.fmt.allocPrint(ctx.allocator, "sid={s}; HttpOnly; Path=/", .{new_sid});
            defer ctx.allocator.free(cookie);
            try ctx.response.headers.append("Set-Cookie", cookie);
            return ctx.json(.{ .ok = true, .session = "created" });
        }
    }.h);

    try server.get("/profile", struct {
        fn h(ctx: *httpx.Context) anyerror!httpx.Response {
            const cookie_header = ctx.cookie("sid") orelse return ctx.status(401).json(.{ .err = "no session" });
            const user = Globals.session_store.get(cookie_header, "user") orelse
                return ctx.status(401).json(.{ .err = "session not found" });
            defer ctx.allocator.free(user);
            return ctx.json(.{ .user = user, .authenticated = true });
        }
    }.h);

    const t = try server.listenInBackground();
    defer t.join();
    defer server.stop();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer client.deinit();

    const login_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/login", .{port});
    defer allocator.free(login_url);

    var login_resp = try client.post(login_url, .{});
    defer login_resp.deinit();
    std.debug.print("POST /login  -> {d} {s}\n", .{ login_resp.status.code, login_resp.text().? });

    const profile_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/profile", .{port});
    defer allocator.free(profile_url);
    var profile_resp = try client.get(profile_url, .{});
    defer profile_resp.deinit();
    std.debug.print("GET  /profile -> {d} {s}\n", .{ profile_resp.status.code, profile_resp.text().? });

    std.debug.print("\n=== Session Example Complete ===\n", .{});
}
