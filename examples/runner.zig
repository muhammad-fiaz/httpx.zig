const std = @import("std");
const builtin = @import("builtin");

const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

const ExampleSpec = struct {
    name: []const u8,
    bin_path: []const u8,
    timeout_ms: u32,
};

const ExampleStatus = enum {
    passed,
    failed,
    timed_out,
    skipped,
};

const ExampleResult = struct {
    name: []const u8,
    duration_ms: u64,
    status: ExampleStatus,
    exit_code: u32,
    log_path: ?[]const u8 = null,
};

// Win32 bindings
const STARTUPINFOW = extern struct {
    cb: windows.DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?windows.LPWSTR = null,
    lpDesktop: ?windows.LPWSTR = null,
    lpTitle: ?windows.LPWSTR = null,
    dwX: windows.DWORD = 0,
    dwY: windows.DWORD = 0,
    dwXSize: windows.DWORD = 0,
    dwYSize: windows.DWORD = 0,
    dwXCountChars: windows.DWORD = 0,
    dwYCountChars: windows.DWORD = 0,
    dwFillAttribute: windows.DWORD = 0,
    dwFlags: windows.DWORD = 0,
    wShowWindow: windows.WORD = 0,
    cbReserved2: windows.WORD = 0,
    lpReserved2: ?*windows.BYTE = null,
    hStdInput: ?windows.HANDLE = null,
    hStdOutput: ?windows.HANDLE = null,
    hStdError: ?windows.HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: windows.DWORD,
    dwThreadId: windows.DWORD,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: windows.DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: windows.BOOL = .TRUE,
};

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CloseHandle(
    hObject: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

const STARTF_USESTDHANDLES: windows.DWORD = 0x00000100;
const WAIT_OBJECT_0: windows.DWORD = 0x00000000;
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;
const GENERIC_READ: windows.DWORD = 0x80000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const FILE_SHARE_READ: windows.DWORD = 0x00000001;
const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
const CREATE_ALWAYS: windows.DWORD = 2;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;

fn getNowMillis() u64 {
    if (builtin.os.tag == .windows) {
        return GetTickCount64();
    } else {
        const linux = std.os.linux;
        var t: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &t);
        return @as(u64, @intCast(t.sec)) * 1000 + @as(u64, @intCast(@divTrunc(t.nsec, 1_000_000)));
    }
}

