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
readiness, loads `scripts/mtr-extern-init.sql`, then runs:

```sh
perl /usr/share/mariadb-test/mariadb-test-run.pl \
  --extern host=127.0.0.1 \
  --extern port="$port" \
  --extern user=root \
  --extern ssl=0 \
  --client-bindir=/usr/bin \
  --force \
  --timer \
  "$test_name"
```

Versions:

- Server under test: `11.4.12-MariaDB` inside `wasmtime-mariadb 0.1.3`
- MTR package: Fedora `mariadb-test-11.8.8`
- Note: the ideal next step is to build/use the pinned 11.4 `mariadb-test`
  binary and runner. The source tree has 11.4 tests, but its runner needed a
  built `my_safe_process`; this first pass used Fedora's packaged test tools.

Raw logs:

- `build/mtr-extern-smoke/summary.tsv`
- `build/mtr-extern-smoke/<test_name>/mtr.log`
- `build/mtr-extern-smoke/<test_name>/init.stdout`
- `build/mtr-extern-smoke/<test_name>/init.stderr`
- `build/mtr-extern-smoke/<test_name>/server/mariadbd-runtime.err`

The init SQL is intentionally minimal. It creates `mysql.proc`,
`mysql.procs_priv`, and `mtr.add_suppression()` using InnoDB so tests can get
past MTR's own warning-suppression setup without requiring currently broken
Aria/MyISAM system tables.

## Summary

22 tests were run:

- Passed: 3
- Failed: 19

Passed:

- `main.ps`
- `main.prepare`
- `main.information_schema`

## Failures

| Test | First failure |
| --- | --- |
| `main.select` | `CREATE TEMPORARY TABLE tmp ENGINE=MyISAM SELECT * FROM t3` failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 'tmp'`. |
| `main.insert` | `CREATE TABLE t1 (sid CHAR(20), id INT(2) NOT NULL AUTO_INCREMENT, KEY(sid, id))` failed with `ER_WRONG_AUTO_KEY (1075)`. This appears tied to running the suite with InnoDB as default storage engine instead of the test's expected engine behavior. |
| `main.update` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |
| `main.delete` | Insert into an explicit `ENGINE=MyISAM` table failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't1'`. |
| `main.create` | `INSERT INTO t1 VALUES (""),(NULL)` on `CHAR(0) NOT NULL` failed with `ER_BAD_NULL_ERROR (1048)`, while the test expected the legacy result output. |
| `main.drop` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |
| `main.type_int` | `INFORMATION_SCHEMA.COLUMNS ... ORDER BY ...` failed with `Incorrect file format '(temporary)'`. |
| `main.type_varchar` | Test tried to access `/tmp/data//upgrade1/vchar.frm`; `mysqltest` rejected it because it is outside `MYSQLTEST_VARDIR` and `MYSQL_TMP_DIR`. |
| `main.func_math` | Insert into `t1` failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't1'`. |
| `main.func_str` | Test `connect conn1,localhost,...` tried Unix socket `/tmp/mysqld.sock`; this harness exposes TCP only. |
| `main.join` | Insert into `t1` failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't1'`. |
| `main.union` | Insert into `t1` failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't1'`. |
| `main.order_by` | Insert into an explicit `ENGINE=MyISAM PACK_KEYS=1` table failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't1'`. |
| `main.group_by` | Query using grouping/left join failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format '(temporary)'`. |
| `main.subselect` | Insert into an explicit `ENGINE=MyISAM` table failed with `HA_ERR_NOT_A_TABLE (130): Incorrect file format 't8'`. |
| `innodb.innodb` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |
| `innodb.create_select` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |
| `innodb.foreign_key` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |
| `innodb.alter_table` | `include/have_innodb.inc` failed querying `information_schema.system_variables`; internal temporary table opened as `Incorrect file format '(temporary)'`. |

## Failure buckets

The failures cluster into a few concrete areas:

1. MyISAM/Aria table files are still unusable in this WASI port. Explicit
   MyISAM temporary tables and several default table paths fail with
   `Incorrect file format`.
2. Internal temporary tables are still a major blocker. Several
   `information_schema` and grouping queries fail on `'(temporary)'` with
   `HA_ERR_NOT_A_TABLE`.
3. Some `main` tests assume legacy default-engine behavior. Running the port
   with InnoDB by default exposes differences in auto-increment key validation
   and `CHAR(0) NOT NULL` handling.
4. MTR's external-server mode assumes filesystem paths and sometimes Unix
   sockets. This conflicts with the current TCP-only runner and `/tmp` guest
   preopen mapping.
5. The MTR system-table bootstrap is only a smoke-test shim. It removes the
   `mtr.add_suppression()` setup blocker, but it is not a complete datadir
   initialization.

## Follow-up probe

I also reran a subset with:

```sh
OUT_DIR=build/mtr-extern-smoke-memory-tmp \
BASE_PORT=3370 \
SERVER_ARGS='--default-tmp-storage-engine=MEMORY' \
./scripts/run-mtr-extern-smoke.sh main.select main.update innodb.innodb innodb.foreign_key
```

It did not move the observed failures: `main.select` still failed on explicit
`ENGINE=MyISAM`, and the InnoDB-gated tests still failed on internal
`'(temporary)'` table handling.

## Next likely fixes

1. Fix internal temporary table storage so `information_schema` and grouped
   query paths work reliably.
2. Route/fix Aria and MyISAM file I/O, or disable those engines more
   completely and force tests away from them.
3. Add a real datadir initialization step with system tables using a working
   engine under WASI.
4. Add a Unix socket bridge or patch MTR external connection options for tests
   that issue `connect ...,localhost,...`.
5. Build the pinned MariaDB 11.4 `mariadb-test`/`mysqltest` tooling for
   version-matched results.
