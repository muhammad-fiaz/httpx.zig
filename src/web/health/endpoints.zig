//! Health/readiness endpoints: liveness vs readiness as data, not strings.

const std = @import("std");

pub const Status = enum {
    healthy,
    unhealthy,
    ready,
    notReady,

    /// HTTP status code for this health state.
    pub fn httpStatus(self: Status) u16 {
        return switch (self) {
            .healthy, .ready => 200,
            .unhealthy, .notReady => 503,
        };
    }

    /// JSON body describing the state.
    pub fn jsonBody(self: Status) []const u8 {
        return switch (self) {
            .healthy => "{\"status\":\"healthy\"}",
            .unhealthy => "{\"status\":\"unhealthy\"}",
            .ready => "{\"status\":\"ready\"}",
            .notReady => "{\"status\":\"notReady\"}",
        };
    }
};

pub const Config = struct {
    /// Liveness route. Empty disables it.
    healthPath: []const u8 = "/health",
    /// Readiness route. Empty disables it.
    readyPath: []const u8 = "/ready",
    enabled: bool = true,
};

test "healthy is 200" {
    try std.testing.expectEqual(@as(u16, 200), Status.healthy.httpStatus());
    try std.testing.expectEqualStrings("{\"status\":\"healthy\"}", Status.healthy.jsonBody());
}

test "unhealthy is 503" {
    try std.testing.expectEqual(@as(u16, 503), Status.unhealthy.httpStatus());
    try std.testing.expectEqual(@as(u16, 503), Status.notReady.httpStatus());
}
