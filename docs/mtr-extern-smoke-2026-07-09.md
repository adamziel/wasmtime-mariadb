# MTR external smoke results, 2026-07-09

This run used MariaDB Test Run (MTR) against the Wasmtime-hosted MariaDB
server as an external server. The goal was to get a first compatibility map,
not a clean certification run.

## MTR suite scope

MTR is MariaDB's integration/regression test harness. It runs `.test` scripts
with `mysqltest`, manages per-test vardirs and ports, and compares output
against checked-in `.result` files. The suite covers core SQL behavior,
optimizer behavior, storage engines, information schema, stored routines,
replication/binlog features, plugins, upgrade paths, and many historical bug
regressions.

The installed Fedora MTR tree on this machine contains 8,421 `.test` files
(`main`: 1,356, `plugin`: 1,771, `suite`: 5,291, `include`: 3). The pinned
MariaDB source checkout in this repository contains 6,588 tests under
`mysql-test`. This smoke run executes 22 tests, so it is useful as an early
compatibility signal but not comprehensive coverage.

## Harness

Command:

```sh
./scripts/run-mtr-extern-smoke.sh
```

The harness starts a fresh Wasmtime server/datadir per test, waits for TCP
readiness, loads `scripts/mtr-extern-init.sql`, starts a small
Unix-socket-to-TCP proxy for `mysqltest` `localhost` connections, then runs:

```sh
perl "$MTR_DIR/mariadb-test-run.pl" \
  --extern host=127.0.0.1 \
  --extern port="$port" \
  --extern socket="$socket_path" \
  --extern user=root \
  --extern ssl=0 \
  --client-bindir="$MTR_TOOLROOT/bin" \
  --vardir="$vardir" \
  --force \
  --timer \
  "$test_name"
```

Versions:

- Server under test: `11.4.12-MariaDB` inside `wasmtime-mariadb 0.1.3`
- MTR runner/test tree: pinned MariaDB 11.4 source checkout at
  `build/mariadb-wasi-port/src/mysql-test`
- Client/test helper binaries: Fedora `mariadb-test-11.8.8` tools, exposed
  through a generated `build/mtr-toolroot/bin`

For source-tree MTR runs, `scripts/run-mtr-extern-smoke.sh` now builds
`my_safe_process` into `build/mtr-toolroot/mysql-test/lib/My/SafeProcess/`,
symlinks required client/helper tools into `build/mtr-toolroot/bin`, and sets
`MTR_BINDIR` for the runner.

The server datadir is mapped under the test vardir as
`<test>/var/mysqld.1/data`, matching MTR's normal path shape. This lets
`mysqltest` file-safety checks accept server paths and lets relative
`../../std_data/...` loads resolve to the vardir copy of `std_data`. The MTR
server profile also overrides the quick-start InnoDB default with MTR-like
defaults such as `--default-storage-engine=MyISAM`,
`--use-stat-tables=preferably`, and `--histogram-type=json_hb`.

Raw logs from the latest run:

- `build/mtr-extern-smoke-current5/summary.tsv`
- `build/mtr-extern-smoke-current5/<test_name>/mtr.log`
- `build/mtr-extern-smoke-current5/<test_name>/init.stdout`
- `build/mtr-extern-smoke-current5/<test_name>/init.stderr`
- `build/mtr-extern-smoke-current5/<test_name>/var/mysqld.1/mariadbd-runtime.err`

The init SQL is intentionally minimal. It creates `mysql.proc`,
`mysql.global_priv`, privilege tables, log tables, `mysql.servers`,
`mysql.event`, `mysql.procs_priv`, `mysql.func`, time-zone tables, statistics
tables, `mysql.gtid_slave_pos`, `performance_schema`, `sys`, and
`mtr.add_suppression()` without requiring a full datadir initialization.
`mysql.proc` is Aria because `main.drop` has a file-level regression test that
expects `proc.MAD` and `proc.MAI`.

By default the harness now starts the server once with `--skip-grant-tables` to
load this bootstrap SQL, then restarts it with grant tables enabled before
running MTR. The second server uses `MTR_GRANT_PORT_OFFSET=10000` by default to
avoid short-lived TCP bind races on restart.

## Summary

22 tests were run:

- Passed: 14
- Failed: 8

Passed:

- `main.select`
- `main.insert`
- `main.update`
- `main.delete`
- `main.create`
- `main.type_int`
- `main.type_varchar`
- `main.func_math`
- `main.subselect`
- `main.ps`
- `main.prepare`
- `main.information_schema`
- `innodb.create_select`
- `innodb.alter_table`

## Failures

