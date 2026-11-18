//! Route state for `httpx.testing.Server`.
//!
//! Every route is a small owned value registered with the production router.
//! The router stores the handler pointer and a `userData` pointer back to the
//! route; both stay valid until the testing server deinitializes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const handlerMod = @import("handler.zig");

pub const Route = struct {
    allocator: Allocator,
    path: []u8,
    status: u16,
    body: []u8,
    contentType: ?[]u8,
    headers: []common.Header,
    handler: ?common.Handler,
    delayMs: u32,
    /// Optional state pointer handed to `handler` as `ctx.userData`.
    userData: ?*anyopaque = null,
    requests: std.atomic.Value(usize) = .init(0),

    pub fn deinit(self: *Route) void {
        self.allocator.free(self.path);
        self.allocator.free(self.body);
        if (self.contentType) |ct| self.allocator.free(ct);
        common.freeHeaders(self.allocator, self.headers);
        self.* = undefined;
    }

    pub fn requestCount(self: *const Route) usize {
        return self.requests.load(.acquire);
    }

    /// Router handler shared by every method registered for this route.
    pub fn serve(ctx: *common.Context) anyerror!common.Response {
        const route: *Route = @ptrCast(@alignCast(ctx.userData orelse return error.MissingRouteState));
        _ = route.requests.fetchAdd(1, .monotonic);

        if (route.delayMs > 0) {
            std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(route.delayMs), .awake) catch {};
        }

        if (route.handler) |handler| {
            // The route pointer occupies `ctx.userData` for the router. Swap in
            // the caller's state for the handler, then restore so nested
            // dispatch keeps working.
            const previous = ctx.userData;
            ctx.userData = route.userData;
            defer ctx.userData = previous;
            return handlerMod.invoke(handler, ctx);
        }

        return .{
            .status = route.status,
            .body = route.body,
            .contentType = route.contentType,
            .headers = route.headers,
        };
    }
};

test "route serves its static response and counts requests" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "/hello");
    errdefer allocator.free(path);
    const body = try allocator.dupe(u8, "hello");
    errdefer allocator.free(body);
    const ct = try allocator.dupe(u8, "text/plain; charset=utf-8");
    errdefer allocator.free(ct);
    const headers = try common.dupeHeaders(allocator, &.{
        .{ .name = "x-route", .value = "yes" },
    });
    errdefer common.freeHeaders(allocator, headers);

    var route = Route{
        .allocator = allocator,
        .path = path,
        .status = 201,
        .body = body,
        .contentType = ct,
        .headers = headers,
        .handler = null,
        .delayMs = 0,
    };
    defer route.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = common.Context{ .allocator = arena.allocator(), .userData = &route };
    const res = try Route.serve(&ctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expectEqualStrings("hello", res.body);
    try std.testing.expectEqualStrings("yes", common.headerValue(res.headers, "x-route").?);
    try std.testing.expectEqual(@as(usize, 1), route.requestCount());
}
