#!/usr/bin/env python3
import asyncio
import os
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


async def handle_client(local_reader, local_writer, tcp_host, tcp_port):
    try:
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
            "usage: tcp-unix-proxy.py UNIX_SOCKET TCP_HOST TCP_PORT",
            file=sys.stderr,
        )
        return 2

    socket_path = sys.argv[1]
    tcp_host = sys.argv[2]
    tcp_port = int(sys.argv[3])

    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    server = await asyncio.start_unix_server(
        lambda reader, writer: handle_client(reader, writer, tcp_host, tcp_port),
        path=socket_path,
    )
    os.chmod(socket_path, 0o777)

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stop.set_result, None)

    async with server:
        await stop

    server.close()
    await server.wait_closed()
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
