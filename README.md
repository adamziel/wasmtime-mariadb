# wasmtime-mariadb

This is an experimental local-development runner for MariaDB 11.4. It is not
MariaDB running directly on the host. It is a patched `mariadbd` WebAssembly
module running inside a Wasmtime host. The host provides the parts WASI does
not: the file calls MariaDB needs, TCP sockets, shared memory, and host threads.

It is useful when the target is a local WordPress-style development database.
It is not a production database server. Do not point it at a production data
directory and then act surprised when the unsupported pieces break.

## Support Boundary

The documented path is deliberately narrow:

- One local server bound to `127.0.0.1`.
- Linux x86_64, macOS Apple Silicon, and Windows x86_64 hosts.
- InnoDB tables, normal DDL/DML, WordPress schema changes, and ordinary local
  development transactions.
- Release archives for Linux x86_64 and macOS Apple Silicon; the next release
  also adds Windows x86_64. CI exercises the real server on all three hosts.
- Root access with `--skip-grant-tables`; there is no authentication setup.

The release validates strict InnoDB process-crash recovery on the tested local
path. It does not claim production power-loss durability, replication, binary
logging, TLS, backup tooling, plugins, performance schema, or normal privilege
management. Those are different projects, not missing README flags.

## Requirements

| Method | What it needs |
| --- | --- |
| Run a release binary | Linux x86_64, macOS Apple Silicon, or Windows x86_64 |
| Connect or run smoke tests | `mysql` or `mariadb` client |
| TCP benchmark | Python 3 |
| 60k transaction workload | `mariadb-admin` plus `mariadb-slap` or `mysqlslap` |
| Crash-recovery acceptance test | `mysql`/`mariadb` plus `mysqladmin`/`mariadb-admin` |
| Build the Wasm server | Docker, Rust, and enough disk for the MariaDB/OpenSSL builds |
| Run MTR profiles | MariaDB source tree, MariaDB test/client tools, a C++ compiler, Python 3 |
| Run WordPress/WooCommerce integration | PHP, WordPress test library, WooCommerce checkout, PHPUnit dependencies |

On an Apple Silicon Mac, this installs a normal client:

```sh
brew install mysql-client
```

The 60k workload uses MariaDB client utilities. On macOS, install them with:

```sh
brew install mariadb
```

## Release Methods

### Install the latest release

The installer chooses the right release archive, downloads `SHA256SUMS`,
verifies the archive, and extracts it. It does not start MariaDB or modify an
existing extracted release directory.

```sh
curl -fsSL https://raw.githubusercontent.com/adamziel/wasmtime-mariadb/main/scripts/install-release.sh \
  | bash
```

It supports Linux x86_64 and macOS Apple Silicon. Intel macOS is not a release
target. Build from source if that is your machine.

### Install on Windows

In PowerShell, the Windows installer performs the same checksum verification
and extraction without starting the server:

```powershell
irm https://raw.githubusercontent.com/adamziel/wasmtime-mariadb/main/scripts/install-release.ps1 | iex
```

Windows x86_64 archives are produced by the next release. The current
`v0.1.11` release predates that archive.

### Install a specific release

Use this when reproducibility matters more than whatever `latest` happens to
mean tomorrow:

```sh
curl -fsSL https://raw.githubusercontent.com/adamziel/wasmtime-mariadb/main/scripts/install-release.sh \
  | bash -s -- --version v0.1.11
```

### Run the extracted release

The installer prints this command. Run it separately, in a real terminal:

```sh
cd wasmtime-mariadb-v0.1.11-macos-aarch64
PORT=3307 ./scripts/run-server.sh
```

Use `wasmtime-mariadb-v0.1.11-linux-x86_64` on Linux. Unix release archives
contain the runner, its supervisor, server helpers, smoke tests, the Python
benchmark, the 60k workload, the durability-recovery test, and validation
docs. The Windows ZIP contains the runner, supervisor, PowerShell helpers,
lifecycle test, and validation docs. Neither contains the MariaDB source tree
or the MTR harness.

### macOS quarantine

The binary is unsigned. macOS may quarantine it. Remove the quarantine bit
from the extracted directory before starting it:

```sh
xattr -dr com.apple.quarantine wasmtime-mariadb-v0.1.11-macos-aarch64
```

