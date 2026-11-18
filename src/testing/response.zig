//! Response configuration for `httpx.testing.Server.route`.
//!
//! A route is either a static response (status, headers, body) or a dynamic
//! handler. Static strings are copied when the route is registered, so they
//! may be literals, stack buffers, or arena-backed slices.

const std = @import("std");
const z = @import("zigantic");
const common = @import("common.zig");
const handlerMod = @import("handler.zig");

/// Schema for a value zigantic cannot inspect structurally (function
/// pointers, slices of runtime types). Type-checked only, matching the
/// production schemas.
fn typedSchema(comptime T: type) type {
    return z.custom(T, .{ .check = struct {
        fn accept(_: T) bool {
            return true;
        }
    }.accept });
}

const RouteOptionsSchema = z.objectOf(.{
    // Method used when `.methods` is empty.
    .method = z.withDefault(z.enumType(common.Method, .{}), .GET),
    // Register the same response for several methods. When non-empty this
    // takes precedence over `.method`.
    .methods = z.withDefault(z.array(z.enumType(common.Method, .{}), .{}), &.{}),
    // Defaults to `200 OK`.
    .status = z.withDefault(z.integer(u16, .{ .min = 100, .max = 599 }), 200),
    // Response body. Copied at registration; ignored when `.handler` is set.
    .body = z.withDefault(z.string(.{}), ""),
    // Optional `Content-Type`; omitted means the transport writes none.
    .contentType = z.optional(z.string(.{ .min = 1 })),
    // Extra response headers. Names and values are copied at registration.
    // `Connection: close` is added automatically for `.closeConnection`.
    .headers = z.withDefault(z.array(common.HeaderSchema, .{}), &.{}),
    // Dynamic response handler. When set it replaces the static response.
    .handler = z.withDefault(typedSchema(?handlerMod.Handler), null),
    // Delays the response by this many milliseconds using the request's
    // I/O context, without blocking any thread beyond the handler call.
    .delayMs = z.withDefault(z.nonNegativeInt(u32, .{}), 0),
    // Adds `Connection: close`, asking the client to close the connection
    // after this response.
    .closeConnection = z.withDefault(z.boolean(.{}), false),
    // `Location` header for redirect fixtures. Stored as a plain field so the
    // value can be runtime data without borrowing a temporary header array.
    .location = z.optional(z.string(.{})),
    // Opaque state handed to `.handler` through `ctx.userData`. The testing
    // server owns the route, not this pointer; the caller keeps it alive for
    // as long as the route is registered.
    .userData = z.withDefault(typedSchema(?*anyopaque), null),
}, .{});

/// Validated route configuration. `.{}` is a `200 OK` empty GET response.
pub const RouteOptions = RouteOptionsSchema.Value;

/// Validates a route description using the same zigantic schema machinery as
/// production configuration.
pub fn validate(options: RouteOptions) !RouteOptions {
    var scratch: [1024]u8 = undefined;
    const issue = z.checkFirst(RouteOptionsSchema, options, &scratch, .{}) catch
        return error.InvalidConfig;
    if (issue != null) return error.InvalidConfig;
    return options;
}

/// Plain-text response body.
pub fn text(body: []const u8) RouteOptions {
    return .{ .body = body, .contentType = "text/plain; charset=utf-8" };
}

/// JSON response body (already serialized).
pub fn json(body: []const u8) RouteOptions {
    return .{ .body = body, .contentType = "application/json" };
}

/// HTML response body.
pub fn html(body: []const u8) RouteOptions {
    return .{ .body = body, .contentType = "text/html; charset=utf-8" };
}

/// Binary response body with an explicit media type.
pub fn binary(body: []const u8, contentType: []const u8) RouteOptions {
    return .{ .body = body, .contentType = contentType };
}

/// Empty response with an explicit status.
pub fn empty(status: u16) RouteOptions {
    return .{ .status = status, .body = "" };
}

/// Redirect response (`302 Found` by default).
pub fn redirect(location: []const u8, status: u16) RouteOptions {
    return .{
        .status = status,
        .location = location,
    };
}

/// Applies a delay to an existing response description.
pub fn delayed(ms: u32, options: RouteOptions) RouteOptions {
    var out = options;
    out.delayMs = ms;
    return out;
}

test "fixture helpers fill expected fields" {
    const r = redirect("/next", 307);
    try std.testing.expectEqual(@as(u16, 307), r.status);
    try std.testing.expectEqualStrings("/next", r.location.?);
    const d = delayed(25, text("later"));
    try std.testing.expectEqual(@as(u32, 25), d.delayMs);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", d.contentType.?);
}
