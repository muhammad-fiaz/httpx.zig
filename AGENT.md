# AGENT.md

## Project Mission

This project is a production-grade, native Zig HTTP/networking library.

The primary objective is to provide a complete, standards-compliant, efficient, secure,
cross-platform HTTP stack implemented natively in Zig.

The implementation must provide complete support for:

- HTTP/1.0
- HTTP/1.1
- HTTP/2
- HTTP/3
- QUIC
- TLS
- TLS 1.3 server and client functionality
- ALPN
- TCP
- UDP
- DNS
- SOCKS5
- HTTP/HTTPS proxies
- WebSockets
- FTP client and server functionality
- Compression
- Cookies
- Multipart
- SSE
- Static files
- SPA serving
- Routing
- Middleware
- Authentication
- OpenAPI
- Health endpoints
- Metrics
- Documentation endpoints
- Connection pooling
- Concurrency
- Worker pools
- Request/response streaming
- HTTP protocol negotiation
- HTTP client and server APIs

All functionality must be implemented as a coherent, reusable, modular Zig
architecture rather than as isolated implementations.

---

# 1. Core Development Rule

## Understand Before Modifying

Before implementing, modifying, replacing, or deleting code:

1. Read the relevant existing Zig source code.
2. Understand the architecture and ownership model.
3. Trace how the module is used by other modules.
4. Search the entire `src/` tree for existing functionality.
5. Reuse existing abstractions wherever appropriate.
6. Identify missing functionality.
7. Research the corresponding standards.
8. Inspect the bundled C/C++ reference implementations.
9. Compare the reference algorithms with the existing Zig implementation.
10. Implement the missing behavior natively in Zig.
11. Integrate it into the existing architecture.
12. Add or update tests.
13. Run the complete test suite.
14. Run interoperability tests where applicable.
15. Verify all supported target architectures.

Never start by blindly rewriting an existing module.

Do not assume that a module is incomplete merely because it appears small.

Do not replace working code simply because a different implementation is possible.

---

# 2. Source of Truth Hierarchy

When implementing networking and protocol functionality, use the following
priority order:

1. Relevant RFC / official protocol specification
2. Existing project architecture and invariants
3. Zig standard library APIs and semantics
4. Existing reusable project implementations
5. Mature C/C++ reference implementations
6. Interoperability behavior
7. Tests and fuzzing results
8. Performance considerations

Reference implementations are implementation references, not specifications.

Never copy C/C++ code mechanically.

Understand the algorithm, invariants, security properties, state transitions,
wire format, error handling, and resource-management behavior before translating
the functionality into Zig.

---

# 3. Bundled Reference Implementations

The repository contains mature C/C++ implementations that must be treated as
important engineering references.

Relevant reference projects include:

- `cpp-httplib`
- `h2o`
- `nghttp2`
- `nghttp3`
- `ngtcp2`
- `picohttpparser`
- `quiche`

When implementing protocol functionality, search the relevant reference
implementation before inventing a new algorithm.

Inspect:

- `.c`
- `.cc`
- `.cpp`
- `.h`
- `.hpp`
- generated source
- protocol state machines
- codec implementations
- parsers
- encoders
- decoders
- cryptographic integration
- flow-control logic
- congestion-control logic
- connection lifecycle
- error handling
- timeout handling
- retransmission handling
- stream handling
- fuzz tests
- interoperability tests
- examples
- integration tests

Important reference areas include:

```text
cpp-httplib/
h2o/
nghttp2/
nghttp3/
ngtcp2/
picohttpparser/
quiche/
````

Do not inspect only README files.

For protocol work, inspect the actual implementation files and headers.

---

# 4. Zig Standard Library

The project targets Zig:

```text
C:\tools\zig-x86_64-windows-0.16.0
```

Before implementing functionality already provided by Zig, inspect the relevant
standard-library implementation.

Important reference:

```text
C:\tools\zig-x86_64-windows-0.16.0\lib\std\std.zig
```

Also inspect relevant files under:

```text
C:\tools\zig-x86_64-windows-0.16.0\lib\std\
```

Do not rely on APIs from another Zig version.

Verify:

* type names
* function signatures
* error sets
* networking APIs
* socket APIs
* cryptographic APIs
* random APIs
* TLS client APIs
* memory APIs
* I/O APIs
* synchronization primitives
* atomic APIs
* platform abstractions

All code must compile against the actual configured Zig version.

---

# 5. Native Zig Requirement

The final implementation must be native Zig.

Do not introduce unnecessary C wrappers merely because the reference project
contains C/C++.

Do not make the library dependent on a C/C++ HTTP implementation.

Do not shell out to external networking programs.

Do not use C/C++ as a runtime implementation shortcut.

C/C++ projects are references for understanding production-quality behavior.

Translate the required algorithms and architecture into idiomatic Zig.

Use Zig's standard library and the project's existing abstractions wherever
possible.

---

# 6. No Duplicate Implementations

Before creating a new function, type, codec, parser, state machine, helper,
algorithm, or abstraction:

Search the entire project.

Check:

```text
src/
```

and relevant Zig standard-library functionality.

If equivalent functionality already exists:

* reuse it
* extend it
* generalize it
* refactor it carefully

Do not create another implementation with slightly different naming.

Avoid:

* duplicate parsers
* duplicate header containers
* duplicate URI parsing
* duplicate integer encoders
* duplicate Huffman implementations
* duplicate HPACK logic
* duplicate QPACK logic
* duplicate HKDF implementations
* duplicate AEAD wrappers
* duplicate ALPN enums
* duplicate HTTP-version enums
* duplicate socket wrappers
* duplicate connection pools
* duplicate timeout implementations
* duplicate synchronization primitives
* duplicate error types

There must be one authoritative implementation wherever practical.

---

# 7. Reuse Existing Project Algorithms

Important existing modules include:

```text
src/common/
src/protocols/common/
src/protocols/quic/
src/protocols/http1/
src/protocols/http2/
src/protocols/http3/
src/protocols/tls/
src/sockets/
src/net/
src/client/
src/server/
src/web/
src/compression/
src/concurrency/
```

Before implementing a protocol feature, determine whether an existing lower-level
component already provides the required primitive.

Examples:

```text
common/integer.zig
common/headers.zig
common/uri.zig
common/http_version.zig

protocols/common/huffman.zig
protocols/common/huffman_table.zig

quic/crypto.zig
quic/protect.zig
quic/varint.zig
quic/packet.zig
quic/frames.zig
quic/stream.zig
quic/connection.zig
quic/loss.zig
quic/cc.zig
quic/params.zig
quic/path.zig
quic/connection_id.zig

http1/parser.zig
http1/writer.zig
http1/semantics.zig

http2/frame.zig
http2/hpack.zig
http2/stream.zig
http2/connection.zig
http2/transport.zig

http3/frame.zig
http3/qpack.zig
http3/connection.zig

tls/alpn.zig
tls/config.zig
tls/engine.zig
tls/handshake.zig
tls/record.zig
tls/transport.zig
tls/tcp_tls.zig
tls/quic_tls.zig
tls/ls_server.zig
```

Extend these implementations instead of creating parallel architectures.

---

# 8. HTTP Version Architecture

The canonical HTTP version abstraction is:

```text
src/common/http_version.zig
```

It must represent:

```text
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
automatic negotiation
```

Use consistent naming such as:

```text
http_1_0
http_1
h2
h3
auto
```

Do not introduce separate competing HTTP-version enums in individual modules.

ALPN must map consistently to the canonical HTTP-version abstraction.

Expected mappings:

```text
http/1.0 -> HTTP/1.0
http/1.1 -> HTTP/1.1
h2       -> HTTP/2
h3       -> HTTP/3
```

`auto` must negotiate according to the transport and configured capabilities.

---

# 9. HTTP/1.0

HTTP/1.0 must be a first-class supported protocol.

Implement all applicable HTTP/1.0 behavior rather than treating it as merely
HTTP/1.1 with a different version string.

Cover:

* request-line parsing
* response status-line
* headers
* HTTP/1.0 message framing
* Content-Length
* connection close semantics
* keep-alive behavior where applicable
* request-target forms
* response serialization
* body streaming
* error handling
* malformed messages
* limits
* interoperability

HTTP/1.0 must work through:

* client
* server
* TLS
* routing
* middleware
* static files
* SPA
* authentication
* multipart
* SSE where protocol semantics permit
* WebSocket upgrade compatibility where applicable

---

# 10. HTTP/1.1

HTTP/1.1 must be fully implemented.

Cover:

* persistent connections
* request-target forms
* Host
* Content-Length
* Transfer-Encoding
* chunked encoding
* trailers
* connection management
* Expect
* 100 Continue
* range requests
* conditional requests
* cache-related headers
* request/response streaming
* pipelining behavior where supported
* upgrade handling
* WebSocket upgrade
* connection limits
* parser limits
* malformed request rejection
* request smuggling protections
* header validation
* obs-fold handling
* invalid framing detection

Do not weaken parser security for compatibility.

---

# 11. HTTP/2

HTTP/2 must be a complete implementation.

Cover:

* connection preface
* SETTINGS
* SETTINGS synchronization
* stream lifecycle
* frame parsing
* frame serialization
* DATA
* HEADERS
* PRIORITY where applicable
* RST_STREAM
* SETTINGS
* PUSH_PROMISE handling according to supported RFC behavior
* PING
* GOAWAY
* WINDOW_UPDATE
* CONTINUATION
* header compression
* HPACK
* dynamic table
* static table
* Huffman decoding/encoding
* flow control
* stream limits
* connection limits
* graceful shutdown
* protocol errors
* stream errors
* malformed frames
* frame size limits
* header size limits
* concurrent streams
* backpressure
* cancellation
* timeouts
* trailers
* request/response streaming

HTTP/2 must integrate with:

```text
HTTP client
HTTP server
TLS
ALPN
router
middleware
static files
SPA
WebSocket where protocol support applies
SSE
multipart
authentication
metrics
```

---

# 12. HTTP/3

HTTP/3 must be implemented as a real HTTP/3 stack over QUIC.

Cover:

* HTTP/3 connection establishment
* control stream
* request streams
* response streams
* unidirectional streams
* SETTINGS
* frame parsing
* frame serialization
* DATA
* HEADERS
* CANCEL_PUSH
* SETTINGS
* PUSH_PROMISE where supported
* GOAWAY
* MAX_PUSH_ID where supported
* QPACK
* QPACK encoder
* QPACK decoder
* dynamic table
* blocked streams
* stream cancellation
* HTTP/3 errors
* request cancellation
* trailers
* flow control
* connection shutdown
* QUIC stream reset
* graceful connection termination

HTTP/3 must use:

```text
UDP
QUIC
QUIC TLS
ALPN h3
QPACK
HTTP/3 connection management
```

Do not implement fake HTTP/3 over TCP.

---

# 13. QUIC

QUIC must be a real protocol implementation.

Cover the required QUIC functionality including:

* packet parsing
* packet construction
* long headers
* short headers
* version negotiation
* connection IDs
* Initial packets
* Handshake packets
* 0-RTT handling
* 1-RTT
* packet number spaces
* ACK processing
* loss detection
* retransmission
* congestion control
* flow control
* stream management
* bidirectional streams
* unidirectional streams
* connection flow control
* stream flow control
* connection migration
* path validation
* PATH_CHALLENGE
* PATH_RESPONSE
* idle timeout
* keepalive
* transport parameters
* connection close
* stateless reset where supported
* packet protection
* header protection
* key updates
* cryptographic packet handling

Use existing:

```text
src/protocols/quic/
```

and extend it instead of creating a second QUIC stack.

Use mature references such as:

```text
ngtcp2
quiche
```

for implementation and interoperability guidance.

---

# 14. TLS

TLS must be treated as a complete subsystem.

The project requires native TLS integration for both:

```text
TCP -> TLS -> HTTP/1.0 / HTTP/1.1 / HTTP/2

UDP -> QUIC -> QUIC TLS -> HTTP/3
```

TLS 1.3 must be implemented correctly for the server side rather than assuming
the Zig standard library provides every required server feature.

Cover:

* ClientHello
* ServerHello
* supported_versions
* cipher suites
* key shares
* X25519
* signature algorithms
* extensions
* SNI
* ALPN
* EncryptedExtensions
* Certificate
* CertificateVerify
* Finished
* transcript hash
* HKDF key schedule
* handshake traffic keys
* application traffic keys
* record protection
* AEAD
* sequence numbers
* nonce construction
* TLS alerts
* close_notify
* certificate validation
* certificate chains
* private keys
* server identity configuration
* certificate selection
* secure defaults

Do not fake TLS.

Do not send plaintext after claiming a TLS handshake succeeded.

Do not expose an authenticated connection until Finished verification succeeds.

---

# 15. ALPN

ALPN must be centralized.

Primary module:

```text
src/protocols/tls/alpn.zig
```

ALPN must correctly support:

```text
http/1.0
http/1.1
h2
h3
```

TCP TLS must reject inappropriate:

```text
h3
```

because HTTP/3 requires QUIC.

QUIC TLS must negotiate:

```text
h3
```

for HTTP/3.

Do not duplicate ALPN parsing or protocol-selection logic elsewhere.

---

# 16. TCP / UDP / Sockets

Use:

```text
src/sockets/
```

as the socket abstraction layer.

Cover:

* TCP
* UDP
* IPv4
* IPv6
* bind
* listen
* accept
* connect
* read
* write
* vectored I/O where useful
* shutdown
* close
* socket options
* nonblocking operation
* timeout handling
* address handling
* platform differences
* error normalization

Use:

```text
src/sockets/sys.zig
src/sockets/tcp.zig
src/sockets/udp.zig
```

Do not duplicate OS socket wrappers inside protocol modules.

---

# 17. DNS

DNS must integrate with:

```text
src/net/dns.zig
src/net/dns/
src/net/resolve.zig
```

Support:

* IPv4 resolution
* IPv6 resolution
* caching
* cache expiration
* concurrent resolution
* error handling
* resolver configuration
* connection establishment integration

Reuse the existing DNS cache rather than implementing another cache inside
the HTTP client.

---

# 18. Proxy Support

Support the existing networking architecture for:

* HTTP proxies
* HTTPS proxy tunneling
* SOCKS5
* IPv4
* IPv6
* authentication where supported

Use:

```text
src/net/proxy.zig
src/net/socks5.zig
```

Do not duplicate proxy negotiation code in HTTP/1, HTTP/2, HTTP/3, or TLS.

---

# 19. WebSockets

WebSockets must be integrated with the HTTP stack.

Cover:

* handshake
* Upgrade
* Sec-WebSocket-Key
* Sec-WebSocket-Accept
* protocol validation
* frame parsing
* frame writing
* masking
* fragmentation
* continuation frames
* ping
* pong
* close
* close codes
* payload limits
* backpressure
* UTF-8 validation where required
* extensions where implemented
* client and server support

Use:

```text
src/web/websocket/
```

and reuse the common HTTP request/response abstractions.

---

# 20. FTP

FTP must be treated as a proper protocol module.

Support:

* FTP client
* FTP server
* commands
* responses
* authentication
* passive mode
* active mode where supported
* data connections
* file transfer
* directory operations
* streaming
* timeouts
* errors
* resource cleanup
* security boundaries

Keep FTP separate from HTTP while reusing lower-level networking primitives.

---

# 21. Client API

The client API must be simple and ergonomic.

The user should not need to understand protocol internals to make a request.

The client must support:

```text
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
automatic negotiation
```

Example design direction:

```zig
var client = try Client.init(allocator, .{});

defer client.deinit();

var response = try client.get("https://example.com/");
defer response.deinit();
```

Advanced users must be able to configure:

* HTTP version
* automatic negotiation
* TLS
* ALPN
* proxy
* SOCKS5
* DNS
* timeouts
* redirects
* cookies
* headers
* compression
* connection pooling
* concurrency
* HTTP/2 settings
* HTTP/3 settings
* QUIC settings
* certificate validation
* client certificates where supported
* streaming
* request body
* response body
* limits

Do not expose unnecessary protocol implementation details in the basic API.

---

# 22. Server API

The server API must also be ergonomic.

Provide a unified server abstraction capable of serving:

```text
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
```

according to configured transports and protocol negotiation.

The application handler should operate on a common request/response abstraction.

The application should not need separate business logic for:

```text
HTTP/1
HTTP/2
HTTP/3
```

unless it explicitly needs protocol-specific functionality.

---

# 23. Unified Request / Response Model

The project should have a reusable request/response model supporting:

* method
* URI
* path
* query parameters
* headers
* body
* streaming body
* trailers
* status
* response headers
* response body
* cookies
* content type
* content length
* connection metadata
* protocol version

Protocol implementations translate between their wire representation and
this common model.

Do not make HTTP/2 or HTTP/3 application handlers use completely different
request/response APIs.

---

# 24. Router

The router must support:

* static routes
* parameters
* wildcard routes
* nested routes
* method matching
* route metadata
* middleware
* route restrictions
* 404 handling
* 405 handling
* custom error handlers

Use:

```text
src/web/router/
```

Do not create routers inside protocol implementations.

---

# 25. SPA

SPA support must work through the unified HTTP server.

Support:

* static asset serving
* index fallback
* client-side routing
* cache headers
* content types
* compression
* range requests where appropriate
* 404 behavior
* configurable fallback
* custom error pages

SPA functionality must work regardless of whether the request arrived through
HTTP/1.0, HTTP/1.1, HTTP/2, or HTTP/3.

---

# 26. Static Files

Static file serving must be protocol-independent.

Support:

* MIME detection
* Content-Length
* range requests
* conditional requests
* caching
* ETag where implemented
* Last-Modified
* HEAD
* streaming
* path traversal protection
* directory restrictions
* configurable roots

Use:

```text
src/web/static_files/
src/utils/mime.zig
```

---

# 27. Multipart

Support:

* multipart/form-data
* multipart parsing
* multipart encoding
* streaming
* boundaries
* file uploads
* limits
* malformed input handling
* memory limits
* temporary storage strategy where applicable

Use:

```text
src/web/multipart/
```

---

# 28. SSE

Support:

* event streams
* data
* event
* id
* retry
* multiline data
* flushing
* disconnect handling
* backpressure

Use:

```text
src/web/sse/
```

---

# 29. Middleware

Middleware must be transport-independent.

Support reusable middleware for:

* security
* authentication
* logging
* metrics
* compression
* request limits
* CORS where applicable
* custom application policies

Middleware should work equally over:

```text
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
```

---

# 30. Authentication

Use:

```text
src/web/auth/
```

Support reusable:

* Basic authentication
* Bearer authentication
* extensible authentication mechanisms

Authentication must operate on the common request abstraction.

---

# 31. Compression

Compression must be centralized under:

```text
src/compression/
```

Do not implement compression separately inside HTTP/1, HTTP/2, and HTTP/3.

Support configured codecs and correct negotiation through HTTP headers.

Compression must be safe with streaming and respect request/response limits.

---

# 32. Concurrency

Concurrency must be carefully designed.

Use:

```text
src/concurrency/
```

including:

```text
queue.zig
worker_pool.zig
```

Avoid:

* deadlocks
* lock-order inversions
* starvation
* unbounded queues
* accidental busy loops
* leaked workers
* leaked tasks
* races
* unsafe shared mutable state

Every synchronization primitive must have clearly defined ownership.

Prefer designs that minimize shared mutable state.

Use backpressure.

Do not introduce unnecessary locks.

---

# 33. Connection Pooling

Connection pooling must be shared by all appropriate client protocols.

Support:

* HTTP/1 persistent connections
* HTTP/2 multiplexed connections
* HTTP/3 multiplexed QUIC connections
* idle timeout
* maximum connections
* maximum idle connections
* connection reuse
* connection eviction
* DNS changes where appropriate
* protocol-aware pooling
* TLS session state where supported

Do not implement a separate pool for every HTTP protocol unless there is a
real architectural requirement.

---

# 34. Error Handling

Use:

```text
src/common/errors.zig
```

as the common error architecture.

Errors must distinguish between:

* invalid input
* protocol errors
* transport errors
* timeout
* cancellation
* connection reset
* TLS errors
* certificate errors
* HTTP errors
* QUIC errors
* resource exhaustion
* unsupported features

Never silently convert a protocol failure into success.

Never ignore an error simply to make a test pass.

---

# 35. Memory Management

Every allocation must have clear ownership.

Use:

* allocators
* arenas where appropriate
* stack buffers for bounded temporary data
* deterministic cleanup
* `defer`
* `errdefer`

Avoid:

* memory leaks
* use-after-free
* double-free
* unbounded allocations
* attacker-controlled allocation growth

All network-facing parsers must have explicit size limits.

---

# 36. Security Requirements

All network-facing code must be fail-closed.

Pay special attention to:

* request smuggling
* malformed framing
* integer overflow
* buffer overflow
* allocation exhaustion
* header bombs
* decompression bombs
* QPACK/HPACK abuse
* HTTP/2 stream abuse
* QUIC packet abuse
* TLS transcript manipulation
* certificate validation
* ALPN confusion
* SNI handling
* nonce reuse
* replay-sensitive behavior
* connection exhaustion
* worker exhaustion
* path traversal
* WebSocket framing attacks
* malformed multipart input

Never weaken validation merely to achieve interoperability.

---

# 37. Source Organization

Every new Zig file must be placed in the directory corresponding to the
functionality it implements.

Examples:

```text
HTTP/1 functionality
    src/protocols/http1/

