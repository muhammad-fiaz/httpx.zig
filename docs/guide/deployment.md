# Server Deployment, Reverse Proxy & Cloud Architecture

This guide details best practices for deploying HTTPX applications in production across bare metal, Virtual Private Servers (VPS), container environments (Docker/Kubernetes), and public clouds (AWS, GCP, Azure), as well as pairing with **Nginx** or running standalone HTTPS.

---

## 1. Deployment Architecture Overview

HTTPX is built on standards-based TCP/UDP, TLS, and HTTP abstractions. It runs identically on:
- Local development workstations
- Standard Linux/Unix and Windows servers
- Cloud VMs (EC2, Google Compute Engine, Azure VMs)
- Containerized environments (Docker, ECS, Kubernetes)

### Common Deployment Topologies

#### Topology A: Reverse Proxy (Recommended for Public Web)
```
  [Internet]
      │ HTTPS (Port 443) / HTTP (Port 80)
      ▼
┌───────────────┐
│     Nginx     │ ── TLS termination, static asset caching, DDoS buffering
└───────────────┘
      │ HTTP (Port 8080 or Unix Socket)
      ▼
┌───────────────┐
│   HTTPX App   │ ── Dynamic routing, WebSocket, API handlers, SSE
└───────────────┘
```

#### Topology B: Direct Standalone TLS / HTTPS
```
  [Internet]
      │ HTTPS (Port 8443 or Port 443 with bind capabilities)
      ▼
┌───────────────────────┐
│ HTTPX (httpx.tls.Listener) │ ── Native Zig TLS 1.3 engine (+ std.crypto.tls HTTPS client)
└───────────────────────┘
```

---

## 2. Server Initialization & Network Binding

HTTPX servers follow the canonical resource ownership rule: they receive their `Allocator` and `IO` once at initialization, retain them, and reuse all internal listener and parser resources across connections.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "0.0.0.0", // Bind all interfaces for containers/VPS
        .port = 8080,      // Unprivileged internal application port
        .keepAlive = true,
        .trustForwardedHeaders = true, // Trust X-Forwarded-* from Nginx
    });
    defer server.deinit();

    try server.get("/health", healthCheck);
    try server.get("/api/v1/data", dataHandler);

    // Blocking server loop
    server.serve();
}

fn healthCheck(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "healthy", .timestamp = std.time.timestamp() });
}

fn dataHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    // When trustForwardedHeaders is true, remoteAddress() reads X-Forwarded-For
    const clientIp = ctx.remoteAddress() orelse "unknown";
    const scheme = ctx.scheme(); // "https" or "http"
    return ctx.renderJson(.{
        .clientIp = clientIp,
        .scheme = scheme,
        .data = "Production payload",
    });
}
```

### Port Handling & Privileges
- **Port 0**: Lets the operating system assign an ephemeral port (ideal for test suites or microservice registration). Query `server.localPort()` to discover the allocated port.
- **Unprivileged Ports (`> 1024`)**: Recommended for running HTTPX under dedicated non-root service users (`httpx-user`).
- **Privileged Ports (80 / 443)**: On Linux, avoid running your binary as `root`. If binding directly without a reverse proxy, grant capability:
  ```bash
  sudo setcap 'cap_net_bind_service=+ep' /opt/myapp/bin/server
  ```

---

## 3. Production Nginx Configuration

When deploying behind Nginx, Nginx handles public TLS certificates (e.g. Let's Encrypt / Certbot), HTTP/2 or HTTP/3 negotiation, and client connection buffering, while forwarding requests to HTTPX over loopback or private networking.

### Complete `nginx.conf` Production Template

```nginx
# Define upstream connection pool
upstream httpx_backend {
    server 127.0.0.1:8080;
    keepalive 64;
}

# HTTP: Redirect all plain HTTP traffic to HTTPS
server {
    listen 80;
    listen [::]:80;
    serverName example.com www.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS: Primary Application Server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    serverName example.com www.example.com;

    # TLS Certificates
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    # Modern TLS Security Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security Headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Maximum upload size (align with HTTPX Config.maxBody)
    client_max_body_size 16M;

    # Primary Proxy Pass Location
    location / {
        proxy_pass http://httpx_backend;
        proxy_httpVersion 1.1;

        # Forwarded Client Metadata
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # WebSocket Upgrade Support
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;

        # Timeouts
        proxy_connect_timeout 5s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Server-Sent Events (SSE) Route (Streaming, unbuffered)
    location /events {
        proxy_pass http://httpx_backend/events;
        proxy_httpVersion 1.1;
        proxy_set_header Connection "";

        # Crucial for SSE: disable Nginx proxy buffering
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;

        proxy_read_timeout 24h;
    }
}
```

---

## 4. Trusted Proxy Security Model

Never blindly trust client headers like `X-Forwarded-For` or `X-Forwarded-Proto` without configuration:
1. When `trustForwardedHeaders: false` (the default), `ctx.remoteAddress()` will report the direct TCP peer address, and `ctx.scheme()` will return `"https"` only if direct TLS was negotiated.
2. When `trustForwardedHeaders: true`, HTTPX will parse the client IP from the first entry of `X-Forwarded-For` (or `X-Real-IP`), and use `X-Forwarded-Proto` for canonical redirect generation and scheme detection.

---

## 5. Systemd Service Deployment (VPS & Bare Metal)

To manage your HTTPX server process with auto-restart, logging, and sandboxing under Linux `systemd`:

Create `/etc/systemd/system/httpx-app.service`:

```ini
[Unit]
Description=HTTPX High Performance Web Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/httpx-app
ExecStart=/var/www/httpx-app/bin/server
Restart=always
RestartSec=3

# Security Sandboxing
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/www/httpx-app/logs

# Resource Limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable httpx-app
sudo systemctl start httpx-app
sudo systemctl status httpx-app
```

---

## 6. Container & Cloud Deployment

### Dockerfile Pattern
```dockerfile
# Build Stage
FROM alpine:3.20 AS builder
RUN apk add --no-cache zig
WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseFast

# Runtime Stage
FROM alpine:3.20
RUN adduser -D -u 1001 appuser
WORKDIR /home/appuser
COPY --from=builder /app/zig-out/bin/server ./server
USER appuser
EXPOSE 8080
ENV PORT=8080 HOST=0.0.0.0
ENTRYPOINT ["./server"]
```

### Cloud Platform Guidance
- **AWS (EC2 / ECS / App Runner)**: Listen on `0.0.0.0:8080`. Target with an AWS Application Load Balancer (ALB). Configure ALB health checks to target `GET /health`.
- **Google Cloud (Compute Engine / Cloud Run / GKE)**: Bind to `0.0.0.0:$PORT`. Cloud Run dynamically injects `PORT=8080`.
- **Azure (App Service / AKS / Container Apps)**: Ensure container listens on `0.0.0.0:8080`. Azure load balancers terminate TLS and forward `X-Forwarded-Proto: https`.
