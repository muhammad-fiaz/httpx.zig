# Request and Response Customization

This demo shows the full request/response customization surface that is already implemented in `httpx.zig`:

- Request builders and direct request mutation
- Query params, headers, bearer auth, and JSON bodies
- Response accessors for status, headers, content type, content length, location, and body text
- Server-side request inspection with `Context` helpers
- Redirects and HTML/JSON responses

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

// See examples/request_response_customization.zig
```

## Run

```bash
zig build run-request_response_customization
```

## What to Verify

- Direct request serialization includes custom headers, query params, and auth.
- RequestBuilder can build JSON requests with explicit protocol versions.
- The server sees query params, headers, body text, and auth values.
- Response accessors return the expected content type, content length, redirect location, and text body.
