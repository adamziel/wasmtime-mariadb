# wasmtime-mariadb

Experimental harness for running a patched MariaDB 11.4 server WebAssembly
module inside a native Wasmtime host executable.

This is the MariaDB counterpart to `adamziel/wasmtime-mysql`. It is not an
official MariaDB port. The current build can start `mariadbd` in Wasmtime,
listen on TCP, accept normal MySQL/MariaDB clients, and run basic SQL against
InnoDB tables.

## Requirements

- For release binaries: macOS Apple Silicon or Linux x86_64
- For building from source: Rust toolchain and Docker
- Optional: a local `mysql` or `mariadb` CLI for manual connections
- Python 3, only for the included dependency-free benchmark client

## Quick Start On Mac M4

This downloads the latest Apple Silicon release, verifies `SHA256SUMS`,
extracts it, and starts MariaDB on `127.0.0.1:3307`:

```sh
curl -fsSL https://raw.githubusercontent.com/adamziel/wasmtime-mariadb/main/scripts/install-release.sh | bash -s -- --run --port 3307
```

The server runs in the foreground. From another terminal, connect with a
`mysql` client:

```sh
cd wasmtime-mariadb-*-macos-aarch64
PORT=3307 ./scripts/test-mysql-client.sh
```

If macOS blocks the unsigned binary, remove quarantine and start it again:

```sh
xattr -d com.apple.quarantine ./wasmtime-mariadb 2>/dev/null || true
PORT=3307 ./scripts/run-server.sh
```

To only download and extract without starting the server:

```sh
curl -fsSL https://raw.githubusercontent.com/adamziel/wasmtime-mariadb/main/scripts/install-release.sh | bash
```

## Build

Fetch the pinned MariaDB source:

```sh
./scripts/fetch-mariadb-source.sh
```

Build the patched WASI `mariadbd` module:

```sh
./scripts/probe-mariadb-wasi-port.sh
```

Bundle the resulting WebAssembly module into one native runner:

```sh
./scripts/build-single.sh build/mariadb-wasi-port/build/sql/mariadbd
```

The runner is written to:

```sh
target/release/wasmtime-mariadb
```

## Run

Start MariaDB on `127.0.0.1:3307`:

```sh
RUN_DIR="$PWD/build/run" PORT=3307 ./scripts/run-server.sh
```

The helper creates `build/run/tmp` and `build/run/data`, preopens `build/run`
as guest `/tmp`, and starts the process from the host datadir. That current
working directory matters for this prototype because the custom file shim does
not yet model guest `chdir()`.

The helper also sets small InnoDB defaults that fit the current WASI build:
16 MiB buffer pool, 8 MiB redo log file, and 4 MiB redo log buffer. Extra
arguments passed to `run-server.sh` are forwarded to `mariadbd`.

If port `3307` is occupied, choose another port:

```sh
RUN_DIR="$PWD/build/run" PORT=3317 ./scripts/run-server.sh
```

Wait for:

```text
mariadbd: ready for connections.
```

## Connect

With Oracle's `mysql` CLI:

```sh
mysql --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl-mode=DISABLED
```

With the MariaDB CLI:

```sh
mariadb --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl=0
```

This prototype runs with `--skip-grant-tables`, so the documented root
connection has no password. A normal `CREATE TABLE` uses InnoDB:

```sql
CREATE DATABASE demo;
CREATE TABLE demo.t (id INT PRIMARY KEY, payload VARCHAR(64));
INSERT INTO demo.t VALUES (1, 'hello from wasmtime');
SELECT * FROM demo.t;
SHOW CREATE TABLE demo.t;
```

The included Python client can also verify connectivity without external
database client libraries:

```sh
python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 5 --batch-size 5
```

The packaged mysql-client smoke script runs `SELECT VERSION()`, creates a
default InnoDB table, inserts one row, reads it back, and reports the table
engine:

```sh
PORT=3307 ./scripts/test-mysql-client.sh
```

On Apple Silicon Macs with Homebrew, install a client with:

```sh
brew install mysql-client
```

If Homebrew does not put `mysql` on `PATH`, run:

```sh
MYSQL=/opt/homebrew/opt/mysql-client/bin/mysql PORT=3307 ./scripts/test-mysql-client.sh
```

## Benchmark

`scripts/bench-tcp.py` opens concurrent TCP connections, creates one uniquely
named InnoDB table per client in the `bench` schema, inserts rows in batches,
and verifies `COUNT(*)`. Pass `--engine MEMORY` if you want the older
in-memory-table smoke benchmark.

```sh
python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 2000 --batch-size 100
python3 scripts/bench-tcp.py --port 3307 --clients 4 --rows 500 --batch-size 100
```

Recent numbers from this workspace on Linux x86_64, using the release runner
and the MariaDB 11.4.12 WASI module. The server was run on port `3324` with
the default InnoDB runner settings.

| Clients | Rows/client | Inserted rows | Counted rows | Elapsed | Rows/sec |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 5 | 5 | 0.002 s | 2,900 |
| 1 | 2,000 | 2,000 | 2,000 | 0.009 s | 215,185 |
| 4 | 500 | 2,000 | 2,000 | 0.006 s | 322,836 |

These numbers are a TCP/protocol smoke benchmark over InnoDB with the
prototype runner's default `--debug-no-sync` setting, not a durability
benchmark.

## Transaction Validation

