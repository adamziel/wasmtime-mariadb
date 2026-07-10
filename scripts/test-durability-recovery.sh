#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-$root/build/durability-recovery}"
host="${HOST:-127.0.0.1}"
port="${PORT:-3352}"
committed_rows="${COMMITTED_ROWS:-12}"
run_dir="$out_dir/server"
host_pid_file="$out_dir/host.pid"
server_stdout="$out_dir/server.stdout"
server_stderr="$out_dir/server.stderr"

if ! [[ "$port" =~ ^[1-9][0-9]*$ ]] || ! [[ "$committed_rows" =~ ^[1-9][0-9]*$ ]]; then
  echo "PORT and COMMITTED_ROWS must be positive integers" >&2
  exit 2
fi

if [[ -n "${MYSQL:-}" ]]; then
  client="$MYSQL"
elif command -v mariadb >/dev/null 2>&1; then
  client="mariadb"
elif command -v mysql >/dev/null 2>&1; then
  client="mysql"
else
  echo "mariadb or mysql client is required" >&2
  exit 2
fi

if [[ -n "${MYSQL_ADMIN:-}" ]]; then
  admin="$MYSQL_ADMIN"
elif command -v mariadb-admin >/dev/null 2>&1; then
  admin="mariadb-admin"
elif command -v mysqladmin >/dev/null 2>&1; then
  admin="mysqladmin"
else
  echo "mariadb-admin or mysqladmin is required" >&2
  exit 2
fi

client_ssl_args=(--ssl-mode=DISABLED)
admin_ssl_args=(--ssl-mode=DISABLED)
client_version="$("$client" --version 2>&1 || true)"
admin_version="$("$admin" --version 2>&1 || true)"
case "$client_version" in
  *MariaDB*|*mariadb*) client_ssl_args=(--ssl=0) ;;
esac
case "$admin_version" in
  *MariaDB*|*mariadb*) admin_ssl_args=(--ssl=0) ;;
esac

configure_client_args() {
  client_args=(--no-defaults --protocol=TCP "-h$host" "-P$port" -uroot "${client_ssl_args[@]}")
  admin_args=(--no-defaults --protocol=TCP "-h$host" "-P$port" -uroot "${admin_ssl_args[@]}")
}
configure_client_args

server_wrapper_pid=""
server_host_pid=""
uncommitted_client_pid=""

cleanup() {
  set +e
  if [[ -n "$uncommitted_client_pid" ]] && kill -0 "$uncommitted_client_pid" 2>/dev/null; then
    kill "$uncommitted_client_pid" 2>/dev/null || true
    wait "$uncommitted_client_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_wrapper_pid" ]] && kill -0 "$server_wrapper_pid" 2>/dev/null; then
    kill -TERM "$server_wrapper_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$server_wrapper_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$server_wrapper_pid" 2>/dev/null || true
    wait "$server_wrapper_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_ready() {
  local attempt

  for attempt in $(seq 1 120); do
    if "$admin" "${admin_args[@]}" ping >/dev/null 2>&1; then
      if [[ -r "$host_pid_file" ]]; then
        server_host_pid="$(<"$host_pid_file")"
      fi
      if [[ -n "$server_host_pid" ]] && kill -0 "$server_host_pid" 2>/dev/null; then
        return 0
      fi
    fi
    if [[ -n "$server_wrapper_pid" ]] && ! kill -0 "$server_wrapper_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  cat "$server_stderr" >&2 2>/dev/null || true
  return 1
}

start_server() {
  rm -f "$host_pid_file"
  WASMTIME_MARIADB_FILE_TRACE=1 DURABILITY=strict \
    RUN_DIR="$run_dir" PORT="$port" HOST_PID_FILE="$host_pid_file" \
    "$root/scripts/run-server.sh" >>"$server_stdout" 2>>"$server_stderr" &
  server_wrapper_pid=$!
  server_host_pid=""
  wait_for_ready
}

stop_server_after_test() {
  # COM_SHUTDOWN does not yet reliably tear down the Wasmtime host. Use the
  # same signal path as Ctrl-C; strict mode is specifically tested for this.
  kill -TERM "$server_wrapper_pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! kill -0 "$server_wrapper_pid" 2>/dev/null; then
      wait "$server_wrapper_pid" 2>/dev/null || true
      server_wrapper_pid=""
      server_host_pid=""
      return 0
    fi
    sleep 0.1
  done

  echo "MariaDB did not exit after the signal shutdown path" >&2
  return 1
}