HTTP/2 functionality
    src/protocols/http2/

HTTP/3 functionality
    src/protocols/http3/

QUIC functionality
    src/protocols/quic/

TLS functionality
    src/protocols/tls/

shared protocol codecs
    src/protocols/common/

networking
    src/net/

sockets
    src/sockets/

client
    src/client/

server
    src/server/

web framework
    src/web/

compression
    src/compression/

concurrency
    src/concurrency/

common types
    src/common/
```

Do not create meaningless nested structures such as:

```text
src/protocols/tls/alpn/alpn.zig
```

when a flat related module is sufficient.

Prefer:

```text
src/protocols/tls/alpn.zig
```

Similarly, do not create a new directory containing only one arbitrary file
unless the module genuinely requires multiple related files.

---

# 38. Modularity

Each module must have a clear responsibility.

Avoid giant files containing unrelated functionality.

Split modules when separation improves:

* ownership
* testing
* readability
* reuse
* compilation
* maintenance

However, do not split files merely to create artificial abstraction.

A module should have a meaningful cohesive purpose.

---

# 39. Documentation and Comments

All public APIs and important internal algorithms must have professional
documentation.

Documentation must explain:

* what the module does
* what the type represents
* what the function does
* ownership
* lifetime
* important invariants
* protocol behavior
* error behavior
* algorithmic decisions
* security requirements
* relevant standards

Use normal professional prose.

Do NOT use decorative separator comments such as:

```text
──────────────────────────────────────
======================================
--------------------------------------
```

Do not use ASCII art as documentation.

Do not write noisy banner comments.

Do not use the `§` symbol in standards references.

Use:

```text
RFC 7541 Section 5.1
```

instead of:

```text
RFC 7541 §5.1
```

Documentation should be concise but technically meaningful.

---

# 40. Tests Are Mandatory

Never skip tests.

Every implementation change must include appropriate tests.

Test:

* valid input
* invalid input
* boundary values
* malformed input
* truncated input
* oversized input
* allocation failure where practical
* protocol state errors
* timeout behavior
* cancellation
* concurrent access
* connection shutdown
* resource cleanup
* interoperability

Do not remove an existing test simply because the new implementation makes it
difficult to satisfy.

Fix the implementation instead.

---

# 41. No Test Suppression

Do not:

* skip tests to hide failures
* mark tests expected-failure without justification
* delete failing tests
* weaken assertions
* replace integration tests with unit tests
* reduce coverage merely to get a green build

If an interoperability test cannot run in a particular environment, document
the exact environmental reason.

The final verification report must explicitly list:

```text
passed
failed
skipped
not run
```

with reasons.

---

# 42. Target Platforms

The library must be designed and tested for:

```text
Windows 32-bit
Windows 64-bit
Linux 32-bit
Linux 64-bit
macOS
AArch64
```

Where supported by Zig and the project's build configuration, verify all
relevant targets.

Pay attention to:

* pointer width
* integer sizes
* endianness
* socket APIs
* file APIs
* threading
* synchronization
* atomics
* TLS behavior
* filesystem behavior
* platform-specific errors

Do not assume Windows and POSIX behavior are identical.

---

# 43. Cross-Platform Code

Prefer Zig's cross-platform abstractions.

Isolate platform-specific behavior in:

```text
src/sockets/sys.zig
```

or an appropriate platform abstraction.

Do not spread OS-specific conditionals throughout protocol implementations.

---

# 44. Interoperability

Protocol implementations must be tested against real implementations where
possible.

Relevant interoperability references include:

```text
nghttp2
nghttp3
ngtcp2
quiche
h2o
curl
standard HTTP clients/servers
```

HTTP interoperability must cover:

```text
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
```

TLS interoperability must include real TLS peers.

QUIC interoperability must include real QUIC implementations where available.

---

# 45. Fuzzing

Network-facing parsers should have fuzz coverage.

Prioritize:

* HTTP/1 parser
* HTTP/2 frame parser
* HPACK
* HTTP/3 frame parser
* QPACK
* QUIC packet parser
* QUIC frame parser
* TLS record parser
* TLS handshake parser
* WebSocket frame parser
* multipart parser
* URI parser
* header parser

Use existing fuzz infrastructure such as:

```text
src/protocols/http1/fuzz.zig
```

as a model.

---

# 46. Performance

Performance matters, but correctness comes first.

Optimize through:

* buffer reuse
* allocation reduction
* zero-copy where safe
* efficient parsing
* efficient serialization
* connection reuse
* HTTP/2 multiplexing
* HTTP/3 multiplexing
* QUIC packet batching
* efficient queues
* efficient worker pools

Do not sacrifice correctness or security for micro-optimizations.

Avoid premature optimization.

Benchmark meaningful workloads.

---

# 47. Resource Lifecycle

Every resource must have a deterministic lifecycle.

This includes:

* sockets
* TLS state
* QUIC connections
* HTTP/2 streams
* HTTP/3 streams
* worker tasks
* timers
* buffers
* allocators
* connection-pool entries
* DNS cache entries
* file handles
* WebSocket connections
* FTP data connections

Every success path and failure path must release resources correctly.

---

# 48. Deadlock and Race Prevention

Before merging concurrency-related code, reason about:

* lock ordering
* ownership
* blocking operations
* callbacks
* worker shutdown
* queue shutdown
* cancellation
* connection close
* protocol shutdown
* error propagation

Never hold a lock while performing an operation that can synchronously call
back into the same subsystem unless reentrancy is explicitly safe.

---

# 49. Protocol Layering

Maintain clean layering.

The intended architecture is conceptually:

```text
Application
    |
Web framework
    |
HTTP request/response abstraction
    |
HTTP/1 / HTTP/2 / HTTP/3
    |
TLS / QUIC
    |
TCP / UDP
    |
OS networking
```

Examples:

```text
TCP
 |
TLS
 |
ALPN
 |
HTTP/1.0 or HTTP/1.1 or HTTP/2
```

and:

```text
UDP
 |
QUIC
 |
QUIC TLS
 |
ALPN h3
 |
HTTP/3
```

Do not allow protocol modules to bypass lower-level abstractions unnecessarily.

---

# 50. Client and Server Feature Parity

Features should be exposed consistently wherever technically applicable.

Verify all relevant functionality on:

```text
client
server
HTTP/1.0
HTTP/1.1
HTTP/2
HTTP/3
TLS
QUIC
SPA
router
static files
middleware
WebSocket
SSE
multipart
compression
authentication
```

Do not implement a feature only for HTTP/1 unless the protocol itself requires
that limitation.

---

# 51. Build Discipline

After meaningful changes:

```text
zig fmt
zig build
zig build test
```

Also run relevant integration and interoperability tests.

Never declare success based only on compilation.

The final implementation must have:

```text
0 compile errors
0 test failures
0 unexplained skipped tests
```

The project target may use a result such as:

```text
All tests pass.
Any skipped test must have an explicit environmental or protocol reason.
```

Never fabricate a number such as "309 tests pass" unless the actual build
reported that result.

---

# 52. Verification Before Completion

Before declaring work complete, verify:

## Architecture

* no duplicate abstractions
* no dead code introduced
* no unnecessary files
* no circular dependency
* correct module placement
* existing APIs preserved where possible

## Protocols

* HTTP/1.0
* HTTP/1.1
* HTTP/2
* HTTP/3
* QUIC
* TLS
* ALPN

## Networking

* TCP
* UDP
* DNS
* proxy
* SOCKS5

## Web

* router
* middleware
* SPA
* static files
* WebSocket
* SSE
* multipart
* authentication
* OpenAPI
* docs
* health
* metrics

## Client

* request API
* pooling
* cookies
* redirects where supported
* streaming
* TLS
* proxies
* protocol negotiation

## Server

* lifecycle
* routing
* request handling
* response handling
* graceful shutdown
* concurrency
* HTTP protocol selection

## Testing

* unit tests
* integration tests
* fuzz tests
* interoperability tests
* negative tests
* edge cases
* cross-platform build checks

---

# 53. Change Strategy

When functionality is missing:

1. Identify the missing behavior.
2. Locate the nearest existing implementation.
3. Search the reference projects.
4. Read the corresponding C/C++ implementation.
5. Read the associated header declarations.
6. Understand the algorithm.
7. Check the applicable RFC.
8. Determine the correct Zig abstraction.
9. Implement the feature natively.
10. Reuse existing project primitives.
11. Add tests.
12. Run all affected tests.
13. Run the complete test suite.
14. Run interoperability tests.
15. Review for duplication and deadlocks.
16. Review memory ownership.
17. Review security properties.
18. Format the source.
19. Rebuild all applicable targets.

---

# 54. Do Not Rewrite Working Architecture Without Evidence

Do not perform large rewrites simply because another architecture looks cleaner.

A rewrite is justified only when the existing architecture prevents:

* standards compliance
* correctness
* security
* required functionality
* modularity
* resource safety
* interoperability
* maintainability

When a rewrite is necessary, preserve compatible public behavior wherever
possible and migrate incrementally.

---

# 55. Public API Stability

Prefer a stable, ergonomic public API.

Internal protocol changes should not unnecessarily force application developers
to change their code.

Keep protocol-specific implementation details internal unless users genuinely
need configuration or inspection capabilities.

---

# 56. Examples and Documentation

When adding major public functionality, update:

```text
README.md
docs/
examples/
```

where appropriate.

Examples should demonstrate the intended public API rather than internal
protocol machinery.

---

# 57. Final Agent Behavior

The coding agent must behave as an engineer maintaining a production networking
library.

Do not:

* guess
* blindly copy
* duplicate code
* skip tests
* hide failures
* ignore compiler errors
* ignore protocol errors
* invent APIs from another Zig version
* introduce unnecessary dependencies
* create arbitrary nested folders
* create giant unrelated modules
* add decorative comments
* leave dead code
* leave TODOs for functionality that was explicitly requested
* claim full support when functionality is only partially implemented

Do:

* inspect first
* understand first
* search first
* reuse first
* verify standards
* inspect C/C++ references
* implement natively in Zig
* preserve architecture
* add tests
* fuzz parsers
* run interoperability tests
* verify memory ownership
* verify concurrency
* verify security
* verify cross-platform behavior
* document important algorithms
* keep APIs ergonomic
* keep modules cohesive

---

# 58. Definition of Done

A feature is NOT complete merely because it compiles.

A feature is complete only when:

1. The existing architecture has been understood.
2. Relevant source code has been inspected.
3. Relevant C/C++ implementations and headers have been inspected.
4. Applicable standards have been checked.
5. Existing project functionality has been reused.
6. Native Zig implementation is complete.
7. Error handling is complete.
8. Memory ownership is correct.
9. Concurrency is correct.
10. Security properties are satisfied.
11. Unit tests exist.
12. Edge-case tests exist.
13. Negative tests exist.
14. Fuzzing is added where appropriate.
15. Integration tests pass.
16. Interoperability tests pass where applicable.
17. No unrelated regressions exist.
18. Documentation is professional.
19. Source placement is correct.
20. `zig fmt` passes.
21. `zig build` passes.
22. `zig build test` passes.
23. Applicable cross-platform targets build successfully.
24. No unexplained test failures or skips remain.

The final report must clearly distinguish:

```text
Implemented
Verified
Interoperability-tested
Platform-tested
Known limitations
```

Never claim "fully implemented" when known protocol functionality remains
missing.

---

# 59. Repository Structure

The project root contains:

```text
.gitignore
.github/
bench/
build.zig
build.zig.zon
CODE_OF_CONDUCT.md
CONTRIBUTING.md
LICENSE
README.md

cpp-httplib/
h2o/
nghttp2/
nghttp3/
ngtcp2/
picohttpparser/
quiche/

docs/
examples/
zig-pkg/

src/
```

Generated directories such as:

```text
.zig-cache/
zig-out/
.cache/
__cmake_systeminformation/
```

must not be treated as source-of-truth implementation directories.

Do not modify generated build artifacts to implement functionality.

---

# 60. Primary Source Tree

The primary implementation lives under:

```text
src/
```

with the following major areas:

```text
src/client
src/common
src/compression
src/concurrency
src/integration
src/net
src/protocols
src/server
src/sockets
src/utils
src/web
src/httpx.zig
```

Protocol implementations live under:

```text
src/protocols/http1
src/protocols/http2
src/protocols/http3
src/protocols/quic
src/protocols/tls
src/protocols/ftp
src/protocols/common
```

Networking lives under:

```text
src/net
src/sockets
```

Application/web functionality lives under:

```text
src/web
src/server
src/client
```

Shared functionality lives under:

```text
src/common
src/compression
src/concurrency
src/utils
```

Keep this separation intact.

---

# 61. Absolute Priority

When tradeoffs occur, use this priority:

```text
Correctness
    >
Security
    >
Standards compliance
    >
Interoperability
    >
Resource safety
    >
API usability
    >
Maintainability
    >
Performance
```

Performance must never justify incorrect protocol behavior.

Compatibility must never justify a known security vulnerability.

Convenience must never justify violating protocol specifications.

---

# 62. Final Principle

Build the library as one coherent native Zig networking stack.

Do not build four unrelated HTTP implementations.

Build:

```text
                Unified Client / Server API
                         |
              Request / Response Model
                         |
        +----------------+----------------+
        |                |                |
     HTTP/1.x           HTTP/2          HTTP/3
        |                |                |
       TLS              TLS             QUIC TLS
        |                |                |
       TCP              TCP              QUIC
        |                |                |
        +----------------+----------------+
                         |
                    Socket Layer
                         |
                    OS Networking
