#!/usr/bin/env bash
set -euo pipefail

repo="${REPO:-adamziel/wasmtime-mariadb}"
version="${VERSION:-latest}"
port="${PORT:-3307}"
run_server=0

usage() {
  cat <<'EOF'
Usage: install-release.sh [--run] [--port PORT] [--version TAG]

Downloads, verifies, and extracts the wasmtime-mariadb release for this host.
With --run, starts MariaDB in the foreground after extraction.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      run_server=1
      shift
      ;;
    --port)
      port="${2:?--port needs a value}"
      shift 2
      ;;
    --version)
      version="${2:?--version needs a tag, for example v0.1.2}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset_suffix=linux-x86_64 ;;
  Darwin-arm64) asset_suffix=macos-aarch64 ;;
  Darwin-x86_64) asset_suffix=macos-x86_64 ;;
  *)
    echo "unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" == "latest" ]]; then
  base_url="https://github.com/$repo/releases/latest/download"
else
  base_url="https://github.com/$repo/releases/download/$version"
fi

archive="wasmtime-mariadb-$asset_suffix.tar.gz"

curl -fL -o "$archive" "$base_url/$archive"
curl -fL -o SHA256SUMS "$base_url/SHA256SUMS"

checksum_line="$(awk -v file="$archive" '$2 == file { print }' SHA256SUMS)"
if [[ -z "$checksum_line" ]]; then
  echo "checksum for $archive not found in SHA256SUMS" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s\n' "$checksum_line" | sha256sum -c -
else
  printf '%s\n' "$checksum_line" | shasum -a 256 -c -
fi

tar -xzf "$archive"
tar -tzf "$archive" > "$archive.contents"
IFS=/ read -r release_dir _ < "$archive.contents"

cat <<EOF

Downloaded and verified $archive.
Extracted to: $release_dir
EOF

if [[ "$run_server" -eq 1 ]]; then
  echo "Starting MariaDB on 127.0.0.1:$port"
  echo "In another terminal, run:"
  echo "  cd \"$PWD/$release_dir\" && PORT=$port ./scripts/test-mysql-client.sh"
  cd "$release_dir"
  PORT="$port" ./scripts/run-server.sh
else
  cat <<EOF

Next:
  cd "$release_dir"
  PORT=$port ./scripts/run-server.sh

Then, from another terminal:
  cd "$PWD/$release_dir"
  PORT=$port ./scripts/test-mysql-client.sh
EOF
fi
