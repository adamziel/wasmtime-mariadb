#!/usr/bin/env bash
set -euo pipefail

# Writes a portable stop request consumed by the foreground supervisor. This
# avoids relying on MariaDB's COM_SHUTDOWN behavior to end the Wasmtime host.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${SUPERVISOR:-}" ]]; then
  supervisor="$SUPERVISOR"
elif [[ -n "${BIN:-}" ]] && [[ -x "$(cd "$(dirname "$BIN")" && pwd)/wasmtime-mariadb-supervisor" ]]; then
  supervisor="$(cd "$(dirname "$BIN")" && pwd)/wasmtime-mariadb-supervisor"
elif [[ -x "$root/wasmtime-mariadb-supervisor" ]]; then
  supervisor="$root/wasmtime-mariadb-supervisor"
else
  supervisor="$root/target/release/wasmtime-mariadb-supervisor"
fi

if [[ ! -x "$supervisor" ]]; then
  echo "MariaDB supervisor not found: $supervisor" >&2
  exit 2
fi

run_dir="${1:-${RUN_DIR:-$root/build/run}}"
if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [RUN_DIR]" >&2
  exit 2
fi

exec "$supervisor" --stop-run-dir "$run_dir"
