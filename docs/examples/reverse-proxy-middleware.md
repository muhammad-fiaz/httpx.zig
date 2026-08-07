# Reverse Proxy Middleware Example

Demonstrates `middleware.reverseProxy()` and `middleware.reverseProxyRuntime()` for proxying requests to a backend server. Shows both compile-time target configuration and runtime target selection.

## Demo Program

```zig
// Start a backend server
try backend.get("/api/data", backendHandler);

// Proxy with runtime target URL
try proxy.use(httpx.reverseProxyRuntime(backend_url));

// Test the proxy
var resp = try client.get(proxy_url, .{});
// GET /api/data -> proxied to backend
```

## Run

```
zig build example-reverse-proxy-middleware
```

## Checklist

- [x] Backend server starts and handles `/api/data`
- [x] Proxy forwards requests to backend transparently
- [x] `reverseProxyRuntime()` accepts target URL at runtime
- [x] Response body is proxied unchanged
- [x] Status code is forwarded correctly
- [x] Use cases: API gateway, microservice proxy, load balancer
