"""Independent HTTP/2 prior-knowledge server used by the interop runner."""
import argparse
import asyncio

import h2.config
import h2.connection
import h2.events
from h2.settings import SettingCodes


class H2Server:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=False)
        )
        # hyper-h2 4.4.1 still advertises SETTINGS_ENABLE_PUSH from servers,
        # which RFC 9113 Section 6.5.2 forbids. Remove it so this peer is a
        # compliant server instead of tripping the client's mandated check.
        self.conn.local_settings.pop(SettingCodes.ENABLE_PUSH, None)
        self.headers = {}
        self.bodies = {}
        self.done = set()
        self.pending = {}

    async def run(self):
        self.conn.initiate_connection()
        self.writer.write(self.conn.data_to_send())
        await self.writer.drain()
        while True:
            data = await self.reader.read(65536)
            if not data:
                return
            for event in self.conn.receive_data(data):
                if isinstance(event, h2.events.RequestReceived):
                    self.headers[event.stream_id] = dict(event.headers)
                    self.bodies[event.stream_id] = bytearray()
                    if event.stream_ended:
                        self.respond(event.stream_id)
                elif isinstance(event, h2.events.DataReceived):
                    self.bodies[event.stream_id].extend(event.data)
                    self.conn.acknowledge_received_data(
                        event.flow_controlled_length, event.stream_id
                    )
                    if event.stream_ended:
                        self.respond(event.stream_id)
                elif isinstance(event, h2.events.StreamReset):
                    self.headers.pop(event.stream_id, None)
                    self.bodies.pop(event.stream_id, None)
                elif isinstance(event, h2.events.WindowUpdated):
                    self.flush_body(event.stream_id)
            self.flush_body()
            self.writer.write(self.conn.data_to_send())
            await self.writer.drain()

    def flush_body(self, stream_id=None):
        """Sends queued response bytes within the peer's flow-control window."""
        if stream_id is not None:
            ids = [stream_id] if stream_id in self.pending else []
        else:
            ids = list(self.pending)
        for sid in ids:
            payload, offset = self.pending[sid]
            while offset < len(payload):
                window = self.conn.local_flow_control_window(sid)
                if window <= 0:
                    break
                size = min(window, 16384, len(payload) - offset)
                offset += size
                self.conn.send_data(
                    sid,
                    payload[offset - size : offset],
                    end_stream=(offset == len(payload)),
                )
            if offset == len(payload):
                del self.pending[sid]
            else:
                self.pending[sid] = (payload, offset)

    def respond(self, stream_id):
        if stream_id in self.done:
            return
        self.done.add(stream_id)
        headers = self.headers.pop(stream_id, {})
        body = bytes(self.bodies.pop(stream_id, b""))
        path = headers.get(b":path", b"/").decode()
        method = headers.get(b":method", b"GET").decode()
        if path == "/hello":
            payload, status, content_type = b"hello-from-python-h2", 200, "text/plain"
        elif path == "/echo":
            payload, status, content_type = body, 200, "text/plain"
        elif path == "/large":
            payload = bytes(97 + i % 26 for i in range(256 * 1024))
            status, content_type = 200, "application/octet-stream"
        elif path == "/host":
            payload = headers.get(b":authority", b"")
            status, content_type = 200, "text/plain"
        else:
            payload, status, content_type = b"not-found", 404, "text/plain"
        self.conn.send_headers(
            stream_id,
            [
                (":status", str(status)),
                ("content-type", content_type),
                ("content-length", str(len(payload))),
            ],
            end_stream=(method == "HEAD"),
        )
        if method != "HEAD" and payload:
            self.pending[stream_id] = (payload, 0)
            self.flush_body(stream_id)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = await asyncio.start_server(
        lambda r, w: H2Server(r, w).run(), "127.0.0.1", args.port
    )
    port = server.sockets[0].getsockname()[1]
    print(f"LISTEN {port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
