#!/usr/bin/env bash
set -euo pipefail

repo="${REPO:-adamziel/wasmtime-mariadb}"
version="${VERSION:-latest}"

usage() {
  cat <<'EOF'
Usage: install-release.sh [--version TAG]

Downloads, verifies, and extracts the wasmtime-mariadb release for this host.
It does not start MariaDB. The final output prints the separate run command.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?--version needs a tag, for example v0.1.3}"
      shift 2
      ;;
    --run|--port)
      echo "$1 is no longer an installer option." >&2
      echo "Install first, then run the command printed after extraction." >&2
      exit 2
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
  Darwin-x86_64)
    echo "macOS Intel is not a release target; build from source instead" >&2
    exit 1
    ;;
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

release_dir="$(tar -tzf "$archive" | awk -F/ 'NF && $1 != "" && !seen { print $1; seen = 1 }')"
if [[ -z "$release_dir" || "$release_dir" == "." || "$release_dir" == ".." ]]; then
  echo "could not determine the release directory in $archive" >&2
  exit 1
fi
if [[ -e "$release_dir" ]]; then
  echo "refusing to overwrite existing release directory: $release_dir" >&2
  echo "run it directly, remove it intentionally, or install from a different directory" >&2
  exit 1
fi

tar -xzf "$archive"

cat <<EOF

Downloaded and verified $archive.
Extracted to: $release_dir

Run MariaDB in a separate step:
  cd "$PWD/$release_dir" && PORT=3307 ./scripts/run-server.sh

After it reports "ready for connections", use another terminal to connect:
  mysql --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl-mode=DISABLED
EOF
