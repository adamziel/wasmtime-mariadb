#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: $0 VERSION ASSET_SUFFIX [BINARY] [OUT_DIR]}"
asset_suffix="${2:?usage: $0 VERSION ASSET_SUFFIX [BINARY] [OUT_DIR]}"
bin="${3:-target/release/wasmtime-mariadb}"
out_dir="${4:-dist}"
supervisor="${SUPERVISOR:-$(dirname "$bin")/wasmtime-mariadb-supervisor}"

if [[ ! -x "$bin" ]]; then
  echo "runner binary not found or not executable: $bin" >&2
  exit 2
fi
if [[ ! -x "$supervisor" ]]; then
  echo "supervisor binary not found or not executable: $supervisor" >&2
  exit 2
fi

name="wasmtime-mariadb-$version-$asset_suffix"
archive="wasmtime-mariadb-$asset_suffix.tar.gz"

rm -rf "$out_dir/$name" "$out_dir/$archive"
mkdir -p "$out_dir/$name/scripts" "$out_dir/$name/docs"

cp "$bin" "$out_dir/$name/"
cp "$supervisor" "$out_dir/$name/"
cp README.md "$out_dir/$name/"
cp docs/*.md "$out_dir/$name/docs/"
cp scripts/bench-tcp.py "$out_dir/$name/scripts/"
cp scripts/mariadb-system-tables.sql "$out_dir/$name/scripts/"
cp scripts/run-60k-transaction-workload.sh "$out_dir/$name/scripts/"
cp scripts/run-server.ps1 "$out_dir/$name/scripts/"
cp scripts/run-server.sh "$out_dir/$name/scripts/"
cp scripts/stop-server.ps1 "$out_dir/$name/scripts/"
cp scripts/stop-server.sh "$out_dir/$name/scripts/"
cp scripts/test-durability-recovery.sh "$out_dir/$name/scripts/"
cp scripts/test-mysql-client.sh "$out_dir/$name/scripts/"
cp scripts/test-supervisor-lifecycle.py "$out_dir/$name/scripts/"
cp scripts/test-wordpress-local-dev.sh "$out_dir/$name/scripts/"
chmod +x \
  "$out_dir/$name/wasmtime-mariadb" \
  "$out_dir/$name/wasmtime-mariadb-supervisor" \
  "$out_dir/$name/scripts/bench-tcp.py" \
  "$out_dir/$name/scripts/run-60k-transaction-workload.sh" \
  "$out_dir/$name/scripts/run-server.sh" \
  "$out_dir/$name/scripts/stop-server.sh" \
  "$out_dir/$name/scripts/test-durability-recovery.sh" \
  "$out_dir/$name/scripts/test-mysql-client.sh" \
  "$out_dir/$name/scripts/test-supervisor-lifecycle.py" \
  "$out_dir/$name/scripts/test-wordpress-local-dev.sh"

tar -czf "$out_dir/$archive" -C "$out_dir" "$name"
ls -lh "$out_dir/$archive"
