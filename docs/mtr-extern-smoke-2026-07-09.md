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
readiness, starts a small Unix-socket-to-TCP proxy for `mysqltest`
`localhost` connections, loads `scripts/mtr-extern-init.sql`, then runs:

```sh
perl /usr/share/mariadb-test/mariadb-test-run.pl \
  --extern host=127.0.0.1 \
  --extern port="$port" \
  --extern socket="$socket_path" \
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

The server runner also preopens the smoke output directory at the same guest
path, and preopens the MTR `std_data` directory as guest `/std_data`.

Raw logs from the latest run:

- `build/mtr-extern-smoke-current2/summary.tsv`
- `build/mtr-extern-smoke-current2/<test_name>/mtr.log`
- `build/mtr-extern-smoke-current2/<test_name>/init.stdout`
- `build/mtr-extern-smoke-current2/<test_name>/init.stderr`
- `build/mtr-extern-smoke-current2/<test_name>/server/mariadbd-runtime.err`

The init SQL is intentionally minimal. It creates `mysql.proc`,
`mysql.procs_priv`, `mysql.func`, time-zone tables, statistics tables,
`mysql.gtid_slave_pos`, and `mtr.add_suppression()` using InnoDB so tests can
get past MTR's own warning-suppression and system-table setup without requiring
a full datadir initialization.

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
| `main.select` | Insert of `18446744073709551615` into an integer column failed with `ER_WARN_DATA_OUT_OF_RANGE (1264)`. |
| `main.insert` | `CREATE TABLE t1 (sid CHAR(20), id INT(2) NOT NULL AUTO_INCREMENT, KEY(sid, id))` failed with `ER_WRONG_AUTO_KEY (1075)`, consistent with the smoke server running InnoDB as the default engine. |
| `main.update` | Result diff against Fedora's `main/update.result`. The test now runs past the previous socket and internal-temp-table blockers. |
| `main.delete` | `DELETE FROM t1 AS a1 WHERE a1.c1 = 2` failed with `ER_PARSE_ERROR (1064)`. This is an 11.8 packaged-test expectation against an 11.4 server. |
| `main.create` | `INSERT INTO t1 VALUES (""),(NULL)` on `CHAR(0) NOT NULL` failed with `ER_BAD_NULL_ERROR (1048)`. |
| `main.drop` | `mysqltest` rejected `/tmp/data//mysql_test/#sql-347f_6.frm` because it is outside `MYSQLTEST_VARDIR` and `MYSQL_TMP_DIR`. |
| `main.type_int` | Result diff against Fedora's `main/type_int.result`, mostly default engine/charset/collation output differences. |
| `main.type_varchar` | `mysqltest` rejected `/tmp/data//upgrade1/vchar.frm` because it is outside `MYSQLTEST_VARDIR` and `MYSQL_TMP_DIR`. |
| `main.func_math` | Result diff against Fedora's `main/func_math.result`; the earlier missing `std_data` file is fixed. |
| `main.func_str` | Result diff against Fedora's `main/func_str.result`; the earlier Unix-socket and outfile-preopen failures are fixed. |
| `main.join` | Result diff against Fedora's `main/join.result`. |
| `main.union` | InnoDB rejected a foreign key definition with `errno: 150 "Foreign key constraint is incorrectly formed"`. |
| `main.order_by` | Result diff against Fedora's `main/order_by.result`, including `ERROR 21000: Subquery returns more than 1 row`. |
| `main.group_by` | Result diff against Fedora's `main/group_by.result`; server logs also show an `Out of sort memory` error in this area. |
| `main.subselect` | `mysqltest` `remove_file` command failed with `my_errno: 2`, `errno: 2`. |
| `innodb.innodb` | `CREATE TABLE ... ROW_FORMAT=FIXED` failed with `ER_CANT_CREATE_TABLE (errno: 140 "Wrong create options")`. |
| `innodb.create_select` | Result diff: packaged 11.8 result expects `Truncated incorrect BOOLEAN value`, while 11.4 reports `Truncated incorrect DOUBLE value`. |
| `innodb.foreign_key` | MTR restart include failed to open `/tmp/data/(none).pid`; external-mode restart assumptions do not match this harness. |
| `innodb.alter_table` | Result diff against Fedora's `suite/innodb/r/alter_table.result`. |

## Failure buckets

The failures now cluster into a few concrete areas:

1. Packaged-test/server-version mismatch. This run uses Fedora's 11.8.8 MTR
   package against an 11.4.12 server, so some syntax and expected-result files
   do not match the server under test.
2. Default engine and charset/collation differences. The smoke server defaults
   to InnoDB/latin1, while many packaged `main` results expect MyISAM and newer
   default charset/collation output.
3. MTR external-mode filesystem assumptions. Some `mysqltest` commands reject
   `/tmp/data/...` paths because they are outside the allowed vardir/tmpdir
   sandbox, even though the server can access them.
4. MTR restart/PID assumptions. `innodb.foreign_key` tries to use restart
   includes that expect a normal MTR-managed mysqld pid file.
5. Remaining real runtime differences, including sort-memory pressure and
   some SQL behavior differences in expression typing, foreign key validation,
   and row format handling.

## Fixed in this pass

The latest run no longer contains these earlier blockers:

- `Incorrect file format` for MyISAM tables or internal temporary tables.
- Unix socket connection failures for `connect ...,localhost,...`.
- `chmod()` / `fchmod()` returning WASI `ENOSYS` during trigger metadata writes.
- Server-side `Capabilities insufficient` for MTR vardir outfile writes.
- Missing `/std_data/...` for packaged `LOAD DATA INFILE` tests.

Direct repros that now pass:

- Explicit MyISAM table create/insert/select.
- `CREATE TEMPORARY TABLE ... ENGINE=MyISAM SELECT ...`.
- A grouped InnoDB query requiring an internal temporary table.

## Next likely fixes

1. Build and use pinned MariaDB 11.4 `mariadb-test`/`mysqltest` tooling for
   version-matched expected results.
2. Add a better external-mode mapping for `/tmp/data/...` paths that
   `mysqltest` path-safety checks currently reject.
3. Teach the harness how to skip or emulate MTR restart includes for an
   externally managed Wasmtime server.
4. Revisit server defaults for MTR runs, especially default storage engine and
   charset/collation, without changing the user-facing InnoDB quick start.
5. Increase or tune sort buffers for query-heavy tests and investigate the
   remaining SQL behavior diffs.
