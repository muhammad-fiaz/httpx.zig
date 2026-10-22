"""Independent HTTP/3 server (aioquic) used by the interop runner."""
import argparse
import asyncio
import logging

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated
from aioquic.quic.logger import QuicFileLogger


class H3ServerProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.headers = {}
        self.bodies = {}
        self.done = set()

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            if event.alpn_protocol != "h3":
                self.close()
                return
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                self.headers[http_event.stream_id] = {
                    k.decode(): v.decode() for k, v in http_event.headers
                }
                self.bodies.setdefault(http_event.stream_id, bytearray())
                if http_event.stream_ended:
                    self.respond(http_event.stream_id)
            elif isinstance(http_event, DataReceived):
                self.bodies[http_event.stream_id].extend(http_event.data)
                if http_event.stream_ended:
                    self.respond(http_event.stream_id)

    def respond(self, stream_id):
        if stream_id in self.done:
            return
        self.done.add(stream_id)
        headers = self.headers.pop(stream_id, {})
        body = bytes(self.bodies.pop(stream_id, b""))
        path = headers.get(":path", "/")
        method = headers.get(":method", "GET")
        if path == "/hello":
            payload = b"hello-from-python-h3"
            status = 200
        elif path == "/echo":
            payload = body
            status = 200
        elif path == "/large":
            payload = bytes(97 + i % 26 for i in range(256 * 1024))
            status = 200
        elif path == "/host":
            payload = headers.get(":authority", "").encode()
            status = 200
        else:
            payload = b"not-found"
            status = 404
        self.http.send_headers(
            stream_id=stream_id,
            headers=[
                (b":status", str(status).encode()),
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(payload)).encode()),
            ],
            end_stream=(method == "HEAD"),
        )
        if method != "HEAD":
            self.http.send_data(stream_id, payload, end_stream=True)
        self.transmit()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--qlog", help="directory for aioquic qlog files")
    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)

    config = QuicConfiguration(
        is_client=False,
        alpn_protocols=H3_ALPN,
        quic_logger=QuicFileLogger(args.qlog) if args.qlog else None,
    )
    config.load_cert_chain(args.cert, args.key)
    server = await serve(
        "127.0.0.1",
        args.port,
        configuration=config,
        create_protocol=H3ServerProtocol,
    )
    sockname = server._transport.get_extra_info("sockname")
    print(f"LISTEN {sockname[1]}", flush=True)
    await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