## Run Methods

### Standard local server

From a source checkout or extracted release directory:

```sh
RUN_DIR="$PWD/build/run" PORT=3307 ./scripts/run-server.sh
```

The server runs in the foreground. The helper starts a compiled supervisor,
which owns the data-directory lock, metadata, child Wasmtime process, and
signal handling. It streams `RUN_DIR/mariadbd-runtime.err`, so first-start
InnoDB initialization is visible instead of looking stuck. It can take up to
a minute. `Ctrl-C`, `SIGTERM`, and `SIGHUP` terminate the child as a process
crash; strict mode is tested to recover committed InnoDB work after that path.

On Windows PowerShell, use the matching entry point:

```powershell
$env:RUN_DIR = "$PWD\build\run"
$env:PORT = '3307'
.\scripts\run-server.ps1
```

For a controlled stop from another terminal, use the stop command. It asks
MariaDB to shut down, waits for the Wasmtime host, then terminates only a host
that remains stuck. This is bounded cleanup, not a promise that
`COM_SHUTDOWN` is perfect in this port.

```sh
RUN_DIR="$PWD/build/run" ./scripts/stop-server.sh
```

```powershell
.\scripts\stop-server.ps1 -RunDir "$PWD\build\run"
```

Do not use `Ctrl-C` as an initialization retry loop. An interruption before
readiness leaves the run manifest in `initializing` state and the next start
refuses it. For disposable data, remove only that run directory and start
again. The endpoint record at `RUN_DIR/.wasmtime-mariadb-endpoint.json` records
the selected host, port, child PID, and `starting`/`ready`/`stopped` state.

### Durability and data-directory locking

`DURABILITY=strict` is the default. It sets
`innodb_flush_log_at_trx_commit=1` and leaves MariaDB's sync calls enabled.
The WASI file bridge maps InnoDB `fdatasync`/`fsync` calls to the host file
descriptor's `sync_data`/`sync_all` calls. This is the only mode for a local
site whose data you intend to keep.

```sh
DURABILITY=strict RUN_DIR="$PWD/build/site-db" PORT=3307 ./scripts/run-server.sh
```

`DURABILITY=relaxed` is for disposable benchmarks only. It restores
`--debug-no-sync` and changes InnoDB to flush its log every second. It is
faster because it deliberately weakens crash durability.

The supervisor holds `RUN_DIR/.wasmtime-mariadb-supervisor.lock` before it
reads a manifest or starts MariaDB. The child runner also holds
`RUN_DIR/.wasmtime-mariadb.lock` for its lifetime. Starting a second helper
against the same `RUN_DIR` therefore fails before MariaDB opens data files.
InnoDB also acquires host file locks on its files. Do not bypass the helper
with a raw runner invocation unless you accept the loss of these lifecycle and
compatibility checks.

The supervisor writes `RUN_DIR/.wasmtime-mariadb-run.json` only for a
compatible MariaDB 11.4 local directory. A data directory with no manifest is
rejected by default. Set `ADOPT_EXISTING_DATA=1` only after confirming that a
complete existing directory belongs to this runner. `PORT=auto` asks the
supervisor for an available loopback port and publishes it in the endpoint
record.

The checked process-crash contract is narrower than marketing-grade
durability: acknowledged InnoDB commits survived a `SIGKILL` and restart on
the tested host filesystem. A physical power cut, a lying storage controller,
and network filesystems are not covered by that test.

Run the acceptance test with a disposable directory:

```sh
OUT_DIR=build/durability-recovery ./scripts/test-durability-recovery.sh
```

### Different port or data directory

```sh
RUN_DIR="$PWD/build/dev-db" PORT=3317 ./scripts/run-server.sh
```

The data persists in `RUN_DIR/data`. Delete that directory only when you
actually want a fresh database.

On a default macOS filesystem, MariaDB reports
`lower_case_table_names=2`; that is expected because APFS is usually
case-insensitive. A `failed to retrieve the MAC address` warning comes from the
WASI host and only affects MariaDB's unused replication server identifier.
Neither warning prevents local TCP/InnoDB use.

### Pass MariaDB options

Arguments after `run-server.sh` go to `mariadbd`:

