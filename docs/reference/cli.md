# CLI Reference (`httpx` Binary)

The `httpx` binary (`src/cli/main.zig`, built by the `httpx` artifact) runs a
production-style development server with templates, static files, file
watching, and browser live reload.

## Usage

```bash
# Build and run
zig build cli -- <options>
httpx serve --host 127.0.0.1 --port 8080

# Help and version
httpx --help
httpx --version
```

The `serve` subcommand is optional: `httpx serve --port 8080` and
`httpx --port 8080` behave identically.

## Default Routes

Every CLI server mounts two routes out of the box:

| Route     | Handler                                     |
| --------- | ------------------------------------------- |
| `GET /`   | Renders `templates/index.html`, with a friendly landing page fallback when templates are disabled or the file is missing |
| `GET /health` | Returns `{"status":"ok","service":"httpx"}` |

## Options

### Server

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--host`, `-H` | `127.0.0.1` | Host address to bind |
| `--port`, `-p` | `8080` | Port to bind (falls back to `8080` outside `1-65535`) |
| `--backlog` | `128` | Socket listen backlog |
| `--workers` | `0` | Maximum concurrent connections (`0` = unlimited, maps to `max_connections`) |

### Templates, Static Files & SPA

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--templates` | `templates` | Path to templates directory |
| `--no-templates` | — | Disable the template engine |
| `--static` | — | Mount a directory for static assets at `/static` |
| `--spa` | — | Mount a directory for Single Page Application fallback at `/` |

### Development Watching

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--watch` | on | Enable the development file watcher |
| `--no-watch` | — | Disable the development file watcher |
| `--reload` | follows `--watch` | Enable browser live reload |
| `--no-reload` | — | Disable browser live reload |

### Protocols & Security

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--https` | off | Enable TLS / HTTPS (reserved: provide `--cert`/`--key` when wired) |
| `--cert` | — | Path to TLS certificate file |
| `--key` | — | Path to TLS private key file |
| `--http1` | on | Enable HTTP/1.1 |
| `--http2` | on | Enable HTTP/2 cleartext / ALPN |
| `--http3` | off | Enable HTTP/3 over QUIC |

> [!NOTE]
> `--https`, `--cert`, `--key`, `--http1`, `--http2`, `--http3`, `--backlog`,
> and `--log-level` are accepted by the argument parser and reserved for
> upcoming wiring; the running server currently applies host, port, worker,
> template, static/SPA, and watcher settings.

### Logging & Observability

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `--log-level` | `info` | Minimum logging level (`debug`, `info`, `warn`, `error`) |

## Startup Banner

On boot the CLI prints an `HTTPX Server running at: http://<host>:<port>`
banner summarizing templates directory and state, file watcher, live reload,
and static file settings, then blocks serving until interrupted.

## Related

- [Server API](/api/server)
- [HTML Templates](/web/templates)
- [Static Files](/web/static-files)
- [Benchmarks](/reference/benchmarks)
