#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${MTR_TRANSACTION_MANIFEST:-$root/tests/mtr-transaction-verified.txt}"

if [[ ! -r "$manifest" ]]; then
  echo "MTR transaction manifest not found: $manifest" >&2
  exit 2
fi

tests=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] || tests+=("$line")
done < "$manifest"

if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "No transaction tests selected from $manifest" >&2
  exit 2
fi

export OUT_DIR="${OUT_DIR:-$root/build/mtr-transaction-verified}"
export MTR_BATCH_SIZE="${MTR_BATCH_SIZE:-4}"
export MTR_PRESERVE_VARDIRS="${MTR_PRESERVE_VARDIRS:-0}"

printf 'Running %s verified transaction-nuance MTR cases from %s.\n' \
  "${#tests[@]}" "$manifest"
exec "$root/scripts/run-mtr-extern-smoke.sh" "${tests[@]}"
