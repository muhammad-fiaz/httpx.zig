const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try qpackInstructionExample(allocator);
    try quicFrameExample();
    try transportParamsExample(allocator);
}

fn qpackInstructionExample(allocator: std.mem.Allocator) !void {
    var section_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeSectionAck(42, &section_buf, allocator);
    defer section_buf.deinit(allocator);
    const ack_decoded = try httpx.qpack.decodeSectionAck(section_buf.items);
    std.debug.print("Section Ack (stream_id=42): {d} bytes\n", .{ack_decoded.len});
    std.debug.print("  Decoded stream_id: {d}\n", .{ack_decoded.result.stream_id});

    var cancel_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeStreamCancel(7, &cancel_buf, allocator);
    defer cancel_buf.deinit(allocator);
    const cancel_decoded = try httpx.qpack.decodeStreamCancel(cancel_buf.items);
    std.debug.print("\nStream Cancel (stream_id=7): {d} bytes\n", .{cancel_decoded.len});
    std.debug.print("  Decoded stream_id: {d}\n", .{cancel_decoded.result.stream_id});

    var inc_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeInsertCountIncrement(10, &inc_buf, allocator);
    defer inc_buf.deinit(allocator);
    const inc_decoded = try httpx.qpack.decodeInsertCountIncrement(inc_buf.items);
    std.debug.print("\nInsert Count Increment (10): {d} bytes\n", .{inc_decoded.len});
    std.debug.print("  Decoded increment: {d}\n", .{inc_decoded.result.increment});

    var cap_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeSetCapacity(4096, &cap_buf, allocator);
    defer cap_buf.deinit(allocator);
    const cap_decoded = try httpx.qpack.decodeSetCapacity(cap_buf.items);
    std.debug.print("\nSet Capacity (4096): {d} bytes\n", .{cap_decoded.len});
    std.debug.print("  Decoded capacity: {d}\n", .{cap_decoded.result.capacity});

    var ref_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeInsertNameRef(true, 17, "POST", &ref_buf, allocator);
    defer ref_buf.deinit(allocator);
    const ref_decoded = try httpx.qpack.decodeInsertWithNameRef(ref_buf.items, allocator);
    defer {
        allocator.free(ref_decoded.result.name orelse &.{});
        allocator.free(ref_decoded.result.value);
    }
    std.debug.print("\nInsert with Name Ref (static index=17, value=POST): {d} bytes\n", .{ref_decoded.len});
    std.debug.print("  Decoded name: \"{s}\", value: \"{s}\"\n", .{
        ref_decoded.result.name orelse "",
        ref_decoded.result.value,
    });

    var lit_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeInsertLiteral("x-request-id", "req-abc-123", &lit_buf, allocator);
    defer lit_buf.deinit(allocator);
    const lit_decoded = try httpx.qpack.decodeInsertLiteral(lit_buf.items, allocator);
    defer {
        allocator.free(lit_decoded.result.name orelse &.{});
        allocator.free(lit_decoded.result.value);
    }
    std.debug.print("\nInsert Literal (x-request-id=req-abc-123): {d} bytes\n", .{lit_decoded.len});
    std.debug.print("  Decoded name: \"{s}\", value: \"{s}\"\n", .{
        lit_decoded.result.name orelse "",
        lit_decoded.result.value,
    });

    var dup_buf: std.ArrayList(u8) = .empty;
    try httpx.qpack.encodeDuplicate(3, &dup_buf, allocator);
    defer dup_buf.deinit(allocator);
    const dup_decoded = try httpx.qpack.decodeDuplicate(dup_buf.items);
    std.debug.print("\nDuplicate (index=3): {d} bytes\n", .{dup_decoded.len});
    std.debug.print("  Decoded index: {d}\n", .{dup_decoded.result.index});
}

fn quicFrameExample() !void {
    const reset = httpx.quic.ResetStreamFrame{
        .stream_id = 4,
        .error_code = 0x06,
        .final_size = 1024,
    };
    var reset_buf: [64]u8 = undefined;
    const reset_len = try reset.encode(&reset_buf);
    const reset_decoded = try httpx.quic.ResetStreamFrame.decode(reset_buf[0..reset_len]);
    std.debug.print("RESET_STREAM:\n", .{});
    std.debug.print("  stream_id: {d}\n", .{reset_decoded.frame.stream_id});
    std.debug.print("  error_code: 0x{x}\n", .{reset_decoded.frame.error_code});
    std.debug.print("  final_size: {d}\n", .{reset_decoded.frame.final_size});

    const stop = httpx.quic.StopSendingFrame{
        .stream_id = 8,
        .error_code = 0x01,
    };
    var stop_buf: [64]u8 = undefined;
    const stop_len = try stop.encode(&stop_buf);
    const stop_decoded = try httpx.quic.StopSendingFrame.decode(stop_buf[0..stop_len]);
    std.debug.print("\nSTOP_SENDING:\n", .{});
    std.debug.print("  stream_id: {d}\n", .{stop_decoded.frame.stream_id});
    std.debug.print("  error_code: 0x{x}\n", .{stop_decoded.frame.error_code});
}

fn transportParamsExample(allocator: std.mem.Allocator) !void {
    const params = httpx.quic.TransportParameters{
        .max_idle_timeout = 30000,
        .max_udp_payload_size = 1200,
        .initial_max_data = 10 * 1024 * 1024,
        .initial_max_stream_data_bidi_local = 1024 * 1024,
        .initial_max_stream_data_bidi_remote = 1024 * 1024,
        .initial_max_stream_data_uni = 1024 * 1024,
        .initial_max_streams_bidi = 100,
        .initial_max_streams_uni = 100,
        .ack_delay_exponent = 3,
        .max_ack_delay = 25,
        .disable_active_migration = true,
        .active_connection_id_limit = 4,
    };

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);

    std.debug.print("Encoded transport parameters: {d} bytes\n", .{encoded.len});

    const decoded = try httpx.quic.TransportParameters.decode(encoded);

    std.debug.print("\nDecoded values:\n", .{});
    std.debug.print("  max_idle_timeout: {d} ms\n", .{decoded.max_idle_timeout});
    std.debug.print("  max_udp_payload_size: {d}\n", .{decoded.max_udp_payload_size});
    std.debug.print("  initial_max_data: {d} bytes\n", .{decoded.initial_max_data});
    std.debug.print("  initial_max_streams_bidi: {d}\n", .{decoded.initial_max_streams_bidi});
    std.debug.print("  initial_max_streams_uni: {d}\n", .{decoded.initial_max_streams_uni});
    std.debug.print("  ack_delay_exponent: {d}\n", .{decoded.ack_delay_exponent});
    std.debug.print("  max_ack_delay: {d} ms\n", .{decoded.max_ack_delay});
    std.debug.print("  disable_active_migration: {s}\n", .{
        if (decoded.disable_active_migration) "true" else "false",
    });
    std.debug.print("  active_connection_id_limit: {d}\n", .{decoded.active_connection_id_limit});
}
