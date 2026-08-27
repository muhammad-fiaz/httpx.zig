//! Health/readiness endpoints: liveness vs readiness as data, not strings.

const std = @import("std");

pub const Status = enum {
    healthy,
    unhealthy,
    ready,
    not_ready,

    /// HTTP status code for this health state.
    pub fn httpStatus(self: Status) u16 {
        return switch (self) {
            .healthy, .ready => 200,
            .unhealthy, .not_ready => 503,
        };
    }

    /// JSON body describing the state.
    pub fn jsonBody(self: Status) []const u8 {
        return switch (self) {
            .healthy => "{\"status\":\"healthy\"}",
            .unhealthy => "{\"status\":\"unhealthy\"}",
            .ready => "{\"status\":\"ready\"}",
            .not_ready => "{\"status\":\"not_ready\"}",
        };
    }
};

pub const Config = struct {
    /// Liveness route. Empty disables it.
    health_path: []const u8 = "/health",
    /// Readiness route. Empty disables it.
    ready_path: []const u8 = "/ready",
    enabled: bool = true,
};

test "healthy is 200" {
    try std.testing.expectEqual(@as(u16, 200), Status.healthy.httpStatus());
    try std.testing.expectEqualStrings("{\"status\":\"healthy\"}", Status.healthy.jsonBody());
}

test "unhealthy is 503" {
    try std.testing.expectEqual(@as(u16, 503), Status.unhealthy.httpStatus());
    try std.testing.expectEqual(@as(u16, 503), Status.not_ready.httpStatus());
}
