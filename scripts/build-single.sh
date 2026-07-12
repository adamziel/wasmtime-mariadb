#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wasm="${1:-${MARIADBD_WASM:-}}"

if [[ -z "$wasm" ]]; then
  echo "usage: $0 /absolute/or/relative/path/to/mariadbd.wasm" >&2
  echo "or set MARIADBD_WASM before running this script" >&2
  exit 2
fi

if [[ ! -f "$wasm" ]]; then
  echo "mariadbd wasm module not found: $wasm" >&2
  exit 2
fi

cd "$root"
MARIADBD_WASM="$wasm" cargo build --release \
  --bin wasmtime-mariadb \
  --bin wasmtime-mariadb-supervisor
ls -lh \
  "$root/target/release/wasmtime-mariadb" \
  "$root/target/release/wasmtime-mariadb-supervisor"
