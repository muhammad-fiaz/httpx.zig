# Redirect Following Example

Demonstrates redirect policy configuration including `follow_redirects`, `max_redirects`, `preserve_method`, `preserve_headers`, `allow_cross_origin`, and the `getRedirectMethod` logic.

## Demo Program

```zig
const default = httpx.RedirectPolicy{};
std.debug.print("  max_redirects:    {d}\n", .{default.max_redirects});
std.debug.print("  follow_redirects: {}\n", .{default.follow_redirects});

const strict = httpx.RedirectPolicy.strict();
// strict.preserve_method == true

const redirect_method = default.getRedirectMethod(301, .POST);
// 301 with POST -> method changes to GET

const strict_method = strict.getRedirectMethod(301, .POST);
// strict: 301 with POST -> POST preserved
```

## Run

```
zig build example-redirect-example
```

## Checklist

- [ ] Default policy follows redirects, changes POST→GET for 301/302/303
- [ ] `RedirectPolicy.noFollow()` disables following
- [ ] `RedirectPolicy.strict()` preserves original HTTP method
- [ ] 307/308 always preserve the method
- [ ] 301/302 change POST to GET under default policy
- [ ] 303 always changes to GET regardless of policy
