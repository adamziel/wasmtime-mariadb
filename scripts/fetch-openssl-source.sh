#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_ref="${OPENSSL_REF:-openssl-3.0.21}"
dest="${OPENSSL_SOURCE:-$root/third_party/openssl}"

mkdir -p "$(dirname "$dest")"

if [[ -d "$dest/.git" ]]; then
  git -C "$dest" fetch --depth 1 origin "refs/tags/$openssl_ref:refs/tags/$openssl_ref"
  git -C "$dest" checkout --detach "$openssl_ref"
else
  git clone --depth 1 --branch "$openssl_ref" https://github.com/openssl/openssl.git "$dest"
fi

git -C "$dest" rev-parse HEAD
