#!/usr/bin/env python3
import argparse
import socket
import struct
import threading
import time


CLIENT_LONG_PASSWORD = 0x00000001
CLIENT_LONG_FLAG = 0x00000004
CLIENT_PROTOCOL_41 = 0x00000200
CLIENT_TRANSACTIONS = 0x00002000
CLIENT_SECURE_CONNECTION = 0x00008000
CLIENT_MULTI_STATEMENTS = 0x00010000
CLIENT_MULTI_RESULTS = 0x00020000
CLIENT_PLUGIN_AUTH = 0x00080000
CLIENT_CONNECT_ATTRS = 0x00100000


class MysqlError(Exception):
    pass


class MysqlClient:
    def __init__(self, host, port, user):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(30)
        self._handshake(user)

    def close(self):
        try:
            self._write_packet(b"\x01", 0)
        finally:
            self.sock.close()

    def query(self, sql):
        self._write_packet(b"\x03" + sql.encode("utf-8"), 0)
        payload = self._read_packet()
        tag = payload[0]
        if tag == 0x00:
            return []
        if tag == 0xFF:
            raise MysqlError(self._err(payload))

        column_count, _ = read_lenenc(payload, 0)
        for _ in range(column_count):
            self._read_packet()
        self._read_packet()

        rows = []
        while True:
            payload = self._read_packet()
            if payload[0] == 0xFE and len(payload) < 9:
                return rows
            row = []
            pos = 0
            for _ in range(column_count):
                value_len, pos = read_lenenc(payload, pos)
                if value_len is None:
                    row.append(None)
                else:
                    row.append(payload[pos : pos + value_len].decode("utf-8"))
                    pos += value_len
            rows.append(row)

    def _handshake(self, user):
        payload = self._read_packet()
        pos = 1
        nul = payload.index(0, pos)
        pos = nul + 1 + 4 + 8 + 1
        cap_lower = struct.unpack_from("<H", payload, pos)[0]
        pos += 2
        if len(payload) > pos:
            pos += 1 + 2
            cap_upper = struct.unpack_from("<H", payload, pos)[0]
            server_caps = cap_lower | (cap_upper << 16)
        else:
            server_caps = cap_lower

        client_caps = (
            CLIENT_LONG_PASSWORD
            | CLIENT_LONG_FLAG
            | CLIENT_PROTOCOL_41
            | CLIENT_TRANSACTIONS
            | CLIENT_SECURE_CONNECTION
            | CLIENT_MULTI_STATEMENTS
            | CLIENT_MULTI_RESULTS
            | CLIENT_PLUGIN_AUTH
            | CLIENT_CONNECT_ATTRS
        )
        client_caps &= server_caps

        response = bytearray()
        response += struct.pack("<I", client_caps)
        response += struct.pack("<I", 16 * 1024 * 1024)
        response += b"\x21"
        response += b"\0" * 23
        response += user.encode("utf-8") + b"\0"
        response += b"\0"
        if client_caps & CLIENT_PLUGIN_AUTH:
            response += b"caching_sha2_password\0"
        response += b"\0"
        self._write_packet(bytes(response), 1)

        payload = self._read_packet()
        if payload[0] == 0x00:
            return
        if payload[0] == 0x01:
            payload = self._read_packet()
            if payload[0] == 0x00:
                return
        if payload[0] == 0xFF:
            raise MysqlError(self._err(payload))
        raise MysqlError(f"unexpected auth packet: {payload[:16].hex()}")

    def _read_packet(self):
        header = self._read_exact(4)
        length = header[0] | (header[1] << 8) | (header[2] << 16)
        return self._read_exact(length)

    def _write_packet(self, payload, seq):
        header = struct.pack("<I", len(payload))[:3] + bytes([seq])
        self.sock.sendall(header + payload)

    def _read_exact(self, n):
        chunks = []
        remaining = n
        while remaining:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise MysqlError("connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _err(self, payload):
        code = struct.unpack_from("<H", payload, 1)[0]
        message = payload[9:].decode("utf-8", "replace") if len(payload) > 9 else ""
        return f"{code}: {message}"


def read_lenenc(payload, pos):
    first = payload[pos]
    pos += 1
    if first < 0xFB:
        return first, pos
    if first == 0xFB:
        return None, pos
    if first == 0xFC:
        return struct.unpack_from("<H", payload, pos)[0], pos + 2
    if first == 0xFD:
        return (
            payload[pos] | (payload[pos + 1] << 8) | (payload[pos + 2] << 16),
            pos + 3,
        )
    return struct.unpack_from("<Q", payload, pos)[0], pos + 8


def build_values(client_id, start, count):
    values = []
    for offset in range(count):
        row_id = start + offset
        values.append(f"({row_id}, 'client-{client_id}-row-{row_id}')")
    return ",".join(values)


def worker(args, client_id, results, errors):
    try:
        db = MysqlClient(args.host, args.port, args.user)
        table = f"{args.database}.{args.table_prefix}_{args.run_id}_{client_id:02d}"
        db.query(
            f"CREATE TABLE {table} "
            f"(id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE={args.engine}"
        )
        inserted = 0
        started = time.perf_counter()
        while inserted < args.rows:
            batch = min(args.batch_size, args.rows - inserted)
            db.query(
                f"INSERT INTO {table} "
                f"VALUES {build_values(client_id, inserted, batch)}"
            )
            inserted += batch
        rows = db.query(f"SELECT COUNT(*) FROM {table}")
        elapsed = time.perf_counter() - started
        db.close()
        results[client_id] = (inserted, int(rows[0][0]), elapsed)
    except Exception as exc:
        errors[client_id] = repr(exc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3307)
    parser.add_argument("--user", default="root")
    parser.add_argument("--database", default="bench")
    parser.add_argument("--clients", type=int, default=8)
    parser.add_argument("--rows", type=int, default=500)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--engine", default="MEMORY")
    parser.add_argument("--table-prefix", default="t")
    args = parser.parse_args()
    args.run_id = int(time.time() * 1000)

    db = MysqlClient(args.host, args.port, args.user)
    print(db.query("SELECT VERSION()")[0][0])
    db.query(f"CREATE DATABASE IF NOT EXISTS {args.database}")
    db.close()

    results = {}
    errors = {}
    threads = []
    started = time.perf_counter()
    for client_id in range(args.clients):
        thread = threading.Thread(target=worker, args=(args, client_id, results, errors))
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    elapsed = time.perf_counter() - started

    if errors:
        for client_id, error in sorted(errors.items()):
            print(f"client {client_id}: {error}")
        raise SystemExit(1)

    total_inserted = sum(item[0] for item in results.values())
    total_counted = sum(item[1] for item in results.values())
    slowest = max(item[2] for item in results.values())
    print(f"clients={args.clients}")
    print(f"rows_per_client={args.rows}")
    print(f"batch_size={args.batch_size}")
    print(f"inserted_rows={total_inserted}")
    print(f"counted_rows={total_counted}")
    print(f"elapsed_seconds={elapsed:.3f}")
    print(f"slowest_client_seconds={slowest:.3f}")
    print(f"rows_per_second={total_inserted / elapsed:.1f}")


if __name__ == "__main__":
    main()
