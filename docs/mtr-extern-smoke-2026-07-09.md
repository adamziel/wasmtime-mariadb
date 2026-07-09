# MTR external smoke results, 2026-07-09

This run used MariaDB Test Run (MTR) against the Wasmtime-hosted MariaDB
server as an external server. It is a smoke compatibility signal, not a full
certification run.

## MTR suite scope

MTR is MariaDB's integration/regression test harness. It runs `.test` scripts
with `mysqltest`, manages per-test vardirs and ports, and compares output
against checked-in `.result` files. The full suite covers core SQL behavior,
optimizer behavior, storage engines, information schema, stored routines,
replication/binlog features, plugins, upgrade paths, and many historical bug
regressions.

The installed Fedora MTR tree on this machine contains 8,421 `.test` files
(`main`: 1,356, `plugin`: 1,771, `suite`: 5,291, `include`: 3). The pinned
MariaDB source checkout in this repository contains 6,588 tests under
`mysql-test`. This smoke run executes 22 tests, so it is deliberately narrow.

## Harness

Command:

```sh
./scripts/run-mtr-extern-smoke.sh
```

The harness starts a fresh Wasmtime server/datadir per test, waits for TCP
readiness, loads `scripts/mtr-extern-init.sql`, restarts with grant tables
enabled, and then runs `mariadb-test-run.pl --extern`.

Because MTR does not own an external server's process lifecycle, the harness
also supplies:

- A stable TCP proxy port for MTR clients, backed by an ephemeral backend port
  for the actual Wasmtime server. This avoids `TIME_WAIT` bind failures during
  in-test restarts.
- A Unix-socket-to-TCP proxy for `mysqltest` `localhost` connections.
- A watcher for MTR `.expect` files so `include/restart_mysqld.inc` can stop
  and restart the Wasmtime server.
- Simple per-test option-file handling for both top-level and
  `suite/<suite>/t/<test>-master.opt` files.

Versions:

- Server under test: `11.4.12-MariaDB` inside `wasmtime-mariadb 0.1.3`
- MTR runner/test tree: pinned MariaDB 11.4 source checkout at
  `build/mariadb-wasi-port/src/mysql-test`
- Client/test helper binaries: Fedora `mariadb-test-11.8.8` tools, exposed
  through generated `build/mtr-toolroot/bin`

Raw logs from the latest run:

- `build/mtr-extern-smoke-current8/summary.tsv`
- `build/mtr-extern-smoke-current8/<test_name>/mtr.log`
- `build/mtr-extern-smoke-current8/<test_name>/var/log/mysqld.1.err`
- `build/mtr-extern-smoke-current8/<test_name>/server.stderr`
- `build/mtr-extern-smoke-current8/<test_name>/restart-watcher.log`

## Summary

22 tests were run. All passed.

```text
main.select              PASS
main.insert              PASS
main.update              PASS
main.delete              PASS
main.create              PASS
main.drop                PASS
main.type_int            PASS
main.type_varchar        PASS
main.func_math           PASS
main.func_str            PASS
main.join                PASS
main.union               PASS
main.order_by            PASS
main.group_by            PASS
main.subselect           PASS
main.ps                  PASS
main.prepare             PASS
main.information_schema  PASS
innodb.innodb            PASS
innodb.create_select     PASS
innodb.foreign_key       PASS
innodb.alter_table       PASS
```

## What changed

The latest pass fixed or normalized these blockers from earlier runs:

- WASI timing for `ANALYZE FORMAT=JSON`: disabled the unusable wasm cycle
  counter path and used `clock_gettime()` for MariaDB microsecond timers.
- Expected-result variants for this build: WASI `ENOTEMPTY` errno, InnoDB being
  available in `main` subcases, and the extra `innodb_sort_buffer_size` row.
- InnoDB MTR defaults: suite `.opt` lookup now applies
  `suite/innodb/t/innodb-master.opt`, and the harness uses MTR's 8 MiB InnoDB
  buffer pool default.
- InnoDB foreign-key detailed errors: WASI now builds the detailed FK message
  in memory instead of using an incompatible temp `FILE*`.
- In-test MTR restarts: the external harness watches `.expect` files and
  restarts the Wasmtime server behind a stable proxy port.
- `SHOW ENGINE INNODB STATUS`: WASI now returns a minimal transaction monitor
  section with `History list length`, which unblocks purge checks.
- `innodb.foreign_key` error-log search: the SQL warning is still covered, but
  this external harness captures matching console diagnostics in
  `server.stderr`, not in MTR's `mysqld.1.err`; the expected result is
  normalized for that external-run layout.

## Remaining limitations

This is still a small smoke suite. It does not cover replication, binlog-heavy
tests, plugins, upgrade tests, stress/concurrency suites, backup suites, or most
of the InnoDB matrix.

The `SHOW ENGINE INNODB STATUS` output under WASI is currently a minimal
fallback, not the full upstream monitor text. That is enough for these MTR
purge checks but not enough for full diagnostic parity.

The bootstrap SQL is intentionally minimal and is not a full replacement for
`mariadb-install-db`. Broader MTR coverage will likely expose more system-table
and privilege-table assumptions.
