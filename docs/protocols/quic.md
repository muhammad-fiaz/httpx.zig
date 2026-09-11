# QUIC Transport Protocol

RFC 9000 defines QUIC, a secure, general-purpose, multiplexed transport protocol operating directly on top of UDP.

## Core Features

* **Authenticated & Encrypted**: All packet headers and payloads are encrypted using TLS 1.3 (RFC 9001). Middleboxes and firewalls cannot inspect or tamper with stream headers.
* **Stream Multiplexing**: Supports arbitrary numbers of concurrent unidirectional and bidirectional streams.
* **Low Latency Handshake**: 1-RTT connection setup for new connections. (0-RTT early data is not enabled: `0-RTT not enabled in this build`.)
* **Congestion Control**: NewReno controller plus RTT/loss detection primitives (`loss.zig`, `cc.zig`); ACK tracking is integrated into the receive path.

## QUIC Packet Types

* `Initial`: Initiates connection and carries TLS ClientHello / ServerHello.
* `Handshake`: Completes mutual authentication and exchanges application keys.
* `0-RTT Protected`: Carries early application data for resumed sessions.
* `1-RTT (Short Header)`: Carries standard application streams with minimum 1-byte header overhead.

## Related

* [Protocol: HTTP/3](/protocols/http-3)
* [Protocol: UDP](/protocols/udp)
* [Example: HTTP/3 QUIC](/examples/http3-quic)
