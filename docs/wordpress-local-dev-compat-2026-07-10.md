# WordPress local-development compatibility, 2026-07-10

This document records the current compatibility signal for running a normal,
single-node WordPress development database on the Wasmtime-hosted MariaDB
prototype. It is not a production certification.

## Verified coverage

The reproducible profile is:

```sh
OUT_DIR=build/mtr-wordpress-compat ./scripts/run-mtr-wordpress-compat.sh
```

It runs 105 upstream MariaDB MTR cases against a fresh Wasmtime server and
datadir per case. The current profile's 105 cases all passed in the final
clean-server run. Results are retained in:

```text
build/mtr-wordpress-compat-final/summary.tsv
```

The coverage includes:

- Core DDL/DML, joins, grouping, ordering, subqueries, `IN`, `LIKE`, and
  `SQL_CALC_FOUND_ROWS`.
- InnoDB auto-increment basics, transactions, rollback, locks, indexes,
  upserts, multi-table updates, foreign keys, and schema alters.
- `utf8mb4`, `utf8mb4_unicode_520_ci`, UCA collations, date/time functions,
  JSON functions, prepared statements, and schema inspection.
- `SHOW`, `EXPLAIN`, `information_schema`, temporary-table basics, and
  migration-shaped `ALTER TABLE`/index changes.

The profile retains per-test logs and its TSV summary while discarding each
completed datadir. Use `MTR_PRESERVE_VARDIRS=1` to retain full datadirs for a
failure investigation. The harness exits nonzero when any test fails.

## WordPress SQL smoke

With the server running, execute:

```sh
PORT=3307 ./scripts/test-wordpress-local-dev.sh
```

The script creates and removes an isolated database. It uses WordPress-shaped
posts, options, postmeta, term, taxonomy, and term-relationship tables with
the current core index prefixes. It verifies `utf8mb4_unicode_520_ci`, a 1 MiB
`LONGTEXT` post containing an emoji, option upserts, a taxonomy join,
`SQL_CALC_FOUND_ROWS`, schema inspection, a transaction, localized date names,
and an index migration.

The latest run passed through a normal TCP MariaDB client. A PHP `wpdb`
integration test was not run here because the local PHP runtime has no
`mysqli` extension installed.

## Deliberate exclusions and limits

- `innodb.temp_truncate` is excluded because it tests `innodb_force_recovery`
  restart behavior. Forced recovery and crash recovery remain outside the
  prototype's local-development support claim.
- `innodb.temporary_table` is excluded because its fixed 12 MiB temporary
  tablespace exhaustion expectation differs from this WASI path. Ordinary
  temporary-table creation and truncation are covered; plugins that consume
  large temporary tables should be treated cautiously.
- MariaDB's `foreign_null` and `foreign_sql_mode` cases require MTR's full
  combination matrix, which the external-server harness does not emulate.
  Normal foreign-key creation and update/cascade coverage pass.
- `main.type_blob` intentionally does not support MTR external-server mode.
  The dedicated WordPress smoke covers the relevant `LONGTEXT` path instead.
- Authentication, TLS, binary logging, replication, backup, crash recovery,
  XA/durability guarantees, dynamic plugins, and high-concurrency correctness
  remain unvalidated or disabled. The documented runner uses
  `--skip-grant-tables` and `--debug-no-sync`.