MTR is MariaDB's upstream integration/regression harness. Its 6,588 test
scripts are not a query count: individual scripts can run loops, multiple
connections, routines, and restarts. This repository has a focused 57-case
transaction profile covering commits, rollbacks, implicit DDL commits,
snapshots, locks, deadlocks, `NOWAIT`/`SKIP LOCKED`, XA statements, triggers,
and normal foreign-key DDL:

```sh
MTR_BATCH_SIZE=4 \
OUT_DIR=build/mtr-transaction-verified \
./scripts/run-mtr-transaction-nuances.sh
```

For a measured query count, run the separate InnoDB workload. It starts and
stops its own server, runs four concurrent clients with 15,000 mixed
`SELECT`/`INSERT` statements each, turns autocommit off, and commits every 20
statements:

```sh
OUT_DIR=build/slap-60k-transaction \
./scripts/run-60k-transaction-workload.sh
```

The 2026-07-10 Linux x86_64 run issued 60,000 generated workload queries and
recorded 64,012 `Query` commands in the server log, including 3,004 `COMMIT`s,
in 88 wall-clock seconds. The companion transaction profile completed 57/57
passes with zero skips or failures. See
[`docs/transaction-validation-2026-07-10.md`](docs/transaction-validation-2026-07-10.md)
for exact workload parameters, transaction coverage, and known non-passes.

## Development Checks

Verify the Rust host without embedding MariaDB:

```sh
./scripts/verify-dev-fixture.sh
```

Check formatting and host compilation:

```sh
cargo fmt --check
cargo check --features dev-fixture
```

Run the WordPress local-development SQL smoke against a running server. It
creates and removes an isolated database:

```sh
PORT=3307 ./scripts/test-wordpress-local-dev.sh
```

Run the application-level WordPress and WooCommerce regression after preparing
their normal upstream test environment. Its `wp-tests-config.php` must point
at the running Wasmtime MariaDB instance:

```sh
WP_TESTS_DIR=/path/to/wordpress-tests-lib \
WOOCOMMERCE_DIR=/path/to/woocommerce \
./scripts/test-wordpress-woocommerce-local-dev.sh
```

It resets the configured WordPress test database, then verifies WordPress page
creation and updates, WooCommerce product and order persistence, and InnoDB
commit and rollback behavior.

Run the broader WordPress-focused external MTR profile. It starts a fresh
server and datadir for every compatible batch and reruns a non-clean batch in
isolation. It preserves the summary and logs while discarding completed test
datadirs; set `MTR_PRESERVE_VARDIRS=1` when debugging a failure:

```sh
MTR_BATCH_SIZE=8 \
OUT_DIR=build/mtr-wordpress-verified \
./scripts/run-mtr-wordpress-broad.sh
```

The current stable profile has 191 upstream MariaDB MTR cases selected for
WordPress local development. It excludes one malformed-foreign-key recovery
fixture that can intermittently trap a Wasmtime InnoDB purge thread; normal
foreign-key behavior remains covered. Its 2026-07-10 final run passed all 191
with zero skips and zero failures. See
[`docs/wordpress-local-dev-compat-2026-07-10.md`](docs/wordpress-local-dev-compat-2026-07-10.md)
for scope and exclusions.

## Limitations

- Experimental only; this is not an official MariaDB or Wasmtime product.
- The documented server uses `--skip-grant-tables`; authentication and normal
  privilege management are not initialized. It creates only the routine,
  function, and startup metadata tables needed by the local-development runner.
- The WordPress Core suite and focused WooCommerce persistence suites pass,
  but WooCommerce's broad upstream suite also includes fixture-plugin,
  external-service, feature-flag, and current-PHP test-harness coverage that
  is not a server compatibility certification.
- InnoDB is enabled and verified for basic `CREATE TABLE`, `INSERT`, `SELECT`,
  and simple concurrent inserts, but this is still prototype storage support.
- File locking is currently a no-op under WASI, and the no-binlog transaction
  coordinator path uses MariaDB's dummy coordinator instead of the mmap-backed
  TC log.
- MTR exercises XA statement handling, but crash recovery, full two-phase
  commit recovery, replication, and production durability semantics have not
  been validated. The documented runner also uses `--debug-no-sync`.
- Basic MyISAM create/insert/select and temporary-table paths work in the
  current build, but InnoDB remains the documented path. Aria is compiled in
  but not meaningfully validated yet.
- Ordinary temporary tables are covered by the WordPress compatibility suite,
  but fixed temporary-tablespace exhaustion and forced-recovery restart paths
  remain outside the local-development support claim.
- Malformed SFORMAT input can currently abort the Wasm server thread. It is
  not exercised by WordPress, but remains unsupported.
- `idle_transaction_timeout` does not currently disconnect an idle transaction
  as MariaDB's upstream test expects.
- The full upstream `innodb.foreign_key` malformed-FK/restart/recovery fixture
  is excluded after an intermittent Wasmtime InnoDB purge-thread memory trap.
  Ordinary foreign-key create/alter/drop coverage passes, but malformed-FK
  recovery is unsupported.
- `DROP TABLE IF EXISTS` for nonexistent disk-engine tables can report a
  `.par` read-only error in this stripped build, so the benchmark uses unique
  table names instead of pre-dropping.
- The custom file shim does not yet track guest `chdir()`, so the run helper
  starts the process from the datadir.
- Binary logging and TLS are disabled in the documented command.
- Date and day locales via `lc_time_names` work from MariaDB's compiled-in
  locale data. Localized server error messages still require the unbundled
  `errmsg.sys` files, so `lc_messages` is not a supported configuration.
- Dynamic plugin loading, signals, OS-level durability, and higher-concurrency
  correctness still need deeper validation.
