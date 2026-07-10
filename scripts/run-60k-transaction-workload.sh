#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-$root/build/slap-60k-transaction}"
port="${PORT:-3331}"
clients="${SLAP_CLIENTS:-4}"
queries_per_client="${SLAP_QUERIES_PER_CLIENT:-15000}"
commit_every="${SLAP_COMMIT_EVERY:-20}"
seed_rows="${SLAP_SEED_ROWS:-1000}"
run_dir="$out_dir/server"

for value in "$port" "$clients" "$queries_per_client" "$commit_every" "$seed_rows"; do
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "workload settings must be positive integers" >&2
    exit 2
  fi
done

if [[ -n "${MARIADB_SLAP:-}" ]]; then
  slap="$MARIADB_SLAP"
elif command -v mariadb-slap >/dev/null 2>&1; then
  slap="mariadb-slap"
elif command -v mysqlslap >/dev/null 2>&1; then
  slap="mysqlslap"
else
  echo "mariadb-slap or mysqlslap is required" >&2
  exit 2
fi

if ! command -v mariadb-admin >/dev/null 2>&1; then
  echo "mariadb-admin is required" >&2
  exit 2
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"

RUN_DIR="$run_dir" PORT="$port" "$root/scripts/run-server.sh" \
  --general-log \
  --general-log-file=/tmp/general.log \
  >"$out_dir/server.stdout" 2>"$out_dir/server.stderr" &
server_pid=$!

cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 90); do
  if mariadb-admin --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  cat "$out_dir/server.stderr" >&2 || true
  exit 1
fi

started="$(date +%s)"
"$slap" --no-defaults --protocol=TCP -h127.0.0.1 -P"$port" -uroot --skip-ssl \
  --create-schema=slap_60k_transaction \
  --auto-generate-sql \
  --auto-generate-sql-load-type=mixed \
  --auto-generate-sql-execute-number="$queries_per_client" \
  --auto-generate-sql-unique-query-number="$seed_rows" \
  --auto-generate-sql-write-number="$seed_rows" \
  --auto-generate-sql-secondary-indexes=2 \
  --engine=InnoDB \
  --concurrency="$clients" \
  --commit="$commit_every" \
  --iterations=1 | tee "$out_dir/mariadb-slap.out"
finished="$(date +%s)"

general_log="$run_dir/general.log"
query_total="$(awk '/[[:space:]]Query[[:space:]]/ { count++ } END { print count + 0 }' "$general_log")"
selects="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+SELECT / { count++ } END { print count + 0 }' "$general_log")"
inserts="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+INSERT / { count++ } END { print count + 0 }' "$general_log")"
updates="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+UPDATE / { count++ } END { print count + 0 }' "$general_log")"
deletes="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+DELETE / { count++ } END { print count + 0 }' "$general_log")"
commits="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+COMMIT/ { count++ } END { print count + 0 }' "$general_log")"
autocommit_off="$(awk 'BEGIN { IGNORECASE=1 } /[[:space:]]Query[[:space:]]+SET[[:space:]]+AUTOCOMMIT[[:space:]]*=[[:space:]]*0/ { count++ } END { print count + 0 }' "$general_log")"
workload_queries=$((clients * queries_per_client))

printf '%s\n' \
  "clients=$clients" \
  "queries_per_client=$queries_per_client" \
  "requested_workload_queries=$workload_queries" \
  "commit_every=$commit_every" \
  "elapsed_wall_seconds=$((finished - started))" \
  "query_commands=$query_total" \
  "selects=$selects" \
  "inserts=$inserts" \
  "updates=$updates" \
  "deletes=$deletes" \
  "commits=$commits" \
  "autocommit_off=$autocommit_off" | tee "$out_dir/summary.txt"

if [[ "$query_total" -lt "$workload_queries" ]]; then
  echo "expected at least $workload_queries Query commands, found $query_total" >&2
  exit 1
fi
