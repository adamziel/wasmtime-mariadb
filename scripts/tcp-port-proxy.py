#!/usr/bin/env python3
import asyncio
import signal
import sys


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


def read_backend(path):
    with open(path, "r", encoding="utf-8") as f:
        parts = f.read().strip().split()
    if len(parts) == 1:
        return "127.0.0.1", int(parts[0])
    if len(parts) == 2:
        return parts[0], int(parts[1])
    raise ValueError(f"invalid backend file: {path}")


async def handle_client(local_reader, local_writer, backend_file):
    try:
        tcp_host, tcp_port = read_backend(backend_file)
        remote_reader, remote_writer = await asyncio.open_connection(tcp_host, tcp_port)
    except Exception:
        local_writer.close()
        await local_writer.wait_closed()
        return

    await asyncio.gather(
        pipe(local_reader, remote_writer),
        pipe(remote_reader, local_writer),
        return_exceptions=True,
    )


async def main():
    if len(sys.argv) != 4:
        print(
            "usage: tcp-port-proxy.py LISTEN_HOST LISTEN_PORT BACKEND_FILE",
            file=sys.stderr,
        )
        return 2

    listen_host = sys.argv[1]
    listen_port = int(sys.argv[2])
    backend_file = sys.argv[3]

    server = await asyncio.start_server(
        lambda reader, writer: handle_client(reader, writer, backend_file),
        listen_host,
        listen_port,
    )

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stop.set_result, None)

    async with server:
        await stop

    server.close()
    await server.wait_closed()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
