# Readiness Probe Middleware Example

Demonstrates the `readinessProbe` middleware for Kubernetes readiness checks, alongside the `healthCheck` middleware for liveness probes.

## Features Covered

- **Liveness Probe**: `healthCheck()` returns 200 when the process is running. Used by Kubernetes to detect deadlocks.
- **Readiness Probe**: `readinessProbe()` returns 200 when the service is ready to accept traffic. Used during rolling updates.
- **Configurable Paths**: Both probes support custom paths and response bodies.

## Demo Program

```zig
// Liveness probe — always returns 200 when the process is running
try server.use(httpx.middleware.healthCheck(.{
    .path = "/healthz",
    .body = "{\"status\":\"ok\"}",
}));

// Readiness probe — returns 200 when the service is ready to accept traffic
try server.use(httpx.middleware.readinessProbe(.{
    .path = "/readyz",
    .body = "{\"ready\":true}",
}));

// Application routes
try server.get("/", homeHandler);
try server.get("/api/users", usersHandler);
```

## Run

```
zig build run-all-readiness_probe_example
```

## Expected Output

```
GET /healthz (liveness) -> 200 {"status":"ok"}
GET /readyz (readiness) -> 200 {"ready":true}
GET /api/users          -> 200 {"users":["alice","bob","charlie"]}
```

## Kubernetes Integration

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 3
  periodSeconds: 5
```
