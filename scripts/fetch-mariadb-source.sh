#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mariadb_ref="${MARIADB_REF:-mariadb-11.4.12}"
dest="${MARIADB_SOURCE:-$root/third_party/mariadb-server}"

mkdir -p "$(dirname "$dest")"

if [[ -d "$dest/.git" ]]; then
  git -C "$dest" fetch --depth 1 origin "refs/tags/$mariadb_ref:refs/tags/$mariadb_ref"
  git -C "$dest" checkout --detach "$mariadb_ref"
else
  git clone --depth 1 --branch "$mariadb_ref" https://github.com/MariaDB/server.git "$dest"
fi

git -C "$dest" rev-parse HEAD