```

The HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 implementations must share common
application-level abstractions.

TLS and ALPN must integrate cleanly with protocol selection.

QUIC must integrate cleanly with HTTP/3.

TCP and UDP must remain reusable foundations.

The web framework must remain independent of the wire protocol.

The client must remain ergonomic.

The server must remain ergonomic.

Every implementation must be native Zig, modular, reusable, tested, secure,
standards-oriented, interoperable, and maintainable.

Always understand the existing code first.

Then identify what is missing.

Then research the standards and mature C/C++ implementations.

Then implement the missing behavior natively in Zig.

Then test everything.

Never skip the understanding phase.
Never skip required functionality.
Never skip test cases.
Never duplicate existing functionality.
Never claim completion without verification.
Never Mention a feature is complete without interoperability testing.
Never claim a feature is complete without cross-platform verification.
Never claim a feature is complete without security verification.
Never mention this Project is based on C/C++ implementations. This project is a native Zig implementation that may reference C/C++ implementations for interoperability and standards compliance, but it is not based on them.

This Project must be All in one Complete Native Zig Networking Stack. including HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3, QUIC, TLS, ALPN, WebSockets, SSE, FTP, SPA, static files, multipart, compression, authentication, routing, middleware, concurrency, connection pooling, DNS resolution, proxy support, and all other relevant networking functionality.

This project targets Zig 0.16.0. The Zig 0.16.0 standard library does not provide all of the complete, production-grade networking and protocol functionality required by this framework, particularly the complete server-side and protocol-stack capabilities required for TCP/UDP networking, TLS server operation, QUIC, HTTP/2, HTTP/3, WebSocket, DNS, proxying, and the higher-level networking abstractions required by this project. Therefore, this project intentionally provides its own complete native Zig networking and protocol implementations under `src/`.

Do not treat the missing functionality in Zig 0.16.0 as a reason to leave functionality incomplete, create placeholders, fake protocol support, or depend on an unrelated external networking implementation. Where Zig 0.16.0 lacks the required capability, implement the complete functionality natively in this project's Zig source code, using the appropriate operating-system APIs through the project's platform/socket abstraction where necessary.

This means the custom implementations must be real, complete implementations—not compatibility shims that merely make the API compile. TCP, UDP, sockets, DNS, SOCKS5/proxy support, TLS 1.2, TLS 1.3, ALPN, QUIC, HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3, WebSocket, and their associated transports, framing, state machines, cryptography, flow control, connection management, error handling, and server/client functionality must be implemented to the applicable industry standards and protocol specifications.

At the same time, do not unnecessarily reimplement functionality that Zig 0.16.0 already provides correctly as a general-purpose language/runtime facility. The project may and should use appropriate Zig standard-library facilities for allocators, memory management, slices, arrays, hash maps, integer operations, atomics, synchronization primitives, compile-time functionality, formatting, testing, cryptographic primitives where appropriate, randomness/entropy, and other general-purpose facilities. The distinction is that the project's networking stack and protocol implementations must remain owned by and implemented within this project's native Zig architecture.

Before implementing missing functionality, first inspect and understand the existing implementation throughout `src/`, identify what is already implemented and reusable, and determine exactly what is missing or incorrect. Then study the applicable protocol specifications and the provided production reference implementations to understand the required wire formats, state machines, algorithms, security properties, interoperability behavior, and edge cases. Implement the missing functionality natively in Zig and integrate it with the existing abstractions instead of creating a parallel or duplicate subsystem.

The objective is a complete native Zig networking foundation specifically designed around the capabilities and limitations of Zig 0.16.0, rather than assuming that Zig's standard library will eventually provide the missing functionality. Every custom subsystem must be production-quality, modular, reusable, thoroughly tested, interoperable, and correctly integrated into both client and server paths.


## Testing, Edge Cases, Coverage, and Cross-Platform CI

This section supplements the existing `AGENT.md` rules. The existing project architecture, implementation, documentation, source-layout, reuse, and coding rules remain authoritative.

### Complete Test Coverage

Every implemented feature must have comprehensive automated tests. Do not treat existing tests as sufficient evidence of correctness.

For every module, public API, protocol implementation, codec, parser, serializer, state machine, transport, client feature, server feature, and web-framework feature:

- Preserve all existing test cases.
- Add missing tests before declaring the implementation complete.
- Add normal success-path tests.
- Add failure-path tests.
- Add malformed-input tests.
- Add boundary-value tests.
- Add maximum/minimum-value tests.
- Add truncated-input tests.
- Add empty-input tests.
- Add oversized-input tests.
- Add invalid-state and invalid-transition tests.
- Add timeout, cancellation, EOF, connection-close, and partial-I/O tests where applicable.
- Add allocation/error-path tests where practical.
- Add concurrency and synchronization tests where applicable.
- Add regression tests for every bug discovered and fixed.
- Add protocol interoperability tests where applicable.
- Test both client-side and server-side behavior.

Tests must validate actual behavior and protocol correctness rather than merely exercising code lines.

### Test Placement

Keep implementation-specific tests alongside their corresponding Zig source files whenever practical.

Examples:

- `src/protocols/http1/parser.zig` → parser tests
- `src/protocols/http1/writer.zig` → writer tests
- `src/protocols/http2/frame.zig` → frame tests
- `src/protocols/http2/hpack.zig` → HPACK tests
- `src/protocols/http3/frame.zig` → HTTP/3 frame tests
- `src/protocols/http3/qpack.zig` → QPACK tests
- `src/protocols/quic/*` → QUIC packet, transport, crypto, loss, congestion-control, stream, and state-machine tests
- `src/protocols/tls/*` → TLS record, handshake, cryptographic, certificate, ALPN, transport, and state-machine tests
- `src/sockets/*` → socket and transport tests
- `src/net/*` → DNS, proxy, SOCKS5, address, and resolution tests
- `src/client/*` → client behavior tests
- `src/server/*` → server lifecycle and connection tests
- `src/web/*` → framework feature tests
- `src/integration/*` → multi-layer integration and interoperability tests

Do not move tests away from the relevant implementation merely to make coverage reporting easier.

### HTTP Protocol Test Matrix

Comprehensively test:

- HTTP/1.0
- HTTP/1.1
- HTTP/2
- HTTP/3

Test both:

- client → server
- server → client

Where applicable, test:

- request construction
- response construction
- parsing
- serialization
- connection reuse
- keep-alive
- connection closing
- streaming
- request bodies
- response bodies
- trailers
- redirects
- cookies
- compression
- multipart
- authentication
- routing
- middleware
- static files
- SPA serving
- SSE
- WebSocket integration
- error responses
- timeouts
- cancellation
- malformed requests
- malformed responses.

HTTP/1.0 and HTTP/1.1 must not be treated as the same protocol merely because they share the HTTP/1.x parser.

HTTP/2 and HTTP/3 must be tested as independent protocol implementations with their respective framing, stream, flow-control, header-compression, error, and connection-management semantics.

### TLS and ALPN Test Matrix

Comprehensively test the supported TLS stack, including:

- TLS 1.2
- TLS 1.3
- TLS record processing
- handshake state machines
- certificate handling
- certificate validation
- key exchange
- cipher-suite negotiation
- transcript handling
- Finished verification
- encryption/decryption
- sequence numbers
- connection shutdown
- handshake failures
- invalid certificates
- invalid extensions
- unsupported versions
- unsupported cipher suites
- unsupported groups
- invalid signatures
- malformed handshake messages
- record-size limits
- authentication failures.

Test ALPN negotiation for:

- `http/1.0`
- `http/1.1`
- `h2`
- `h3`

Verify that protocol selection is correctly connected to the appropriate transport and HTTP implementation.

Do not allow an invalid transport/protocol combination to silently succeed.

### QUIC and HTTP/3

Test the complete QUIC stack, including:

- packet parsing
- packet encoding
- variable-length integers
- connection IDs
- packet protection
- header protection
- Initial keys
- Handshake keys
- 1-RTT keys
- TLS integration
- crypto streams
- transport parameters
- streams
- flow control
- ACK tracking
- loss detection
- retransmission
- congestion control
- path handling
- connection migration where implemented
- connection close
- idle timeout
- packet-number handling
- malformed packets
- invalid frames
- protocol violations
- key transitions.

HTTP/3 tests must cover:

- control streams
- request streams
- response streams
- SETTINGS
- DATA
- HEADERS
- PRIORITY-related behavior where applicable
- GOAWAY
- CANCEL_PUSH where applicable
- MAX_PUSH_ID where applicable
- QPACK
- stream errors
- connection errors
- malformed frames
- invalid stream usage
- flow-control limits.

### Web Framework Test Coverage

Test the complete framework stack, including:

- router
- route matching
- path parameters
- query parameters
- headers
- request objects
- response objects
- middleware
- authentication
- cookies
- multipart
- SSE
- WebSocket
- static files
- SPA fallback
- OpenAPI
- Swagger UI
- ReDoc
- Scalar
- health endpoints
- metrics
- error handling
- request validation
- response serialization
- content types
- compression
- HTTP version selection.

Verify that these features work consistently through every applicable HTTP version rather than only through HTTP/1.1.

### Networking Test Coverage

Test:

- TCP
- UDP
- DNS
- DNS caching
- address resolution
- proxies
- SOCKS5
- connection pooling
- socket lifecycle
- read/write boundaries
- partial reads
- partial writes
- connection resets
- EOF
- timeouts
- cancellation
- resource cleanup
- concurrent connections.

Do not assume operating-system socket behavior is identical across platforms.

### Concurrency Testing

Test all concurrency primitives and worker infrastructure for:

- normal operation
- queue exhaustion
- queue saturation
- worker shutdown
- cancellation
- concurrent producers
- concurrent consumers
- worker reuse
- shutdown races
- resource cleanup
- synchronization correctness.

Tests must be designed to detect deadlocks, race conditions, starvation, lost work, double completion, and use-after-shutdown behavior.

Never introduce a test that can deadlock indefinitely. Use deterministic timeouts or controlled synchronization.

### Cross-Platform Requirements

All implementation and tests must support the project's intended platforms and targets.

At minimum, validate the configured CI targets for:

- Windows x86
- Windows x86_64
- Windows AArch64
- Linux x86
- Linux x86_64
- Linux AArch64
- macOS x86_64
- macOS AArch64

Where GitHub Actions does not provide a native runner for a target, use an appropriate cross-compilation, emulation, or other deterministic validation strategy.

Platform-specific code must be isolated behind appropriate abstractions and must not leak operating-system assumptions into portable protocol code.

Pay particular attention to:

- socket APIs
- file descriptors versus Windows handles
- address structures
- filesystem paths
- threading
- atomics
- synchronization
- timers
- random-number sources
- byte ordering
- integer widths
- pointer widths
- alignment
- endianness
- network shutdown semantics.

### GitHub Actions

GitHub Actions is a required validation environment.

CI must execute the appropriate:

1. formatting checks
2. build checks
3. unit tests
4. integration tests
5. protocol tests
6. interoperability tests
7. target/platform compilation checks
8. release-build checks.

A passing CI pipeline must represent genuine successful validation.

Never make CI pass by:

- deleting tests
- weakening assertions
- hiding errors
- ignoring exit codes
- disabling failing tests
- converting failures into skips
- adding unconditional skip conditions
- reducing test coverage requirements
- silently excluding platforms.

### Test Skip Policy

Tests must not be skipped simply because they are difficult, slow, inconvenient, flaky, or currently failing.

A test may be skipped only when execution is genuinely impossible in the current environment.

Every legitimate skip must:

- have an explicit environmental or platform condition;
- explain why execution is impossible;
- be limited to the smallest affected test;
- provide deterministic alternative coverage whenever possible;
- never hide an implementation failure.

Prefer replacing external or environment-dependent tests with deterministic local tests when the same behavior can be validated locally.

For example, an external HTTPS interoperability test should not be skipped merely because Internet access is inconvenient. If possible, create a local TLS peer or deterministic interoperability fixture instead.

Never use:

```text
if CI -> skip




# Client-Side API Consistency and Reuse Rules

## Purpose

The client-side API of this project must be clean, consistent, type-safe, ergonomic, minimal by default, and fully reusable across HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3.

Before modifying or adding any client-side API, **first read and understand the existing implementation across the entire `src/` tree**. Do not design an API in isolation from the existing codebase.

The existing client API is not automatically considered correct. If an existing API conflicts with these project rules, **change it**, even if the change is breaking.

The goal is a coherent library API rather than preserving historical API shapes at the expense of correctness or usability.

---

## 1. Read the Existing Code First

Before implementing client-side functionality:

1. Inspect the existing client modules.
2. Inspect common types used by the client.
3. Inspect request and response representations.
4. Inspect protocol negotiation.
5. Inspect HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 implementations.
6. Inspect TLS and QUIC integration.
7. Inspect connection pooling and DNS/resolution.
8. Inspect compression, cookies, multipart, authentication, proxy, and WebSocket support.
9. Inspect existing tests and integration tests.
10. Search the entire `src/` tree for existing functionality before creating anything new.

Relevant existing areas include:

* `src/client`
* `src/common`
* `src/compression`
* `src/net`
* `src/protocols`
* `src/server`
* `src/sockets`
* `src/web`
* `src/integration`
* `src/httpx.zig`

**Reuse existing implementations whenever technically appropriate.**

Do not create duplicate request types, response types, header containers, URI parsers, HTTP-version enums, connection pools, codecs, allocators, protocol state, or error abstractions when an appropriate implementation already exists.

---

## 2. Existing API Is Not Sacred

Do not preserve an existing client API merely because it already exists.

If an existing API is:

* inconsistent,
* unnecessarily verbose,
* difficult to discover,
* unsafe,
* not type-safe,
* duplicating another API,
* allocator-inconsistent,
* difficult to extend,
* incompatible with protocol abstraction,
* unnecessarily coupled to a specific HTTP version,
* or inconsistent with the project's API design,

then **refactor or replace it**.

Breaking changes are explicitly allowed when necessary.

Prefer:

> one correct, consistent API

over:

> multiple legacy APIs maintained only for compatibility.

When changing an API, update:

* implementation,
* tests,
* integration tests,
* examples,
* documentation,
* examples in `README.md`,
* any internal callers,
* benchmarks where applicable,
* and related public types.

Do not leave compatibility wrappers that create unnecessary API duplication unless there is a strong technical reason.

---

# 3. Minimal API by Default

The most basic request must require minimal configuration.

The library should support a clean API such as:

```zig
const httpx = @import("httpx");

pub fn main() !void {
    var response = try httpx.get(.{
        .url = "https://httpbin.org/get",
    });
    defer response.deinit();
}
```

Likewise:

```zig
var response = try httpx.post(.{
    .url = "https://httpbin.org/post",
    .json = "{\"name\":\"Alice\",\"age\":30}",
});
defer response.deinit();
```

The default API must work without requiring users to construct:

* allocators,
* clients,
* pools,
* DNS resolvers,
* transports,
* TLS configuration,
* HTTP-version configuration,
* socket configuration,
* compression configuration,
* or other infrastructure objects.

Reasonable production defaults must be provided internally.

---

# 4. Configuration Must Be Optional

Every client feature should follow this principle:

**Simple by default, configurable when required.**

A user should be able to start with:

```zig
httpx.get(.{
    .url = "...",
});
```

and progressively customize:

```zig
httpx.get(.{
    .url = "...",
    .timeout = ...,
    .headers = ...,
    .query = ...,
    .cookies = ...,
    .proxy = ...,
    .http_version = ...,
    .tls = ...,
    .compression = ...,
});
```

Do not force configuration objects when defaults are sufficient.

All optional configuration should have sensible defaults.

Explicit user configuration must override the corresponding default without unexpectedly changing unrelated defaults.

---

# 5. Explicit Allocator API

The client API must support both:

### Convenience API

No allocator supplied by the caller:

```zig
var response = try httpx.get(.{
    .url = "...",
});
defer response.deinit();
```

### Explicit allocator API

For applications that need complete memory ownership control:

```zig
var client = try httpx.Client.init(allocator, .{});
defer client.deinit();

var response = try client.get(.{
    .url = "...",
});
defer response.deinit();
```

The exact final syntax must be determined after inspecting the existing implementation, but the principle is mandatory.

Do not require an allocator for simple convenience APIs.

Do not hide allocator ownership in explicit-client APIs.

Every allocation must have clear ownership and lifetime semantics.

---

# 6. Convenience HTTP Methods

Provide clean convenience aliases where appropriate.

At minimum, evaluate and implement consistent aliases for:

* `get`
* `post`
* `put`
* `patch`
* `delete`
* `head`
* `options`
* `trace`

Also provide the appropriate lower-level request API for methods not covered by convenience functions.

For example:

```zig
httpx.get(.{ ... });
httpx.post(.{ ... });
httpx.put(.{ ... });
httpx.patch(.{ ... });
httpx.delete(.{ ... });
httpx.head(.{ ... });
httpx.options(.{ ... });
```

Do not implement each alias as an independent request implementation.

All aliases must reuse the same underlying request pipeline.

---

# 7. One Request Model

All convenience APIs must eventually use the same underlying request machinery.

Conceptually:

```text
get()
post()
put()
patch()
delete()
head()
options()
custom()
        |
        v
    Request API
        |
        v
 Client / Transport
        |
        v
 HTTP version selection
        |
        +--> HTTP/1.0
        +--> HTTP/1.1
        +--> HTTP/2
        +--> HTTP/3
```

Do not maintain separate request implementations for each convenience method.

Do not duplicate request construction, headers, body handling, timeout handling, redirects, cookies, authentication, or response processing.

---

# 8. Type-Safe Request Configuration

Request configuration should use typed Zig structures rather than unstructured configuration where practical.

Prefer:

```zig
httpx.post(.{
    .url = "...",
    .headers = ...,
    .json = ...,
});
```

over APIs requiring arbitrary string maps for every feature.

Use Zig's compile-time type system where it materially improves correctness and usability.

Configuration structures should:

* have sensible defaults,
* make common operations obvious,
* prevent invalid combinations where possible,
* remain extensible,
* and avoid unnecessary generic complexity.

---

# 9. JSON API

The JSON API must support both:

### Raw JSON

```zig
.json = "{\"name\":\"Alice\",\"age\":30}"
```

and, where technically possible with the chosen Zig serialization architecture:

### Typed Zig values

```zig
.json = .{
    .name = "Alice",
    .age = 30,
}
```

If compile-time serialization cannot safely support a particular Zig type, do not fake type safety.

Design a proper typed serialization interface using the project's existing infrastructure or Zig facilities.

Do not create a separate JSON subsystem if an appropriate implementation already exists.

JSON request handling must automatically handle appropriate:

* serialization,
* `Content-Type`,
* body length/framing,
* compression where configured,
* errors,
* allocator ownership,
* and response decoding.

---

# 10. Type-Safe Response APIs

Responses should support both convenient raw access and optional typed decoding.

Basic usage:

```zig
var response = try httpx.get(.{
    .url = "...",
});
defer response.deinit();

std.debug.print("{s}", .{response.body});
```

Typed response functionality should be available without forcing it on users.

For example, the final API may support an appropriate pattern such as:

```zig
const User = struct {
    name: []const u8,
    age: u32,
};

const user = try response.json(User);
```

or another idiomatic Zig design determined by the existing architecture.

The implementation must clearly document:

* ownership,
* allocation,
* lifetime,
* parsing errors,
* malformed JSON behavior,
* and whether returned strings reference the response buffer or own independent memory.

---

# 11. Response Must Be Protocol-Independent

The public response API must not force users to care whether the request used:

* HTTP/1.0,
* HTTP/1.1,
* HTTP/2,
* or HTTP/3.

The same high-level response abstraction must work across all supported protocols.

Protocol-specific details may be exposed through advanced APIs where useful, but they must not pollute the basic API.

---

# 12. HTTP Version Configuration

The client must support:

* automatic HTTP-version negotiation,
* explicit HTTP/1.0,
* explicit HTTP/1.1,
* explicit HTTP/2,
* explicit HTTP/3,
* and appropriate fallback behavior.

The public configuration must reuse the existing `src/common/http_version.zig` abstraction rather than introducing another HTTP-version enum.

ALPN must be handled correctly for TLS-based negotiation.

HTTP/3 must use QUIC and appropriate HTTP/3 ALPN.

Do not pretend that HTTP/3 can operate over the TCP/TLS transport.

---

# 13. Protocol-Neutral Client Architecture

The client should conceptually follow:

```text
Client API
   |
Request
   |
Connection / Pool
   |
Protocol Selection
   |
   +-- HTTP/1.0
   +-- HTTP/1.1
   +-- HTTP/2
   +-- HTTP/3
   |
Transport
   |
   +-- TCP
   +-- TLS
   +-- QUIC
```

The API layer must not duplicate protocol implementations.

HTTP/1.x should reuse the existing HTTP/1 implementation.

HTTP/2 should reuse the existing HTTP/2 implementation.

HTTP/3 should reuse the existing HTTP/3 + QUIC implementation.

TLS should reuse the existing TLS subsystem.

---

# 14. All Existing Client Features Must Be Integrated

Before declaring the client API complete, inspect and correctly integrate all existing client-side functionality, including where applicable:

* URLs
* URI parsing
* query parameters
* headers
* HTTP methods
* request bodies
* streaming bodies
* response bodies
* streaming responses
* redirects
* cookies
* compression
* authentication
* Basic authentication
* Bearer authentication
* multipart
* proxies
* SOCKS5
* DNS
* connection pooling
* keep-alive
* timeouts
* cancellation
* TLS
* ALPN
* HTTP/1.0
* HTTP/1.1
* HTTP/2
* HTTP/3
* QUIC
* WebSocket
* SSE
* error handling
* logging
* metrics
* retries where appropriate
* content negotiation
* MIME handling

Do not invent duplicate versions of these systems.

---

# 15. Configuration Hierarchy

Configuration should have a predictable hierarchy:

```text
Built-in defaults
        ↓
Client defaults
        ↓
Per-request configuration
        ↓
Explicit per-request override
```

A more specific configuration must override a less specific configuration.

For example:

```text
library default timeout
        ↓
client timeout
        ↓
request timeout
```

Do not unexpectedly mutate global configuration when a request overrides a value.

---

# 16. Reuse Existing Infrastructure

Before creating a new type/function/module, search for an existing implementation.

Reuse:

* `src/common/headers.zig`
* `src/common/http_version.zig`
* `src/common/method.zig`
* `src/common/status.zig`
* `src/common/uri.zig`
* `src/common/errors.zig`
* `src/compression/codec.zig`
* `src/client/request.zig`
* `src/client/client.zig`
* `src/client/pool.zig`
* `src/client/cookies.zig`
* `src/net/*`
* `src/sockets/*`
* `src/protocols/http1/*`
* `src/protocols/http2/*`
* `src/protocols/http3/*`
* `src/protocols/quic/*`
* `src/protocols/tls/*`
* `src/web/*`

Extend an existing abstraction when appropriate instead of introducing a competing abstraction.

---

# 17. No Duplicate Logic

Do not create:

* multiple HTTP request pipelines,
* multiple response types for the same concept,
* multiple header implementations,
* multiple HTTP-version representations,
* multiple URI implementations,
* multiple allocator strategies,
* multiple connection pools,
* multiple protocol negotiation implementations,
* duplicate compression logic,
* duplicate TLS logic,
* duplicate QUIC logic,
* duplicate serialization logic.

If two implementations solve the same problem, consolidate them where practical.

---

# 18. Thread Safety and Concurrency

Client APIs must have clearly defined concurrency behavior.

Connection pools, shared clients, DNS caches, request state, and reusable transports must not introduce:

* data races,
* deadlocks,
* lock inversions,
* use-after-free,
* double frees,
* allocator lifetime violations,
* connection corruption,
* or stream cross-contamination.

HTTP/2 and HTTP/3 multiplexing must correctly isolate streams.

One request must never accidentally consume another request's response data.

---

# 19. Resource Ownership

Every public API must have clear ownership rules.

Document:

* who owns requests,
* who owns responses,
* who owns body buffers,
* who owns headers,
* who owns cookies,
* who owns connections,
* who owns pools,
* who owns TLS state,
* who owns protocol state,
* and which allocator owns allocated memory.

`deinit()` must be deterministic and safe.

Avoid hidden long-lived allocations.

---

# 20. Testing Requirements

Do not change client APIs without updating tests.

Every new public API must have tests.

Every refactored API must have regression tests.

Test:

* minimal API,
* explicit allocator API,
* every convenience alias,
* custom methods,
* empty configuration,
* full configuration,
* default overrides,
* typed JSON,
* raw JSON,
* typed response decoding,
* malformed response data,
* allocation failures,
* connection failures,
* DNS failures,
* TLS failures,
* ALPN negotiation,
* HTTP/1.0,
* HTTP/1.1,
* HTTP/2,
* HTTP/3,
* redirects,
* cookies,
* compression,
* multipart,
* proxies,
* authentication,
* streaming,
* cancellation,
* timeouts,
* concurrent requests,
* pooled connections,
* connection reuse,
* protocol fallback,
* malformed input,
* oversized input,
* and all relevant edge cases.

Do not remove or weaken existing tests merely to make the new API pass.

If an existing test reflects obsolete behavior that conflicts with the new API contract, update the test intentionally and document the breaking change.

---

# 21. Examples Are Part of the API Contract

Whenever client APIs change, update the examples.

Examples must demonstrate individual features clearly rather than putting every feature into one enormous example.

Examples should include simple patterns such as:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

and progressively advanced usage.

Do not make basic examples unnecessarily complicated.

---

# 22. Documentation

Every public Zig file and public API must have professional documentation.

Documentation must explain:

* what the module does,
* what the API does,
* important parameters,
* ownership,
* allocator behavior,
* supported protocols,
* relevant algorithms,
* important edge cases,
* and relevant standards.

Use references such as:

```text
RFC 9113, Section 5.1
RFC 7541, Section 5.1
RFC 8446, Section 4.4.4
```

Do not use decorative separator comments such as:

```text
--------------------------------
================================
────────────────────────────────
```

Documentation must be normal professional technical documentation.

---

# 23. Zig 0.16.0 Compatibility

The implementation targets Zig 0.16.0.

Do not assume networking functionality exists in Zig standard library merely because similar functionality exists in other languages or older/newer Zig versions.

This project provides its own native networking stack where Zig 0.16.0 lacks the required networking facilities.

However, normal Zig standard-library facilities may be used where appropriate, including:

* allocators,
* slices,
* arrays,
* hash maps,
* formatting,
* memory utilities,
* standard cryptographic primitives where appropriate,
* compile-time facilities,
* and other general-purpose standard-library functionality.

Do not reimplement ordinary Zig language/runtime facilities unnecessarily.

---

# 24. Breaking Changes Are Allowed

If the existing client API does not satisfy these rules, **change it**.

Do not preserve an inferior API solely for compatibility.

A breaking change is acceptable when it produces:

* a cleaner API,
* stronger type safety,
* better allocator semantics,
* better consistency,
* less duplication,
* better protocol abstraction,
* better performance,
* or better long-term maintainability.

After making a breaking change, update the complete repository so there are no stale callers.

Search the entire repository for usages before finishing.

---

# 25. Final Client API Quality Gate

Before considering client-side work complete, verify:

* [ ] Minimal requests work without explicit configuration.
* [ ] Explicit allocator usage works.
* [ ] Convenience APIs work.
* [ ] All aliases use the same underlying request pipeline.
* [ ] Request configuration is type-safe.
* [ ] JSON supports the intended typed and raw forms.
* [ ] Response APIs are ergonomic and optionally type-safe.
* [ ] HTTP/1.0 works.
* [ ] HTTP/1.1 works.
* [ ] HTTP/2 works.
* [ ] HTTP/3 works.
* [ ] TLS works correctly.
* [ ] ALPN works correctly.
* [ ] QUIC works correctly.
* [ ] Connection pooling works.
* [ ] DNS works.
* [ ] Proxy support works where implemented.
* [ ] Cookies work.
* [ ] Compression works.
* [ ] Multipart works.
* [ ] Authentication works.
* [ ] Streaming works.
* [ ] Errors are consistent.
* [ ] Ownership is documented.
* [ ] Allocator behavior is documented.
* [ ] No duplicate implementation exists.
* [ ] No deadlocks are introduced.
* [ ] No unnecessary compatibility wrappers remain.
* [ ] All affected tests pass.
* [ ] Integration tests pass.
* [ ] Examples compile.
* [ ] Documentation matches the final API.

The final result must feel like **one coherent Zig HTTP client API**, not a collection of unrelated APIs accumulated over time.


# Allocator Rules

## Purpose

This project must have a consistent, explicit, safe, and predictable allocator model across the entire codebase.

All source code under `src/` must follow these allocator rules.

Before adding or changing allocation behavior, **first inspect and understand the existing allocator usage throughout the repository**. Reuse existing allocator patterns and ownership abstractions whenever they are correct.

Do not introduce a new allocator abstraction when an existing project abstraction already solves the same problem.

---

## 1. Two Supported Usage Modes

The library must support both:

### Convenience APIs

Users must be able to use the library without explicitly supplying an allocator.

Example:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

The convenience API must use a safe library-managed/default allocator strategy.

The user must not be forced to understand allocator management for basic operations.

### Explicit Allocator APIs

Advanced users must be able to control allocation explicitly.

Example:

```zig
var client = try httpx.Client.init(allocator, .{});
defer client.deinit();

var response = try client.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

The exact API shape must follow the existing project's conventions, but explicit allocator ownership must always be clear.

---

## 2. Never Hide an Explicit Allocator

When a user explicitly provides an allocator, the implementation must use that allocator for memory belonging to that client/request/operation unless a documented subsystem-specific rule says otherwise.

Do not silently replace an explicitly supplied allocator with:

* `page_allocator`,
* `GeneralPurposeAllocator`,
* a global allocator,
* an unrelated allocator,
* or an internal allocator.

Explicit allocator configuration always takes precedence over defaults.

---

## 3. Default Allocator Behavior

Convenience APIs may internally select a default allocator.

The default allocator must:

* be safe,
* have predictable lifetime,
* not leak,
* not be recreated unnecessarily,
* not create hidden per-request allocator overhead without reason,
* and work consistently across supported platforms.

Do not make the default allocator part of the public API unless there is a strong reason.

---

## 4. Allocator Hierarchy

Use a predictable hierarchy:

```text
Library default allocator
        ↓
Client allocator
        ↓
Connection / transport allocator
        ↓
Request allocator
        ↓
Temporary operation allocator
```

More-specific allocator configuration must not accidentally change the ownership of unrelated objects.

If an API explicitly accepts an allocator for an operation, that allocator must be used for allocations owned by that operation.

---

## 5. Ownership Must Be Explicit

Every dynamically allocated object must have a clearly defined owner.

For each allocation, determine:

1. Who allocated it?
2. Which allocator was used?
3. Who owns it?
4. How long does it live?
5. Who frees it?
6. When is it freed?
7. Can another object retain a reference to it?

Never return memory whose lifetime has already ended.

Never store references to temporary allocations without transferring ownership safely.

---

## 6. `deinit()` Is Mandatory for Owned Resources

Any public object that owns allocated resources must provide an appropriate `deinit()`.

Examples include:

* clients,
* responses,
* requests,
* connection pools,
* connections,
* streams,
* cookies,
* multipart bodies,
* protocol state,
* TLS state,
* QUIC state,
* routers,
* caches,
* and other allocating objects.

`deinit()` must:

* release all owned allocations,
* release nested resources,
* be safe to call after partial initialization when documented,
* avoid double-free,
* avoid use-after-free,
* and use the correct allocator.

---

## 7. Never Free With a Different Allocator

Memory must be freed using the allocator that owns the allocation according to the ownership contract.

Do not do this conceptually:

```text
allocate with allocator A
free with allocator B
```

unless the allocator contract explicitly guarantees that behavior.

Allocator mismatch bugs must be treated as correctness bugs.

---

## 8. Error Paths Must Free Correctly

Every allocation must remain correctly owned when an operation fails.

Use appropriate Zig patterns such as:

```zig
errdefer ...
```

where appropriate.

For multi-step initialization:

```text
allocation A
allocation B
allocation C
        ↓
failure
        ↓
free C
free B
free A
```

Do not rely on successful execution paths only.

Every `try`, error union, early return, and protocol failure path must be reviewed for ownership correctness.

---

## 9. Partial Initialization

Objects that perform multiple allocations must remain safely deinitializable after partial initialization.

For example:

```text
init
 ├── allocate configuration
 ├── allocate buffers
 ├── allocate protocol state
 └── initialize transport
```

If transport initialization fails after the earlier allocations succeed, those earlier allocations must be released.

Avoid leaving partially initialized objects with ambiguous ownership.

---

## 10. Borrowed Memory vs Owned Memory

Every API must clearly distinguish:

### Borrowed memory

The object does not own the memory.

Example:

```zig
headers: []const u8
```

if the API contract specifies that the caller retains ownership.

### Owned memory

The object allocates and owns the memory.

Example:

```zig
owned_body: []u8
```

The implementation must never assume ownership merely because it receives a slice.

A slice does not communicate ownership by itself.

Document ownership for public APIs where ambiguity is possible.

---

## 11. Request Lifetime

Request configuration must not retain references to temporary memory beyond the documented request lifetime.

For example, if the caller supplies:

```zig
var buffer: [1024]u8 = undefined;
```

the request must not retain a reference to that buffer after the caller's lifetime unless the API explicitly documents borrowing requirements.

For asynchronous or queued requests, this is especially important.

If data must outlive the caller's scope, the library must copy or otherwise safely own the data.

---

## 12. Response Lifetime

A response must clearly define whether:

* the response owns its body,
* the body borrows transport memory,
* headers are owned,
* cookies are owned,
* decoded JSON owns its memory,
* streaming data is borrowed,
* or data is copied.

After:

```zig
response.deinit();
```

no returned borrowed memory may be accessed.

Typed response decoding must follow the same ownership rules.

---

## 13. Connection Pool Allocation

Connection pools can be long-lived.

Do not allocate per-request state into a pool allocator unless the lifetime matches the pool.

Separate:

```text
pool lifetime
connection lifetime
stream lifetime
request lifetime
response lifetime
temporary operation lifetime
```

Do not accidentally retain request-specific allocations for the lifetime of the pool.

Likewise, never allow pool-owned memory to be freed when an individual request is destroyed.

---

## 14. HTTP/2 and HTTP/3 Multiplexing

HTTP/2 and HTTP/3 require careful allocator isolation.

Each stream must have correctly scoped memory.

A stream must not accidentally own or free memory belonging to:

* another stream,
* the connection,
* the pool,
* the client,
* or the protocol's shared compression state.

HPACK and QPACK dynamic-table allocations must follow their correct lifetime.

Concurrent streams must never cause allocator races or cross-stream ownership violations.

---

## 15. TLS and QUIC

TLS and QUIC allocations must obey the same ownership rules.

Separate lifetimes where appropriate:

```text
Client
 └── Connection
      ├── TLS state
      ├── QUIC state
      └── Streams
```

Do not allow TLS or QUIC temporary handshake allocations to survive unnecessarily.

Do not free TLS/QUIC resources using an allocator unrelated to their owning connection/client.

Handshake failures must clean up all intermediate allocations.

---

## 16. Temporary Allocations

Temporary allocations should have the shortest practical lifetime.

Examples:

* parsing scratch buffers,
* temporary header values,
* URI parsing state,
* handshake parsing,
* compression scratch space,
* serialization buffers,
* protocol frame construction,
* cryptographic intermediate values.

Do not retain temporary allocations after they are no longer needed.

Prefer stack storage for genuinely small fixed-size temporary data where appropriate and safe.

Do not blindly allocate everything on the heap.

---

## 17. Avoid Unnecessary Allocations

Performance-sensitive networking code should minimize unnecessary allocations.

Before adding an allocation, ask:

1. Can this use a stack buffer safely?
2. Can an existing buffer be reused?
3. Can the caller's memory be borrowed safely?
4. Can an existing pool/buffer abstraction be reused?
5. Can capacity be reserved once instead of repeatedly growing?
6. Can the object reuse memory across requests?
7. Is this allocation actually required?

Do not optimize by violating ownership safety.

Correct ownership always takes priority.

---

## 18. Reuse Existing Buffers and Structures

Search the existing source tree before creating a new allocation strategy.

Reuse existing:

* buffers,
* allocators,
* pools,
* arrays,
* queues,
* connection state,
* request state,
* response state,
* protocol buffers,
* compression state,
* DNS caches,
* and other reusable infrastructure.

Do not introduce duplicate allocation systems.

---

## 19. Arena Allocators

Arena allocators may be used where the lifetime is naturally scoped.

Good candidates may include:

* request-scoped temporary parsing,
* handshake-scoped temporary data,
* short-lived protocol operations,
* configuration construction,
* document generation,
* or other clearly bounded lifetimes.

Do not use an arena merely to avoid thinking about ownership.

Arena destruction must happen exactly at the intended lifetime boundary.

Never return arena-owned memory as if it were independently owned unless the arena lifetime explicitly guarantees it.

---

## 20. General Purpose Allocators

Do not instantiate a new `GeneralPurposeAllocator` for every request.

Avoid patterns that create unnecessary allocator overhead.

If a GPA is used for a top-level application or test, its lifetime must be clearly scoped.

Library internals should follow the project's established allocator architecture rather than arbitrarily creating GPAs.

---

## 21. Global Allocators

Avoid hidden global mutable allocation state.

Do not make unrelated clients implicitly share mutable allocator state unless the design explicitly requires it and is thread-safe.

Convenience APIs may use a library-managed default mechanism, but it must have well-defined concurrency and lifetime behavior.

---

## 22. Thread Safety

Allocators and allocator-owned state must be safe under the intended concurrency model.

Review allocator use around:

* worker pools,
* queues,
* connection pools,
* HTTP/2 streams,
* HTTP/3 streams,
* asynchronous operations,
* callbacks,
* background DNS,
* and shared clients.

Never introduce a data race merely because an allocator is convenient.

Never hold a lock across an allocation if that can create lock inversion or deadlock.

---

## 23. `ArrayList`, Hash Maps, and Containers

For every dynamically growing Zig container, ensure its allocator is correct.

Examples:

```zig
std.ArrayList(T).init(allocator)
```

or the equivalent Zig 0.16.0 API.

The container must be deinitialized using its owning allocator according to Zig 0.16.0 semantics.

Do not copy allocator-bearing containers incorrectly.

Pay particular attention to:

* moves,
* copies,
* ownership transfer,
* `deinit`,
* `toOwnedSlice`,
* resizing,
* error paths,
* and container invalidation.

---

## 24. Allocation Failure Must Be Handled

Never assume allocation succeeds.

Every fallible allocation must propagate or handle the appropriate error.

Test:

* allocation failure,
* partial allocation failure,
* repeated allocation failure,
* cleanup after failure,
* and recovery where supported.

Do not silently convert allocation failure into corrupted state.

---

## 25. No Memory Leaks

All tests must be capable of detecting allocator leaks where the chosen allocator supports leak detection.

Tests should use appropriate testing allocators and verify that:

```text
allocation count == deallocation count
```

for owned resources.

Leaks must be fixed rather than ignored.

---

## 26. No Double Free

Every owned allocation must have exactly one responsible owner.

Avoid situations where:

```text
object A owns memory
object B also believes it owns memory
```

When ownership is transferred, the old owner must no longer free the resource.

Document ownership transfers where necessary.

---

## 27. No Use-After-Free

Never retain pointers or slices after their owner has been destroyed.

Pay special attention to:

* parser buffers,
* response bodies,
* header storage,
* connection buffers,
* compression buffers,
* TLS handshake buffers,
* QUIC packet buffers,
* HTTP/2 frame buffers,
* HTTP/3 frame buffers,
* asynchronous callbacks,
* and queued work.

---

## 28. Allocator-Aware Public APIs

Public APIs that genuinely need caller-controlled memory must expose the allocator explicitly.

Do not hide allocator requirements behind unrelated configuration fields.

If an API can safely use a default allocator, provide a convenience form.

If an API requires deterministic memory control, provide an explicit allocator form.

The two APIs must ultimately reuse the same implementation.

---

## 29. Convenience API and Explicit API Must Share Implementation

Do not implement:

```text
httpx.get()
```

and:

```text
Client.get()
```

as separate networking stacks.

Instead:

```text
Convenience API
      ↓
default allocator/client/config
      ↓
common Client implementation
      ↓
common Request implementation
      ↓
common protocol transport
```

This prevents behavior divergence.

---

## 30. Tests Must Cover Allocator Behavior

Add and preserve tests for:

* default allocator usage,
* explicit allocator usage,
* custom allocator usage,
* allocation failure,
* deinitialization,
* partial initialization,
* request cleanup,
* response cleanup,
* connection cleanup,
* pool cleanup,
* stream cleanup,
* TLS cleanup,
* QUIC cleanup,
* HTTP/1 cleanup,
* HTTP/2 cleanup,
* HTTP/3 cleanup,
* concurrent allocation,
* concurrent deinitialization where supported,
* repeated requests,
* connection reuse,
* cancellation,
* timeout failure,
* protocol failure,
* malformed input,
* oversized input,
* and all relevant error paths.

Do not skip allocator tests because the happy path works.

---

## 31. Cross-Platform Requirements

Allocator behavior must work correctly on all supported targets.

At minimum validate:

* Windows 32-bit
* Windows 64-bit
* Windows AArch64 where supported
* Linux 32-bit
* Linux 64-bit
* Linux AArch64
* macOS 64-bit
* macOS AArch64

Do not assume pointer size, alignment, integer width, or platform allocation behavior.

CI must execute the relevant allocator tests for supported targets.

---

## 32. Zig 0.16.0

All allocator code must target Zig 0.16.0 APIs.

Do not copy allocator APIs from other Zig versions without verifying them against the project's configured Zig toolchain.

Use the standard library for ordinary allocator facilities.

The project may provide custom networking infrastructure because Zig 0.16.0 does not provide all networking facilities required by this project, but this does not justify replacing ordinary Zig allocator primitives unnecessarily.

---

## 33. Documentation

Every public allocator-aware API must have professional documentation explaining:

* allocator requirements,
* ownership,
* lifetime,
* whether memory is borrowed or owned,
* deinitialization,
* allocation failure behavior,
* and ownership transfer.

Do not use decorative separator comments such as:

```text
--------------------------------
================================
────────────────────────────────
```

Use normal professional technical documentation.

When referring to standards, use formats such as:

```text
RFC 9113, Section 5.1
RFC 8446, Section 4.4.4
```

Do not use the `§` symbol.

---

# Final Allocator Quality Gate

Before considering allocator-related work complete:

* [ ] Convenience APIs work without explicit allocators.
* [ ] Explicit allocator APIs work.
* [ ] Explicit allocators are never silently replaced.
* [ ] Ownership is clearly defined.
* [ ] Every owned object has correct cleanup.
* [ ] Partial initialization is safely cleaned up.
* [ ] Error paths do not leak.
* [ ] No allocator mismatch exists.
* [ ] No double frees exist.
* [ ] No use-after-free exists.
* [ ] Temporary allocations have bounded lifetimes.
* [ ] Connection pools do not retain request allocations unnecessarily.
* [ ] HTTP/2 streams have correct ownership isolation.
* [ ] HTTP/3 streams have correct ownership isolation.
* [ ] TLS and QUIC cleanup is correct.
* [ ] Convenience and explicit APIs share the same implementation.
* [ ] Existing allocator infrastructure is reused.
* [ ] Duplicate allocation abstractions are avoided.
* [ ] Allocation failures are tested.
* [ ] Leak detection is used where appropriate.
* [ ] Concurrency behavior is safe.
* [ ] Cross-platform behavior is tested.
* [ ] All allocator-related tests pass.
* [ ] Documentation accurately describes ownership and lifetime.



## Public API Ergonomics and User-Friendly API Rules

All public APIs in this project MUST be designed around a simple, predictable, idiomatic Zig developer experience.

The internal implementation may be highly sophisticated, but that complexity MUST NOT leak unnecessarily into the public API. Users should be able to use the library productively without understanding internal protocol state machines, transport implementations, cryptographic engines, connection-pool internals, or codec internals.

### 1. Public API First

Before adding or changing any functionality:

1. Inspect all existing public APIs in `src/`.
2. Reuse existing public types, configuration structures, helpers, transports, codecs, and abstractions whenever possible.
3. Check whether an existing API can be extended instead of creating another API for the same operation.
4. Keep naming, argument structure, allocator behavior, error handling, and configuration style consistent with the rest of the project.
5. If an existing public API violates these rules, fix it even if the change is breaking.
6. Do not preserve a poor API merely for backward compatibility when doing so would permanently make the library inconsistent or difficult to use.

The goal is a coherent library API rather than a collection of individually implemented features.

### 2. Simple Convenience APIs

The common path MUST require minimal code.

For example:

```zig
const httpx = @import("httpx");

pub fn main() !void {
    var response = try httpx.get(.{
        .url = "https://example.com",
    });
    defer response.deinit();
}
```

Common operations should provide concise convenience APIs such as:

```zig
httpx.get(.{ ... })
httpx.post(.{ ... })
httpx.put(.{ ... })
httpx.patch(.{ ... })
httpx.delete(.{ ... })
httpx.head(.{ ... })
httpx.options(.{ ... })
httpx.request(.{ ... })
```

Additional convenience APIs may be provided when they materially improve usability.

Do not force users to construct a client, transport, connection, request object, protocol object, allocator, headers object, URI object, or configuration object manually for ordinary one-shot operations when safe defaults can handle the operation automatically.

### 3. Configuration Uses `.{} `

Configuration MUST use Zig struct literals and default values wherever practical.

Preferred:

```zig
var client = try httpx.Client.init(.{
    .timeout = 30_000,
    .max_redirects = 10,
    .http_version = .auto,
});
```

Avoid APIs requiring long positional argument lists.

Avoid:

```zig
Client.init(allocator, timeout, retries, redirects, proxy, tls, ...)
```

Prefer named configuration fields:

```zig
Client.init(.{
    .allocator = allocator,
    .timeout = 30_000,
    .retries = 3,
    .proxy = .{ ... },
    .tls = .{ ... },
})
```

Defaults MUST provide a useful minimal configuration.

### 4. Allocator API Rule

Allocator handling MUST be consistent across the entire public API.

There should be a clear distinction between:

* zero-configuration/convenience APIs that use the library's documented default allocation strategy;
* explicit allocator APIs for users who require allocator control;
* long-lived objects whose ownership and allocator lifetime must be explicit.

Do not randomly expose allocators on some convenience functions while hiding them on equivalent APIs.

When explicit allocator control is required, it should be expressed clearly through configuration or an explicit initialization API.

Preferred:

```zig
var client = try httpx.Client.init(.{
    .allocator = allocator,
});
```

rather than forcing allocator arguments into every ordinary request:

```zig
httpx.get(allocator, url, ...)
```

The allocator MUST NOT be hidden when doing so would make ownership, lifetime, or deinitialization unsafe.

Every allocator-owning public object MUST document:

* who owns the allocator;
* what memory the object owns;
* when allocated memory is released;
* whether returned objects borrow or own memory;
* required `deinit()` behavior.

### 5. Explicit Initialization

For advanced and long-lived use cases, provide explicit initialization APIs.

Example:

```zig
var client = try httpx.Client.init(.{
    .allocator = allocator,
    .http_version = .auto,
});
defer client.deinit();

var response = try client.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

Explicit initialization MUST expose meaningful customization without requiring users to understand internal implementation details.

### 6. One Consistent Configuration Model

Client configuration, server configuration, TLS configuration, HTTP/1 configuration, HTTP/2 configuration, HTTP/3 configuration, QUIC configuration, WebSocket configuration, multipart configuration, compression configuration, routing configuration, and related APIs MUST follow the same general design philosophy.

Use:

```zig
.{ 
    .option = value,
}
```

with sensible defaults.

Do not introduce unrelated configuration conventions for individual modules.

### 7. Defaults Must Be Production-Sensible

The library MUST work out of the box with minimal configuration.

Defaults should provide:

* sensible HTTP version negotiation;
* safe connection handling;
* reasonable timeouts;
* safe TLS behavior;
* HTTP compression negotiation where supported;
* connection reuse where appropriate;
* redirect handling according to documented defaults;
* cookie handling where enabled;
* HTTP/2 and HTTP/3 negotiation when available;
* appropriate ALPN negotiation;
* sane header limits;
* sane body limits;
* safe protocol limits;
* correct resource cleanup.

Defaults MUST NOT silently disable important protocol functionality merely to simplify implementation.

Security-sensitive behavior MUST use secure defaults.

### 8. Progressive Complexity

The API should support progressive disclosure.

Beginner:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

Intermediate:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
    .headers = .{
        .authorization = "Bearer token",
    },
    .timeout = 10_000,
});
defer response.deinit();
```

Advanced:

```zig
var client = try httpx.Client.init(.{
    .allocator = allocator,
    .http_version = .h2,
    .tls = .{
        .verify_peer = true,
    },
    .proxy = .{ ... },
    .connection_pool = .{ ... },
});
defer client.deinit();
```

The advanced API MUST NOT make the simple API unnecessarily complex.

### 9. Type-Safe Request Data

Where practical, APIs should provide strongly typed request structures.

Support appropriate representations for:

* raw bytes;
* strings;
* JSON;
* forms;
* multipart;
* streaming bodies;
* files;
* readers;
* custom body producers.

Do not make JSON APIs dependent on users manually serializing everything when a safe typed API can reasonably be provided.

For example, support a design conceptually similar to:

```zig
var response = try httpx.post(.{
    .url = "https://example.com/users",
    .json = .{
        .name = "Alice",
        .age = 30,
    },
});
```

If Zig's compile-time type system or serialization design requires a specific mechanism, implement the appropriate native Zig solution rather than exposing an awkward API.

Raw JSON must remain available when users need exact control:

```zig
.json = "{\"name\":\"Alice\",\"age\":30}"
```

Both convenience and explicit forms should coexist where technically appropriate.

### 10. Type-Safe Responses

Response APIs should support both:

```zig
response.status
response.headers
response.body
```

and typed decoding where appropriate:

```zig
const User = struct {
    name: []const u8,
    age: u32,
};

const user = try response.json(User);
```

Typed response APIs MUST clearly document ownership and lifetime.

Do not make typed responses mandatory.

Users must always be able to access the underlying raw response when required.

### 11. HTTP Version API

HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 MUST be exposed through a consistent API.

Do not create separate incompatible client APIs for each HTTP version.

Preferred conceptual model:

```zig
.http_version = .auto
```

or:

```zig
.http_version = .h1_0
.http_version = .h1
.http_version = .h2
.http_version = .h3
```

Automatic negotiation should be the normal default where appropriate.

The public API MUST hide unnecessary protocol-specific implementation details.

### 12. TLS and ALPN API

TLS configuration MUST remain simple for normal users while exposing complete controls for advanced users.

Normal use should work without manually constructing TLS records, handshake states, cryptographic keys, ALPN frames, or transport objects.

Advanced users may configure:

```zig
.tls = .{
    .verify_peer = true,
    .min_version = .tls_1_2,
    .max_version = .tls_1_3,
}
```

ALPN should normally be negotiated automatically.

Do not expose internal ALPN wire-format structures as the normal public API.

### 13. Server API

Server APIs must follow the same ergonomic philosophy as client APIs.

A minimal server should be straightforward:

```zig
var server = try httpx.Server.init(.{});
defer server.deinit();

try server.get("/", handler);
try server.listen(.{
    .host = "127.0.0.1",
    .port = 8080,
});
```

Advanced configuration should remain available through `.{} ` configuration structures.

Routing, middleware, TLS, HTTP versions, compression, static files, WebSockets, SSE, multipart, OpenAPI, and documentation should integrate into the same server abstraction instead of requiring unrelated server implementations.

### 14. No Internal Naming Leakage

Internal implementation naming MUST NOT leak into the public API.

Do not expose names such as:

```zig
engine_mod
transport_mod
parser_mod
connection_mod
foo_impl
bar_internal
```

Avoid unnecessarily exposing implementation-specific structs merely because they exist internally.

Public names should describe what the user is doing, not how the library implements it.

Prefer:

```zig
Client
Server
Request
Response
Headers
Router
TlsConfig
HttpVersion
WebSocket
```

over implementation-oriented names.

### 15. No `_mod` Public API Pattern

Do not use `_mod` naming in public APIs.

Internal imports may use whatever naming is necessary for implementation clarity, but public symbols must use clean, conventional Zig names.

Prefer:

```zig
httpx.Client
httpx.Response
httpx.Headers
httpx.TlsConfig
```

not:

```zig
httpx.client_mod.Client
httpx.tls_mod.Config
```

### 16. Consistent Naming

Across the entire source tree:

* use clear nouns for types;
* use verbs for operations;
* use consistent terminology;
* use the same name for the same concept everywhere;
* do not create multiple names for equivalent concepts;
* avoid abbreviations unless they are industry-standard;
* preserve standard protocol terminology where appropriate.

Examples:

```zig
Request
Response
Headers
CookieJar
Connection
Client
Server
Router
Middleware
TlsConfig
QuicConfig
```

### 17. Reuse Before Adding APIs

Before creating a new public type or function:

1. Search all of `src/`.
2. Search existing protocol modules.
3. Search common utilities.
4. Search client and server APIs.
5. Search integration code.
6. Determine whether an existing abstraction already solves the problem.
7. Extend the existing abstraction when appropriate.

Never create a second abstraction for functionality already represented elsewhere.

### 18. Breaking Changes Are Allowed When Necessary

If an existing public API is inconsistent, unsafe, redundant, overly complicated, or contrary to these rules, it MAY be redesigned.

Do not maintain an incorrect API solely to avoid a breaking change.

When changing an API:

* update all internal callers;
* update examples;
* update tests;
* update documentation;
* update integration tests;
* remove obsolete APIs when appropriate;
* verify the entire project builds;
* verify all tests;
* verify all supported platforms.

### 19. Public API Must Hide Protocol Complexity

Users should not need to manually understand:

* HTTP/1 parser state machines;
* HTTP/2 frame state machines;
* HPACK;
* HTTP/3 frame processing;
* QPACK;
* QUIC packet protection;
* TLS records;
* TLS handshake states;
* ALPN wire encoding;
* socket platform abstractions;
* DNS internals;
* connection pooling internals.

These are implementation details unless the user explicitly chooses an advanced low-level API.

### 20. Low-Level APIs Still Must Exist Where Useful

High-level convenience APIs MUST NOT prevent advanced users from accessing lower-level functionality.

Provide clean layers:

```text
Convenience API
    ↓
Client / Server API
    ↓
HTTP abstraction
    ↓
HTTP/1 / HTTP/2 / HTTP/3
    ↓
TLS / QUIC / TCP / UDP
    ↓
Native Zig platform networking
```

Each layer should be usable independently when there is a legitimate advanced use case.

### 21. API Consistency Across Client and Server

Equivalent concepts MUST behave consistently between client and server.

For example:

* allocator configuration;
* timeout configuration;
* TLS configuration;
* HTTP version selection;
* compression;
* headers;
* cookies;
* body handling;
* streaming;
* WebSockets;
* multipart;
* error handling;
* shutdown;
* connection lifecycle.

Do not create completely different conventions for client and server APIs unless the underlying semantics genuinely require it.

### 22. Every Public API Must Be Tested

Every new public API MUST have tests covering:

* normal usage;
* default configuration;
* explicit configuration;
* allocator behavior;
* ownership;
* invalid arguments;
* boundary conditions;
* error handling;
* protocol interoperability where applicable;
* resource cleanup;
* repeated use;
* concurrent use where supported.

Examples must compile and exercise the actual public API.

A feature is NOT complete merely because its internal implementation compiles.

### 23. Examples Must Use the Public API

Examples must demonstrate the API users are actually expected to use.

Do not write examples that bypass the public API and directly instantiate internal protocol machinery unless the example specifically documents a low-level API.

Examples should favor:

```zig
httpx.get(.{ ... })
httpx.post(.{ ... })
client.get(.{ ... })
server.get(...)
```

over internal transport construction.

### 24. Final API Quality Gate

Before considering any client/server/TLS/HTTP feature complete, verify:

* Is the simplest use case simple?
* Are defaults sensible?
* Can advanced users customize everything important?
* Is allocator behavior consistent?
* Is `.{} ` configuration used consistently?
* Are names understandable?
* Is the API type-safe where practical?
* Are ownership rules clear?
* Is `deinit()` behavior clear?
* Is the same concept represented only once?
* Does the API reuse existing abstractions?
* Does it work consistently across HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3?
* Does it integrate correctly with TLS, ALPN, QUIC, TCP, and UDP?
* Does it work on every supported platform?
* Are all tests passing?
* Are interoperability tests passing?
* Are examples compiling?
* Are public APIs documented?

The implementation should be sophisticated internally but **simple externally**.

The project's defining API principle is:

> **Complexity belongs inside the implementation; usability belongs in the public API.**


## Internal Codebase Quality, Reuse, and Refactoring Rules

Treat the existing `src/` codebase as the primary implementation foundation. Before adding any new functionality, **first understand and search the existing implementation** and reuse what already exists wherever technically appropriate.

### 1. Reuse Before Creating

* Never implement functionality that already exists elsewhere in `src/`.
* Before creating a new helper, type, algorithm, codec, parser, encoder, decoder, state machine, utility, error type, buffer abstraction, synchronization primitive, or transport abstraction:

  1. Search the entire `src/` tree.
  2. Understand the existing implementation.
  3. Determine whether it can be reused, generalized, or extended.
  4. Only create a new implementation when the existing implementation genuinely cannot satisfy the requirement.
* Prefer extending a well-designed existing abstraction over creating a parallel abstraction.
* Reuse existing algorithms and common protocol primitives across HTTP/1.x, HTTP/2, HTTP/3, TLS, QUIC, networking, client, server, and web layers whenever their semantics permit it.
* Do not duplicate implementations merely because they are used by different protocol versions.

### 2. Eliminate Duplication

Continuously inspect the codebase for:

* duplicated algorithms
* duplicated parsing logic
* duplicated encoding/decoding logic
* duplicated validation
* duplicated error handling
* duplicated buffer management
* duplicated header handling
* duplicated URI handling
* duplicated HTTP method/status handling
* duplicated HTTP version logic
* duplicated timeout/deadline logic
* duplicated connection lifecycle logic
* duplicated stream management
* duplicated TLS/ALPN handling
* duplicated QUIC primitives
* duplicated compression logic
* duplicated socket operations
* duplicated client/server configuration logic
* duplicated allocator handling
* duplicated response/request construction
* duplicated test utilities

When duplication is found, consolidate it into the **correct existing common/module location** rather than allowing multiple implementations to remain.

### 3. Keep Protocol-Specific Code Thin

Protocol modules should contain protocol-specific behavior only.

For example:

* `src/protocols/http1/` → HTTP/1.0 and HTTP/1.1 protocol behavior
* `src/protocols/http2/` → HTTP/2 framing, streams, HPACK, flow control, etc.
* `src/protocols/http3/` → HTTP/3 framing, streams, QPACK, etc.
* `src/protocols/quic/` → QUIC transport and packet mechanisms
* `src/protocols/tls/` → TLS behavior and TLS transport integration
* `src/common/` → genuinely shared HTTP/common primitives
* `src/sockets/` → native socket abstractions
* `src/net/` → networking, DNS, proxy, and addressing functionality
* `src/client/` → public/client-side HTTP API and client orchestration
* `src/server/` → server lifecycle and server orchestration
* `src/web/` → framework-level web functionality

Do not copy common functionality into protocol directories simply to make a module self-contained.

### 4. Generalize Carefully

If two implementations are substantially similar:

* identify the actual common abstraction;
* extract only the genuinely shared behavior;
* keep protocol-specific differences explicit;
* avoid excessive generic programming;
* avoid abstractions that make simple code harder to understand.

Do **not** refactor merely to reduce line count. Refactor when it improves correctness, reuse, maintainability, performance, or architectural consistency.

### 5. No Ugly Internal APIs

Keep internal APIs:

* explicit
* predictable
* composable
* type-safe
* allocator-correct
* ownership-safe
* easy to test
* easy to reason about

Avoid unnecessary:

* `_mod` naming patterns
* meaningless wrapper functions
* wrapper-on-wrapper abstractions
* duplicate structs representing the same concept
* unnecessary conversions
* unnecessary allocations
* hidden global state
* hidden ownership
* circular dependencies
* excessive generic abstractions
* protocol-specific copies of common functionality

Use clear Zig naming and idiomatic module imports.

### 6. One Source of Truth

Every important concept should have one authoritative implementation whenever possible.

Examples:

* HTTP versions → `common/http_version.zig`
* HTTP methods → `common/method.zig`
* HTTP status → `common/status.zig`
* headers → `common/headers.zig`
* URI handling → `common/uri.zig`
* shared integer encoding → `protocols/common/integer.zig`
* Huffman implementation → `protocols/common/huffman.zig`
* HPACK → HTTP/2 implementation
* QPACK → HTTP/3 implementation
* QUIC cryptographic primitives → QUIC implementation
* TLS ALPN negotiation → TLS ALPN implementation
* socket primitives → socket layer

Do not introduce a second source of truth for the same concept.

### 7. Reuse Across Client and Server

The client and server must share common infrastructure wherever appropriate.

Do not create separate implementations for identical:

* headers
* HTTP methods
* status codes
* URI parsing
* HTTP versions
* compression
* request/response metadata
* body handling
* protocol negotiation
* connection abstractions
* timeout handling
* error classification
* common serialization/deserialization

Client-specific and server-specific behavior should remain separate only when their semantics genuinely differ.

### 8. Reuse Across HTTP Versions

The framework must support HTTP/1.0, HTTP/1.1, HTTP/2, and HTTP/3 without unnecessarily duplicating framework-level behavior.

Share common request/response abstractions while preserving the protocol-specific wire implementation.

The higher-level client/server APIs should not need separate duplicated implementations simply because the underlying protocol differs.

### 9. Reuse Existing Algorithms

Before implementing an algorithm:

* search `src/`;
* inspect related protocol implementations;
* inspect existing mathematical/cryptographic helpers;
* determine whether the algorithm can be shared;
* verify that the existing implementation follows the required standard.

Do not implement a second version of an algorithm because it is easier locally.

If an existing implementation is incorrect, **fix the authoritative implementation** and update all consumers.

### 10. Refactor Incorrect Existing Code

Existing code is not automatically considered correct.

If an existing implementation violates:

* project architecture
* protocol requirements
* allocator/ownership rules
* API consistency
* security requirements
* performance requirements
* portability requirements
* testing requirements
* naming conventions
* modularity
* reuse principles

then refactor or replace it.

Breaking changes are allowed when required to achieve the project's intended architecture and correctness.

Do not preserve a bad API merely for compatibility if the project requirements explicitly call for a cleaner design.

### 11. Avoid Dead Code

Remove or refactor:

* unreachable implementations
* obsolete compatibility layers
* unused helpers
* abandoned abstractions
* duplicate functions
* dead branches
* unused fields
* unused imports
* redundant conversions
* obsolete protocol implementations

Do not leave old implementations behind after replacing them.

Every retained abstraction should have a clear purpose.

### 12. Avoid Deadlocks and Concurrency Duplication

All concurrency primitives must have clear ownership and locking rules.

Before adding synchronization:

* inspect `src/concurrency/`;
* inspect `src/common/sync.zig`;
* reuse existing queues, worker pools, synchronization, and lifecycle mechanisms where appropriate.

Avoid:

* nested locks without a documented ordering
* inconsistent lock ordering
* unnecessary locking
* duplicated worker pools
* duplicated queues
* blocking operations while holding unrelated locks
* lock ownership that is unclear from the API

Add concurrency tests for relevant changes, including contention and shutdown cases.

### 13. Allocation and Ownership Consistency

Respect the project's allocator rules everywhere.

Do not introduce a new allocation strategy when an existing one already applies.

Clearly establish:

* who owns allocated memory;
* who frees it;
* whether returned data is borrowed or owned;
* which allocator performs allocation;
* whether a structure requires explicit `deinit()`.

Avoid unnecessary allocations and copies.

Prefer existing buffers, arenas, pools, slices, and allocation helpers where appropriate.

### 14. Performance Without Sacrificing Correctness

Reuse should also improve efficiency.

Prefer:

* zero-copy paths where safe;
* buffer reuse;
* connection pooling;
* stream reuse;
* bounded allocations;
* incremental parsing;
* incremental encoding;
* efficient state machines;
* existing compression/codec implementations;
* existing QUIC/TLS cryptographic primitives.

Do not duplicate data structures or processing pipelines unnecessarily.

Do not sacrifice correctness or security merely for micro-optimizations.

### 15. Correct Module Placement

Every new `.zig` file must live in the module where its responsibility naturally belongs.

Do not create confusing structures such as:

```text
src/foo/foo.zig
src/protocols/http2/http2.zig
src/protocols/tls/tls/tls.zig
```

unless the architecture genuinely requires that hierarchy.

Prefer the existing project's organization and place new functionality beside the related implementation.

Before creating a file, determine whether the functionality belongs in an existing file instead.

### 16. Refactor After Feature Work

After implementing a feature, perform a second pass specifically for:

1. duplicate code;
2. unnecessary abstractions;
3. opportunities to reuse existing code;
4. inconsistent APIs;
5. unnecessary allocations;
6. dead code;
7. naming problems;
8. ownership problems;
9. concurrency hazards;
10. protocol-specific logic accidentally duplicated elsewhere.

Do not consider a feature complete until this cleanup pass has been performed.

### 17. Tests Must Follow Refactoring

When consolidating or changing an existing implementation:

* preserve all meaningful existing tests;
* add tests for the shared abstraction;
* add regression tests for every bug fixed;
* add edge-case tests;
* ensure all existing consumers still work;
* run the complete project test suite.

Never delete a test merely because the implementation changed.

If a test is obsolete, replace it with an equivalent or stronger test that validates the intended behavior.

### 18. Final Codebase Standard

The final `src/` tree should have:

* one authoritative implementation for shared functionality;
* minimal duplication;
* clear module boundaries;
* reusable protocol primitives;
* clean client/server separation;
* consistent allocator and ownership semantics;
* no unnecessary wrappers;
* no dead code;
* no redundant algorithms;
* no avoidable allocations;
* no avoidable locks;
* no deadlocks;
* clear dependency direction;
* idiomatic Zig;
* complete tests;
* production-quality error handling.

**Do not implement locally first and clean it up later.**

The required workflow is:

```text
Understand existing code
        ↓
Search for reusable implementation
        ↓
Identify the authoritative module
        ↓
Extend/reuse existing code
        ↓
Implement missing functionality
        ↓
Add tests and edge cases
        ↓
Search again for duplication
        ↓
Refactor and consolidate
        ↓
Run complete test suite
        ↓
Verify all consumers
```

Always prefer **reuse + extension + consolidation** over **copy + modify + duplicate**.



## Internal and Public API Cleanliness

The entire project must be clean, consistent, simple, and user-friendly **both externally and internally**. Do not focus only on the public client/server API. Internal APIs, module interfaces, structs, functions, types, naming, ownership, and abstractions must also be professionally designed.

### 1. Clean Everything

When working on any part of the codebase, actively identify and clean:

* ugly APIs;
* confusing function signatures;
* unnecessary parameters;
* redundant parameters;
* unnecessary wrapper functions;
* excessive nesting;
* duplicated abstractions;
* duplicate types;
* inconsistent naming;
* inconsistent initialization patterns;
* inconsistent allocator handling;
* unnecessary conversions;
* unnecessary allocations;
* unnecessary copies;
* overly complicated generics;
* overly complicated state management;
* dead code;
* obsolete compatibility code;
* unused fields;
* unused helpers;
* awkward module boundaries;
* circular dependencies;
* unnecessary indirection;
* inconsistent error handling;
* inconsistent ownership rules;
* unclear lifetime rules;
* confusing internal APIs.

If an existing API is clearly inferior to the project's intended design, **change it even if that requires a breaking change**. Correctness, consistency, simplicity, and long-term maintainability take priority over preserving an intentionally poor API.

### 2. Internal APIs Must Be Simple Too

Do not create a beautiful public API while leaving complicated internal APIs underneath it.

Internal APIs should be:

* simple;
* explicit;
* predictable;
* composable;
* strongly typed;
* allocator-correct;
* ownership-safe;
* efficient;
* easy to test;
* easy to extend;
* easy to understand.

A developer working inside `src/` should be able to understand what a function does from its name, parameters, return type, ownership rules, and documentation without tracing unnecessary layers of wrappers.

### 3. Avoid Unnecessary Abstraction

Do not introduce abstractions merely because they look architecturally sophisticated.

Prefer:

```text
simple abstraction
        >
unnecessary abstraction layer
```

Avoid patterns such as:

```text
public API
    ↓
wrapper
    ↓
adapter
    ↓
helper
    ↓
internal wrapper
    ↓
actual implementation
```

when the same functionality can be expressed clearly with fewer layers.

Every abstraction must have a concrete purpose.

### 4. Consistent Initialization

Initialization APIs throughout the project must follow a consistent pattern.

Use simple initialization when defaults are sufficient.

Use explicit configuration only when customization is required.

For example, APIs should naturally support patterns such as:

```zig
const client = try httpx.Client.init(allocator);
```

or, where the project provides a default/global convenience API:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
```

Do not force users to construct unnecessary configuration objects for ordinary operations.

At the same time, every important subsystem must provide an explicit configuration path when advanced customization is required.

### 5. Allocator API Consistency

Allocator handling must be consistent throughout the entire codebase.

Do not randomly mix different allocator conventions.

The project should clearly distinguish:

* default/convenience APIs that do not require the caller to provide an allocator;
* explicit APIs where the caller controls the allocator;
* constructors that require an allocator because ownership requires it.

Do not hide allocator ownership in confusing ways.

Do not add allocator parameters to every function merely for consistency if the function does not allocate.

Likewise, do not silently allocate through an unrelated global allocator when explicit ownership is required.

### 6. Public API Should Be Minimal

The public API should expose the smallest useful surface that provides complete functionality.

Prefer:

```zig
httpx.get(.{ .url = "https://example.com" });
httpx.post(.{ .url = "https://example.com", .json = value });
```

over forcing users through multiple low-level objects for basic operations.

Advanced users must still have access to explicit configuration and lower-level APIs when necessary.

The API should progressively expose complexity:

```text
Simple use
    ↓
Convenience API
    ↓
Configurable API
    ↓
Explicit client/server API
    ↓
Low-level protocol API
```

Do not expose low-level protocol complexity unnecessarily at the highest API level.

### 7. Consistent Naming

Use straightforward, idiomatic Zig names.

Names should communicate intent immediately.

Avoid unnecessary naming patterns such as:

```text
*_mod
*_impl
*_wrapper
*_helper
*_internal
```

unless the distinction is genuinely meaningful.

Avoid meaningless abbreviations.

Prefer names that describe the actual responsibility.

### 8. Consistent Request/Response APIs

Request and response APIs must remain consistent across:

* HTTP/1.0;
* HTTP/1.1;
* HTTP/2;
* HTTP/3;
* TLS;
* QUIC;
* TCP;
* UDP;
* client;
* server.

Protocol-specific differences belong in protocol implementations, not in unnecessarily duplicated high-level APIs.

A user should not need to learn a completely different request/response model merely because HTTP/2 or HTTP/3 is selected.

### 9. Configuration Must Be Progressive

Defaults should provide a useful, production-oriented baseline.

Users should be able to start with minimal configuration:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
```

and progressively customize:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
    .headers = .{ ... },
    .timeout = ...,
    .version = .h2,
});
```

Advanced configuration should remain available through explicit client/server configuration.

Do not force advanced configuration onto simple use cases.

### 10. Internal Types Should Have One Purpose

Avoid structures containing unrelated responsibilities.

If a type handles:

* transport;
* protocol state;
* application routing;
* metrics;
* authentication;
* serialization;

all at once, reconsider the design.

Separate responsibilities into composable modules while keeping the public experience simple.

### 11. Clean Module Interfaces

Every module should have a clear responsibility.

Before adding functions to a file, determine whether they actually belong there.

If a module becomes a dumping ground for unrelated helpers, refactor it.

If two modules contain overlapping responsibilities, consolidate them into the appropriate authoritative module.

### 12. Remove Ugly Code While Touching It

Whenever Codex modifies a file, inspect the surrounding implementation.

Do not leave obvious nearby problems untouched simply because they were not part of the original feature request.

When safe and relevant, clean:

* inconsistent naming;
* duplicated code;
* unnecessary branches;
* unnecessary allocations;
* awkward APIs;
* obsolete comments;
* dead code;
* redundant wrappers;
* poor error propagation;
* poor ownership handling.

Do not perform unrelated massive rewrites, but do not knowingly preserve obvious architectural problems in code being actively modified.

### 13. Internal API Review

After implementing a feature, explicitly review both:

**Public API**

* Is it simple?
* Is it discoverable?
* Are defaults sensible?
* Are common operations concise?
* Are advanced options available?
* Are types clear?
* Is allocator usage understandable?

**Internal API**

* Is the abstraction necessary?
* Can existing code be reused?
* Is ownership obvious?
* Is the function signature minimal?
* Is the implementation duplicated?
* Is there unnecessary indirection?
* Is the module boundary correct?
* Can another protocol reuse it?
* Can it be tested independently?

### 14. No "Works but Ugly" Code

Do not consider an implementation complete merely because tests pass.

The final implementation must satisfy:

```text
Correct
+ Secure
+ Tested
+ Efficient
+ Reusable
+ Modular
+ Maintainable
+ Simple
+ Consistent
```

If functionality works but the API is unnecessarily complicated, refactor it.

If functionality works but the implementation duplicates existing code, consolidate it.

If functionality works but ownership is unclear, redesign it.

If functionality works but the module boundary is wrong, move it.

If functionality works but the naming is confusing, clean it.

### 15. Final Code Quality Gate

Before declaring any feature complete, perform this checklist:

* [ ] Existing implementation searched first.
* [ ] Existing abstractions reused where appropriate.
* [ ] No duplicate implementation introduced.
* [ ] No unnecessary abstraction introduced.
* [ ] Public API is simple and user-friendly.
* [ ] Internal API is simple and maintainable.
* [ ] Naming is clear and idiomatic.
* [ ] Allocator behavior is consistent.
* [ ] Ownership and lifetime are clear.
* [ ] No unnecessary allocations or copies.
* [ ] No dead code.
* [ ] No redundant wrappers.
* [ ] No unnecessary locks or deadlock risks.
* [ ] Correct module placement.
* [ ] Existing tests preserved.
* [ ] New tests and edge cases added.
* [ ] Full test suite passes.
* [ ] Relevant cross-platform tests pass.

**The goal is not merely a working codebase. The goal is a codebase where both users and maintainers can understand the API quickly and use it without unnecessary complexity.**



# Additional I/O and Concurrency Rules

## 1. Ownership of I/O

The framework must own its networking and I/O implementation.

Do not make normal users configure or understand operating-system I/O mechanisms.

Internal I/O may use:

* Windows Winsock / IOCP where appropriate
* Linux socket APIs / epoll where appropriate
* macOS socket APIs / kqueue where appropriate
* native OS polling and waiting mechanisms
* native socket options
* native DNS facilities where appropriate
* the project's own transport abstractions

These details must remain behind the project's internal APIs.

The public API must remain platform-independent.

---

## 2. Do Not Depend on Missing Zig 0.16.0 Networking

Zig 0.16.0 is the project's target compiler.

If Zig 0.16.0 lacks a networking primitive required by the framework, implement that primitive in the appropriate project module.

Do not:

* invent nonexistent `std.net` APIs
* assume APIs from another Zig version
* depend on unstable/inapplicable standard-library networking abstractions
* work around missing functionality by weakening the framework
* duplicate the networking implementation in every protocol

Use Zig standard-library functionality freely for general-purpose facilities such as:

* allocators
* memory
* slices
* arrays
* hash maps
* atomics
* hashing
* formatting
* type reflection
* compile-time functionality
* generic containers
* general synchronization primitives when appropriate

The distinction is:

> Use Zig std for general-purpose language/library facilities; provide the missing networking stack natively inside this project.

---

## 3. One Internal I/O Abstraction

All protocols must use the project's transport/I/O abstractions.

HTTP/1.x, HTTP/2, HTTP/3, TLS, QUIC, WebSocket, SSE, FTP, and other protocols must not each create their own unrelated socket/I/O layer.

Prefer:

```text
HTTP
 ↓
Protocol Transport
 ↓
TLS / QUIC where required
 ↓
Project Transport
 ↓
TCP / UDP
 ↓
OS networking
```

When a protocol needs functionality that does not currently exist, extend the appropriate abstraction instead of bypassing it.

---

## 4. Non-Blocking vs Blocking Architecture

The implementation must explicitly distinguish:

* blocking operations
* non-blocking operations
* polling
* waiting
* cancellation
* timeout
* shutdown

Do not mix these semantics implicitly.

Every internal I/O API must have clearly defined behavior for:

* success
* partial read
* partial write
* would-block
* interrupted operation
* timeout
* cancellation
* connection reset
* peer shutdown
* local shutdown
* invalid handle
* OS error
* protocol-level error

Never silently convert one category into another.

---

## 5. Partial Reads and Writes

Never assume:

```zig
read() == requested_size
```

or:

```zig
write() == requested_size
```

unless the specific API explicitly guarantees it.

Every transport implementation must correctly handle:

* partial TCP reads
* partial TCP writes
* fragmented TLS records
* fragmented handshake messages
* multiple protocol messages in one read
* multiple records in one read
* empty reads
* EOF
* interrupted operations
* backpressure

Use `writeAll`-style behavior where complete transmission is required.

---

## 6. Buffering

Every buffering layer must have explicit:

* maximum size
* growth policy
* ownership
* lifetime
* reset behavior
* failure behavior

Never allow unbounded attacker-controlled allocation.

Apply limits to:

* HTTP headers
* HTTP request targets
* HTTP response headers
* HTTP bodies where configured
* TLS records
* TLS handshake messages
* HTTP/2 frames
* HTTP/3 frames
* HPACK dynamic tables
* QPACK dynamic tables
* QUIC packets
* WebSocket frames
* multipart sections
* decompression output
* DNS responses
* proxy messages

Configuration defaults must be safe and production-appropriate.

---

## 7. Zero-Copy Where Appropriate

Prefer zero-copy operations where they improve performance without making ownership unsafe.

Do not introduce zero-copy complexity merely for theoretical performance.

Correctness takes priority over micro-optimizations.

When borrowing memory:

* document the lifetime
* do not retain references after the owner expires
* do not mutate borrowed immutable data
* do not expose internal buffers accidentally

---

## 8. Socket Lifecycle

Every socket must have a deterministic lifecycle:

```text
create
 ↓
configure
 ↓
bind/connect
 ↓
use
 ↓
shutdown
 ↓
close
```

Handle:

* connect failure
* bind failure
* listen failure
* accept failure
* shutdown failure
* close failure
* peer reset
* half-close
* repeated close
* shutdown during active I/O

Close operations must be idempotent where the abstraction promises idempotency.

Never leak sockets on an error path.

---

## 9. Connection Shutdown

Shutdown must be coordinated across:

* application
* protocol
* TLS
* QUIC
* transport
* socket
* worker/concurrency system

Do not allow:

```text
worker waiting for socket
socket waiting for worker
```

or equivalent circular dependencies.

Shutdown must wake blocked operations when required.

---

## 10. Timeouts

Timeout handling must not depend on arbitrary sleeps.

Support appropriate timeout categories such as:

* DNS timeout
* connect timeout
* TLS handshake timeout
* request timeout
* response-header timeout
* response-body timeout
* idle timeout
* keep-alive timeout
* write timeout
* read timeout
* shutdown timeout

Timeouts must use monotonic time.

Never use wall-clock time for elapsed-duration calculations.

Reuse the project's clock abstraction where available.

---

# Concurrency Rules

## 11. Concurrency Must Be Explicit Internally

Every concurrent component must clearly define:

* ownership
* thread safety
* synchronization
* mutation rules
* shutdown semantics
* cancellation semantics

Do not claim something is thread-safe without auditing all mutable state.

---

## 12. Reuse Existing Concurrency Infrastructure

Before creating a new:

* mutex
* spinlock
* semaphore
* condition variable
* queue
* worker pool
* atomic state machine
* thread manager
* task scheduler

search:

```text
src/concurrency/
src/common/sync.zig
```

and the entire repository.

Extend or generalize existing infrastructure whenever possible.

Do not create protocol-specific copies.

---

## 13. WorkerPool Is Optional Infrastructure

A plain client/server operation must not require users to manually create a worker pool.

The framework should provide sensible internal defaults.

Worker pools may be used internally for:

* parallel request processing
* DNS work
* blocking compatibility operations
* background maintenance
* server workloads
* application callbacks

but must not unnecessarily add threads to simple operations.

Avoid creating a thread for every request or connection.

Prefer bounded reusable workers.

---

## 14. No Hidden Unbounded Concurrency

Never create unbounded:

* threads
* tasks
* queues
* connections
* buffers
* retries

Concurrency must be bounded by configuration and safe defaults.

Backpressure must propagate correctly.

For example:

```text
socket
 ↓
protocol
 ↓
request processing
 ↓
worker queue
```

If the worker queue is full, the system must have defined backpressure behavior rather than allocating indefinitely.

---

## 15. Queue Correctness

Bounded queues must correctly handle:

* empty
* full
* push
* pop
* tryPush
* tryPop
* close
* drain
* cancellation
* producer waiting
* consumer waiting
* simultaneous producers
* simultaneous consumers
* shutdown while waiting
* repeated shutdown
* initialization failure

Do not use arbitrary semaphore over-posting as a substitute for correct queue state management.

The semaphore/condition state must remain consistent with the queue state.

---

## 16. Worker Shutdown

Worker pools must explicitly support the required lifecycle:

```text
initialized
 ↓
started
 ↓
running
 ↓
shutdown requested
 ↓
draining/cancelling
 ↓
workers stopped
 ↓
deinitialized
```

Define exactly what happens to:

* queued jobs
* currently running jobs
* cancelled jobs
* rejected jobs
* failed jobs

No worker may access destroyed pool state.

---

## 17. Cancellation

Cancellation must be cooperative where the operation cannot safely be forcefully interrupted.

Cancellation must propagate through:

```text
client request
 ↓
protocol
 ↓
transport
 ↓
I/O
```

and where applicable:

```text
server
 ↓
request
 ↓
worker
 ↓
application callback
```

Do not leave resources active after cancellation.

Cancellation must not cause:

* double completion
* double free
* deadlock
* leaked socket
* leaked worker
* stale queue item
* use-after-free

---

## 18. Atomic Memory Ordering

Do not use stronger atomic ordering blindly.

Select memory ordering based on the actual synchronization relationship.

Audit all:

* acquire
* release
* acq_rel
* monotonic
* sequentially consistent

operations.

Document non-obvious memory-order requirements.

Do not replace proper locking with atomics merely to appear faster.

---

## 19. Lock Ordering

Whenever multiple locks can be held:

1. Define a consistent lock order.
2. Acquire locks in that order.
3. Release in reverse order where appropriate.
4. Never call user/application code while holding internal locks unless explicitly safe.
5. Never perform potentially blocking I/O while holding a lock unless unavoidable and documented.

This prevents lock inversion and deadlocks.

---

## 20. Never Hold Locks Across Blocking I/O

Avoid:

```text
lock
 ↓
socket.read()
 ↓
wait
 ↓
unlock
```

Prefer:

```text
lock
 ↓
capture required state
 ↓
unlock
 ↓
perform I/O
 ↓
lock
 ↓
update state
 ↓
unlock
```

unless the architecture specifically requires otherwise.

---

## 21. User Callbacks

Never invoke arbitrary user callbacks while holding internal synchronization primitives unless the callback contract explicitly requires it.

User callbacks may:

* block
* call back into the library
* initiate another request
* destroy an object
* trigger shutdown
* acquire unrelated locks

Design accordingly.

---

## 22. Connection Pool Concurrency

Connection pools must safely handle:

* concurrent acquisition
* concurrent release
* connection expiration
* idle timeout
* maximum connections
* per-host limits
* connection reuse
* failed connections
* shutdown
* cancellation
* TLS session state
* HTTP/2 multiplexing
* HTTP/3 multiplexing

Never return the same exclusive connection to two users simultaneously.

HTTP/2 and HTTP/3 streams may be shared according to protocol semantics rather than treating every stream as an independent TCP connection.

---

## 23. Protocol Concurrency

HTTP/1.x:

* one request/response exchange per connection unless explicitly supporting pipelining
* safely manage keep-alive
* correctly handle connection reuse

HTTP/2:

* multiplex streams
* enforce stream state
* enforce flow control
* synchronize connection-level state
* avoid blocking unrelated streams

HTTP/3:

* multiplex QUIC streams
* correctly handle stream-level and connection-level flow control
* synchronize shared QUIC state
* avoid blocking unrelated streams

QUIC:

* packet processing must be safe under the chosen concurrency architecture
* connection state must have a clear owner
* packet number spaces must not race
* cryptographic key state must not race
* timers/loss detection must be synchronized

---

## 24. TLS Concurrency

TLS state must have a clearly defined owner.

Do not concurrently mutate one TLS handshake state machine from multiple threads unless explicitly designed and synchronized.

TLS read/write operations must correctly coordinate:

* sequence numbers
* keys
* handshake state
* alerts
* key updates
* shutdown
* application data

Never allow concurrent access to cryptographic state to produce nonce reuse or sequence-number corruption.

---

## 25. QUIC Concurrency

QUIC has shared connection state.

Protect or serialize access to:

* packet number spaces
* ACK state
* congestion control
* loss detection
* stream state
* connection IDs
* packet protection keys
* TLS secrets
* flow-control windows
* path state

Do not solve races by adding arbitrary locks everywhere.

Prefer clear ownership and serialization boundaries.

---

## 26. Timers and Background Work

Background timers must be bounded and shutdown-safe.

Never create an unmanaged background thread merely to perform a timer operation.

Every background task must have:

* owner
* lifetime
* cancellation
* shutdown path
* resource ownership

No background task may outlive the object that owns it.

---

## 27. Error Propagation

Do not swallow errors from:

* sockets
* DNS
* TLS
* QUIC
* HTTP parsing
* compression
* workers
* queues
* shutdown

Translate errors only at architectural boundaries.

Preserve enough information for the caller to understand the failure.

Do not convert every failure into a generic `IoError`.

---

## 28. Testing Requirements

Every I/O/concurrency implementation must have tests for:

### Basic

* normal operation
* initialization
* deinitialization
* success paths

### Boundaries

* zero
* one
* minimum
* maximum
* overflow
* underflow
* empty
* full

### Failure

* allocation failure
* socket failure
* DNS failure
* timeout
* cancellation
* connection reset
* peer close
* interrupted I/O
* partial I/O
* invalid state

### Concurrency

* multiple producers
* multiple consumers
* simultaneous shutdown
* shutdown while blocked
* cancellation while blocked
* concurrent close
* concurrent connect
* concurrent pool access
* worker startup failure
* worker shutdown
* queue drain

### Stress

Run high-iteration tests where appropriate.

Tests must attempt to expose:

* races
* deadlocks
* lost wakeups
* starvation
* resource leaks
* use-after-free
* double-close
* incorrect atomic synchronization

---

## 29. Cross-Platform Requirements

I/O and concurrency code must work correctly on:

* Windows
* Linux
* macOS

and supported:

* x86
* x86_64
* ARM64/AArch64
* 32-bit targets where the platform supports them

Do not assume:

* pointer size
* integer size
* socket-handle type
* error-number representation
* alignment
* endianness
* thread implementation
* timer implementation

Use explicit integer widths where protocol or wire formats require them.

---

## 30. CI Requirements

All relevant tests must execute correctly in GitHub Actions.

Do not mark a test as skipped simply because it is difficult to run.

A test may be skipped only when:

1. The capability genuinely cannot execute on that platform/environment.
2. The limitation is documented.
3. The skip is conditional and precise.
4. The test runs normally on platforms where the capability exists.

Do not use unconditional skips to hide failures.

The target is:

```text
All applicable tests pass.
No hidden failures.
No unnecessary skips.
```

For example, a live external HTTPS test may require conditional handling if external network access is unavailable in CI, but the test must not be silently disabled on environments where it can run.

---

## 31. No Sleep-Based Synchronization

Do not use:

```zig
std.time.sleep(...)
```

or equivalent arbitrary delays to make concurrency tests "pass".

Use:

* proper synchronization
* condition signaling
* atomics
* barriers
* deterministic state transitions
* bounded polling only where appropriate

A test that passes because it sleeps is not a deterministic concurrency test.

---

## 32. No Busy Waiting

Do not implement production synchronization with indefinite busy loops.

Busy waiting is acceptable only for tightly controlled low-level primitives where it is demonstrably appropriate and bounded.

Prefer blocking/waiting mechanisms for normal workloads.

---

## 33. Internal APIs Must Stay Clean

Internal APIs should be:

* modular
* cohesive
* small
* reusable
* strongly typed
* ownership-safe
* explicit about lifecycle

Avoid:

* `_mod` naming
* unnecessary wrapper layers
* generic `*anyopaque` when a typed interface is possible
* duplicated state
* redundant configuration structures
* protocol-specific copies of common utilities

Use typed interfaces wherever practical.

---

## 34. Public API Must Not Leak Internals

Do not expose:

```text
WorkerPool
BoundedQueue
Semaphore
Spinlock
OS socket handle
epoll fd
kqueue fd
IOCP handle
internal transport state
TLS engine internals
QUIC packet state
```

through the normal convenience client API.

Advanced low-level APIs may expose controlled transport customization when there is a genuine use case, but the default API must remain simple.

---

## 35. Performance Rule

Optimize the architecture, not individual lines.

Prefer:

* connection reuse
* pooling
* bounded allocations
* reusable buffers
* multiplexing
* efficient parsing
* efficient codecs
* zero-copy where safe
* bounded worker pools
* native OS networking
* appropriate batching

Avoid premature micro-optimizations that make correctness or maintainability worse.

Every optimization must preserve:

* correctness
* thread safety
* protocol compliance
* memory safety
* deterministic shutdown

---

## 36. Final Review Before Completion

Before declaring an I/O or concurrency feature complete:

1. Search for duplicate implementations.
2. Verify existing abstractions were reused.
3. Verify ownership and lifetimes.
4. Audit shutdown paths.
5. Audit cancellation.
6. Audit timeout behavior.
7. Audit partial reads/writes.
8. Audit all error paths.
9. Audit locks and atomic ordering.
10. Check for deadlocks.
11. Check for resource leaks.
12. Run unit tests.
13. Run stress tests.
14. Run integration tests.
15. Run protocol interoperability tests where applicable.
16. Run supported platform builds.
17. Run GitHub CI-equivalent tests.
18. Run formatting.
19. Verify documentation/docstrings.
20. Verify no debug code, temporary workarounds, dead code, duplicate code, or unconditional test skips remain.

Never report a feature as production-ready merely because it compiles.

## I/O, Networking, and Concurrency Rules

### Native I/O Architecture

This project is a **complete native Zig networking and HTTP stack**.

Zig 0.16.0 does not provide all of the networking, socket, TLS, QUIC, HTTP/2, or HTTP/3 functionality required by this project. Therefore:

* Do **not** depend on missing or insufficient `std` networking abstractions.
* Implement the required networking primitives natively in the project's `src/sockets/` and `src/net/` modules.
* `std` may still be used for general-purpose functionality such as:

  * `std.mem`
  * `std.ArrayList`
  * `std.StringHashMap`
  * allocators
  * atomics
  * threads where appropriate
  * synchronization primitives where appropriate
  * hashing and cryptographic primitives where appropriate
  * platform-independent utility functionality
* Do not recreate functionality that already exists correctly in this codebase.
* Always inspect and reuse the existing socket, address, DNS, synchronization, concurrency, protocol, and error abstractions before adding new ones.

### I/O Must Be Layered

Keep I/O responsibilities separated:

```text
Application
    ↓
HTTP client/server
    ↓
HTTP/1.0 / HTTP/1.1 / HTTP/2 / HTTP/3
    ↓
TLS / QUIC
    ↓
TCP / UDP
    ↓
Native platform socket implementation
    ↓
Windows / Linux / macOS system APIs
```

A protocol implementation must not directly duplicate lower-level socket logic.

For example:

* HTTP/1.x must use the project's TCP/TLS transport.
* HTTP/2 must use the project's transport abstraction.
* HTTP/3 must use QUIC.
* TLS-over-TCP must use `tcp.zig`.
* TLS-over-QUIC must use the QUIC transport and QUIC TLS adapter.
* UDP must use the project's UDP implementation.
* DNS must use the project's DNS/resolution modules.
* Proxy support must use the existing proxy abstractions.
* SOCKS5 must use the existing SOCKS5 implementation.

Do not create a second socket abstraction merely because a protocol needs a slightly different operation.

### Explicit vs Internal I/O

The normal high-level client API should **not require users to manually construct or manage I/O objects**.

A minimal API such as:

```zig
var response = try httpx.get(.{
    .url = "https://example.com",
});
defer response.deinit();
```

must work using the library's internal/default networking, connection pooling, DNS, TLS, HTTP version negotiation, and transport configuration.

Advanced users may explicitly provide/customize:

* allocator
* timeout configuration
* proxy
* DNS resolver
* connection pool
* TLS configuration
* transport configuration
* socket configuration
* HTTP version
* concurrency/worker configuration

Explicit customization must override the default configuration without breaking the simple API.

Do not force an I/O runtime, event loop, worker pool, or custom executor onto users who only need a simple synchronous request.

### Blocking and Non-Blocking I/O

Every blocking operation must have a clearly defined ownership and lifecycle.

Never introduce hidden indefinite blocking.

Operations involving:

* socket reads
* socket writes
* DNS
* connection establishment
* TLS handshake
* HTTP/2 flow control
* HTTP/3/QUIC processing
* connection pool acquisition
* queue submission
* worker shutdown

must correctly handle:

* timeout
* cancellation where supported
* connection closure
* peer closure
* partial reads
* partial writes
* interruption
* transient errors
* resource exhaustion
* shutdown
* platform-specific errors

Never assume that one `read()` or `write()` transfers the complete requested buffer unless the abstraction explicitly guarantees it.

### Concurrency Architecture

Concurrency must be **opt-in and appropriately scoped**.

A simple client request must not automatically create a worker pool or unnecessary threads.

The existing:

```text
src/concurrency/queue.zig
src/concurrency/worker_pool.zig
src/common/sync.zig
```

must be reused wherever applicable.

Do not create duplicate:

* thread pools
* task queues
* mutex implementations
* semaphore implementations
* worker abstractions
* condition-variable abstractions
* atomic state machines

### Worker Pool Rules

The worker pool must provide deterministic lifecycle semantics:

```text
init
  ↓
start
  ↓
submit
  ↓
running
  ↓
shutdown
  ↓
drain/cancel
  ↓
join
  ↓
deinit
```

Required guarantees:

* no task executes after the worker pool has completely shut down
* no worker thread remains unjoined
* no queue memory is freed while workers can still access it
* shutdown is safe and idempotent
* queued work has explicitly defined drain/cancel semantics
* submission after shutdown returns a deterministic error
* worker creation failure cleans up already-created workers
* allocator ownership is explicit
* no allocation occurs in worker execution unless the task itself intentionally allocates
* no deadlock during shutdown
* no lock is held while performing an operation that can indefinitely block unless that behavior is explicitly required and proven safe

### Queue Rules

The bounded queue must maintain strict invariants.

Required properties:

* FIFO ordering
* bounded memory
* correct full/empty handling
* correct close semantics
* producer wake-up on capacity becoming available
* consumer wake-up when an item becomes available
* safe shutdown while producers or consumers are blocked
* no lost wakeups
* no double-posting that can corrupt semaphore state
* no underflow/overflow
* no use-after-free
* no data races
* deterministic behavior after close

Do not implement shutdown by blindly posting an arbitrary number of semaphore tokens unless the synchronization abstraction explicitly guarantees that behavior is correct.

The close/wakeup mechanism must be designed around the actual number and state of waiters or use a synchronization primitive whose semantics make the operation safe.

Test blocked producers and blocked consumers concurrently.

### Locking Rules

Every lock must have a clearly defined ownership and scope.

Never:

* acquire the same non-recursive lock twice from the same execution path
* hold a lock while calling arbitrary user callbacks
* hold a global lock while performing network I/O
* hold a lock while waiting on another synchronization primitive unless required and proven deadlock-safe
* access mutable shared state without synchronization
* introduce lock-order inversions

Document lock ordering for components that use multiple locks.

Prefer reducing shared mutable state over adding more locks.

### Atomic Rules

Use atomics only when they are actually required.

For each atomic state variable, define:

* owner
* state transitions
* required memory ordering
* shutdown semantics

Do not use stronger memory ordering merely because it is convenient.

Do not replace a proper synchronization design with atomics without proving correctness.

### Connection Pool Concurrency

Connection pools must safely support concurrent users.

The pool must correctly handle:

* simultaneous acquisition
* simultaneous release
* connection reuse
* connection expiration
* idle timeout
* connection failure
* TLS state
* HTTP/2 multiplexing
* HTTP/3 multiplexing
* maximum connections
* maximum idle connections
* shutdown
* cancellation
* allocator lifetime

Never return a connection to the pool while another operation still owns it.

Never reuse a connection after the peer has closed it or after the protocol has placed it into an unusable state.

### HTTP/2 and HTTP/3 Concurrency

HTTP/2 and HTTP/3 are inherently multiplexed protocols.

Do not model them as simply:

```text
one connection = one request
```

Correctly support:

```text
connection
 ├── stream 1
 ├── stream 3
 ├── stream 5
 └── stream N
```

Stream state must be independently tracked.

Implement and test:

* concurrent streams
* stream creation
* stream closure
* cancellation
* flow control
* connection-level flow control
* stream-level flow control
* backpressure
* SETTINGS changes
* GOAWAY
* RST_STREAM
* priority-related behavior where applicable
* protocol errors
* connection shutdown
* peer shutdown
* concurrent read/write activity

HTTP/2 and HTTP/3 protocol state machines must never deadlock because application code is waiting for another stream.

### Callback Rules

Never invoke user callbacks while holding internal locks.

Callbacks may:

* perform another request
* close a connection
* modify application state
* trigger shutdown
* allocate
* log
* call another library API

Therefore internal locks must be released before entering user-controlled code.

### Cancellation

Cancellation must be cooperative and deterministic.

Cancellation must correctly propagate through:

```text
request
 → connection acquisition
 → DNS
 → connect
 → TLS
 → protocol handshake
 → stream
 → body read/write
```

Cancellation must not leak:

* sockets
* streams
* connections
* worker jobs
* queue entries
* buffers
* TLS state
* QUIC state

### I/O Error Handling

Do not collapse every platform or protocol error into a generic error when useful information can be preserved.

Reuse:

```text
src/common/errors.zig
```

and existing protocol-specific errors.

Errors must distinguish appropriately between:

* timeout
* connection refused
* connection reset
* peer closed
* DNS failure
* TLS failure
* certificate failure
* protocol violation
* HTTP error
* stream cancellation
* resource exhaustion
* invalid configuration
* shutdown

Avoid creating redundant error sets in individual modules.

### Cross-Platform I/O

All native I/O must work correctly on:

* Windows x86
* Windows x86_64
* Windows AArch64 where supported by the toolchain/platform
* Linux x86
* Linux x86_64
* Linux AArch64
* macOS x86_64
* macOS AArch64

Platform-specific code belongs behind the appropriate existing abstraction.

Do not scatter OS-specific system calls throughout HTTP or protocol implementations.

Use the project's socket/system layers:

```text
src/sockets/sys.zig
src/sockets/tcp.zig
src/sockets/udp.zig
src/net/address.zig
src/net/resolve.zig
```

and extend those modules when additional platform functionality is required.

### Testing I/O and Concurrency

Every I/O or concurrency feature must have tests at the bottom of the relevant Zig source file where appropriate.

Do not remove an existing test merely because an implementation changes.

Add tests for:

* normal operation
* boundary values
* empty input
* maximum input
* partial I/O
* peer closure
* timeout
* cancellation
* concurrent access
* shutdown races
* repeated initialization/deinitialization
* allocation failure
* queue full
* queue empty
* queue close
* worker startup failure
* worker shutdown
* concurrent submit/shutdown
* connection pool races
* stream races
* protocol errors
* malformed network data

Concurrency tests must be deterministic and must not rely on arbitrary sleeps as their primary correctness mechanism.

Avoid tests that merely spin for an arbitrary number of iterations and call that success. Prefer synchronization, completion counters with proper waiting, barriers, events, or deterministic test coordination.

### No Hidden Runtime

Do not introduce a mandatory global runtime, hidden worker pool, hidden event loop, or hidden allocator.

The library should remain usable with:

```zig
httpx.get(.{ ... })
```

with sensible built-in defaults.

Advanced users can explicitly configure execution and I/O behavior.

The implementation should therefore provide both:

```text
simple/default API
```

and:

```text
explicit/custom API
```

without duplicating the underlying implementation.

Both paths must ultimately reuse the same internal networking and protocol stack.

### Resource Ownership

Every resource must have one clearly defined owner.

For every:

* allocator allocation
* socket
* connection
* stream
* TLS session
* QUIC connection
* worker
* queue
* buffer

define who creates it, who owns it, and who destroys it.

Prefer RAII-style Zig lifecycle APIs:

```zig
init(...)
deinit()
```

and explicit ownership transfer where necessary.

Never rely on garbage collection or process termination for cleanup.

### Internal Code Quality

Before adding new I/O or concurrency code:

1. Search the entire `src/` tree.
2. Find an existing abstraction that can perform the operation.
3. Reuse it if possible.
4. Extend it if necessary.
5. Only create a new abstraction when the existing architecture genuinely cannot represent the required behavior.

No duplicate networking stack.

No duplicate synchronization stack.

No duplicate allocator abstraction.

No duplicate connection management.

No duplicate protocol transport.

No dead code.

No unreachable compatibility layer.

No redundant wrapper whose only purpose is renaming an existing function.

Keep implementation modular, composable, testable, and suitable for production use.


## Final Implementation, Reuse, Correctness, and Optimization Rule

All rules, architecture requirements, API requirements, documentation requirements, testing requirements, platform requirements, networking requirements, protocol requirements, allocator rules, I/O rules, concurrency rules, and source-code organization rules defined in this `AGENT.md` are **mandatory** and must be followed together. Do not treat any section as optional unless it explicitly says it is optional.

Before modifying or creating code, **first inspect and understand the existing source code and architecture**. Determine what functionality already exists, what is incomplete, what is incorrect, what is duplicated, what is inefficient, and what can be reused. Do not immediately create a new implementation when an existing module can be extended or reused.

For every implementation decision, explicitly choose the **best production-quality approach for correctness, performance, memory usage, scalability, maintainability, portability, and API usability**. Do not optimize for only one metric. Prefer the solution that provides the best overall engineering trade-off for this library.

### Optimization decision rules

* Reuse existing abstractions whenever they are correct and suitable.
* Do not duplicate algorithms, codecs, parsers, protocol state machines, synchronization primitives, networking logic, serialization logic, or utility functionality.
* If existing code is incorrect, incomplete, unsafe, unnecessarily complex, or inefficient, **fix or refactor the existing implementation instead of preserving it merely for compatibility**.
* Do not introduce an abstraction only because it looks architecturally elegant; introduce it when it provides real reuse, correctness, isolation, performance, or maintainability benefits.
* Avoid unnecessary allocations, copies, conversions, locks, system calls, thread creation, wakeups, buffering, and synchronization.
* Prefer bounded memory and predictable resource usage for networking and protocol paths.
* Keep hot paths allocation-conscious and avoid unnecessary dynamic allocation.
* Prefer zero-copy or minimal-copy processing where it is safe and practical.
* Do not sacrifice protocol correctness or security merely for performance.
* Do not sacrifice API clarity merely to reduce internal code size.
* Prefer simple implementations when two approaches provide equivalent correctness and performance.
* Prefer specialized implementations when generic abstractions would create measurable unnecessary overhead.
* Prefer generic reusable implementations when specialization would duplicate substantial logic.
* Ensure concurrency designs cannot introduce deadlocks, livelocks, races, starvation, unsafe shutdown behavior, or lost wakeups.
* Ensure asynchronous, blocking, worker, queue, socket, and I/O behavior has clearly defined ownership and shutdown semantics.
* Ensure allocator ownership and lifetime are explicit internally and ergonomic externally.
* Ensure public APIs remain clean, predictable, user-friendly, and consistent across all features.
* Keep protocol implementations modular so HTTP/1.x, HTTP/2, HTTP/3, QUIC, TLS, ALPN, WebSocket, multipart, compression, sockets, and other subsystems can evolve independently without duplicated infrastructure.
* Keep platform-specific code isolated behind appropriate abstractions and ensure the same public behavior across supported platforms.
* Do not add complexity solely to imitate another implementation. External C/C++ implementations may be used as technical references for standards-compliant behavior, algorithms, interoperability, and edge cases, but the resulting implementation must fit this project's native Zig architecture and conventions.
* Never mention external C/C++ projects as the architectural basis in source-code comments or documentation. Document the applicable protocol, algorithm, or standard instead.

### Before implementation

For every substantial change:

1. Read the relevant existing Zig modules.
2. Trace the callers and consumers of the functionality.
3. Identify existing reusable helpers and abstractions.
4. Check whether another subsystem already implements equivalent functionality.
5. Identify protocol, platform, memory, concurrency, and security requirements.
6. Compare reasonable implementation approaches.
7. Select the approach with the best overall correctness/performance/maintainability trade-off.
8. Implement it in the existing architectural location.
9. Add or update comprehensive tests, including edge cases and failure paths.
10. Run formatting, compilation, unit tests, integration tests, interoperability tests, and relevant platform/target checks.
11. Re-review the resulting code for duplication, unnecessary allocations, unnecessary synchronization, dead code, API inconsistency, and unnecessary complexity.

### No premature optimization and no careless optimization

Do not blindly optimize code without understanding its behavior.

Do not blindly choose the fastest-looking implementation if it makes correctness, portability, security, ownership, or maintainability worse.

Do not retain inefficient code merely because it already exists.

The goal is:

**correct first, secure first, standards-compliant first, then efficiently implemented with the simplest maintainable design.**

When performance-sensitive behavior is involved, reason about:

* CPU cost
* allocation cost
* memory footprint
* cache behavior
* copying
* system-call frequency
* lock contention
* thread scheduling
* queue contention
* network I/O
* buffering
* backpressure
* latency
* throughput
* scalability
* connection and stream counts
* platform-specific behavior

Choose the implementation that provides the best practical result rather than optimizing an isolated micro-operation.

### Final quality gate

Before considering any work complete, verify that the change:

* follows every applicable rule in `AGENT.md`;
* reuses existing code where appropriate;
* introduces no unnecessary duplicate implementation;
* introduces no dead code;
* introduces no redundant abstraction;
* introduces no avoidable allocation or copy;
* introduces no avoidable lock or synchronization overhead;
* does not create deadlocks or shutdown races;
* preserves or intentionally improves API consistency;
* remains allocator-correct;
* remains I/O-correct;
* remains thread-safe where required;
* remains portable across supported targets;
* follows the applicable protocol and industry standards;
* handles normal, boundary, malformed, adversarial, and failure cases;
* has appropriate tests for the implementation;
* passes all applicable tests without unjustified skips;
* has professional documentation and docstrings for all new or modified public/internal Zig functionality;
* keeps source organization modular and consistent with the existing project structure.

**Never declare a feature complete merely because it compiles. Completion means the implementation is correct, tested, interoperable, secure, efficient, maintainable, documented, and integrated with the rest of the codebase.**


## Testing, Examples, and Demonstration Rules

All implementation work MUST include appropriate tests and examples. Tests and examples are part of the feature implementation, not optional follow-up work.

### 1. Tests Are Required for Every Feature

Whenever adding, changing, fixing, or refactoring functionality:

* Inspect the existing tests before modifying implementation code.
* Reuse existing test helpers, fixtures, utilities, and infrastructure wherever possible.
* Add new tests for every newly introduced behavior.
* Update existing tests when behavior intentionally changes.
* Never delete or weaken an existing test merely to make the build pass.
* Never comment out, disable, or bypass a failing test.
* Never replace a meaningful assertion with a weaker assertion simply to satisfy CI.
* Preserve regression coverage for every bug that is fixed.
* Test both normal behavior and failure behavior.
* Test boundary conditions, malformed input, invalid state transitions, resource exhaustion, cancellation, timeouts, concurrency, and protocol violations where applicable.
* Add interoperability tests whenever a protocol implementation requires interoperability validation.

Tests must be deterministic and must not depend on timing races, arbitrary sleeps, unavailable external services, or machine-specific behavior unless the test is explicitly classified as an external interoperability test.

### 2. Test Every Relevant Layer

For protocol and networking functionality, test at the appropriate levels:

1. Primitive/codec tests
2. Parser and serializer tests
3. State-machine tests
4. Unit tests
5. Integration tests
6. Client/server loopback tests
7. Protocol interoperability tests
8. Error-path tests
9. Boundary and edge-case tests
10. Cross-platform tests where platform behavior differs

For example, HTTP/1, HTTP/2, HTTP/3, QUIC, TLS, ALPN, WebSocket, multipart, compression, DNS, sockets, and concurrency implementations must each have tests appropriate to their individual behavior.

Do not rely exclusively on one end-to-end test to prove correctness.

### 3. Never Skip Tests Without a Real Reason

The target is:

* All tests pass.
* No test is silently skipped.
* No test is conditionally disabled merely because implementation is inconvenient.
* No test is marked expected-failure just to hide an implementation defect.

A test may be skipped only when execution is genuinely impossible in the current environment.

Examples of legitimate environmental limitations include:

* A required external service is unavailable.
* A platform-specific API does not exist on the current operating system.
* A GitHub Actions runner cannot provide a required external dependency.
* A test explicitly requires hardware unavailable in CI.
* A test requires an external interoperability peer that cannot be started in the current CI environment.

When this happens:

* Make the skip condition explicit.
* Document exactly why it is skipped.
* Ensure the test runs automatically when the required environment is available.
* Prefer replacing external dependencies with a deterministic local test server or loopback fixture when practical.
* Never use a skip as a workaround for a broken implementation.

The ideal CI result is:

`All tests pass, with only genuinely environment-impossible tests skipped.`

If a test can reasonably be made runnable in GitHub Actions, make it runnable rather than skipping it.

### 4. Test Edge Cases at the Source-Code Boundary

Every important source module should contain or have directly associated tests covering its boundary conditions.

Examples include:

* Empty input
* One-byte input
* Maximum valid input
* Maximum configured input
* Oversized input
* Truncated input
* Invalid encoding
* Invalid enum/value
* Integer overflow and underflow
* Length-field mismatch
* Duplicate fields
* Missing required fields
* Invalid state transitions
* Unexpected EOF
* Partial reads
* Partial writes
* Short writes
* Connection reset
* Timeout
* Cancellation
* Resource exhaustion
* Allocation failure where practical
* Invalid UTF-8/WTF-8/WTF-16 handling where applicable
* Concurrent access
* Queue full/empty conditions
* Shutdown while blocked
* Repeated shutdown/deinit
* Protocol downgrade attempts
* Authentication failures
* Invalid certificates
* Cryptographic verification failures
* Invalid frames
* Unknown extensions
* Unknown protocol values
* Stream limits
* Flow-control exhaustion
* Connection migration/path changes where applicable

Do not assume that successful-path tests are sufficient.

### 5. Protocol-Specific Test Requirements

For HTTP/1.0 and HTTP/1.1:

* Test request-line parsing.
* Test response parsing.
* Test headers.
* Test repeated headers.
* Test content length.
* Test chunked transfer encoding.
* Test trailers.
* Test connection persistence.
* Test connection close.
* Test HTTP/1.0 keep-alive behavior.
* Test HTTP/1.1 persistent connections.
* Test redirects.
* Test malformed requests.
* Test malformed responses.
* Test request-target forms.
* Test framing ambiguity and request-smuggling protections.
* Test partial network reads/writes.
* Test streaming bodies.

For HTTP/2:

* Test all supported frame types.
* Test frame encoding/decoding.
* Test SETTINGS.
* Test SETTINGS acknowledgement.
* Test HEADERS.
* Test CONTINUATION.
* Test DATA.
* Test PRIORITY where supported.
* Test RST_STREAM.
* Test PING.
* Test GOAWAY.
* Test WINDOW_UPDATE.
* Test PUSH_PROMISE where relevant to the implementation.
* Test stream lifecycle.
* Test connection lifecycle.
* Test flow control.
* Test HPACK encoding/decoding.
* Test dynamic table behavior.
* Test Huffman encoding/decoding.
* Test malformed frames.
* Test invalid stream states.
* Test protocol errors.
* Test graceful shutdown.

For HTTP/3:

* Test every supported frame type.
* Test QUIC stream mapping.
* Test control streams.
* Test request streams.
* Test QPACK encoding/decoding.
* Test QPACK dynamic table behavior.
* Test blocked/unblocked decoding.
* Test unidirectional stream rules.
* Test stream limits.
* Test HTTP/3 errors.
* Test connection shutdown.
* Test malformed frames.
* Test invalid stream usage.
* Test QUIC transport interaction.
* Test HTTP/3 over real local QUIC loopback.

For QUIC:

* Test packet parsing/building.
* Test connection IDs.
* Test variable-length integers.
* Test packet protection.
* Test AEAD.
* Test header protection.
* Test packet number reconstruction.
* Test ACK handling.
* Test loss detection.
* Test retransmission.
* Test congestion control.
* Test flow control.
* Test streams.
* Test connection state.
* Test path handling.
* Test key phases.
* Test TLS integration.
* Test malformed packets.
* Test invalid frames.
* Test packet truncation.
* Test duplicate packets.
* Test reordered packets.

For TLS:

* Test TLS 1.2 and TLS 1.3 independently.
* Test record encoding/decoding.
* Test handshake parsing.
* Test handshake state transitions.
* Test cipher negotiation.
* Test key exchange.
* Test HKDF/key schedule.
* Test transcript hashing.
* Test Finished verification.
* Test Certificate handling.
* Test CertificateVerify.
* Test SNI.
* Test ALPN.
* Test supported groups.
* Test signature algorithms.
* Test alert handling.
* Test sequence numbers.
* Test AEAD nonce construction.
* Test authentication failures.
* Test malformed handshake messages.
* Test unsupported versions.
* Test unsupported cipher suites.
* Test unsupported groups.
* Test invalid certificates.
* Test verification failures.
* Test key-update behavior where implemented.

For ALPN:

* Test parsing.
* Test serialization.
* Test preference negotiation.
* Test no-common-protocol behavior.
* Test HTTP/1.0.
* Test HTTP/1.1.
* Test HTTP/2.
* Test HTTP/3.
* Test protocol/path restrictions such as HTTP/3 only being selected through the appropriate QUIC/HTTP/3 transport.

### 6. Examples Are First-Class Project Artifacts

The `examples/` directory is part of the public developer experience.

Examples MUST be:

* Small.
* Focused.
* Independently understandable.
* Buildable.
* Runnable.
* Representative of the public API.
* Kept synchronized with the actual API.
* Written using the recommended user-facing syntax.
* Free from internal implementation details unless the example specifically demonstrates an advanced/internal API.

Do NOT create one giant example demonstrating every feature.

Each example should demonstrate one logical feature or one closely related group of features.

### 7. Examples Directory Organization

Keep examples directly inside `examples/` unless the project explicitly establishes another structure.

Use descriptive filenames that identify what the example demonstrates.

Examples should follow a pattern such as:

```text
examples/
    get.zig
    post_json.zig
    post_form.zig
    custom_headers.zig
    query_parameters.zig
    timeout.zig
    redirects.zig
    cookies.zig
    streaming_response.zig
    multipart_upload.zig
    authentication_basic.zig
    authentication_bearer.zig
    websocket_client.zig
    http2_client.zig
    http3_client.zig
    tls_client.zig
    tls_server.zig
    http_server.zig
    server_middleware.zig
    openapi.zig
    sse.zig
```

Do not create unnecessary nested structures such as:

```text
examples/alpn/alpn.zig
```

unless a future project-level rule explicitly requires grouping.

Choose filenames that describe the actual demonstrated API.

### 8. One Example Must Demonstrate One Primary Concept

Do not create examples that combine unrelated functionality merely to reduce the number of files.

For example:

* `post_json.zig` should primarily demonstrate JSON POST.
* `cookies.zig` should primarily demonstrate cookies.
* `http2_client.zig` should primarily demonstrate HTTP/2.
* `multipart_upload.zig` should primarily demonstrate multipart uploads.
* `websocket_client.zig` should primarily demonstrate WebSocket usage.

Related functionality may appear when necessary to make the example runnable.

### 9. Examples Must Show Actual Output

Every executable example should provide a useful visible result.

Examples should print the important result they demonstrate, such as:

* HTTP status
* Selected HTTP version
* Response headers when relevant
* Response body
* Parsed JSON result
* Uploaded/downloaded byte count
* Streamed chunks
* WebSocket messages
* Server lifecycle events
* TLS/ALPN information when demonstrating TLS or protocol negotiation
* Error information when demonstrating error handling

The expected output should be documented when the output is deterministic.

Example:

```zig
std.debug.print("Status: {d}\n", .{@intFromEnum(response.status)});
std.debug.print("Body: {s}\n", .{response.body});
```

Avoid examples that execute successfully but provide no observable demonstration.

### 10. Client Examples Must Use Public Client API

Prefer the simplest supported public syntax.

For example:

```zig
var response = try httpx.get(.{
    .url = "https://httpbin.org/get",
});
defer response.deinit();

std.debug.print("Status: {d}\n", .{@intFromEnum(response.status)});
```

When demonstrating typed JSON, use the project's supported type-safe JSON API rather than manually serializing JSON when that feature exists.

Examples must reflect the final public API, including:

* Convenience functions
* Explicit client initialization
* Explicit allocator initialization
* Request configuration
* Response handling
* Typed JSON
* Optional response typing
* Streaming
* Headers
* Cookies
* Authentication
* Timeouts
* Proxies
* TLS configuration
* HTTP version selection
* HTTP/2
* HTTP/3
* Multipart
* WebSocket
* SSE
* Other supported client features

### 11. Server Examples Must Show Both Sides When Appropriate

For client/server features, provide enough information for a developer to understand the complete interaction.

Where useful, document:

```text
Client
  |
  | HTTP request
  v
Server
  |
  | HTTP response
  v
Client
```

The example should clearly show:

* Server startup
* Route registration
* Request handling
* Response creation
* Client request
* Client response
* Shutdown/cleanup

Do not hide important lifecycle behavior behind unexplained helpers.

### 12. Example Validation

Every example added or modified must be validated.

At minimum:

1. Format it.
2. Compile it.
3. Run it where practical.
4. Verify its output.
5. Verify its cleanup behavior.
6. Verify it works with the current public API.
7. Ensure it does not depend on undocumented internal behavior.

Examples should be included in CI when practical so API-breaking changes are detected automatically.

### 13. Examples Must Follow the Same Allocator Rules

Examples must demonstrate both supported allocation models when the public API supports them:

* Default/out-of-the-box API without requiring explicit allocator configuration.
* Explicit allocator API for applications that need allocator control.

Do not expose unnecessary allocator complexity in simple examples.

A minimal user should be able to use the library with sensible built-in defaults.

An advanced user should be able to explicitly provide an allocator/configuration when required.

### 14. Keep Tests and Examples Consistent With the Public API

If an API changes:

* Update implementation.
* Update tests.
* Update examples.
* Update documentation.
* Update integration coverage.

Never leave examples using an obsolete API simply because they are outside the main source directory.

Tests and examples are part of the API compatibility surface.

### 15. CI Requirement

GitHub Actions must validate:

* Library compilation.
* Unit tests.
* Integration tests.
* Examples where practical.
* Supported operating systems.
* Supported architectures.
* Relevant protocol interoperability.

Do not make local-only assumptions.

A test that passes on one machine but fails on Windows, Linux, macOS, x86, x86_64, ARM, or AArch64 must be investigated rather than hidden.

### 16. Final Verification Requirement

Before considering a task complete, verify:

```text
Implementation
    ↓
Unit tests
    ↓
Edge-case tests
    ↓
Integration tests
    ↓
Interop tests
    ↓
Examples
    ↓
Example execution/output
    ↓
Formatting
    ↓
Cross-platform/CI validation
```

A feature is NOT considered complete merely because the source compiles.

It is complete only when its implementation, tests, edge cases, integration behavior, interoperability, examples, public API, documentation, and cleanup behavior are all consistent and production-ready.



for all testcases and all examples use this (httpbun.com)

API access on plain http:// on httpbun.com will start redirecting to `https://` soon. Requests over https:// will keep working exactly as they do today, so most people only need to add the s.

If you depend on httpbun for anything critical, like CI, please run a local instance instead of relying on the hosted one.

Logo Httpbun
A service to help test the behaviour of HTTP clients like browsers, libraries, developer tools or anything else. Inspired by httpbin. Built because httpbin lacked some things I needed, like:

The /mix endpoint, and the Mixer, with powerful ingredients like:
A RequestBin-like functionality with the slack directive.
Build response body by writing a Golang template, with the t directive.
Learn more at the Mixer guide.
The /run endpoint, and the Runner. (Beta).
A mock OAuth2 provider. (Beta).
A mock LLM API endpoint, compatible with OpenAI (chat completions, completions and responses) and Anthropic messages APIs.
Ability to run on a custom path prefix.
The /payload endpoint.
Allowing request body in /get endpoint.
Accept any method in /headers and most other such endpoints.
Not hiding some headers in responses.
More practical handling of unescaped special characters in x-www-form-urlencoded payloads.
Hosted versions:
Canonical version is at httpbun.com.
At any.httpbun.com, with --root-is-any enabled.
https://self-signed-cert.httpbun.com that uses a self-signed HTTPS certificate.
★ Star this project on GitHub.

Endpoints
Mix
/mix
Combine behaviour from multiple of other endpoints, into one. For example, if we want an endpoint with some response headers, as well as a specific status code, we can use:
/mix/s=400/h=x-custom-header:some-value
The s= and h= are directives that /mix understands. Supported directives are:
s: HTTP response status code.
h: Set a response header, in the form name:value.
c: Set a cookie, in the form name:value.
r: Set a redirect URL. Uses status code 307. To change, use s= directive.
b64: Set the response body to the base64 decoded value.
t: The base64 decoded value of this, is rendered as a Golang text template, and the result is used as the response body.
end: Takes no value, marks the end of directive processing. Path segment after this is ignored by Httpbun.
When using r or a Location header, relative redirect targets continue to work, but absolute targets are restricted to http/https URLs on an allowlist. By default this includes httpbun.com and example.com. When self-hosting, set HTTPBUN_ALLOWED_REDIRECT_DOMAINS to a comma- or whitespace-separated list like example.com httpbun.com *.github.io.

Note: Status code 101 and the Connection / Upgrade headers are hop-by-hop semantics that reverse proxies (like the Caddy instance fronting httpbun.com) handle per HTTP spec — they will be stripped or rewritten by the proxy. To test upgrade-like responses, run a local instance (docker run -p 80:80 sharat87/httpbun) and hit it directly without a proxy in front.


Learn more in the guide, and use the mixer for a UI to build these URLs.
Try it out
Methods
/get
/post
/put
/patch
/delete
Accepts GET/POST/... requests and responds with a JSON object with form body, query params, headers and a few other information about the request.
Examples
Try it out
/any
/any/{extraPath}
Acts like /get, /post etc., but works on any method, and any extra path after /any is also accepted.
Try it out
/headers
Responds with a JSON object with a single field, headers which is an object of all the headers in the request, as keys and values. If a header repeats in the request, then its values are concatenated with a comma and treated as a single header value.
Examples
Try it out
/payload
Responds with the same Content-Type header as the request and the body of the request as is.
Examples
Try it out
Authentication
/basic-auth/{username}/{password}
Requires basic authentication with username and password as the credentials.
Examples
Try it out
/bearer
/bearer/{expectedToken}
Requires bearer authentication. Which needs an Authorization header in the request, that takes the form Bearer some-auth-token-here. If no expectedToken is given, any token will be treated as valid. If no Authorization header is present in the request, this results in a 401 response.
Examples
Try it out
/digest-auth/{username}/{password}
/digest-auth/{qop}/{username}/{password}
Digest authentication. The endpoint /digest-auth/auth/scott/tiger requires to be authenticated with the credentials scott and tiger as username and password. The implementation is based on this example from Wikipedia. The value of qop can be one of auth (default), auth-int or auth,auth-int.
Try it out
/oauth2/authorize
Mock OAuth2 authorization endpoint. Displays a consent page where the user enters their email and approves or denies access. The email is later retrievable via the /oauth2/userinfo endpoint.

Required query parameters:
response_type: Must be code.
client_id: Your application's client ID (any non-empty string).
redirect_uri: The URI to redirect to after authorization.
Optional query parameters:
state: An opaque value to maintain state between request and callback.
scope: Requested scope (displayed on consent page, not validated).
On approval, redirects to redirect_uri with code and state parameters. On denial, redirects with error=access_denied. Absolute redirect_uri values are currently restricted to http/https URLs on an allowlist. By default this includes httpbun.com and example.com. When self-hosting, set HTTPBUN_ALLOWED_REDIRECT_DOMAINS to a comma- or whitespace-separated list like example.com httpbun.com *.github.io.
Example
Try it out
/oauth2/token
Mock OAuth2 token endpoint. Exchanges an authorization code for an access token.

Required form parameters (POST):
grant_type: Must be authorization_code.
code: The authorization code received from the authorize endpoint.
client_id: Your application's client ID (must match the authorization request).
client_secret: Your application's client secret (any non-empty string).
redirect_uri: Must match the redirect_uri from the authorization request.
Returns a JSON response with access_token, token_type, and expires_in.
Examples
Try it out
/oauth2/userinfo
Mock OAuth2 userinfo endpoint. Returns the email address that was entered on the consent page.

Authorization: Requires a Bearer token in the Authorization header.

Returns a JSON response with the user's email.
Examples
Try it out
Client Details
/ip
/ip.txt
Responds with a JSON object with a single field, origin, with the client's IP Address for value.
Try it out
Caching
/cache
If the request contains an If-Modified-Since or If-None-Match header, returns a 304 response. Otherwise, it behaves the same as /get for GET requests, /post for POST requests, etc.
Try it out
/cache/{age}
Sets a Cache-Control header for age seconds.
Try it out
/etag/{etag}
Assumes the resource has the given etag and responds to If-None-Match and If-Match headers appropriately.
Try it out
Client Tuned Response
/status/{codes}
Responds with the HTTP status as given by codes. It can be a comma-separated list of multiple status codes, of which a random one is chosen for the response.
Try it out
/response-headers
/respond-with-headers
Sends given query parameters as headers in the response. For example, in the response from /response-headers?one=two, there is a header called One, whose value is two. The response body contains all the headers again, in the form of a JSON object. (This JSON object in the response should be considered deprecated, and may be removed in the future.) If you set a Location header here, relative values are allowed, but absolute values are restricted to http/https URLs on httpbun.com and example.com.
Try it out
/deny
Returns page denied by robots.txt rules.
Try it out
/html
Returns a small HTML document than can trigger XSS, in vulnerable places.
Try it out
/svg/{text}
Renders an SVG circle image with fill color determined by the text. The first two letters of the text are also shown at the center of the circle. Examples:  for svg/bun,  for svg/foo.
Try it out
/robots.txt
Returns some robots.txt rules.
Try it out
/base64
/base64/{encoded}
Decodes the encoded text with base64 encoding scheme. Defaults to SFRUUEJVTiBpcyBhd2Vzb21lciE=.
Try it out
/bytes/{count}
Returns count random bytes in the response. The Content-Type header is set to application/octet-stream. The randomness is not cryptographically secure. The maximum number of bytes can be set with --endpoint-bytes-size-limit CLI argument, defaults to 90.
Try it out
/delay/{seconds}
Respond with a delay of seconds seconds. The seconds parameter can be a positive integer or floating point number.
Try it out
/drip
/drip-lines
Drips data over a duration, with an interval between each piece of data. The piece of data is the * character. The following query params can be used to configure this endpoint:
duration: Total number of seconds over which to stream the data. Default: 2.
numbytes: Total number of bytes to stream. Default: 10.
code: The HTTP status code to be used in their response. Default: 200.
delay: An initial delay, in seconds. Default: 2.
When using /drip-lines, a newline character is written after every piece of data.
Try it out
/sse
Responds with 10 Server sent events, each after 1s of delay. The count and delay can be set as query params. Count should be between 1 and 100. Delay should be between 1 and 10.
Try it out
/links/{count}
/links/{count}/{offset}
Returns an HTML document with count links, which in turn respond with HTML documents with links again. You mostly want to use the first version (i.e., without offset).
Try it out
/range/{count}
Returns count random bytes, that are generated with the same random seed every time. The value of count is capped to 1000.
Try it out
Cookie Data
/cookies
Returns cookie data from the request headers.
Try it out
/cookies/set
Sets cookies for all given query params.
Try it out
/cookies/set/{name}/{value}
Set the cookie name to value.
Try it out
/cookies/delete
Returns a response that will delete cookies in the browser. Cookies to be deleted should be given as query params. The values of these query params are ignored and can be empty.
Try it out
Redirects
/redirect
/redirect-to
Responds with a redirect to the URL given by the url query param. If a status query param is also given, it is used as the HTTP Status code in the response. Otherwise, 302 is used. Relative redirect targets continue to work, but absolute targets are restricted to http/https URLs on an allowlist. By default this includes httpbun.com and example.com. When self-hosting, set HTTPBUN_ALLOWED_REDIRECT_DOMAINS to a comma- or whitespace-separated list like example.com httpbun.com *.github.io.
Try it out
/redirect/{count}
/relative-redirect/{count}
Redirect count times. For example, /redirect/3 will redirect three times before settling on a response. The redirect URLs specified in the Location header will be relative URLs.
Try it out
/absolute-redirect/{count}
Redirect count times. For example, /redirect/3 will redirect three times before settling on a response. The redirect URLs specified in the Location header will be absolute URLs.
Try it out
LLM Mock API
Overview
Mock endpoints that mimic real LLM APIs, so you can point an SDK at httpbun instead of a paid provider. Set base_url to httpbun.com/llm, pass any dummy API key, and you're all set. No auth, no keys. Responses are deterministic with a plausible usage block, and the stream flag is honored using the right SSE protocol for each provider.
Custom responses: add an httpbun field to the request body to override the mock output:
{
  "model": "gpt-4",
  "messages": [{"role": "user", "content": "Hello!"}],
  "httpbun": {"content": "Your custom response here"}
}
If the SDK rejects unknown fields, pass it via extra_body instead, like extra_body={"httpbun": {"content": "..."}} in the Python SDK. Without it, you get a default placeholder response.
/llm/v1/chat/completions
Implements the OpenAI Chat Completions API. Accepts model, messages, max_tokens, temperature, n, stream, stop, user, and returns a chat.completion response.
Examples
Try it out
/llm/v1/completions
Implements the OpenAI legacy Completions API. Accepts model, prompt (string or list), max_tokens, temperature, n, stream, stop, user, suffix, and returns a text_completion response.
Example
Try it out
/llm/v1/responses
Implements the OpenAI Responses API. Accepts model, input (string or a list of messages), stream, user, and returns a response object. Customize output with httpbun.output_text.
Example
Try it out
/llm/v1/messages
Implements the Anthropic Messages API. Accepts model, messages, max_tokens, stream, temperature, top_p, top_k, stop_sequences, and returns an Anthropic message. Customize output with httpbun.content. Streaming uses Anthropic's event types (message_start, content_block_delta, message_stop, etc.).
Example
Try it out
Self Hosting
With Docker: docker run -p 80:80 sharat87/httpbun

From source, with task installed: task run

If using for your project's CI, please consider running a self-hosted version using the Docker container. An example of this is in the container-run.yml workflow.

Configuration
--bind
The network address to bind the server to. Defaults to localhost:3090, which configures the server to listen on TCP port 3090 on localhost.
This option can also be set with the HTTPBUN_BIND environment variable.
--path-prefix
Sets a path prefix for all the paths in Httpbun. For example, if this is set to the-one, then the /get endpoint will be available on /the-one/get. Similarly, all other endpoints are also prefixed with the value of this argument.
--root-is-any
If provided, all endpoint routes are disabled, and all endpoints behave like /any. This means that when this option is given, all HTML pages will also become inaccessible. Like the homepage, Mixer UI, help pages etc. A hosted instance with this option enabled is available at any.httpbun.com.
--endpoint-bytes-size-limit
Maximum number of bytes allowed in the /bytes endpoint.
License
Httpbun is distributed with the Apache-2.0 License. Please refer to the LICENSE and NOTICE files present in the source distribution of this project.

Credits
httpbin. This project might not have existed, if not for httpbin.
Go's excellent documentation. This project might've taken a hell of a lot longer, if not for Go's docs.
The bun icon was generated using the following graphics from Twitter Twemoji:

Graphics Title: 1fad3.svg.
Graphics Author: Copyright 2020 Twitter, Inc and other contributors.
Graphics Source.
Graphics License: CC-BY 4.0.
A project by Shri. Built from 9fa1b74 on 2026-08-20T05:53:15Z.

