# Durability validation, 2026-07-10

This note records what was tested after the local runner changed from an
unsynced default to strict InnoDB commit durability. It is not a production
database certification. It is a statement about a specific process-crash path
on one local Linux host.

## What changed

The old `run-server.sh` always passed `--debug-no-sync`. That made MariaDB
execute its normal transaction code while turning the actual sync operations
into no-ops. The Rust host already had a real sync bridge, so the fix is not
clever: strict mode stops disabling it.

`DURABILITY=strict` is now the default and passes
`--innodb-flush-log-at-trx-commit=1`. MariaDB's WASI port routes its
`fdatasync` and `fsync` calls to Rust `File::sync_data()` and `File::sync_all()`
on the real host descriptor. `DURABILITY=relaxed` is explicit and passes both
`--debug-no-sync` and `--innodb-flush-log-at-trx-commit=2` for disposable
benchmarks.

The port also used to return success without taking the InnoDB file lock.
That is not the same thing as row locking. InnoDB's internal lock manager,
transactions, deadlocks, and MVCC run in MariaDB's shared Wasm memory and
were already exercised by concurrent MTR and slap workloads. The missing lock
was the cross-process host file lock that stops a second server from using the
same tablespace. The current build does both of these:

- Routes InnoDB's whole-file `F_SETLK` call through `HostFiles` to the native
  host file descriptor.
- Makes `run-server.sh` hold a separate nonblocking `flock` lock at
  `RUN_DIR/.wasmtime-mariadb.lock` for the native runner lifetime.

The run-directory lock is the hard guard for the supported launch path. It
also avoids relying on subtle per-process `fcntl` semantics when a guest opens
the same file more than once.

## Process-crash acceptance test

Run this against a disposable directory:

```sh
OUT_DIR=build/durability-recovery ./scripts/test-durability-recovery.sh
```

The test starts strict MariaDB with host file tracing enabled, confirms the
InnoDB lock bridge, attempts a second server on the same `RUN_DIR`, writes 12
separate committed transactions, starts one uncommitted transaction, and sends
`SIGKILL` to the native Wasmtime process. It restarts the same data directory
on a fresh port and checks the rows.

The recorded result was:

```text
durability=strict
run_dir_lock=pass
innodb_file_lock_bridge=pass
host_syncs_before_commits=103
host_syncs_after_commits=116
committed_rows_after_sigkill=12
uncommitted_rows_after_sigkill=0
```

The restart log contained normal InnoDB crash recovery. The test proves that
acknowledged InnoDB transactions survived a killed host process and that the
uncommitted transaction was rolled back. It does not prove behavior after a
physical power loss, a broken drive cache, or a network filesystem failure.

## Performance measurements

Host: Linux x86_64, 8-core AMD Ryzen AI MAX+ 395, ext4. The client workload
starts a fresh local server each time; client time excludes server bootstrap.

### Four-client mixed workload

Command shape:

```sh
OUT_DIR=build/benchmark-60k-strict DURABILITY=strict \
  ./scripts/run-60k-transaction-workload.sh
OUT_DIR=build/benchmark-60k-relaxed DURABILITY=relaxed \
  ./scripts/run-60k-transaction-workload.sh
```

Each run requested 60,000 generated mixed statements over four clients,
committed every 20 statements, and recorded 64,012 `Query` commands with
3,004 `COMMIT`s.

| Mode | Client time | Logged command rate | Commit rate |
| --- | ---: | ---: | ---: |
| `strict` | 162.673 s | 393.5/s | 18.5/s |
| `relaxed` | 88.705 s | 721.6/s | 33.9/s |

Strict was 1.83x slower. That is the actual price of making thousands of
commits wait for the host sync path in this mixed concurrent workload.

### Commit-per-transaction workload

Command shape:

```sh
SLAP_CLIENTS=1 SLAP_QUERIES_PER_CLIENT=2000 SLAP_COMMIT_EVERY=1 \
  DURABILITY=strict ./scripts/run-60k-transaction-workload.sh
```

Each mode logged 5,006 command statements and 2,001 explicit commits:

| Mode | Client time | Explicit commits/s |
| --- | ---: | ---: |
| `strict` | 3.008 s | 665.2/s |
| `relaxed` | 1.170 s | 1,710.3/s |

This is a local host measurement, not a universal number. SSD, filesystem,
kernel writeback policy, background load, and MariaDB version all matter.

## Remaining boundary

`COM_SHUTDOWN` does not reliably tear down the Wasmtime-hosted server yet.
The foreground helper's `Ctrl-C` path stops the native host rather than asking
MariaDB for a clean checkpoint. Strict mode has the crash-recovery evidence
above; it is not a graceful-shutdown API. A Studio integration should manage
server lifetime with that distinction in mind and should not expose the data
directory to another process.