rm -rf "$out_dir"
mkdir -p "$out_dir"
: > "$server_stdout"
: > "$server_stderr"

start_server

if ! grep -q '\[wasmtime-mariadb:files\] lock_exclusive .* rc=0' "$server_stderr"; then
  echo "did not observe MariaDB's InnoDB host file-lock bridge" >&2
  exit 1
fi

set +e
DURABILITY=strict RUN_DIR="$run_dir" PORT="$((port + 1))" \
  "$root/scripts/run-server.sh" >"$out_dir/lock-contention.stdout" \
  2>"$out_dir/lock-contention.stderr"
lock_status=$?
set -e
if [[ "$lock_status" -eq 0 ]] || ! grep -q 'data directory is already in use' "$out_dir/lock-contention.stderr"; then
  echo "second server did not fail cleanly on the active data-directory lock" >&2
  cat "$out_dir/lock-contention.stderr" >&2 || true
  exit 1
fi

"$client" "${client_args[@]}" <<'SQL'
CREATE DATABASE IF NOT EXISTS durability_probe;
CREATE TABLE IF NOT EXISTS durability_probe.commits (
  id INT PRIMARY KEY,
  payload VARCHAR(64) NOT NULL
) ENGINE=InnoDB;
DELETE FROM durability_probe.commits;
SQL

syncs_before="$(grep -c '\[wasmtime-mariadb:files\] sync .* rc=0' "$server_stderr" || true)"
for id in $(seq 1 "$committed_rows"); do
  "$client" "${client_args[@]}" -e \
    "START TRANSACTION; INSERT INTO durability_probe.commits VALUES ($id, 'committed-$id'); COMMIT;"
done
sleep 1
syncs_after="$(grep -c '\[wasmtime-mariadb:files\] sync .* rc=0' "$server_stderr" || true)"
if [[ "$syncs_after" -le "$syncs_before" ]]; then
  echo "strict commits did not produce a host sync call" >&2
  exit 1
fi

"$client" "${client_args[@]}" --database=durability_probe --batch <<'SQL' \
  >"$out_dir/uncommitted-client.out" 2>"$out_dir/uncommitted-client.err" &
START TRANSACTION;
INSERT INTO commits VALUES (999999, 'uncommitted');
SELECT SLEEP(300);
SQL
uncommitted_client_pid=$!

transaction_seen=0
for _ in $(seq 1 30); do
  active_transactions="$("$client" "${client_args[@]}" -Nse \
    'SELECT COUNT(*) FROM information_schema.innodb_trx' 2>/dev/null || true)"
  if [[ "$active_transactions" =~ ^[1-9][0-9]*$ ]]; then
    transaction_seen=1
    break
  fi
  sleep 0.2
done
if [[ "$transaction_seen" -ne 1 ]]; then
  echo "could not establish the uncommitted InnoDB transaction before the crash" >&2
  exit 1
fi

kill -KILL "$server_host_pid"
for _ in $(seq 1 80); do
  if ! kill -0 "$server_wrapper_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
wait "$server_wrapper_pid" 2>/dev/null || true
server_wrapper_pid=""
server_host_pid=""
wait "$uncommitted_client_pid" 2>/dev/null || true
uncommitted_client_pid=""

# A killed TCP listener can leave its old port briefly unavailable. The data
# directory is the recovery target, so use a fresh loopback port for restart.
port="$((port + 1))"
configure_client_args
start_server

committed_after="$("$client" "${client_args[@]}" -Nse \
  'SELECT COUNT(*) FROM durability_probe.commits WHERE id BETWEEN 1 AND 999998')"
uncommitted_after="$("$client" "${client_args[@]}" -Nse \
  'SELECT COUNT(*) FROM durability_probe.commits WHERE id = 999999')"
if [[ "$committed_after" != "$committed_rows" ]] || [[ "$uncommitted_after" != "0" ]]; then
  echo "crash recovery lost a committed row or retained an uncommitted row" >&2
  echo "committed_after=$committed_after expected=$committed_rows" >&2
  echo "uncommitted_after=$uncommitted_after expected=0" >&2
  exit 1
fi

cat > "$out_dir/summary.txt" <<EOF
durability=strict
run_dir_lock=pass
innodb_file_lock_bridge=pass
host_syncs_before_commits=$syncs_before
host_syncs_after_commits=$syncs_after
committed_rows_after_sigkill=$committed_after
uncommitted_rows_after_sigkill=$uncommitted_after
EOF

cat "$out_dir/summary.txt"
stop_server_after_test
