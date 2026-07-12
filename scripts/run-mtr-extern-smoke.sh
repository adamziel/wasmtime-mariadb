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
    --loose-innodb-buffer-pool-size=8M
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
preserve_vardirs="${MTR_PRESERVE_VARDIRS:-1}"
batch_size="${MTR_BATCH_SIZE:-1}"

if [[ "$mtr_dir" != /* ]]; then
  mtr_dir="$root/$mtr_dir"
fi
if [[ "$out_dir" != /* ]]; then
  out_dir="$root/$out_dir"
fi
if ! [[ "$batch_size" =~ ^[1-9][0-9]*$ ]]; then
  echo "MTR_BATCH_SIZE must be a positive integer" >&2
  exit 2
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
  read_test_option_file "$mtr_dir/suite/$suite/t/$name.opt"
  read_test_option_file "$mtr_dir/suite/$suite/t/$name-master.opt"
}

test_has_server_options() {
  local test_name="$1"
  local suite="${test_name%%.*}"
  local name="${test_name#*.}"
  local option_file

  for option_file in \
    "$mtr_dir/$suite/$name.opt" \
    "$mtr_dir/$suite/$name-master.opt" \
    "$mtr_dir/suite/$suite/t/$name.opt" \
    "$mtr_dir/suite/$suite/t/$name-master.opt"; do
    if [[ -r "$option_file" ]]; then
      return 0
    fi
  done
  return 1
}

test_requires_bootstrapless_restart() {
  local option

  for option in "${test_server_args[@]}"; do
    case "$option" in
      --transaction-read-only|--transaction-read-only=*)
        return 0
        ;;
    esac
  done
  return 1
}

rm -rf "$out_dir"
mkdir -p "$out_dir"
summary="$out_dir/summary.tsv"
printf 'test\tstatus\texit_code\tlog\n' > "$summary"
failed_tests=0

server_pid=""
server_pid_file=""
server_port=""
backend_port_file=""
server_error_log=""
active_server_args=()
skip_system_tables_init=0
tcp_proxy_pid=""
proxy_pid=""
proxy_socket=""
restart_watcher_pid=""
cleanup_server() {
  if [[ -n "$restart_watcher_pid" ]]; then
    kill "$restart_watcher_pid" 2>/dev/null || true
    wait "$restart_watcher_pid" 2>/dev/null || true
    restart_watcher_pid=""
  fi
  if [[ -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
    proxy_pid=""
  fi
  if [[ -n "$tcp_proxy_pid" ]]; then
    kill "$tcp_proxy_pid" 2>/dev/null || true
    wait "$tcp_proxy_pid" 2>/dev/null || true
    tcp_proxy_pid=""
  fi
  if [[ -n "$proxy_socket" ]]; then
    rm -f "$proxy_socket"
    proxy_socket=""
  fi
  local pids=()
  if [[ -n "$server_pid" ]]; then
    pids+=("$server_pid")
  fi
  if [[ -n "$server_pid_file" && -r "$server_pid_file" ]]; then
    local pid_from_file
    pid_from_file="$(<"$server_pid_file")"
    if [[ -n "$pid_from_file" ]]; then
      pids+=("$pid_from_file")
    fi
  fi

  local pid
  local seen=" "
  for pid in "${pids[@]}"; do
    if [[ "$seen" == *" $pid "* ]]; then
      continue
    fi
    seen+="$pid "
    kill "$pid" 2>/dev/null || true
  done

  seen=" "
  for pid in "${pids[@]}"; do
    if [[ "$seen" == *" $pid "* ]]; then
      continue
    fi
    seen+="$pid "
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    server_pid=""
  done
  server_pid=""
  if [[ -n "$server_pid_file" ]]; then
    rm -f "$server_pid_file"
  fi
}
trap cleanup_server EXIT

wait_ready() {
  local port="$1"
  local run_dir="$2"
  local pid_file="$run_dir/data/mysqld.pid"

  for _ in $(seq 1 90); do
    if mariadb-admin --protocol=TCP -h127.0.0.1 -P"$port" -uroot --ssl=0 ping >/dev/null 2>&1; then
      # mysqltest's --shutdown_server sends a normal shutdown, then waits for
      # the PID read from @@pid_file to disappear. Inside WASI MariaDB reports
      # a guest PID (normally 42), which can accidentally name an unrelated
      # host process. Publish the Wasmtime host PID for the external MTR run.
      if [[ -n "$server_pid" ]]; then
        printf '%s\n' "$server_pid" > "$pid_file"
      fi
      return 0
    fi
    if [[ -n "$server_pid" ]] && ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  cat "$run_dir/mariadbd-runtime.err" "$server_error_log" 2>/dev/null || true
  return 1
}

port_is_listening() {
  local port="$1"

  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c ":</dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
  else
    bash -c ":</dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
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

pick_backend_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_server() {
  local skip_grants="$1"
  shift
  local restart_args=("$@")

  if [[ -n "$backend_port_file" ]]; then
    printf '127.0.0.1 %s\n' "$server_port" > "$backend_port_file"
  fi

  RUN_DIR="$run_dir" PORT="$server_port" RUNNER_ARGS="$test_runner_args" SKIP_GRANT_TABLES="$skip_grants" \
    SKIP_SYSTEM_TABLES_INIT="$skip_system_tables_init" \
    "$root/scripts/run-server.sh" "${active_server_args[@]}" "${restart_args[@]}" \
    >>"$test_dir/server.stdout" 2>>"$test_dir/server.stderr" &
  server_pid=$!
  if [[ -n "$server_pid_file" ]]; then
    printf '%s\n' "$server_pid" > "$server_pid_file"
  fi
}

stop_server_for_mtr_restart() {
  local watcher_log="$1"
  local pid=""

  sleep 0.2
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 mariadb-admin --protocol=TCP -h127.0.0.1 -P"$server_port" -uroot --ssl=0 shutdown \
      >>"$watcher_log" 2>&1 || true
  else
    mariadb-admin --protocol=TCP -h127.0.0.1 -P"$server_port" -uroot --ssl=0 shutdown \
      >>"$watcher_log" 2>&1 || true
  fi

  if [[ -r "$server_pid_file" ]]; then
    pid="$(<"$server_pid_file")"
  fi

  for _ in $(seq 1 50); do
    if ! port_is_listening "$server_port" && \
       { [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; }; then
      return 0
    fi
    sleep 0.1
  done

  if [[ -n "$pid" ]]; then
    kill "$pid" >>"$watcher_log" 2>&1 || true
  fi
  for _ in $(seq 1 50); do
    if ! port_is_listening "$server_port" && \
       { [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; }; then
      return 0
    fi
    sleep 0.1
  done

  if [[ -n "$pid" ]]; then
    kill -KILL "$pid" >>"$watcher_log" 2>&1 || true
  fi
  if [[ -n "$pid" ]]; then
    wait "$pid" 2>/dev/null || true
  fi
}

start_server_for_mtr_restart() {
  local watcher_log="$1"
  shift
  local restart_args=("$@")
  local attempt

  for attempt in $(seq 1 30); do
    server_port="$(pick_backend_port)"
    printf 'restart watcher: start attempt %s on backend port %s\n' "$attempt" "$server_port" >>"$watcher_log"
    start_server 0 "${restart_args[@]}"
    if wait_ready "$server_port" "$run_dir" >>"$watcher_log" 2>&1; then
      printf 'restart watcher: server ready on backend port %s\n' "$server_port" >>"$watcher_log"
      return 0
    fi
    wait "$server_pid" 2>/dev/null || true
    rm -f "$server_pid_file"
    sleep 1
  done

  printf 'restart watcher: server did not become ready on backend port %s\n' "$server_port" >>"$watcher_log"
  return 1
}

start_mtr_restart_watcher() {
  local expect_dir="$vardir/tmp"
  local watcher_log="$test_dir/restart-watcher.log"

  (
    set +e
    local expect_file=""
    local processed_content=""
    local processed_signature=""
    local observed_content=""
    local observed_signature=""
    local content signature new_content line clean_line restart_tail
    local restart_args=()

    expect_file_signature() {
      perl -MTime::HiRes=stat -e '
        my @stat= stat($ARGV[0]) or exit 1;
        printf "%d:%d:%.9f:%.9f\n", $stat[1], $stat[7], $stat[9], $stat[10];
      ' "$1" 2>/dev/null
    }

    printf 'restart watcher: watching %s\n' "$expect_dir" >"$watcher_log"
    while true; do
      if [[ -z "$expect_file" || ! -e "$expect_file" ]]; then
        for candidate in "$expect_dir"/*.expect; do
          if [[ -e "$candidate" ]]; then
            expect_file="$candidate"
            processed_content=""
            processed_signature=""
            observed_content=""
            observed_signature=""
            printf 'restart watcher: using %s\n' "$expect_file" >>"$watcher_log"
            break
          fi
        done
      fi

      if [[ -n "$expect_file" && -r "$expect_file" ]]; then
        content="$(cat "$expect_file" 2>/dev/null || true)"
        signature="$(expect_file_signature "$expect_file")"
        if [[ -n "$signature" ]] && \
          { [[ "$content" != "$processed_content" ]] || \
            [[ "$signature" != "$processed_signature" ]]; }; then
          # mysqltest rewrites this file while switching from "wait" to a
          # restart command. It can also rewrite an identical command for the
          # next restart. Require stable contents and metadata so neither a
          # partial write nor a repeated command is lost.
          if [[ "$content" != "$observed_content" || \
                "$signature" != "$observed_signature" ]]; then
            observed_content="$content"
            observed_signature="$signature"
            sleep 0.1
            continue
          fi
          observed_content=""
          observed_signature=""
          if [[ "$content" != "$processed_content" && \
                "$content" == "$processed_content"* ]]; then
            new_content="${content#"$processed_content"}"
          else
            new_content="$content"
          fi
          processed_content="$content"
          processed_signature="$signature"
          while IFS= read -r line; do
            if [[ -z "$line" ]]; then
              continue
            fi
            clean_line="${line%\"}"
            clean_line="${clean_line#\"}"
            printf 'restart watcher: command %s\n' "$clean_line" >>"$watcher_log"

            case "$clean_line" in
              wait)
                stop_server_for_mtr_restart "$watcher_log"
                ;;
              restart|restart:*)
                restart_args=()
                if [[ "$clean_line" == restart:* ]]; then
                  restart_tail="${clean_line#restart: }"
                  read -r -a restart_args <<< "$restart_tail"
                fi
                start_server_for_mtr_restart "$watcher_log" "${restart_args[@]}"
                ;;
              restart_bindir*)
                start_server_for_mtr_restart "$watcher_log"
                ;;
            esac
          done <<< "$new_content"
        fi
        if [[ "$content" == "$processed_content" && \
              "$signature" == "$processed_signature" ]]; then
          observed_content=""
          observed_signature=""
        fi
      fi

      sleep 0.05
    done
  ) &
  restart_watcher_pid=$!
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

start_tcp_proxy() {
  local public_port="$1"
  local backend_file="$2"
  local log_dir="$3"

  "$root/scripts/tcp-port-proxy.py" 127.0.0.1 "$public_port" "$backend_file" \
    >"$log_dir/tcp-proxy.stdout" 2>"$log_dir/tcp-proxy.stderr" &
  tcp_proxy_pid=$!

  for _ in $(seq 1 30); do
    if port_is_listening "$public_port"; then
      return 0
    fi
    if ! kill -0 "$tcp_proxy_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  cat "$log_dir/tcp-proxy.stderr" 2>/dev/null || true
  return 1
}

run_mtr_batch() {
  local batch_number="$1"
  shift
  local batch_tests=("$@")
  local batch_test result status exit_code=0
  local batch_has_nonpass=0
  local batch_index=0
  local safe_batch

  cleanup_server

  printf -v safe_batch 'batch-%03d' "$batch_number"
  port=$((base_port + batch_number))
  server_port="$(pick_backend_port)"
  test_dir="$out_dir/$safe_batch"
  vardir="$test_dir/var"
  run_dir="$vardir/mysqld.1"
  log_file="$test_dir/mtr.log"
  server_error_log="$vardir/log/mysqld.1.err"
  socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
  server_pid_file="$test_dir/server.pid"
  backend_port_file="$test_dir/backend-port"
  mkdir -p "$test_dir"

  rm -rf "$run_dir" "$vardir" "$socket_path"
  mkdir -p "$vardir/log" "$vardir/run" "$vardir/tmp"
  test_runner_args="$runner_args --preopen $run_dir=$run_dir"
  test_server_args=(
    "${extra_server_args[@]}"
    "--datadir=$run_dir/data"
    "--tmpdir=$run_dir/tmp"
    "--log-error=$server_error_log"
    "--pid-file=$run_dir/data/mysqld.pid"
    "--secure-file-priv=$vardir"
  )
  active_server_args=("${test_server_args[@]}")
  skip_system_tables_init=0
  start_server 1

  if wait_ready "$server_port" "$run_dir"; then
    if ! mariadb --protocol=TCP -h127.0.0.1 -P"$server_port" -uroot --ssl=0 <"$init_sql" >"$test_dir/init.stdout" 2>"$test_dir/init.stderr"; then
      exit_code=1
      cp "$test_dir/init.stderr" "$log_file"
    fi

    if [[ "$exit_code" -eq 0 ]] && [[ "$restart_with_grants" == "1" ]]; then
      cleanup_server
      if [[ "$grant_port_offset" -ne 0 ]]; then
        port=$((port + grant_port_offset))
        server_port="$(pick_backend_port)"
        socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
      elif ! wait_port_closed "$server_port"; then
        exit_code=124
        printf 'server port did not close before grant-table restart\n' > "$log_file"
      else
        server_port="$(pick_backend_port)"
      fi
      if [[ "$exit_code" -eq 0 ]]; then
        start_server 0
        if ! wait_ready "$server_port" "$run_dir"; then
          exit_code=124
          printf 'server did not become ready after grant-table restart\n' > "$log_file"
        fi
      fi
    fi

    if [[ "$exit_code" -eq 0 ]]; then
      if start_tcp_proxy "$port" "$backend_port_file" "$test_dir" &&
        start_socket_proxy "$port" "$socket_path" "$test_dir"; then
        start_mtr_restart_watcher
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
            "${batch_tests[@]}"
        ) >"$log_file" 2>&1
        exit_code=$?
        set -e
      else
        exit_code=124
        printf 'MTR proxy did not become ready\n' > "$log_file"
      fi
    fi
  else
    exit_code=124
    printf 'server did not become ready\n' > "$log_file"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    batch_has_nonpass=1
  fi

  for batch_test in "${batch_tests[@]}"; do
    result="$(awk -v test="$batch_test" '$1 == test && $2 == "[" { result = $3 } END { print result }' "$log_file")"
    case "$result" in
      pass) status="PASS" ;;
      skipped) status="SKIP" ;;
      *) status="FAIL" ;;
    esac
    if [[ "$status" != "PASS" ]]; then
      batch_has_nonpass=1
    fi
  done

  cleanup_server
  if [[ "$batch_has_nonpass" -ne 0 ]]; then
    printf 'batch %s had a non-pass result; rerunning its cases in isolation\n' "$safe_batch" >&2
    for batch_test in "${batch_tests[@]}"; do
      run_isolated_test "$batch_test" "$((batch_number * batch_size + batch_index))"
      batch_index=$((batch_index + 1))
    done
  else
    for batch_index in "${!batch_tests[@]}"; do
      printf '%s\tPASS\t0\t%s\n' "${batch_tests[$batch_index]}" "$log_file" | tee -a "$summary"
    done
  fi
  if [[ "$preserve_vardirs" != "1" ]]; then
    rm -rf "$vardir/mysqld.1" "$vardir/run" "$vardir/std_data" "$vardir/tmp"
  fi
}

run_isolated_test() {
  local test_name="$1"
  local index="$2"
  local safe_name="${test_name//./_}"
  local child_dir="$out_dir/isolated-$safe_name"
  local child_summary="$child_dir/summary.tsv"
  local child_status=1
  local child_rows=""

  set +e
  OUT_DIR="$child_dir" \
    BASE_PORT=$((base_port + 1000 + index)) \
    MTR_BATCH_SIZE=1 \
    MTR_PRESERVE_VARDIRS="$preserve_vardirs" \
    "$root/scripts/run-mtr-extern-smoke.sh" "$test_name"
  child_status=$?
  set -e

  if [[ -r "$child_summary" ]] &&
    child_rows="$(awk -F '\t' -v test="$test_name" 'NR > 1 && $1 == test { print; found = 1 } END { exit !found }' "$child_summary")" &&
    [[ -n "$child_rows" ]]; then
    if [[ "$child_status" -ne 0 ]] && [[ "$(awk -F '\t' 'NR == 1 { print $2; exit }' <<< "$child_rows")" == "PASS" ]]; then
      printf '%s\tFAIL\t%s\t%s\n' "$test_name" "$child_status" "$child_dir" | tee -a "$summary"
      failed_tests=$((failed_tests + 1))
    else
      printf '%s\n' "$child_rows" | tee -a "$summary"
      if awk -F '\t' '$2 != "PASS" { found = 1 } END { exit !found }' <<< "$child_rows"; then
        failed_tests=$((failed_tests + 1))
      fi
    fi
  else
    printf '%s\tFAIL\t%s\t%s\n' "$test_name" "$child_status" "$child_dir" | tee -a "$summary"
    failed_tests=$((failed_tests + 1))
  fi
}

if [[ "$batch_size" -gt 1 ]]; then
  index=0
  batch_number=0
  batch_tests=()

  while [[ "$index" -lt "${#tests[@]}" ]]; do
    test_name="${tests[$index]}"
    if test_has_server_options "$test_name"; then
      if [[ "${#batch_tests[@]}" -gt 0 ]]; then
        run_mtr_batch "$batch_number" "${batch_tests[@]}"
        batch_tests=()
        batch_number=$((batch_number + 1))
        continue
      fi
      run_isolated_test "$test_name" "$index"
      index=$((index + 1))
      continue
    fi

    batch_tests+=("$test_name")
    index=$((index + 1))
    if [[ "${#batch_tests[@]}" -ge "$batch_size" ]]; then
      run_mtr_batch "$batch_number" "${batch_tests[@]}"
      batch_tests=()
      batch_number=$((batch_number + 1))
    fi
  done

  if [[ "${#batch_tests[@]}" -gt 0 ]]; then
    run_mtr_batch "$batch_number" "${batch_tests[@]}"
  fi

  cleanup_server
  echo "summary: $summary"
  if [[ "$failed_tests" -ne 0 ]]; then
    echo "failed tests: $failed_tests" >&2
    exit 1
  fi
  exit 0
fi

for idx in "${!tests[@]}"; do
  cleanup_server

  test_name="${tests[$idx]}"
  port=$((base_port + idx))
  server_port="$(pick_backend_port)"
  safe_name="${test_name//./_}"
  test_dir="$out_dir/$safe_name"
  vardir="$test_dir/var"
  run_dir="$vardir/mysqld.1"
  log_file="$test_dir/mtr.log"
  server_error_log="$vardir/log/mysqld.1.err"
  socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
  server_pid_file="$test_dir/server.pid"
  backend_port_file="$test_dir/backend-port"
  mkdir -p "$test_dir"

  rm -rf "$run_dir" "$vardir" "$socket_path"
  mkdir -p "$vardir/log" "$vardir/run" "$vardir/tmp"
  test_runner_args="$runner_args --preopen $run_dir=$run_dir"
  bootstrap_server_args=(
    "${extra_server_args[@]}"
  )
  bootstrap_server_args+=(
    "--datadir=$run_dir/data"
    "--tmpdir=$run_dir/tmp"
    "--log-error=$server_error_log"
    "--pid-file=$run_dir/data/mysqld.pid"
    "--secure-file-priv=$vardir"
  )
  test_server_args=("${bootstrap_server_args[@]}")
  has_test_server_options=0
  if test_has_server_options "$test_name"; then
    has_test_server_options=1
  fi
  append_test_server_options "$test_name"
  active_server_args=("${bootstrap_server_args[@]}")
  skip_system_tables_init=0
  start_server 1

  status="FAIL"
  exit_code=0
  mtr_result=""
  if wait_ready "$server_port" "$run_dir"; then
    if ! mariadb --protocol=TCP -h127.0.0.1 -P"$server_port" -uroot --ssl=0 <"$init_sql" >"$test_dir/init.stdout" 2>"$test_dir/init.stderr"; then
      exit_code=1
      cp "$test_dir/init.stderr" "$log_file"
    fi

    active_server_args=("${test_server_args[@]}")
    if test_requires_bootstrapless_restart; then
      skip_system_tables_init=1
    fi
    if [[ "$exit_code" -eq 0 ]] && { [[ "$restart_with_grants" == "1" ]] || [[ "$has_test_server_options" -eq 1 ]]; }; then
      cleanup_server
      if [[ "$restart_with_grants" == "1" && "$grant_port_offset" -ne 0 ]]; then
        port=$((port + grant_port_offset))
        server_port="$(pick_backend_port)"
        socket_path="/tmp/wasmtime-mariadb-mtr-$port.sock"
      elif ! wait_port_closed "$server_port"; then
        exit_code=124
        printf 'server port did not close before grant-table restart\n' > "$log_file"
      else
        server_port="$(pick_backend_port)"
      fi
      if [[ "$exit_code" -eq 0 ]]; then
        if [[ "$restart_with_grants" == "1" ]]; then
          start_server 0
        else
          start_server 1
        fi
        if ! wait_ready "$server_port" "$run_dir"; then
          exit_code=124
          printf 'server did not become ready after grant-table restart\n' > "$log_file"
        fi
      fi
    fi

    if [[ "$exit_code" -eq 0 ]]; then
      if start_tcp_proxy "$port" "$backend_port_file" "$test_dir" &&
        start_socket_proxy "$port" "$socket_path" "$test_dir"; then
        start_mtr_restart_watcher
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
          mtr_result="$(awk -v test="$test_name" '$1 == test && $2 == "[" { result = $3 } END { print result }' "$log_file")"
          case "$mtr_result" in
            pass) status="PASS" ;;
            skipped) status="SKIP" ;;
            *) status="FAIL" ;;
          esac
          if [[ "$status" != "PASS" ]]; then
            exit_code=1
          fi
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
  if [[ "$status" != "PASS" ]]; then
    failed_tests=$((failed_tests + 1))
  fi
  cleanup_server
  if [[ "$preserve_vardirs" != "1" ]]; then
    rm -rf "$vardir/mysqld.1" "$vardir/run" "$vardir/std_data" "$vardir/tmp"
  fi
done

cleanup_server
echo "summary: $summary"
if [[ "$failed_tests" -ne 0 ]]; then
  echo "failed tests: $failed_tests" >&2
  exit 1
fi
