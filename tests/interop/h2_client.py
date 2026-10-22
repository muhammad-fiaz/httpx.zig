"""Independent HTTP/2 prior-knowledge client used by the interop runner."""
import argparse
import asyncio

import h2.config
import h2.connection
import h2.events


async def request(host, port, method, path, body, expected):
    reader, writer = await asyncio.open_connection(host, port)
    conn = h2.connection.H2Connection(
        config=h2.config.H2Configuration(client_side=True)
    )
    conn.initiate_connection()
    writer.write(conn.data_to_send())
    await writer.drain()

    headers = [
        (":method", method),
        (":scheme", "http"),
        (":authority", f"{host}:{port}"),
        (":path", path),
    ]
    if body is not None:
        headers.append(("content-length", str(len(body))))
    conn.send_headers(1, headers, end_stream=body is None)
    if body is not None:
        conn.send_data(1, body, end_stream=True)
    writer.write(conn.data_to_send())
    await writer.drain()

    status = None
    received = bytearray()
    ended = False
    while not ended:
        data = await asyncio.wait_for(reader.read(65536), timeout=15)
        if not data:
            break
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.ResponseReceived):
                status = int(dict(event.headers).get(b":status", b"0"))
            elif isinstance(event, h2.events.DataReceived):
                received.extend(event.data)
                conn.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id
                )
            elif isinstance(event, h2.events.StreamEnded):
                ended = True
        writer.write(conn.data_to_send())
        await writer.drain()
    writer.close()
    await writer.wait_closed()

    if status != 200:
        raise SystemExit(f"FAIL status={status} expected=200")
    if bytes(received) != expected:
        raise SystemExit(f"FAIL body={bytes(received)!r} expected={expected!r}")
    print(f"OK status={status} protocol=h2 bytes={len(received)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--method", default="GET")
    parser.add_argument("--path", default="/hello")
    parser.add_argument("--body")
    parser.add_argument("--expect", required=True)
    parser.add_argument(
        "--expect-gen", choices=["large"], help="generate the expected body instead"
    )
    args = parser.parse_args()
    body = args.body.encode() if args.body is not None else None
    expected = (
        bytes(97 + i % 26 for i in range(256 * 1024))
        if args.expect_gen == "large"
        else args.expect.encode()
    )
    asyncio.run(
        request(
            args.host,
            args.port,
            args.method,
            args.path,
            body,
            expected,
        )
    )


if __name__ == "__main__":
    main()
