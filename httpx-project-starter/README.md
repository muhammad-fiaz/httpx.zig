# httpx Project Starter

The `httpx-project-starter` folder is a standalone Zig starter project pinned to the tagged `httpx.zig` `0.0.7` release in `build.zig.zon`.

Known limitation: with Zig `0.16`, the published `httpx.zig` `0.0.7` package build script currently uses an older build API and fails during dependency evaluation. The pin is intentionally kept at `0.0.7` for now.

## Download Starter Only (Quick Start)

Get started quickly with a pre-configured project template:

**[Download Project Starter Example](https://download-directory.github.io/?url=https://github.com/muhammad-fiaz/httpx.zig/tree/main/httpx-project-starter)**

This downloads only the `httpx-project-starter` folder from the `httpx.zig` repository.


## Included Starter Features (`src/main.zig`)

- Simple GET request.
- POST request with JSON body.
- Cookie jar helpers.
- Custom headers request.
- Optional customization builder helpers for `ClientConfig` and `RequestOptions` (defaults remain implicit).
- Client alias methods (`fetch`, `options`, `del`).
- Top-level helpers (`httpx.fetch`, `httpx.postJson`).
- MIME helper usage (`mimeTypeFromPath`, `mimeTypeFromPathOr`, `mimeTypeFromPathWith`) for static/file responses.
- Request build and wire serialization.
- Connection pool configuration and stats.

## Included Example Set (`examples/`)

This folder includes the bundled sample programs, such as:

- Basic client examples (`simple_get`, `post_json`, `custom_headers`).
- Cookie and pool examples (`cookies_demo`, `connection_pool`).
- Concurrent and interceptor examples.
- HTTP/2 and HTTP/3 runtime examples.
- Local TCP/UDP examples.
- Server/routing/middleware/static-file examples.

## Quick Start (Any Platform)

From `httpx-project-starter`:

```text
zig build
zig build run
```

## Platform-Specific Host Run Guide

### Windows (PowerShell)

```powershell
Set-Location "<your-httpx-project-starter-folder>"
zig build
zig build run
zig build run-simple_get
```

### Linux (bash)

```bash
cd httpx-project-starter
zig build
zig build run
zig build run-simple_get
```

### macOS (zsh/bash)

```bash
cd httpx-project-starter
zig build
zig build run
zig build run-simple_get
```

## Run Individual Local Examples

Build one example:

```text
zig build example-simple_get
```

Run one example:

```text
zig build run-simple_get
```

Run all runnable examples in sequence:

```text
zig build run-all-examples
```

## Build All Local Example Targets (Current Host)

### PowerShell

```powershell
$steps = @(
	'example-simple_get','example-simple_get_deserialize','example-post_json',
	'example-concurrent_requests','example-custom_headers','example-tcp_local',
	'example-udp_local','example-simple_server','example-router_example',
	'example-middleware_example','example-streaming','example-interceptors',
	'example-connection_pool','example-cookies_demo','example-simplified_api_aliases',
	'example-static_files','example-multi_page_website','example-http2_example',
	'example-http2_client_runtime','example-http2_server_runtime',
	'example-http3_client_runtime','example-http3_server_runtime','example-http3_example'
)
foreach ($s in $steps) { zig build $s }
```

### bash/zsh

```bash
for s in \
	example-simple_get example-simple_get_deserialize example-post_json \
	example-concurrent_requests example-custom_headers example-tcp_local \
	example-udp_local example-simple_server example-router_example \
	example-middleware_example example-streaming example-interceptors \
	example-connection_pool example-cookies_demo example-simplified_api_aliases \
	example-static_files example-multi_page_website example-http2_example \
	example-http2_client_runtime example-http2_server_runtime \
	example-http3_client_runtime example-http3_server_runtime example-http3_example
do
	zig build "$s"
done
```

## Cross-Platform Build Validation (Build-Only)

Use these commands from any host machine to cross-build major targets:

```text
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86-linux
zig build -Dtarget=aarch64-linux

zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86-windows
zig build -Dtarget=aarch64-windows

zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
```

## Notes

- `zig build run` runs the all-in-one starter app in `src/main.zig`.
- `run-all-examples` excludes long-running server examples by design.
- Network/TLS behavior can vary by environment (proxy, firewall, runner policy).
