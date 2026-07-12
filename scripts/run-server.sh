#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${BIN:-}" ]]; then
  bin="$BIN"
elif [[ -x "$root/wasmtime-mariadb" ]]; then
  bin="$root/wasmtime-mariadb"
else
  bin="$root/target/release/wasmtime-mariadb"
fi
run_dir="${RUN_DIR:-$root/build/run}"
port="${PORT:-3307}"
durability="${DURABILITY:-strict}"
system_tables_source="$root/scripts/mariadb-system-tables.sql"
extra_runner_args=()
if [[ -n "${RUNNER_ARGS:-}" ]]; then
  read -r -a extra_runner_args <<< "$RUNNER_ARGS"
fi
grant_args=()
if [[ "${SKIP_GRANT_TABLES:-1}" != "0" ]]; then
  grant_args+=(--skip-grant-tables)
fi
init_args=(--init-file=/tmp/mariadb-system-tables.sql)
if [[ "${SKIP_SYSTEM_TABLES_INIT:-0}" == "1" ]]; then
  init_args=()
fi
durability_args=()
case "$durability" in
  strict)
    # Default: acknowledged InnoDB commits reach the host fdatasync bridge.
    durability_args+=(--innodb-flush-log-at-trx-commit=1)
    ;;
  relaxed)
    # Benchmark-only escape hatch. It deliberately weakens crash durability.
    durability_args+=(--debug-no-sync --innodb-flush-log-at-trx-commit=2)
    ;;
  *)
    echo "DURABILITY must be strict or relaxed, got: $durability" >&2
    exit 2
    ;;
esac
if [[ "$durability" == "strict" ]]; then
  for server_arg in "$@"; do
    case "$server_arg" in
      --debug-no-sync|--debug-no-sync=*)
        echo "DURABILITY=strict cannot be combined with $server_arg" >&2
        echo "Use DURABILITY=relaxed only for disposable benchmarks." >&2
        exit 2
        ;;
    esac
  done
fi

if [[ ! -x "$bin" ]]; then
  echo "runner binary not found: $bin" >&2
  echo "build it with: ./scripts/build-single.sh build/mariadb-wasi-port/build/sql/mariadbd" >&2
  exit 2
fi
if [[ ! -r "$system_tables_source" ]]; then
  echo "MariaDB system-table bootstrap not found: $system_tables_source" >&2
  exit 2
fi

mkdir -p "$run_dir/tmp" "$run_dir/data"
run_dir="$(cd "$run_dir" && pwd)"
system_tables_init="$run_dir/mariadb-system-tables.sql"
runtime_log="$run_dir/mariadbd-runtime.err"
host_pid_file="${HOST_PID_FILE:-}"
if [[ -n "$host_pid_file" ]]; then
  host_pid_dir="$(dirname "$host_pid_file")"
  mkdir -p "$host_pid_dir"
  host_pid_file="$(cd "$host_pid_dir" && pwd)/$(basename "$host_pid_file")"
fi

if [[ "${SKIP_SYSTEM_TABLES_INIT:-0}" != "1" && -e "$run_dir/data/ibdata1" ]]; then
  if [[ ! -e "$run_dir/data/mysql/servers.frm" || \
        ! -e "$run_dir/data/mysql/time_zone_leap_second.frm" ]]; then
    cat >&2 <<EOF
MariaDB data directory is incomplete: $run_dir/data
It contains InnoDB files but not the completed local system-table bootstrap.
This normally means the first startup was interrupted before "ready for connections".

If this is disposable local data, remove only this run directory and start again:
  rm -rf "$run_dir"
EOF
    exit 2
  fi
fi

new_datadir=0
if [[ ! -e "$run_dir/data/ibdata1" ]]; then
  new_datadir=1
fi

runtime_log_start_line=1
if [[ -f "$runtime_log" ]]; then
  runtime_log_start_line="$(awk 'END { print NR + 1 }' "$runtime_log")"
fi

cp "$system_tables_source" "$system_tables_init"

if [[ "$new_datadir" -eq 1 ]]; then
  cat <<EOF
Initializing a new local InnoDB data directory at: $run_dir/data
The first startup can take up to a minute. Do not interrupt it; wait for
"ready for connections" before using a client.
EOF
fi
echo "MariaDB runtime log: $runtime_log"
echo "MariaDB durability mode: $durability"

# The current file shim does not track guest chdir(), and MariaDB uses relative
# paths after selecting its datadir. Run from the host datadir until chdir is
# modeled explicitly.
cd "$run_dir/data"

# Bash 3.2 treats an empty array as unset under `set -u`.
set +u
"$bin" \
  --no-inherit-env \
  --lock-file "$run_dir/.wasmtime-mariadb.lock" \
  --preopen "$run_dir=/tmp" \
  --env TMPDIR=/tmp/tmp \
  --env HOME=/tmp \
  "${extra_runner_args[@]}" \
  -- \
  --no-defaults \
  --console \
  "${grant_args[@]}" \
  --skip-external-locking \
  "${durability_args[@]}" \
  --skip-ssl \
  --basedir=/tmp \
  --datadir=/tmp/data \
  --tmpdir=/tmp/tmp \
  "${init_args[@]}" \
  --log-error=/tmp/mariadbd-runtime.err \
  --port="$port" \
  --bind-address=127.0.0.1 \
  --skip-log-bin \
  --skip-slave-start \
  --default-storage-engine=InnoDB \
  --innodb-buffer-pool-size=16M \
  --innodb-buffer-pool-size-max=16M \
  --innodb-log-file-size=8M \
  --innodb-log-buffer-size=4M \
  "$@" \
  "${durability_args[@]}" &
server_pid=$!
set -u

if [[ -n "$host_pid_file" ]]; then
  printf '%s\n' "$server_pid" > "$host_pid_file"
fi

remove_host_pid_file() {
  if [[ -n "$host_pid_file" ]]; then
    rm -f "$host_pid_file"
  fi
}

tail_pid=""
stop_log_stream() {
  if [[ -n "$tail_pid" ]]; then
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    tail_pid=""
  fi
}

forward_signal() {
  local status="$1"

  trap - INT TERM
  if kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
  fi
  wait "$server_pid" 2>/dev/null || true
  stop_log_stream
  remove_host_pid_file
  exit "$status"
}

trap 'forward_signal 130' INT
trap 'forward_signal 143' TERM

# --log-error writes MariaDB's useful startup diagnostics to a file. Stream
# only lines from this invocation so a foreground user can see first boot work.
while [[ ! -f "$runtime_log" ]]; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
if [[ -f "$runtime_log" ]]; then
  tail -n "+$runtime_log_start_line" -F "$runtime_log" &
  tail_pid=$!
fi

# Bash defers INT/TERM traps while it blocks in `wait` for a child. Polling
# keeps Ctrl-C responsive while the Wasmtime host runs in the background.
while kill -0 "$server_pid" 2>/dev/null; do
  sleep 0.1
done
if wait "$server_pid"; then
  server_status=0
else
  server_status=$?
fi
stop_log_stream
remove_host_pid_file

if [[ "$server_status" -ne 0 ]]; then
  echo "MariaDB exited with status $server_status." >&2
  if [[ -f "$runtime_log" ]]; then
    echo "Last 80 lines of $runtime_log:" >&2
    tail -n 80 "$runtime_log" >&2 || true
  fi
fi

exit "$server_status"
