# Transaction validation, 2026-07-10

This note separates throughput from transactional correctness for the
Wasmtime-hosted MariaDB prototype. Neither signal is a production durability
certification. Strict process-crash validation and current strict-versus-
relaxed measurements are recorded separately in
[`durability-validation-2026-07-10.md`](durability-validation-2026-07-10.md).

## MTR in this context

MariaDB Test Run (MTR) is MariaDB's upstream integration and regression test
harness. A test script can issue a handful of statements or drive multiple
connections, stored routines, restarts, and loops, so its script count is not
a meaningful query count. The pinned MariaDB 11.4 source tree contains 6,588
MTR test scripts. The transaction profile in this repository selects 57 cases
with local-development relevance.

Run it with:

```sh
MTR_BATCH_SIZE=4 \
OUT_DIR=build/mtr-transaction-verified \
./scripts/run-mtr-transaction-nuances.sh
```

It records a pass, skip, or failure for every case in
`build/mtr-transaction-verified/summary.tsv`; a skip is a non-pass.

The final 2026-07-10 run at
`build/mtr-transaction-verified-final2/summary.tsv` recorded 57 passes, zero
skips, and zero failures.

The 57-case profile covers:

- Explicit commit, rollback, savepoints, implicit commits from DDL, and
  transaction read-only mode.
- Consistent snapshots, isolation, lock waits, deadlocks, killed lockers,
  `NOWAIT`, `SKIP LOCKED`, secondary-index locking, and concurrent inserts.
- InnoDB auto-increment locking and persistence, triggers, stored procedures,
  temporary tables, and `INSERT ... ON DUPLICATE KEY UPDATE`.
- XA statement handling and normal foreign-key creation/alter/drop behavior.
- `innodb.snapshot_isolation_race`, which runs concurrent stored-procedure
  transactions in two connections.

## Measured 60,000-query workload

The separate workload below starts an ephemeral server, then uses
`mariadb-slap`/`mysqlslap` with InnoDB and four concurrent clients. It runs
15,000 generated mixed read/write statements per client with autocommit off
and commits every 20 statements:

```sh
OUT_DIR=build/slap-60k-transaction \
./scripts/run-60k-transaction-workload.sh
```

The run fails if the server general log contains fewer than the requested
60,000 `Query` commands. It requires the local `mariadb-admin` client and
either `mariadb-slap` or `mysqlslap`.

The earlier unsynced Linux x86_64 workspace result was:

| Measurement | Result |
| --- | ---: |
| Generated workload queries | 60,000 |
| Logged `Query` commands | 64,012 |
| `SELECT` commands | 29,972 |
| `INSERT` commands | 31,027 |
| `COMMIT` commands | 3,004 |
| Clients | 4 |
| Slap elapsed time | 87.300 s |
| Wall-clock time | 88 s |

The extra logged commands are schema/setup and connection-control statements.
This is a mixed `SELECT`/`INSERT` workload, not a benchmark of every query
shape. It was captured before strict mode became the default, when the runner
used `--debug-no-sync`; do not use it as a durable-mode performance number.

The current completed 60k measurements recorded the same 64,012 query
commands and 3,004 commits in 162.673 seconds with strict durability and
88.705 seconds in explicit relaxed mode. See the durability note for commands,
host details, and the process-crash test.

## Fixes found by discovery

Two MTR failures exposed runner/bootstrap gaps rather than MariaDB SQL
behavior:

- `main.implicit_commit` initially failed because `HELP 'foo'` needs the
  `mysql.help_*` metadata tables. The minimal local bootstrap now creates
  those empty tables, and the test passes.
- `main.trans_read_only` initially tried to run the bootstrap `CREATE TABLE`
  statements after enabling `--transaction-read-only`. The MTR runner now
  initializes first and performs an option-aware restart, so the test passes.

## Discovery results and limits

The broader transaction discovery pass identified the following non-passes.
They are deliberately not hidden by the verified profile.

| Case or category | Outcome | Meaning |
| --- | --- | --- |
| `main.transaction_timeout` | Fail | `idle_transaction_timeout=1` does not disconnect the idle transaction as upstream expects. Do not rely on server-side idle transaction expiry. |
| `innodb.gap_locks` | Fail | The lock behavior reaches the diagnostic assertion, but the WASI `SHOW ENGINE INNODB STATUS` fallback lacks the full upstream lock-monitor detail. |
| `innodb.deadlock_detect` | Fail | The upstream test is a combination-matrix test with `innodb_deadlock_detect` both ON and OFF. The external harness runs only its base variant, whose expected result does not match the server's ON default. Other deadlock and lock-wait cases in the profile pass. |
| `innodb.foreign_key` | Unstable | This malformed-FK/restart/recovery fixture once trapped the Wasmtime InnoDB purge thread with an out-of-bounds linear-memory access. A later rerun passed, but it is excluded until reliable. Normal foreign-key cases pass. |
| `main.lock_multi`, `main.lock_user` | Fail | These require privilege-table/authentication behavior that the documented `--skip-grant-tables` local runner intentionally does not provide. |
| Binlog, performance-schema, metadata-lock plugin cases | Skip | Those facilities are disabled or absent in the documented runtime. |

The detailed invalid-FK recovery scenario is not relevant to normal WordPress
schemas, which do not use foreign keys, but the instability remains a real
prototype limitation. The verified profile still includes normal
`innodb.add_foreign_key`, `innodb.fk_col_alter`, and `innodb.fk_drop_alter`
coverage.