```sh
RUN_DIR="$PWD/build/trace-db" PORT=3307 \
  ./scripts/run-server.sh --general-log --general-log-file=/tmp/general.log
```

Do not override the helper's datadir, tmpdir, port, system-table bootstrap, or
durability settings unless you understand the host/guest path mapping described
below. In strict mode, the helper applies its commit-flush setting after these
arguments and rejects `--debug-no-sync`.

### Host-runner options

`BIN` selects a Wasmtime runner binary. `RUNNER_ARGS` supplies Wasmtime-host
arguments such as extra `--preopen` or `--env` values. It is split on shell
whitespace, so it is not a quoting mechanism. Leave it alone for normal use.

`SKIP_GRANT_TABLES=0` and `SKIP_SYSTEM_TABLES_INIT=1` exist for the MTR
harness. They are not an authentication feature and not a normal startup
mode.

## Connect Methods

The documented server listens on loopback and starts with `--skip-grant-tables`.
Root has no password. That is convenient for a local sandbox and unacceptable
for anything exposed to a network.

### Oracle MySQL client

```sh
mysql --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl-mode=DISABLED
```

### MariaDB client

```sh
mariadb --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl=0
```

### Homebrew client outside `PATH`

```sh
/opt/homebrew/opt/mysql-client/bin/mysql \
  --protocol=TCP -h127.0.0.1 -P3307 -uroot --ssl-mode=DISABLED
```

### Minimal SQL check

```sql
CREATE DATABASE demo;
CREATE TABLE demo.t (id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=InnoDB;
INSERT INTO demo.t VALUES (1, 'hello from wasmtime');
SELECT * FROM demo.t;
```

## Smoke-Test Methods

These tests require a running server unless stated otherwise.

| Method | Command | What it proves |
| --- | --- | --- |
| MySQL client smoke | `PORT=3307 ./scripts/test-mysql-client.sh` | TCP connection, InnoDB create/insert/read, `information_schema` engine lookup |
| WordPress SQL smoke | `PORT=3307 ./scripts/test-wordpress-local-dev.sh` | WordPress-shaped schema, utf8mb4, LONGTEXT, indexes, transactions, routines, locale data |
| Raw protocol benchmark smoke | `python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 5 --batch-size 5` | Python implementation of the MySQL wire protocol can connect and issue SQL |
| Supervisor lifecycle | `python3 scripts/test-supervisor-lifecycle.py` | Startup metadata, controlled-stop recovery, Unix signal cleanup, and Windows runner-crash recovery |
| WordPress/WooCommerce integration | `WP_TESTS_DIR=/path/to/wordpress-tests-lib WOOCOMMERCE_DIR=/path/to/woocommerce ./scripts/test-wordpress-woocommerce-local-dev.sh` | Real WordPress/WooCommerce persistence against a configured upstream test environment |

Set `HOST`, `PORT`, and `MYSQL` to override the smoke-test target and client.
For example:

```sh
MYSQL=/opt/homebrew/opt/mysql-client/bin/mysql PORT=3307 \
  ./scripts/test-wordpress-local-dev.sh
```

The WordPress/WooCommerce integration method is source-checkout-only. It does
not install WordPress, WooCommerce, PHP, or PHPUnit for you.

## Benchmark Methods

### TCP insert benchmark

`scripts/bench-tcp.py` is dependency-free. It opens concurrent TCP
connections, creates one uniquely named table per client, inserts rows in
batches, and verifies `COUNT(*)`.

```sh
python3 scripts/bench-tcp.py --port 3307 --clients 1 --rows 2000 --batch-size 100
python3 scripts/bench-tcp.py --port 3307 --clients 4 --rows 500 --batch-size 100
```

Useful options:

| Option | Default | Meaning |
| --- | ---: | --- |
| `--host` | `127.0.0.1` | Server address |
| `--port` | `3307` | Server port |
| `--database` | `bench` | Database created if absent |
| `--clients` | `8` | Concurrent client threads |
| `--rows` | `500` | Rows per client |
| `--batch-size` | `50` | Rows per `INSERT` |
| `--engine` | `InnoDB` | Table engine; `MEMORY` is only a smoke comparison |

These are protocol and InnoDB smoke measurements, not a durability benchmark.
They are sensitive to host page cache and batch size. Use the measured
transaction workload below when commit durability matters.

