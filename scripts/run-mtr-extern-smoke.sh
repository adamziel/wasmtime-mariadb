#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mtr_dir="${MTR_DIR:-/usr/share/mariadb-test}"
out_dir="${OUT_DIR:-$root/build/mtr-extern-smoke}"
base_port="${BASE_PORT:-3340}"
read -r -a extra_server_args <<< "${SERVER_ARGS:-}"
init_sql="$root/scripts/mtr-extern-init.sql"

if [[ "$out_dir" != /* ]]; then
  out_dir="$root/$out_dir"
fi

tests=("$@")
if [[ "${#tests[@]}" -eq 0 ]]; then
  tests=(
    main.select
    main.insert
    main.update
    main.delete
    main.create
    main.drop
    main.type_int
    main.type_varchar
    main.func_math
    main.func_str
    main.join
    main.union
    main.order_by
    main.group_by
    main.subselect
    main.ps
    main.prepare
    main.information_schema
    innodb.innodb
    innodb.create_select
    innodb.foreign_key
    innodb.alter_table
  )
fi

if [[ ! -x "$mtr_dir/mariadb-test-run.pl" ]]; then
  echo "MTR runner not found: $mtr_dir/mariadb-test-run.pl" >&2
  echo "On Fedora, install it with: sudo dnf install mariadb-test" >&2
  exit 2
fi

if ! command -v mariadb-admin >/dev/null 2>&1 || ! command -v mariadb >/dev/null 2>&1; then
  echo "mariadb client tools are required" >&2
  exit 2
fi

if [[ ! -r "$init_sql" ]]; then
  echo "MTR init SQL not found: $init_sql" >&2
  exit 2
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"
summary="$out_dir/summary.tsv"
printf 'test\tstatus\texit_code\tlog\n' > "$summary"

server_pid=""
cleanup_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap cleanup_server EXIT

wait_ready() {
  local port="$1"
  local run_dir="$2"

  for _ in $(seq 1 90); do
    if mariadb-admin --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 ping >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$server_pid" ]] && ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  cat "$run_dir/mariadbd-runtime.err" 2>/dev/null || true
  return 1
}

for idx in "${!tests[@]}"; do
  test_name="${tests[$idx]}"
  port=$((base_port + idx))
  safe_name="${test_name//./_}"
  test_dir="$out_dir/$safe_name"
  run_dir="$test_dir/server"
  vardir="$test_dir/var"
  log_file="$test_dir/mtr.log"
  mkdir -p "$test_dir"

  cleanup_server
  rm -rf "$run_dir" "$vardir"
  RUN_DIR="$run_dir" PORT="$port" "$root/scripts/run-server.sh" "${extra_server_args[@]}" >"$test_dir/server.stdout" 2>"$test_dir/server.stderr" &
  server_pid=$!

  status="FAIL"
  exit_code=0
  if wait_ready "$port" "$run_dir"; then
    mariadb --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 <"$init_sql" >"$test_dir/init.stdout" 2>"$test_dir/init.stderr"

    set +e
    (
      cd "$mtr_dir"
      perl mariadb-test-run.pl \
        --extern host=127.0.0.1 \
        --extern port="$port" \
        --extern user=root \
        --extern ssl=0 \
        --client-bindir=/usr/bin \
        --vardir="$vardir" \
        --force \
        --timer \
        "$test_name"
    ) >"$log_file" 2>&1
    exit_code=$?
    set -e
    if [[ "$exit_code" -eq 0 ]]; then
      status="PASS"
    fi
  else
    exit_code=124
    printf 'server did not become ready\n' > "$log_file"
  fi

  printf '%s\t%s\t%s\t%s\n' "$test_name" "$status" "$exit_code" "$log_file" | tee -a "$summary"
done

cleanup_server
echo "summary: $summary"
