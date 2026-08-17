# Installation

This guide covers all supported installation methods for `httpx.zig`.

## Requirements

- **Zig Version**: 0.16.0 or later
- **Operating System**: Windows, Linux, or macOS

::: warning v0.1.6 release and Zig 0.15 deprecation
`v0.1.6` is the current release and targets Zig `0.16.0+`.
`v0.1.5` is the previous stable release for the immediate prior `0.1.x` line.
Zig `0.15` support is legacy and remains available only through `0.0.7`.
The HTTPS/TLS reader fix for Zig `0.16` empty-buffer reads is included in this release.
If you are upgrading from `0.0.7`, review the GitHub Releases page for migration notes.
:::

## Platform Support

httpx.zig supports Linux, Windows, and macOS across 32-bit and 64-bit builds:

### Operating Systems

| OS | Status | Notes |
|----|--------|-------|
| Linux | Full support | All major distributions. Unix domain sockets fully supported. |
| Windows | Full support | Windows 10/11, Server 2019+. Unix domain sockets require build 17061+ with Developer Mode. |
| macOS | Full support | macOS 11+ (Big Sur and later). Unix domain sockets fully supported. |

### Architectures

| Architecture | Linux | Windows | macOS |
|--------------|-------|---------|-------|
| x86_64 (64-bit) | Yes | Yes | Yes |
| aarch64 (ARM64) | Yes | Yes | Yes |
| x86 (32-bit) | Yes | Yes | No |

::: tip Cross-Compilation
Zig makes cross-compilation easy. You can build for any supported target from any host:
```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows

# Build for macOS from Linux
zig build -Dtarget=aarch64-macos
```
:::

## Method 1: Zig Fetch (Latest Release 0.1.6)

Use the latest tagged release for reproducible builds:

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.6.tar.gz
```

## Method 2: Zig Fetch (Previous Stable 0.1.5)

Use the previous stable `0.1.5` release if you want the last `0.1.x` tag before `0.1.6`:

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.5.tar.gz
```

## Method 3: Zig Fetch (Legacy Zig 0.15 Support - 0.0.7)

For Zig version 0.15 support, use this version:

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.7.tar.gz
```

::: warning Zig 0.15 deprecation
Zig `0.15` support is deprecated; use `0.0.7` if you need the older API surface.
:::

## Method 4: Zig Fetch (Nightly/Main)

Use the Git URL if you want the latest commits from main:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

## Method 5: Manual `build.zig.zon` Configuration

You can also add the dependency manually:

```zig
.{
    .name = "my-project",
    .version = "0.1.6",
    .dependencies = .{
        .httpx = .{
            .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.1.6.tar.gz",
            .hash = "...", // Run zig fetch --save <url> to auto-fill this.
        },
    },
    .paths = .{
        "",
    },
}
```

## Method 6: Local Source Checkout

Clone and build directly:

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

To use a local checkout from another project:

```zig
.dependencies = .{
    .httpx = .{
        .path = "../httpx.zig",
    },
},
```

## Configure `build.zig`

After adding the dependency, expose the module in your build script:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
    b.installArtifact(exe);
}
```

## Import in your code

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    _ = try client.get("https://httpbun.com/get", .{});
}
```

## Validation and Target Matrix

Run these commands from the repository root to verify functionality:

```bash
# Host tests and runnable examples
zig build test
zig build run-all-examples  # Runs sequentially to prevent parallel compiler OOM / PC crashes

# Cross-target library compile matrix
zig build build-all-targets
```

To validate Linux runtime behavior (not only cross-compilation), build Linux-target artifacts and execute them on Linux/WSL:

```bash
# Build Linux artifacts
zig build test -Dtarget=x86_64-linux
zig build run-all-udp_local -Dtarget=x86_64-linux

# Run on Linux/WSL
./zig-out/bin/test
./zig-out/bin/udp_local
```

To compile tests or examples for a specific target:

```bash
# Cross-target test artifact build
zig build test -Dtarget=x86-windows

# Cross-target example build
zig build run-all-udp_local -Dtarget=aarch64-macos
```

For client requests against external endpoints, prefer explicit timeout and error handling:

```zig
var res = client.get("https://example.com", .{ .timeout_ms = 10_000 }) catch |err| {
    std.debug.print("request failed: {s}\n", .{@errorName(err)});
    return;
};
defer res.deinit();
```

`httpx.zig` uses `build-all-targets` as the all-targets validation step.
