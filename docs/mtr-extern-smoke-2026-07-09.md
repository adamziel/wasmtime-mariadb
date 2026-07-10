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
  and restart the Wasmtime server. It waits for a stable file observation so
  a partially written restart command cannot lose its options.
- Simple per-test option-file handling for both top-level and
  `suite/<suite>/t/<test>-master.opt` files.
- A PID bridge: `mysqltest --shutdown_server` sees the actual host Wasmtime
  PID, rather than MariaDB's guest PID, so restart tests cannot accidentally
  wait for an unrelated host process.
- Status-aware result parsing. MTR `skipped` is a non-pass and makes the
  harness exit nonzero.

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

## Historical smoke result

The raw 22-case result below predates status-aware parsing, when MTR skips
could be recorded as passes. Keep it as historical diagnostic context, not as
the current compatibility pass-rate claim.

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

## Broader WordPress profile

The WordPress-focused profile is maintained separately in
`tests/wordpress-mtr-verified.txt`. Its current stable profile selects 191
normal local-development cases. It excludes the deep
`innodb.foreign_key` malformed-FK/restart/recovery fixture after an
intermittent Wasmtime InnoDB purge-thread trap:

```sh
MTR_BATCH_SIZE=8 \
OUT_DIR=build/mtr-wordpress-verified \
./scripts/run-mtr-wordpress-broad.sh
```

The harness can batch compatible cases. If a batch has a non-pass result, it
reruns every case in that batch in isolation before writing the summary. This
keeps the profile practical to run while preserving per-case results.
The final 2026-07-10 run recorded 191 passes, zero skips, and zero failures.

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
- External restart PID handling: the harness publishes the host Wasmtime PID
  into MTR's pid file after readiness, preventing `mysqltest` from waiting on
  an unrelated process with the same guest PID.
- Routine bootstrap: `mysql.func` is initialized alongside `mysql.proc`, so
  SQL-function create/drop paths work in the documented local-development
  runner.
- `SHOW ENGINE INNODB STATUS`: WASI now returns a minimal transaction monitor
  section with `History list length`, which unblocks purge checks.
- `innodb.foreign_key` error-log search: the external harness captures
  matching console diagnostics in `server.stderr`, not MTR's
  `mysqld.1.err`. The full malformed-FK/restart/recovery fixture is now
  excluded from stable profiles after an intermittent Wasmtime purge-thread
  memory trap; normal foreign-key cases remain covered.

## Remaining limitations

The 22-case smoke suite is intentionally small. The separate 191-case
WordPress profile expands normal SQL and InnoDB coverage, but neither profile
covers replication, binlog-heavy tests, plugins, upgrade tests,
stress/concurrency suites, backup suites, or all of the InnoDB matrix.

The `SHOW ENGINE INNODB STATUS` output under WASI is currently a minimal
fallback, not the full upstream monitor text. It is enough for the historical
purge check, but not for the full lock-monitor diagnostic assertions in
`innodb.gap_locks`.

The bootstrap SQL is intentionally minimal and is not a full replacement for
`mariadb-install-db`. Broader MTR coverage will likely expose more system-table
and privilege-table assumptions.
