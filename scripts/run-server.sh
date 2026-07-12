#!/usr/bin/env bash
set -euo pipefail

# Keep the documented Unix command stable while the compiled supervisor owns
# lifecycle, data-directory compatibility, and Ctrl-C behavior on every host.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suffix=""
if [[ "${OS:-}" == "Windows_NT" ]]; then
  suffix=".exe"
fi

if [[ -n "${SUPERVISOR:-}" ]]; then
  supervisor="$SUPERVISOR"
elif [[ -x "$root/wasmtime-mariadb-supervisor$suffix" ]]; then
  supervisor="$root/wasmtime-mariadb-supervisor$suffix"
else
  supervisor="$root/target/release/wasmtime-mariadb-supervisor$suffix"
fi

if [[ ! -x "$supervisor" ]]; then
  echo "MariaDB supervisor not found: $supervisor" >&2
  echo "build it with: MARIADBD_WASM=/path/to/mariadbd cargo build --release" >&2
  exit 2
fi

# The supervisor reserves its own options for direct invocations. The public
# helper has always accepted mariadbd options, so preserve that contract.
exec "$supervisor" -- "$@"