| Test | First failure |
| --- | --- |
| `main.drop` | Result diff: WASI reports `ENOTEMPTY` as errno `55`; the pinned expected file wants Linux errno `39`. `SHOW DATABASES` now matches. |
| `main.func_str` | Result diff: `random_bytes()` returns deterministic or `NULL` results in cases where the expected file has non-`NULL` random byte lengths, plus one binary conversion predicate differs. |
| `main.join` | Result diff: the pinned expected file assumes `ENGINE=InnoDB` is unavailable and expects three warnings; this build has InnoDB enabled. The `mysql.global_priv` metadata rows now match. |
| `main.union` | Result diff: slow-query counters stay at `0` and `mysql.slow_log` does not receive the expected row. The earlier missing metadata row is fixed. |
| `main.order_by` | Result diff in `ANALYZE FORMAT=JSON`; runtime timing fields such as `r_total_time_ms` are absent, and `innodb_sort_buffer_size` is present in `SHOW VARIABLES`. |
| `main.group_by` | Result diff: the pinned expected file assumes `ENGINE=InnoDB` is unavailable for one subcase, while this build has InnoDB enabled. |
| `innodb.innodb` | `CREATE TABLE ... ROW_FORMAT=FIXED` failed with `ER_CANT_CREATE_TABLE (errno: 140 "Wrong create options")`. |
| `innodb.foreign_key` | MTR restart include waited for the external server to disappear and timed out. External-mode restart assumptions still do not match this harness. |

## Failure buckets

The failures now cluster into a few concrete areas:

1. Remaining minimal-datadir/runtime differences. The grant-enabled restart and
   datadir enumeration now work for this smoke set, but table-based slow
   logging still does not fully match a normal MTR datadir.
2. Expected-result variants for the exact server build. Some pinned results
   assume InnoDB is unavailable in `main` subcases, while this build has InnoDB.
3. MTR restart assumptions. `innodb.foreign_key` tries to use restart includes
   that expect MTR to own the server lifecycle.
4. Remaining behavior differences, including `random_bytes()` coercion
   behavior, `ANALYZE FORMAT=JSON` fields, and `ROW_FORMAT=FIXED` handling in
   InnoDB.

## Fixed in this pass

The latest run no longer contains these earlier blockers:

- Fedora 11.8 expected-result mismatch for the smoke set; the harness now uses
  the pinned MariaDB 11.4 MTR tree by default when present.
- MTR source-tree runner failure due to missing `my_safe_process`.
- Default-engine drift for the `main` suite; MTR runs now override the
  quick-start InnoDB default with MyISAM.
- `mysqltest` path-safety failures for server files under `/tmp/data/...`; the
  datadir now lives under the MTR vardir.
- Missing `mysql.event` causing `DROP DATABASE` warning diffs.
- Missing `mysql/proc.MAD` / `mysql/proc.MAI` for the `main.drop` file-level
  regression case.
- `Incorrect file format` for MyISAM tables or internal temporary tables.
- Unix socket connection failures for `connect ...,localhost,...`.
- `chmod()` / `fchmod()` returning WASI `ENOSYS` during trigger metadata writes.
- Server-side `Capabilities insufficient` for MTR vardir outfile writes.
- Missing or inaccessible `std_data` for `LOAD DATA INFILE` tests.
- Grant-table execution for the smoke set. The harness now restarts without
  `--skip-grant-tables`, which flips `main.select` and `main.create` to pass.
- Missing `mysql.db`, table/column privilege tables, role mappings, proxy
  privileges, plugin table, `mysql.general_log`, and `mysql.slow_log`.
- Host-path `stat()` support in the WASI file shim. MariaDB's `my_stat()` now
  uses the same preopen-aware resolver as table-file open/read/write calls,
  fixing datadir enumeration through `SHOW DATABASES` and
  `information_schema.SCHEMATA`.
- Missing bootstrap `performance_schema` and `sys` schemas.

Tests that flipped from failing to passing since `build/mtr-extern-smoke-current4`:

- `main.type_varchar`

Tests that flipped from failing to passing since `build/mtr-extern-smoke-current3`:

- `main.select`
- `main.create`

Tests that flipped from failing to passing since `build/mtr-extern-smoke-current2`:

- `main.insert`
- `main.update`
- `main.delete`
- `main.type_int`
- `main.func_math`
- `main.subselect`
- `innodb.create_select`
- `innodb.alter_table`

Direct repros that now pass:

- Explicit MyISAM table create/insert/select.
- `CREATE TEMPORARY TABLE ... ENGINE=MyISAM SELECT ...`.
- A grouped InnoDB query requiring an internal temporary table.

## Next likely fixes

1. Replace the minimal grant/system-table bootstrap with enough of
   `mariadb-install-db` to match normal MTR metadata and logging behavior more
   closely.
2. Teach the harness how to skip, emulate, or explicitly mark MTR restart
   includes for an externally managed Wasmtime server.
3. Decide whether to use alternate expected-result files or targeted skips for
   subcases whose expected output assumes InnoDB is unavailable.
4. Investigate the remaining SQL behavior diffs in string predicates,
   `random_bytes()` argument coercion, `ANALYZE FORMAT=JSON`, and InnoDB
   `ROW_FORMAT=FIXED`.
