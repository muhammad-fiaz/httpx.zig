# Session API

In-memory server-side sessions with TTL expiry.

Located in `src/session/`.

## SessionStore

| Method | Returns | Description |
|--------|---------|-------------|
| `init(allocator, config)` | `SessionStore` | Create a store with the given config |
| `deinit()` | `void` | Release all resources |
| `create()` | `![SESSION_ID_LEN * 2]u8` | Create a new session, return hex ID |
| `set(hex_id, key, value)` | `!void` | Set a key in the session (duplicates value) |
| `get(hex_id, key)` | `?[]const u8` | Get a value; null if not found or expired |
| `delete(hex_id)` | `void` | Remove a session |
| `exists(hex_id)` | `bool` | True if session exists and is not expired |
| `evictExpired()` | `usize` | Remove expired sessions, returns count removed |
| `count()` | `usize` | Number of sessions in the store |

## SessionConfig

| Field | Default | Description |
|-------|---------|-------------|
| `ttl_ms` | `1_800_000` | Session TTL in milliseconds since last access |
| `cookie_name` | `"session_id"` | Cookie name for session ID |
| `max_sessions` | `0` | Max sessions (0 = unlimited) |

## Constants

- `SESSION_ID_LEN = 32` — raw session ID byte length
- `DEFAULT_TTL_MS = 1_800_000` — 30 minutes

Root-level aliases: `httpx.SessionStore`, `httpx.SessionConfig`, `httpx.SESSION_ID_LEN`.
