const std = @import("std");

fn linkPlatformLibs(exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        // Winsock symbols are required on Windows for std.net/httpx networking.
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("mswsock", .{});
        exe.root_module.linkSystemLibrary("c", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "httpx_project_starter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
    linkPlatformLibs(exe, target);

    const install_exe = b.addInstallArtifact(exe, .{});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_exe.step);

    const run_step = b.step("run", "Run the all-in-one starter sample");
    run_step.dependOn(&run_cmd.step);

    const examples = [_]struct { name: []const u8, path: []const u8, skip_run_all: bool = false }{
        .{ .name = "simple_get", .path = "examples/simple_get.zig" },
        .{ .name = "simple_get_deserialize", .path = "examples/simple_get_deserialize.zig" },
        .{ .name = "post_json", .path = "examples/post_json.zig" },
        .{ .name = "concurrent_requests", .path = "examples/concurrent_requests.zig" },
        .{ .name = "custom_headers", .path = "examples/custom_headers.zig" },
        .{ .name = "tcp_local", .path = "examples/tcp_local.zig" },
        .{ .name = "udp_local", .path = "examples/udp_local.zig" },
        .{ .name = "simple_server", .path = "examples/simple_server.zig", .skip_run_all = true },
        .{ .name = "router_example", .path = "examples/router_example.zig" },
        .{ .name = "middleware_example", .path = "examples/middleware_example.zig" },
        .{ .name = "streaming", .path = "examples/streaming.zig" },
        .{ .name = "interceptors", .path = "examples/interceptors.zig" },
        .{ .name = "connection_pool", .path = "examples/connection_pool.zig" },
        .{ .name = "cookies_demo", .path = "examples/cookies_demo.zig" },
        .{ .name = "simplified_api_aliases", .path = "examples/simplified_api_aliases.zig" },
        .{ .name = "static_files", .path = "examples/static_files.zig", .skip_run_all = true },
        .{ .name = "multi_page_website", .path = "examples/multi_page_website.zig", .skip_run_all = true },
        .{ .name = "http2_example", .path = "examples/http2_example.zig" },
        .{ .name = "http2_client_runtime", .path = "examples/http2_client_runtime.zig" },
        .{ .name = "http2_server_runtime", .path = "examples/http2_server_runtime.zig" },
        .{ .name = "http3_client_runtime", .path = "examples/http3_client_runtime.zig" },
        .{ .name = "http3_server_runtime", .path = "examples/http3_server_runtime.zig" },
        .{ .name = "http3_example", .path = "examples/http3_example.zig" },
    };

    inline for (examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        example_exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
        linkPlatformLibs(example_exe, target);

        const install_example = b.addInstallArtifact(example_exe, .{});
        const example_step = b.step("example-" ++ example.name, "Build " ++ example.name ++ " example");
        example_step.dependOn(&install_example.step);

        const run_example = b.addRunArtifact(example_exe);
        run_example.step.dependOn(&install_example.step);
        const run_example_step = b.step("run-" ++ example.name, "Run " ++ example.name ++ " example");
        run_example_step.dependOn(&run_example.step);
    }

    const run_all_examples = b.step("run-all-examples", "Run all runnable examples in sequence");
    var previous_run_step: ?*std.Build.Step = null;

    inline for (examples) |example| {
        if (example.skip_run_all) continue;

        const run_all_exe = b.addExecutable(.{
            .name = "run-all-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        run_all_exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
        linkPlatformLibs(run_all_exe, target);

        const install_run_all = b.addInstallArtifact(run_all_exe, .{});
        const run_exe = b.addRunArtifact(run_all_exe);
        run_exe.step.dependOn(&install_run_all.step);

        if (previous_run_step) |prev| {
            run_exe.step.dependOn(prev);
        }
        previous_run_step = &run_exe.step;
    }

    if (previous_run_step) |last| {
        run_all_examples.dependOn(last);
    }
}
