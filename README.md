# wasmtime-mariadb

Experimental harness for running a patched MariaDB 11.4 server WebAssembly
module inside a native Wasmtime host executable.

This is the MariaDB counterpart to `adamziel/wasmtime-mysql`. It is not an
official MariaDB port. The current build can start `mariadbd` in Wasmtime,
listen on TCP, accept normal MySQL/MariaDB clients, and run basic SQL against
`MEMORY` tables.

## Requirements

- Rust toolchain
- Docker, for the WASI SDK build scripts
- Optional: a local `mysql` or `mariadb` CLI for manual connections
- Python 3, only for the included dependency-free benchmark client

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
connection has no password. Use `MEMORY` tables for the working SQL path:

```sql
CREATE DATABASE demo;
CREATE TABLE demo.t (id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=MEMORY;
INSERT INTO demo.t VALUES (1, 'hello from wasmtime');
SELECT * FROM demo.t;
```

The included Python client can also verify connectivity without external
database client libraries:

```sh
python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 5 --batch-size 5
```

## Benchmark

`scripts/bench-tcp.py` opens concurrent TCP connections, creates one uniquely
named `MEMORY` table per client in the `bench` schema, inserts rows in batches,
and verifies `COUNT(*)`.

```sh
python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 2000 --batch-size 100
python3 scripts/bench-tcp.py --port 3307 --clients 4 --rows 500 --batch-size 100
```

Recent numbers from this workspace on Linux x86_64, using the release runner
and the MariaDB 11.4.12 WASI module. The server was run on port `3317` because
`3307` was briefly unavailable from a previous test.

| Clients | Rows/client | Inserted rows | Counted rows | Elapsed | Rows/sec |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 5 | 5 | 0.001 s | 4,376 |
| 1 | 2,000 | 2,000 | 2,000 | 0.005 s | 400,182 |
| 4 | 500 | 2,000 | 2,000 | 0.004 s | 537,227 |

These numbers are a TCP/protocol smoke benchmark over in-memory tables, not a
durability or storage-engine benchmark.

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

## Limitations

- Experimental only; this is not an official MariaDB or Wasmtime product.
- The documented server uses `--skip-grant-tables`; authentication and system
  privilege tables are not initialized.
- `MEMORY` tables are the currently verified SQL path. Data is not persistent.
- InnoDB is disabled in the current WASI build.
- MyISAM and Aria are compiled in and can create table files, but inserts
  currently fail with `Incorrect file format` in local testing.
- `DROP TABLE IF EXISTS` for nonexistent disk-engine tables can report a
  `.par` read-only error in this stripped build, so the benchmark uses unique
  table names instead of pre-dropping.
- The custom file shim does not yet track guest `chdir()`, so the run helper
  starts the process from the datadir.
- Binary logging and TLS are disabled in the documented command.
- Dynamic plugin loading, signals, OS-level durability, and higher-concurrency
  correctness still need deeper validation.
