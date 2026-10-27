# QUIC Transport Protocol

RFC 9000 defines QUIC, a secure, general-purpose, multiplexed transport protocol operating directly on top of UDP.

## Core Features

* **Authenticated & Encrypted**: All packet headers and payloads are encrypted using TLS 1.3 (RFC 9001). Middleboxes and firewalls cannot inspect or tamper with stream headers.
* **Stream Multiplexing**: Unidirectional and bidirectional streams with per-stream and connection flow control, RESET_STREAM/STOP_SENDING, and MAX_STREAMS updates.
* **Low Latency Handshake**: 1-RTT connection setup and 0-RTT resumption with PSK tickets, bounded server-side anti-replay, and early-data policy enforcement.
* **Recovery & Congestion Control**: ACK tracking, RTT estimation, PTO probes, loss declaration/retransmission, and a NewReno controller are integrated into the send/receive paths.
* **Transport Parameters**: Peer parameters are exchanged during the handshake and applied to stream limits and flow-control windows.
* **Handshake Lifecycle**: The server confirms after verifying the client Finished and signals `HANDSHAKE_DONE`; the client confirms on that frame or on an acknowledgment of a 1-RTT packet. Confirmation discards the Handshake keys and releases their recovery state, and late Handshake packets are ignored (RFC 9001 Sections 4.1.2 and 4.9.2).

## Deliberate Limits

* Retry/token validation, QUIC v1/v2 version negotiation, and 1-RTT key updates are implemented; compatible-version negotiation is not.
* No HelloRetryRequest handling in the QUIC TLS driver.
* No connection migration yet.
* The high-level HTTP/3 client pools QUIC connections for sequential reuse without multiplexing concurrent requests over one connection; the server multiplexes requests on its active connection.

## QUIC Packet Types

* `Initial`: Initiates connection and carries TLS ClientHello / ServerHello.
* `Handshake`: Completes mutual authentication and exchanges application keys.
* `0-RTT Protected`: Carries early application data for resumed sessions.
* `1-RTT (Short Header)`: Carries standard application streams with minimum 1-byte header overhead.

## Related

* [Protocol: HTTP/3](/protocols/http-3)
* [Protocol: UDP](/protocols/udp)
* [Example: HTTP/3 QUIC](/examples/http3-quic)