Earlier Linux x86_64 smoke results, kept only as a rough protocol baseline:

| Clients | Rows/client | Inserted rows | Counted rows | Elapsed | Rows/sec |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 5 | 5 | 0.002 s | 2,900 |
| 1 | 2,000 | 2,000 | 2,000 | 0.009 s | 215,185 |
| 4 | 500 | 2,000 | 2,000 | 0.006 s | 322,836 |

### Measured 60k transaction workload

This is the workload with an actual query count. It starts its own ephemeral
server, enables the general log, runs four clients with 15,000 generated
mixed read/write statements each, disables autocommit, and commits every 20
statements.

```sh
OUT_DIR=build/slap-60k-transaction \
  ./scripts/run-60k-transaction-workload.sh
```

It requires `mariadb-admin` and `mariadb-slap` or `mysqlslap`. It does not use
an already running server. The script exits nonzero if the general log contains
fewer than the requested query count.

Configuration is through environment variables:

| Variable | Default |
| --- | ---: |
| `PORT` | `3331` |
| `SLAP_CLIENTS` | `4` |
| `SLAP_QUERIES_PER_CLIENT` | `15000` |
| `SLAP_COMMIT_EVERY` | `20` |
| `SLAP_SEED_ROWS` | `1000` |
| `DURABILITY` | `strict` |
| `MARIADB_SLAP` | auto-detect `mariadb-slap`, then `mysqlslap` |

Current Linux x86_64 workspace measurements used an 8-core AMD Ryzen AI MAX+
395 host on ext4. Each completed run recorded 64,012 `Query` commands,
including 3,004 `COMMIT`s:

| Workload | Durability | Client time | Relative to relaxed |
| --- | --- | ---: | ---: |
| 4 clients, 60k mixed statements, commit every 20 | `strict` | 162.673 s | 1.83x |
| 4 clients, 60k mixed statements, commit every 20 | `relaxed` | 88.705 s | 1.00x |
| 1 client, 2k mixed statements, commit every statement (2,001 commits) | `strict` | 3.008 s | 2.57x |
| 1 client, 2k mixed statements, commit every statement (2,001 commits) | `relaxed` | 1.170 s | 1.00x |

`relaxed` is not a valid comparison point for retained local data. It exists
to show the sync cost, not to justify turning sync off. The complete process
crash test and benchmark notes are in
[`docs/durability-validation-2026-07-10.md`](docs/durability-validation-2026-07-10.md).

## Build Methods

This is the full source path. It builds a WASI MariaDB module first, then
embeds that module into the Rust Wasmtime runner.

```sh
./scripts/fetch-mariadb-source.sh
./scripts/probe-mariadb-wasi-port.sh
./scripts/build-single.sh build/mariadb-wasi-port/build/sql/mariadbd
```

The result is:

```text
target/release/wasmtime-mariadb
target/release/wasmtime-mariadb-supervisor
```

`probe-mariadb-wasi-port.sh` is the expensive step. It copies a pinned
MariaDB source snapshot, applies the WASI port patches, builds the required
host import tools, and runs a WASI SDK Docker image to build `mariadbd`.
It automatically fetches/builds the WASI OpenSSL dependency if needed.

The OpenSSL methods are exposed for maintenance, not normal use:

```sh
./scripts/fetch-openssl-source.sh
./scripts/build-openssl-wasi.sh
```

Do not run `cargo build --release` without `MARIADBD_WASM` after a clean
checkout. `build.rs` refuses to create a normal runner without a real MariaDB
Wasm module. The only exception is the deliberately fake development fixture:

```sh
cargo run --bin wasmtime-mariadb --features dev-fixture
```

## Regression-Test Methods

### Host-only fixture checks

```sh
./scripts/verify-dev-fixture.sh
cargo fmt --check
cargo check --features dev-fixture
```

These verify the Rust host plumbing. They do not prove that MariaDB runs.

### Strict crash recovery

```sh
OUT_DIR=build/durability-recovery ./scripts/test-durability-recovery.sh
```

This starts a real strict server, rejects a second server on the same data
directory, verifies host file-lock and sync calls, kills the Wasmtime host, and
checks committed-versus-uncommitted InnoDB rows after restart. It is a
process-crash test, not a power-loss test.

