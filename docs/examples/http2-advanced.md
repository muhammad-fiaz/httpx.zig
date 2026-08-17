# HTTP/2 Advanced Example

Demonstrates production HTTP/2 features: SETTINGS enforcement, GOAWAY/RST_STREAM, HPACK security, and trailers.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // SETTINGS enforcement: peer limits are applied to the stream manager
    var manager = httpx.StreamManager.init(allocator, true);
    defer manager.deinit();

    const peer_settings = httpx.Http2Connection.Http2ConnectionSettings{
        .max_concurrent_streams = 3,
        .initial_window_size = 32768,
        .max_frame_size = 16384,
    };
    try manager.applyPeerSettings(peer_settings);

    // canOpenStream respects MAX_CONCURRENT_STREAMS
    const s1 = try manager.createStream();
    try s1.open();
    // ... open more streams until limit is reached
    // manager.canOpenStream() returns false at limit

    // validateFrameSize checks against peer's MAX_FRAME_SIZE
    try manager.validateFrameSize(16384);   // ok
    // manager.validateFrameSize(16385) returns error.FrameTooLarge

    // GOAWAY frame for clean shutdown
    const goaway = try httpx.stream.buildGoawayFrame(
        7, .no_error, "server shutting down", allocator,
    );
    defer allocator.free(goaway);

    // RST_STREAM to cancel a single stream
    const rst = httpx.stream.buildRstStreamFrame(5, .cancel);

    // HPACK Without Indexing / Never Indexed for security headers
    var auth_out = std.ArrayList(u8).empty;
    defer auth_out.deinit(allocator);
    try httpx.hpack.encodeHeaderWithoutIndexing(
        null, "authorization", "Bearer secret-token", allocator, &auth_out,
    );

    // Trailer support: HEADERS frame with END_STREAM
    const trailer = try httpx.stream.buildHeadersAndContinuations(
        &manager, 1, &[_]httpx.hpack.HeaderEntry{
            .{ .name = "x-checksum", .value = "abc123" },
        }, null, 16384, true, allocator,
    );
    defer allocator.free(trailer);
}
```

## Run

```bash
zig build run-all-http2_advanced
```

## What to Verify

- SETTINGS enforcement correctly limits concurrent streams and validates frame sizes.
- GOAWAY and RST_STREAM frames have correct wire format (9-byte header + payload).
- HPACK Without Indexing/Never Indexed do NOT add entries to the dynamic table.
- Trailer HEADERS frames have the END_STREAM flag set.
