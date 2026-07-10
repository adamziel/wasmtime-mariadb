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
an index migration, and a stored procedure create/call/drop cycle.

The stored-routine check caught a real runner gap: MariaDB needs
`mysql.proc` when creating routines, even when the server runs with
`--skip-grant-tables`. `scripts/run-server.sh` now bootstraps the minimal
non-authentication metadata tables needed for routine and startup handling.

## WordPress Core and WooCommerce

The WordPress Core PHP suite was run against the Wasmtime server using
WordPress source at `cec8718050f2` (WordPress 7.1.0):

```text
Tests: 30059, Assertions: 4556437, Warnings: 86, Skipped: 77.
```

It completed with no failures. The warnings and skips are Core's
environment-dependent coverage (for example image and external-cache support),
not database errors.

WooCommerce source at `00b15cb109a9` (11.1.0-dev) was tested against a clean
database before every group. The database-facing groups passed:

| Coverage | Result |
| --- | --- |
| Simple product CRUD | 15 tests, 33 assertions |
| Product datastore CRUD/search/meta | 35 tests, 144 assertions |
| CPT order CRUD | 143 tests, 215 assertions |
| HPOS order datastore | 106 tests, 674 assertions, 1 upstream skip |
| HPOS queries and synchronization | 56 tests, 248 assertions, 1 upstream skip |
| Repository WordPress/WooCommerce smoke | 3 tests, 24 assertions |

The repository smoke is reproducible once a normal WooCommerce test
environment is configured to use the running server:

```sh
WP_TESTS_DIR=/path/to/wordpress-tests-lib \
WOOCOMMERCE_DIR=/path/to/woocommerce \
./scripts/test-wordpress-woocommerce-local-dev.sh
```

It resets the configured test database and boots real WordPress and
WooCommerce. It saves and reloads a page, a simple product, and an order; it
also verifies direct InnoDB `ROLLBACK` and `COMMIT` behavior.

The broad default WooCommerce suite was also attempted. Its initial run
reported 176 errors and 77 failures, but the failures were not database server
errors: the current suite emits bootstrap output before tests that set cookies,
uses a reflection call deprecated by PHP 8.5, and expects fixture plugins,
external data, and feature configurations absent from this checkout. After
installing WordPress outside PHPUnit and enabling output buffering, the suite
passed the database-facing groups above but later stalled in an upstream PHP
subprocess with idle database connections. It is therefore not used as a
server pass-rate claim.

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
