#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_mtr_dir="$root/build/mariadb-wasi-port/src/mysql-test"
if [[ -d "$default_mtr_dir" ]]; then
  mtr_dir="${MTR_DIR:-$default_mtr_dir}"
else
  mtr_dir="${MTR_DIR:-/usr/share/mariadb-test}"
fi
out_dir="${OUT_DIR:-$root/build/mtr-extern-smoke}"
base_port="${BASE_PORT:-3340}"
if [[ -n "${SERVER_ARGS+x}" ]]; then
  read -r -a extra_server_args <<< "$SERVER_ARGS"
else
  extra_server_args=(
    --default-storage-engine=MyISAM
    --use-stat-tables=preferably
    --histogram-type=json_hb
    --key-buffer-size=1M
    --sort-buffer-size=256K
    --max-heap-table-size=1M
    --loose-aria-pagecache-buffer-size=8M
    --local-infile=1
    --log-bin-trust-function-creators=1
    --binlog-direct-non-transactional-updates
  )
fi
init_sql="$root/scripts/mtr-extern-init.sql"
mtr_bindir="${MTR_BINDIR:-}"
mtr_client_bindir="${MTR_CLIENT_BINDIR:-/usr/bin}"
mtr_toolroot="${MTR_TOOLROOT:-$root/build/mtr-toolroot}"
restart_with_grants="${MTR_RESTART_WITH_GRANTS:-1}"
grant_port_offset="${MTR_GRANT_PORT_OFFSET:-10000}"

