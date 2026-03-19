# Installation

This guide covers all supported installation methods for `httpx.zig`.

## Requirements

- **Zig Version**: 0.15.0 or later (tested on 0.15.2)
- **Operating System**: Windows, Linux, macOS, or FreeBSD

## Platform Support

httpx.zig supports all major platforms and architectures:

### Operating Systems

| OS | Status | Notes |
|----|--------|-------|
| Linux | Full support | All major distributions |
| Windows | Full support | Windows 10/11, Server 2019+ |
| macOS | Full support | macOS 11+ (Big Sur and later) |
| FreeBSD | Full support | FreeBSD 13+ |

### Architectures

| Architecture | Linux | Windows | macOS |
|--------------|-------|---------|-------|
| x86_64 (64-bit) | Yes | Yes | Yes |
| aarch64 (ARM64) | Yes | Yes | Yes |
| i386 (32-bit) | Yes | Yes | Yes |
| arm (32-bit) | Yes | Yes | Yes |

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

## Method 1: Zig Fetch (Recommended Stable Release)

Use the latest tagged release for reproducible builds:

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz
```

## Method 2: Zig Fetch (Nightly/Main)

Use the Git URL if you want the latest commits from main:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

## Method 3: Manual `build.zig.zon` Configuration

You can also add the dependency manually:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .httpx = .{
            .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.0.3.tar.gz",
            .hash = "...", // Run zig fetch --save <url> to auto-fill this.
        },
    },
    .paths = .{
        "",
    },
}
```

## Method 4: Local Source Checkout

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    _ = try client.get("https://httpbin.org/get", .{});
}
```