### Direct external MTR

MTR means MariaDB Test Run, the upstream integration/regression harness. It
is source-checkout-only because it needs the MariaDB test tree and MariaDB
test tools. The entry point is:

```sh
OUT_DIR=build/mtr-extern-smoke ./scripts/run-mtr-extern-smoke.sh
```

Pass explicit test names to avoid the small default smoke selection:

```sh
MTR_BATCH_SIZE=4 \
  ./scripts/run-mtr-extern-smoke.sh main.commit innodb.innodb-isolation
```

The runner starts the Wasmtime server, creates loopback TCP and Unix-socket
proxies for MTR, restarts the server when MTR requests it, and records a
per-test TSV result. A skip is a non-pass.

`main.func_in` builds a disk-backed Aria temporary table larger than 140 MiB.
Use a normal filesystem for `OUT_DIR`; a quota-limited `/tmp` can fail that
case even though the server and test are correct.

Key controls:

| Variable | Default | Use |
| --- | ---: | --- |
| `MTR_DIR` | pinned source tree or `/usr/share/mariadb-test` | MariaDB test tree |
| `MTR_BATCH_SIZE` | `1` | Compatible tests per server/datadir batch |
| `OUT_DIR` | `build/mtr-extern-smoke` | Logs and `summary.tsv` output |
| `MTR_PRESERVE_VARDIRS` | `1` | Set `0` to delete completed datadirs |
| `MTR_RESTART_WITH_GRANTS` | `1` | Harness mode; not a security switch |

### Transaction correctness profile

```sh
MTR_BATCH_SIZE=4 \
OUT_DIR=build/mtr-transaction-verified \
./scripts/run-mtr-transaction-nuances.sh
```

This selects 57 upstream cases for commits, rollbacks, DDL transaction
boundaries, snapshots, locks, deadlocks, XA statements, savepoints,
`NOWAIT`/`SKIP LOCKED`, auto-increment locking, and concurrency. The
validated result is 57/57 pass, zero skip, zero fail.

### WordPress-focused MTR profile

```sh
MTR_BATCH_SIZE=8 \
OUT_DIR=build/mtr-wordpress-verified \
./scripts/run-mtr-wordpress-broad.sh
```

This selects 191 MariaDB cases relevant to normal WordPress local development.
The validated result is 191/191 pass, zero skip, zero fail. The old
`run-mtr-wordpress-compat.sh` name is an alias for this script.

The test counts are not query counts. MTR tests include loops, concurrent
connections, restarts, routines, and test-control commands. Use the 60k
workload when you need a measured SQL command count.

## Release-Maintenance Methods

These are maintainer operations. They are not required to run the database.

| Method | Command | Result |
| --- | --- | --- |
| Package Linux/macOS release | `./scripts/package-release.sh vX.Y.Z linux-x86_64 target/release/wasmtime-mariadb` | Tarball with runner and supervisor |
| Package Windows release | `./scripts/package-release.ps1 vX.Y.Z windows-x86_64 target/release/wasmtime-mariadb.exe` | ZIP with runner and supervisor |
| Build release binaries locally | `MARIADBD_WASM=/path/to/mariadbd cargo build --release --bin wasmtime-mariadb --bin wasmtime-mariadb-supervisor` | Runner and supervisor with embedded Wasm |
| Build release assets in CI | `gh workflow run release-assets.yml --ref main -f tag=vX.Y.Z` | Linux, macOS, and Windows archives, each lifecycle-tested before upload |
| Install a Unix release | `scripts/install-release.sh --version vX.Y.Z` | Verified extraction and a printed run command |
| Install a Windows release | `scripts/install-release.ps1 -Version vX.Y.Z` | Verified extraction and a printed PowerShell run command |

The release workflow expects a `mariadbd-wasm.tar.gz` asset on the draft
release before it runs. It builds the runner and supervisor per target; the
MariaDB Wasm module is the shared payload embedded into each runner. A final
job generates `SHA256SUMS` after all three platform archives exist. Do not
publish a release before that check works.

## Internal Helpers

Not every file in `scripts/` is a public command:

| File | Role |
| --- | --- |
| `mariadb-system-tables.sql` | Minimal bootstrap metadata loaded at server startup |
| `mtr-extern-init.sql` | MTR-only database bootstrap |
| `tcp-port-proxy.py` | Stable TCP endpoint while MTR restarts the backend |
| `tcp-unix-proxy.py` | MTR Unix-socket compatibility over TCP |
| `run-mtr-extern-smoke.sh` | Shared MTR harness behind the named profiles |
| `fetch-*.sh` and `build-openssl-wasi.sh` | Build dependencies used automatically by the probe script |

Run the named top-level methods above. Calling a proxy or an MTR init file by
hand is debugging, not a supported deployment method.

## Limitations

- This is experimental. It is not an official MariaDB or Wasmtime product.
- The normal runner uses `--skip-grant-tables`. There is no real user/password
  setup or privilege-table support.
- It binds loopback in the documented command. Do not expose it to a network.
- The normal helper has supervisor and runner run-directory locks, and InnoDB
  now calls host file locks. MyISAM/Aria-style external table locking is still disabled
  with `--skip-external-locking`; this runner claims InnoDB local development,
  not shared non-InnoDB data directories.
- Strict mode has a process-crash recovery test, not a physical power-loss
  certification. Storage-controller behavior, network filesystems, prepared
  XA recovery, replication, binlog, backup, and production durability remain
  unvalidated.
- Windows cannot flush directory handles through this host API. Strict mode
  still syncs data files, but directory sync is a no-op there; do not infer
  power-loss durability for freshly created tables or DDL metadata.
- MariaDB `COM_SHUTDOWN` does not reliably terminate the Wasmtime host yet.
  `stop-server` gives it a bounded grace period before terminating the child;
  do not treat it as a clean checkpoint/shutdown API.
- A forced supervisor crash can leave its child runner alive. The endpoint file
  records that PID for diagnosis; use a normal signal or `stop-server` whenever
  possible instead of killing the supervisor.
- TLS, dynamic plugins, performance schema, guest OS signals, and normal auth
  are disabled or unsupported in the documented runtime.
- Windows supports the local TCP path, not the Unix-socket MTR harness.
- `idle_transaction_timeout` does not disconnect an idle transaction as the
  upstream test expects.
- The full malformed-FK/restart/recovery `innodb.foreign_key` fixture can
  trap a Wasmtime InnoDB purge thread. A non-routine worker trap now fails the
  host instead of letting MariaDB continue with shared memory in doubt, but
  that recovery path remains unsupported.
- `SHOW ENGINE INNODB STATUS` is a minimal WASI fallback, not full monitor
  output. The detailed `innodb.gap_locks` diagnostic assertion does not pass.
- Malformed SFORMAT input can abort a Wasm server thread.
- `DROP TABLE IF EXISTS` for a nonexistent disk-engine table can report a
  `.par` read-only error in this stripped build.
- The custom file shim does not track guest `chdir()`. The run helper works
  around that by starting the host process from the data directory.
- `lc_time_names` uses compiled-in locale data; localized server error
  messages need unbundled `errmsg.sys` files and are unsupported.

## Architecture

This is the whole arrangement. The Wasmtime executable is a host. MariaDB is the
guest. Keep those two layers separate when debugging.

```text
 MariaDB source + WASI patches
              |
              v
 patched mariadbd WebAssembly module
              |
              | build.rs embeds the module bytes
              v
 run-server / run-server.ps1
              |
              v
 wasmtime-mariadb-supervisor
              |
              +-- private run directory and compatibility manifest
              +-- endpoint record, lifecycle lock, Ctrl-C/TERM control
              +-- controlled shutdown, then bounded child termination
              |
              v
 Wasmtime wasmtime-mariadb executable
              |
              +-- Wasmtime engine: threads, exceptions, shared memory
              +-- WASI Preview 1: args, env, stdio, preopened directories
              +-- HostFiles: POSIX-like file calls missing from plain WASI
              +-- HostSockets: host TCP sockets exposed as Wasm imports
              +-- Host thread spawn for MariaDB WASI pthreads
              |
              v
        embedded mariadbd _start
              |
              +-- InnoDB files under guest /tmp/data
              +-- TCP listener on guest 127.0.0.1:PORT
              v
 normal mysql/mariadb client over host loopback TCP
```

### Build path