if [[ "$mtr_dir" != /* ]]; then
  mtr_dir="$root/$mtr_dir"
fi
if [[ "$out_dir" != /* ]]; then
  out_dir="$root/$out_dir"
fi
runner_args="--preopen $out_dir=$out_dir"
if [[ -d "$mtr_dir/std_data" ]]; then
  runner_args+=" --preopen $mtr_dir/std_data=/std_data"
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

prepare_source_mtr_toolroot() {
  local safe_process_src="$mtr_dir/lib/My/SafeProcess/safe_process.cc"
  local safe_process_bin="$mtr_toolroot/mysql-test/lib/My/SafeProcess/my_safe_process"
  local compiler="${CXX:-c++}"

  if [[ ! -r "$safe_process_src" ]]; then
    return 0
  fi
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C++ compiler required to build MTR my_safe_process: $compiler" >&2
    exit 2
  fi

  rm -rf "$mtr_toolroot"
  mkdir -p "$mtr_toolroot/bin" "$mtr_toolroot/share" "$(dirname "$safe_process_bin")"
  "$compiler" -O2 -Wall -Wextra -o "$safe_process_bin" "$safe_process_src"

  local tools=(
    mariadb
    mariadb-admin
    mariadb-binlog
    mariadb-check
    mariadb-client-test
    mariadb-conv
    mariadb-dump
    mariadb-import
    mariadb-plugin
    mariadb-show
    mariadb-slap
    mariadb-test
    mariadb-tzinfo-to-sql
    mariadb-upgrade
    mariadbd
    my_print_defaults
    aria_chk
    aria_pack
    myisam_ftdump
    myisamchk
    myisamlog
    myisampack
    perror
    replace
  )

  local tool tool_path missing=0
  for tool in "${tools[@]}"; do
    tool_path="$(command -v "$tool" || true)"
    if [[ -z "$tool_path" ]]; then
      echo "MTR helper not found in PATH: $tool" >&2
      missing=1
      continue
    fi
    ln -s "$tool_path" "$mtr_toolroot/bin/$tool"
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 2
  fi

  if [[ -d /usr/share/mariadb ]]; then
    ln -s /usr/share/mariadb "$mtr_toolroot/share/mariadb"
  elif [[ -d /usr/share/mysql ]]; then
    ln -s /usr/share/mysql "$mtr_toolroot/share/mysql"
  else
    echo "Could not find MariaDB share directory under /usr/share" >&2
    exit 2
  fi

  mtr_bindir="$mtr_toolroot"
  mtr_client_bindir="$mtr_toolroot/bin"
}

if [[ -z "$mtr_bindir" ]]; then
  prepare_source_mtr_toolroot
fi

read_test_option_file() {
  local opt_file="$1"
  local line
  local words=()

  if [[ ! -r "$opt_file" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    if [[ -z "${line//[[:space:]]/}" ]]; then
      continue
    fi
    read -r -a words <<< "$line"
    test_server_args+=("${words[@]}")
  done < "$opt_file"
}

append_test_server_options() {
  local test_name="$1"
  local suite="${test_name%%.*}"
  local name="${test_name#*.}"

  read_test_option_file "$mtr_dir/$suite/$name.opt"
  read_test_option_file "$mtr_dir/$suite/$name-master.opt"
}

rm -rf "$out_dir"
mkdir -p "$out_dir"
summary="$out_dir/summary.tsv"
printf 'test\tstatus\texit_code\tlog\n' > "$summary"

server_pid=""
proxy_pid=""
proxy_socket=""
cleanup_server() {
  if [[ -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
    proxy_pid=""
  fi
  if [[ -n "$proxy_socket" ]]; then
    rm -f "$proxy_socket"
    proxy_socket=""
  fi
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$server_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
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

port_is_listening() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$port" | tail -n +2 | grep -q .
  else
    mariadb-admin --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 ping >/dev/null 2>&1
  fi
}

wait_port_closed() {
  local port="$1"

  for _ in $(seq 1 100); do
    if ! port_is_listening "$port"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_server() {
  local skip_grants="$1"

  RUN_DIR="$run_dir" PORT="$port" RUNNER_ARGS="$test_runner_args" SKIP_GRANT_TABLES="$skip_grants" \
    "$root/scripts/run-server.sh" "${test_server_args[@]}" >"$test_dir/server.stdout" 2>"$test_dir/server.stderr" &
  server_pid=$!
}

start_socket_proxy() {
  local port="$1"
  local socket_path="$2"
  local log_dir="$3"

  "$root/scripts/tcp-unix-proxy.py" "$socket_path" 127.0.0.1 "$port" \
    >"$log_dir/socket-proxy.stdout" 2>"$log_dir/socket-proxy.stderr" &
  proxy_pid=$!
  proxy_socket="$socket_path"

  for _ in $(seq 1 30); do
    if [[ -S "$socket_path" ]]; then
      return 0
    fi
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  cat "$log_dir/socket-proxy.stderr" 2>/dev/null || true
  return 1
}

for idx in "${!tests[@]}"; do
  test_name="${tests[$idx]}"
  port=$((base_port + idx))
  safe_name="${test_name//./_}"
  test_dir="$out_dir/$safe_name"
  vardir="$test_dir/var"
  run_dir="$vardir/mysqld.1"
  log_file="$test_dir/mtr.log"
  socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
  mkdir -p "$test_dir"

  cleanup_server
  rm -rf "$run_dir" "$vardir" "$socket_path"
  mkdir -p "$vardir/log" "$vardir/run" "$vardir/tmp"
  test_runner_args="$runner_args --preopen $run_dir=$run_dir"
  test_server_args=(
    "${extra_server_args[@]}"
  )
  append_test_server_options "$test_name"
  test_server_args+=(
    "--datadir=$run_dir/data"
    "--tmpdir=$run_dir/tmp"
    "--log-error=$run_dir/mariadbd-runtime.err"
    "--pid-file=$run_dir/data/mysqld.pid"
    "--secure-file-priv=$vardir"
  )
  start_server 1

  status="FAIL"
  exit_code=0
  if wait_ready "$port" "$run_dir"; then
    mariadb --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 <"$init_sql" >"$test_dir/init.stdout" 2>"$test_dir/init.stderr"

    if [[ "$restart_with_grants" == "1" ]]; then
      cleanup_server
      if [[ "$grant_port_offset" -ne 0 ]]; then
        port=$((port + grant_port_offset))
        socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
      elif ! wait_port_closed "$port"; then
        exit_code=124
        printf 'server port did not close before grant-table restart\n' > "$log_file"
      fi
      if [[ "$exit_code" -eq 0 ]]; then
        start_server 0
        if ! wait_ready "$port" "$run_dir"; then
          exit_code=124
          printf 'server did not become ready after grant-table restart\n' > "$log_file"
        fi
      fi
    fi

    if [[ "$exit_code" -eq 0 ]]; then
      if start_socket_proxy "$port" "$socket_path" "$test_dir"; then
        set +e
        (
          cd "$mtr_dir"
          if [[ -n "$mtr_bindir" ]]; then
            export MTR_BINDIR="$mtr_bindir"
          fi
          perl mariadb-test-run.pl \
            --extern host=127.0.0.1 \
            --extern port="$port" \
            --extern socket="$socket_path" \
            --extern user=root \
            --extern ssl=0 \
            --client-bindir="$mtr_client_bindir" \
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
        printf 'socket proxy did not become ready\n' > "$log_file"
      fi
    fi
  else
    exit_code=124
    printf 'server did not become ready\n' > "$log_file"
  fi

  printf '%s\t%s\t%s\t%s\n' "$test_name" "$status" "$exit_code" "$log_file" | tee -a "$summary"
done

cleanup_server
echo "summary: $summary"