fn executeExampleWindows(
    allocator: std.mem.Allocator,
    bin_path: []const u8,
    timeout_ms: u32,
    log_path: []const u8,
) !struct { exit_code: u32, timed_out: bool, elapsed_ms: u64 } {
    _ = allocator;
    // Prepare log file
    var log_path_w: [512]u16 = undefined;
    const l_len = try std.unicode.utf8ToUtf16Le(&log_path_w, log_path);
    log_path_w[l_len] = 0;

    var sa: SECURITY_ATTRIBUTES = .{ .bInheritHandle = .TRUE };
    const hFile = CreateFileW(
        @ptrCast(&log_path_w),
        GENERIC_WRITE | GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        &sa,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (hFile == windows.INVALID_HANDLE_VALUE) return error.LogFileCreateFailed;

    // Prepare command line
    var cmd_w: [1024]u16 = undefined;
    // Quote binary path in case of spaces
    var cmd_buf: [1024]u8 = undefined;
    const cmd_str = try std.fmt.bufPrint(&cmd_buf, "\"{s}\"", .{bin_path});
    const c_len = try std.unicode.utf8ToUtf16Le(&cmd_w, cmd_str);
    cmd_w[c_len] = 0;

    var si: STARTUPINFOW = .{
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdOutput = hFile,
        .hStdError = hFile,
    };
    var pi: PROCESS_INFORMATION = undefined;

    const hJob = CreateJobObjectW(null, null);
    defer {
        if (hJob) |j| _ = CloseHandle(j);
    }

    const start_time = getNowMillis();
    const ok = CreateProcessW(null, @ptrCast(&cmd_w), null, null, .TRUE, 0, null, null, &si, &pi);
    _ = CloseHandle(hFile);

    if (ok == .FALSE) return error.CreateProcessFailed;
    defer _ = CloseHandle(pi.hThread);
    defer _ = CloseHandle(pi.hProcess);

    if (hJob) |j| {
        _ = AssignProcessToJobObject(j, pi.hProcess);
    }

    const wait_res = WaitForSingleObject(pi.hProcess, timeout_ms);
    const elapsed = getNowMillis() - start_time;

    if (wait_res == WAIT_OBJECT_0) {
        var exit_code: windows.DWORD = 0;
        _ = GetExitCodeProcess(pi.hProcess, &exit_code);
        return .{ .exit_code = exit_code, .timed_out = false, .elapsed_ms = elapsed };
    } else if (wait_res == WAIT_TIMEOUT) {
        if (hJob) |j| {
            _ = TerminateJobObject(j, 124);
        } else {
            _ = TerminateProcess(pi.hProcess, 124);
        }
        return .{ .exit_code = 124, .timed_out = true, .elapsed_ms = elapsed };
    } else {
        return error.ProcessWaitFailed;
    }
}

fn printCapturedLog(log_path: []const u8) void {
    if (builtin.os.tag == .windows) {
        var log_path_w: [512]u16 = undefined;
        const l_len = std.unicode.utf8ToUtf16Le(&log_path_w, log_path) catch return;
        log_path_w[l_len] = 0;

        const hRead = CreateFileW(
            @ptrCast(&log_path_w),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (hRead == windows.INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(hRead);

        var buf: [4096]u8 = undefined;
        var bytesRead: windows.DWORD = 0;
        if (ReadFile(hRead, &buf, @intCast(buf.len), &bytesRead, null) != .FALSE and bytesRead > 0) {
            std.debug.print("      --- Captured Output ---\n", .{});
            var it = std.mem.splitScalar(u8, buf[0..bytesRead], '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r");
                if (trimmed.len > 0) {
                    std.debug.print("      | {s}\n", .{trimmed});
                }
            }
            std.debug.print("      -----------------------\n", .{});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const rawArgs = try init.minimal.args.toSlice(init.arena.allocator());

    var specs = std.ArrayList(ExampleSpec).empty;
    defer specs.deinit(allocator);

    var default_timeout_ms: u32 = 15_000;
    var suite_timeout_ms: u64 = 1_800_000; // 30 minutes
    var filter: ?[]const u8 = null;

    var i: usize = 1;
    while (i < rawArgs.len) : (i += 1) {
        const arg = rawArgs[i];
        if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i < rawArgs.len) {
                default_timeout_ms = try std.fmt.parseInt(u32, rawArgs[i], 10);
            }
        } else if (std.mem.eql(u8, arg, "--suite-timeout")) {
            i += 1;
            if (i < rawArgs.len) {
                suite_timeout_ms = try std.fmt.parseInt(u64, rawArgs[i], 10);
            }
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i < rawArgs.len) {
                filter = rawArgs[i];
            }
        } else if (std.mem.eql(u8, arg, "--example")) {
            i += 1;
            if (i + 1 < rawArgs.len) {
                const name = rawArgs[i];
                i += 1;
                const path = rawArgs[i];
                try specs.append(allocator, .{
                    .name = name,
                    .bin_path = path,
                    .timeout_ms = default_timeout_ms,
                });
            }
        }
    }

    const total_specs = specs.items.len;
    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("  HTTPX Example Suite Runner (Zig {s})\n", .{builtin.zig_version_string});
    std.debug.print("  Discovered Examples: {d}\n", .{total_specs});
    std.debug.print("  Per-Example Timeout: {d}ms | Suite Timeout: {d}s\n", .{ default_timeout_ms, suite_timeout_ms / 1000 });
    std.debug.print("================================================================================\n\n", .{});

    var results = try allocator.alloc(ExampleResult, total_specs);
    defer allocator.free(results);

    var passed_count: usize = 0;
    var failed_count: usize = 0;
    var timed_out_count: usize = 0;
    var skipped_count: usize = 0;

    const suite_start = getNowMillis();

    for (specs.items, 0..) |spec, idx| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, spec.name, f) == null) {
                results[idx] = .{
                    .name = spec.name,
                    .duration_ms = 0,
                    .status = .skipped,
                    .exit_code = 0,
                };
                skipped_count += 1;
                continue;
            }
        }

        const suite_elapsed = getNowMillis() - suite_start;
        if (suite_elapsed >= suite_timeout_ms) {
            std.debug.print("SUITE TIMEOUT: overall limit of {d}ms reached. Halting.\n", .{suite_timeout_ms});
            for (specs.items[idx..], idx..) |rem_spec, rem_idx| {
                results[rem_idx] = .{
                    .name = rem_spec.name,
                    .duration_ms = 0,
                    .status = .timed_out,
                    .exit_code = 124,
                };
                timed_out_count += 1;
            }
            break;
        }

        // Print header before starting example
        std.debug.print("[{d: >2}/{d}] {s} ", .{ idx + 1, total_specs, spec.name });
        // Padding dots
        const prefix_len = 8 + spec.name.len;
        const target_cols: usize = 50;
        if (prefix_len < target_cols) {
            const dots = target_cols - prefix_len;
            var d: usize = 0;
            while (d < dots) : (d += 1) {
                std.debug.print(".", .{});
            }
        }
        std.debug.print(" ", .{});

        var log_buf: [256]u8 = undefined;
        const log_path = try std.fmt.bufPrint(&log_buf, "zig-out/.runner_{s}.log", .{spec.name});

        var res_status: ExampleStatus = .passed;
        var res_code: u32 = 0;
        var res_elapsed: u64 = 0;

        if (builtin.os.tag == .windows) {
            const exec_res = executeExampleWindows(allocator, spec.bin_path, spec.timeout_ms, log_path) catch |err| {
                std.debug.print("FAIL (spawn error: {s})\n", .{@errorName(err)});
                results[idx] = .{
                    .name = spec.name,
                    .duration_ms = 0,
                    .status = .failed,
                    .exit_code = 1,
                    .log_path = null,
                };
                failed_count += 1;
                continue;
            };

            res_code = exec_res.exit_code;
            res_elapsed = exec_res.elapsed_ms;

            if (exec_res.timed_out) {
                res_status = .timed_out;
                timed_out_count += 1;
                std.debug.print("TIMEOUT (>{d}ms)\n", .{spec.timeout_ms});
                printCapturedLog(log_path);
            } else if (res_code != 0) {
                res_status = .failed;
                failed_count += 1;
                std.debug.print("FAIL (exit {d}, {d}ms)\n", .{ res_code, res_elapsed });
                printCapturedLog(log_path);
            } else {
                res_status = .passed;
                passed_count += 1;
                std.debug.print("PASS ({d}ms)\n", .{res_elapsed});
            }
        } else {
            // Non-windows placeholder
            std.debug.print("SKIPPED (non-windows host)\n", .{});
            res_status = .skipped;
            skipped_count += 1;
        }

        results[idx] = .{
            .name = spec.name,
            .duration_ms = res_elapsed,
            .status = res_status,
            .exit_code = res_code,
            .log_path = null,
        };
    }

    const total_suite_time = getNowMillis() - suite_start;

    // Summary Section
    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("  EXECUTION SUMMARY\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("  Discovered:       {d}\n", .{total_specs});
    std.debug.print("  Passed:           {d}\n", .{passed_count});
    std.debug.print("  Failed:           {d}\n", .{failed_count});
    std.debug.print("  Timed Out:        {d}\n", .{timed_out_count});
    if (skipped_count > 0) {
        std.debug.print("  Skipped:          {d}\n", .{skipped_count});
    }
    std.debug.print("  Total Wall Clock: {d}.{d:0>3}s\n", .{ total_suite_time / 1000, total_suite_time % 1000 });
    std.debug.print("--------------------------------------------------------------------------------\n", .{});

    // Slowest examples analysis
    const Slowest = struct {
        name: []const u8,
        ms: u64,
    };
    var slowest_list: [5]Slowest = undefined;
    for (&slowest_list) |*item| {
        item.* = .{ .name = "", .ms = 0 };
    }

    for (results) |r| {
        if (r.status == .skipped) continue;
        var slot: usize = 0;
        while (slot < 5) : (slot += 1) {
            if (r.duration_ms > slowest_list[slot].ms) {
                var j: usize = 4;
                while (j > slot) : (j -= 1) {
                    slowest_list[j] = slowest_list[j - 1];
                }
                slowest_list[slot] = .{ .name = r.name, .ms = r.duration_ms };
                break;
            }
        }
    }

    std.debug.print("  Top Slowest Examples:\n", .{});
    for (slowest_list, 1..) |s, rank| {
        if (s.name.len > 0) {
            std.debug.print("    {d}. {s: <35} {d}ms\n", .{ rank, s.name, s.ms });
        }
    }
    std.debug.print("================================================================================\n\n", .{});

    if (failed_count > 0 or timed_out_count > 0) {
        std.process.exit(1);
    } else {
        std.process.exit(0);
    }
}
