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
read -r -a extra_runner_args <<< "${RUNNER_ARGS:-}"

if [[ ! -x "$bin" ]]; then
  echo "runner binary not found: $bin" >&2
  echo "build it with: ./scripts/build-single.sh build/mariadb-wasi-port/build/sql/mariadbd" >&2
  exit 2
fi

mkdir -p "$run_dir/tmp" "$run_dir/data"

# The current file shim does not track guest chdir(), and MariaDB uses relative
# paths after selecting its datadir. Run from the host datadir until chdir is
# modeled explicitly.
cd "$run_dir/data"

exec "$bin" \
  --no-inherit-env \
  --preopen "$run_dir=/tmp" \
  --env TMPDIR=/tmp/tmp \
  --env HOME=/tmp \
  "${extra_runner_args[@]}" \
  -- \
  --no-defaults \
  --console \
  --skip-grant-tables \
  --skip-external-locking \
  --debug-no-sync \
  --skip-ssl \
  --basedir=/tmp \
  --datadir=/tmp/data \
  --tmpdir=/tmp/tmp \
  --log-error=/tmp/mariadbd-runtime.err \
  --port="$port" \
  --bind-address=127.0.0.1 \
  --skip-log-bin \
  --default-storage-engine=InnoDB \
  --innodb-buffer-pool-size=16M \
  --innodb-buffer-pool-size-max=16M \
  --innodb-log-file-size=8M \
  --innodb-log-buffer-size=4M \
  "$@"