`probe-mariadb-wasi-port.sh` takes the pinned MariaDB source, copies the WASI
shim headers and C source, applies targeted source rewrites, and builds a
WASI `mariadbd` module in Docker. `build-single.sh` passes that module through
`MARIADBD_WASM` to Cargo. `build.rs` checks that it is real Wasm and embeds it
with `include_bytes!`. The release host binary therefore has no runtime path
to a separate `.wasm` file.

### Runtime path

`run-server.sh` and `run-server.ps1` are deliberately thin wrappers around the
supervisor. The supervisor creates `RUN_DIR/data` and `RUN_DIR/tmp`, takes its
own lifecycle lock before it reads the manifest, copies the minimal
system-table bootstrap, writes an endpoint record, then starts the Wasmtime
host from `RUN_DIR/data`. It preopens the host `RUN_DIR` as guest `/tmp`.
MariaDB therefore sees:

```text
guest /tmp/data                    host RUN_DIR/data
guest /tmp/tmp                     host RUN_DIR/tmp
guest /tmp/mariadb-system-tables.sql  host RUN_DIR/mariadb-system-tables.sql
```

MariaDB calls into the WASI socket shim. That shim imports functions from the
Rust `HostSockets` module. `HostSockets` owns real host socket file descriptors
and translates the guest address/socket conventions to the host. The MySQL
wire protocol is not reimplemented by Rust; MariaDB still speaks it. Rust only
bridges the missing operating-system interfaces.

`HostFiles` does the same for MariaDB file operations. It resolves paths only
through configured preopens and keeps a separate guest file-descriptor table.
The file and socket shims are why this is a host plus a Wasm module, not a
random command line wrapped around `wasmtime`.

InnoDB row locks, transaction locks, MVCC, deadlock detection, and isolation
live inside MariaDB's shared guest memory. They were always real and are what
the concurrent MTR and 60k workloads exercised. That is unrelated to OS file
locking: file locks stop two server *processes* from opening the same data
directory. The old WASI port returned success from that file-lock call. The
current port routes InnoDB's whole-file lock through `HostFiles` to the host.
The supervisor lock closes the startup window before the runner acquires its
separate lifetime lock. Those layers cover different failures.

In strict mode, the same file bridge routes InnoDB `fdatasync` and `fsync`
calls to the host filesystem. In relaxed mode, MariaDB's `--debug-no-sync`
deliberately bypasses that work. This is a configuration choice, not a claim
that Wasm has magically become a database filesystem.

### Thread and memory model

MariaDB needs threads. The host enables Wasmtime shared memory, wasm threads,
and wasm exceptions. A guest `wasi.thread-spawn` import starts a Rust host
thread, creates a fresh Wasmtime store, reconnects the same shared Wasm memory,
and invokes `wasi_thread_start`. File and socket tables are shared behind
mutexes. This is enough for the tested local-development paths. It does not
make the system magically equivalent to directly hosted MariaDB under failure
or heavy contention.

### WASI Preview 2 status

The guest is a Preview 1 core module with WASI threads. It is not a Preview 2
component. That distinction matters: the guest imports a shared Wasm memory
and starts MariaDB pthreads by re-instantiating that module in separate
Wasmtime stores.

Wasmtime's Preview 1 adapter is implemented on top of its Preview 2 host
implementation, so ordinary Preview 1 WASI operations already use that host
layer internally. It does not make file descriptors shareable across the
per-thread stores, and it does not provide a component-thread implementation
for this module. Replacing `HostFiles`, `HostSockets`, or the thread launcher
with a component today breaks InnoDB or DDL. The evidence, failed experiments,
and conditions for a real migration are in
[`docs/wasi-preview2-boundary-2026-07-12.md`](docs/wasi-preview2-boundary-2026-07-12.md).

### Test and release path

MTR does not run inside the release binary. The external harness starts the
same runner, fronts it with stable TCP/Unix proxies, watches MTR restart
requests, and preserves per-test results. The release workflow downloads the
same `mariadbd-wasm` payload, embeds it into Linux, macOS, and Windows runners,
runs platform lifecycle acceptance plus Unix TCP/MySQL/WordPress smokes,
packages the assets, and publishes checksums. That is the chain. There is no
hidden daemon, container, or database service behind it.
