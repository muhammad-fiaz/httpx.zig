"""Independent HTTP/3 client (aioquic) used by the interop runner."""
import argparse
import asyncio
import logging

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated
from aioquic.quic.logger import QuicFileLogger


class H3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.status = None
        self.body = bytearray()
        self.finished = asyncio.get_running_loop().create_future()

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated) and event.alpn_protocol != "h3":
            if not self.finished.done():
                self.finished.set_exception(RuntimeError("ALPN mismatch"))
            return
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                for name, value in http_event.headers:
                    if name == b":status":
                        self.status = int(value)
                if http_event.stream_ended and not self.finished.done():
                    self.finished.set_result(None)
            elif isinstance(http_event, DataReceived):
                self.body.extend(http_event.data)
                if http_event.stream_ended and not self.finished.done():
                    self.finished.set_result(None)

    async def request(self, authority, method, path, body):
        stream_id = self._quic.get_next_available_stream_id()
        headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
        ]
        if body is not None:
            headers.append((b"content-length", str(len(body)).encode()))
        self.http.send_headers(stream_id, headers, end_stream=body is None)
        if body is not None:
            self.http.send_data(stream_id, body, end_stream=True)
        self.transmit()
        await asyncio.wait_for(self.finished, timeout=20)
        return self.status, bytes(self.body)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--method", default="GET")
    parser.add_argument("--path", default="/hello")
    parser.add_argument("--body")
    parser.add_argument("--expect", required=True)
    parser.add_argument("--ca", required=True)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--qlog", help="directory for aioquic qlog files")
    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)

    config = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        cafile=args.ca,
        quic_logger=QuicFileLogger(args.qlog) if args.qlog else None,
    )
    body = args.body.encode() if args.body is not None else None
    async with connect(
        args.host,
        args.port,
        configuration=config,
        create_protocol=H3ClientProtocol,
        wait_connected=True,
    ) as client:
        status, received = await client.request(
            f"{args.host}:{args.port}", args.method, args.path, body
        )
    if status != 200:
        raise SystemExit(f"FAIL status={status} expected=200")
    if received != args.expect.encode():
        raise SystemExit(f"FAIL body={received!r} expected={args.expect!r}")
    print(f"OK status={status} protocol=h3 bytes={len(received)}")


if __name__ == "__main__":
    asyncio.run(main())
