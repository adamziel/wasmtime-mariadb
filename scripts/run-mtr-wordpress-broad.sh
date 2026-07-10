#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${MTR_MANIFEST:-$root/tests/wordpress-mtr-verified.txt}"
start="${MTR_TEST_START:-0}"
limit="${MTR_TEST_LIMIT:-0}"

if [[ ! -r "$manifest" ]]; then
  echo "MTR manifest not found: $manifest" >&2
  exit 2
fi
if ! [[ "$start" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]]; then
  echo "MTR_TEST_START and MTR_TEST_LIMIT must be non-negative integers" >&2
  exit 2
fi

tests=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] || tests+=("$line")
done < "$manifest"

selected=()
for ((index = start; index < ${#tests[@]}; index++)); do
  if [[ "$limit" -ne 0 && "${#selected[@]}" -ge "$limit" ]]; then
    break
  fi
  selected+=("${tests[$index]}")
done

if [[ "${#selected[@]}" -eq 0 ]]; then
  echo "No tests selected from $manifest" >&2
  exit 2
fi

export OUT_DIR="${OUT_DIR:-$root/build/mtr-wordpress-broad}"
export MTR_PRESERVE_VARDIRS="${MTR_PRESERVE_VARDIRS:-0}"

printf 'Running %s of %s WordPress-relevant MTR cases from %s.\n' \
  "${#selected[@]}" "${#tests[@]}" "$manifest"
exec "$root/scripts/run-mtr-extern-smoke.sh" "${selected[@]}"
