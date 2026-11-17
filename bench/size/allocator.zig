const builtin = @import("builtin");
const std = @import("std");

pub const allocator: std.mem.Allocator = if (builtin.target.os.tag == .wasi)
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;
