#!/usr/bin/env python3
"""Exercise the release supervisor's local start, stop, and recovery contract."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


READY_TIMEOUT_SECONDS = 90
STOP_TIMEOUT_SECONDS = 25
INTERRUPT_TIMEOUT_SECONDS = 5


def load_mysql_client(root):
    """Loads the existing dependency-free TCP MySQL client used by benchmarks."""
    path = root / "scripts" / "bench-tcp.py"
    spec = importlib.util.spec_from_file_location("wasmtime_mariadb_bench", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load MySQL test client from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.MysqlClient


def read_json(path):
    """Reads one supervisor metadata file after its atomic replacement completes."""
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def wait_for_ready(process, endpoint_path, log_path):
    """Waits for a live supervisor to publish a ready endpoint record."""
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if endpoint_path.exists():
            try:
                endpoint = read_json(endpoint_path)
            except (OSError, ValueError):
                endpoint = None
            if endpoint and endpoint.get("state") == "ready":
                return endpoint
        if process.poll() is not None:
            raise RuntimeError(
                f"supervisor exited with {process.returncode}; see {log_path}"
            )
        time.sleep(0.1)
    raise RuntimeError(f"MariaDB did not become ready within {READY_TIMEOUT_SECONDS}s; see {log_path}")


def wait_for_exit(process, timeout, description):
    """Waits for a supervisor result and turns a timeout into a useful failure."""
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{description} did not exit within {timeout}s") from error


def process_is_alive(pid):
    """Checks whether a recorded runner PID still names a process on this host."""
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def force_cleanup(process, endpoint):
    """Removes test processes on failure without relying on protocol shutdown."""
    if endpoint and process_is_alive(endpoint.get("pid")):
        try:
            os.kill(endpoint["pid"], signal.SIGKILL if os.name != "nt" else signal.SIGTERM)
        except OSError:
            pass
    if process and process.poll() is None:
        process.kill()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def start_supervisor(args, run_dir, number):
    """Starts one foreground supervisor and returns its process, metadata, and log path."""
    endpoint_path = run_dir / ".wasmtime-mariadb-endpoint.json"
    log_path = run_dir / f"supervisor-{number}.log"
    command = [
        str(args.supervisor),
        "--bin",
        str(args.runner),
        "--run-dir",
        str(run_dir),
        "--port",
        args.port,
        "--durability",
        "strict",
    ]
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    endpoint = wait_for_ready(process, endpoint_path, log_path)
    return process, endpoint, log_path


def request_stop(args, run_dir):
    """Uses the public control command instead of reaching into a process table."""
    subprocess.run(
        [str(args.supervisor), "--stop-run-dir", str(run_dir)],
        check=True,
        timeout=10,
    )


def verify_recovery(mysql_client, endpoint):
    """Checks that a committed InnoDB row remains after the previous lifecycle stop."""
    client = mysql_client(endpoint["host"], int(endpoint["port"]), "root")
    try:
        rows = client.query("SELECT payload FROM lifecycle_probe.rows WHERE id = 1")
    finally:
        client.close()
    if rows != [["survives-control-stop"]]:
        raise RuntimeError(f"unexpected recovered rows: {rows!r}")


def populate(mysql_client, endpoint):
    """Creates one small committed InnoDB record for the restart assertion."""
    client = mysql_client(endpoint["host"], int(endpoint["port"]), "root")
    try:
        client.query("CREATE DATABASE IF NOT EXISTS lifecycle_probe")
        client.query(
            "CREATE TABLE IF NOT EXISTS lifecycle_probe.rows "
            "(id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=InnoDB"
        )
        client.query("DELETE FROM lifecycle_probe.rows")
        client.query(
            "INSERT INTO lifecycle_probe.rows VALUES (1, 'survives-control-stop')"
        )
    finally:
        client.close()


def default_binary(root, name):
    """Selects a release sibling first and a source-tree release build second."""
    suffix = ".exe" if os.name == "nt" else ""
    sibling = root / f"{name}{suffix}"
    if sibling.is_file():
        return sibling
    return root / "target" / "release" / f"{name}{suffix}"


def parse_args():
    """Parses a disposable local test directory and explicit binary overrides."""
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, default=root / "build" / "supervisor-lifecycle")
    parser.add_argument("--supervisor", type=Path, default=default_binary(root, "wasmtime-mariadb-supervisor"))
    parser.add_argument("--runner", type=Path, default=default_binary(root, "wasmtime-mariadb"))
    parser.add_argument("--port", default="auto")
    return parser.parse_args()


def main():
    """Runs controlled stop/restart checks everywhere and a direct SIGINT check on Unix."""
    args = parse_args()
    args.supervisor = args.supervisor.resolve()
    args.runner = args.runner.resolve()
    if not args.supervisor.is_file():
        raise RuntimeError(f"supervisor binary not found: {args.supervisor}")
    if not args.runner.is_file():
        raise RuntimeError(f"runner binary not found: {args.runner}")

    root = Path(__file__).resolve().parent.parent
    mysql_client = load_mysql_client(root)
    run_dir = args.run_dir.resolve()
    shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True)

    process = None
    endpoint = None
    try:
        process, endpoint, _ = start_supervisor(args, run_dir, 1)
        populate(mysql_client, endpoint)
        request_stop(args, run_dir)
        status = wait_for_exit(process, STOP_TIMEOUT_SECONDS, "supervisor after stop request")
        if status != 0:
            raise RuntimeError(f"supervisor stop returned {status}")
        process = None
        endpoint = None

        manifest = read_json(run_dir / ".wasmtime-mariadb-run.json")
        stopped = read_json(run_dir / ".wasmtime-mariadb-endpoint.json")
        if manifest.get("state") != "ready" or stopped.get("state") != "stopped":
            raise RuntimeError(f"unexpected lifecycle metadata: {manifest!r}; {stopped!r}")

        process, endpoint, _ = start_supervisor(args, run_dir, 2)
        verify_recovery(mysql_client, endpoint)
        print("control_stop_recovery=pass")

        if os.name != "nt":
            runner_pid = endpoint["pid"]
            process.send_signal(signal.SIGINT)
            status = wait_for_exit(process, INTERRUPT_TIMEOUT_SECONDS, "supervisor after SIGINT")
            if status != 0 or process_is_alive(runner_pid):
                raise RuntimeError("SIGINT did not terminate the supervisor and runner cleanly")
            process = None
            endpoint = None
            print("sigint_lifecycle=pass")
        else:
            request_stop(args, run_dir)
            status = wait_for_exit(process, STOP_TIMEOUT_SECONDS, "Windows supervisor after stop request")
            if status != 0:
                raise RuntimeError(f"Windows supervisor stop returned {status}")
            process = None
            endpoint = None
            print("windows_control_stop=pass")
    finally:
        force_cleanup(process, endpoint)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"lifecycle test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
