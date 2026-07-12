# WASI Preview 2 boundary, 2026-07-12

## Result

This MariaDB port cannot become a Preview 2 component today without deleting
working database behavior. That is not a naming problem. MariaDB is a real
shared-memory, multi-threaded server. The current Wasmtime component path does
not carry that execution model end to end.

The guest remains a `wasm32-wasip1-threads` core module. It imports shared
memory, `wasi.thread-spawn`, the file bridge, and the socket bridge. Each guest
pthread gets a fresh Wasmtime store and a fresh guest instance attached to the
same shared Wasm memory.

## What already uses Preview 2

Wasmtime's `wasmtime-wasi` Preview 1 adapter is implemented on top of its
Preview 2 support. Ordinary Preview 1 arguments, environment variables,
stdio, clocks, randomness, and preopened-directory calls therefore already
reach Wasmtime's Preview 2 host implementation internally.

That is useful implementation reuse. It is not a guest component migration,
and it does not solve the per-thread descriptor problem below.

## The blocking facts

### MariaDB needs shared-memory pthreads

The module imports one shared memory and starts a guest thread by calling
`wasi.thread-spawn`. The host creates another store, instantiates the module
again with that same memory, and calls `wasi_thread_start`.

The current component translator rejects the relevant thread intrinsics. In
Wasmtime 46.0.1, its component translation path explicitly rejects
`ThreadSpawnRef`, `ThreadSpawnIndirect`, and
`ThreadAvailableParallelism` as an `unsupported intrinsic`. The P2 pthread
support shipped by the current WASI toolchain is stub-level support, not the
shared-memory execution model MariaDB uses.

The toolchain probe is concrete. WASI SDK 33 can produce and Wasmtime can run
an ordinary `wasm32-wasip2` command component. Adding `-pthread` to an
otherwise minimal program cannot link a shared-memory module because the P2
TLS startup object was not built with the required atomics and bulk-memory
features. Inspecting the SDK's P2 `pthread_create` object shows the
single-threaded fallback: it immediately returns error 58 (`ENOTSUP`). It is
not a latent implementation of MariaDB's pthread model.

The component encoder has a separate hard stop. After temporary adapters
satisfied every MariaDB-specific import, `wasm-tools component new` rejected
the remaining `env::memory` import because a component's main core module
cannot import memory. MariaDB's memory is specifically imported and shared so
fresh stores can run its guest threads. Hiding that memory inside one
component instance would prevent the host from attaching it to the fresh
stores that the current thread ABI requires.

`wasmtime-wasi-threads` does not change this result. It also creates a store
per guest thread, requires cloneable store data, and exits the host process on
a thread trap. It cannot clone a `WasiP1Ctx` with its descriptor table, and it
is not a suitable replacement for this runner.

### Preview 1 descriptors are per store

`WasiP1Ctx` owns a `ResourceTable`. A new guest thread means a new store and a
new `WasiP1Ctx`, so an ordinary WASI file descriptor opened in one thread is
unknown to another. MariaDB intentionally passes open data, log, and DDL file
descriptors between threads.

This was tested, not guessed:

- A simple standard-WASI probe successfully performed `open`, `pread`,
  `pwrite`, `fstat`, `ftruncate`, `fdatasync`, `fsync`, and exclusive create.
- Replacing the shared `HostFiles` table with ordinary Preview 1 descriptors
  made clean InnoDB startup fail on `pwrite("ib_logfile0")` with bad file
  descriptor.
- Keeping the bridge only for InnoDB files got farther, then DDL failed while
  writing `ddl_recovery.log`, again with bad file descriptor.
- Removing only the bridge's `stat` handling made MTR `main.sp` fail because
  the standard path does not reproduce the runner's relative-path behavior.

The bridge is therefore required for shared descriptor lifetime and path
resolution. It is not a convenience wrapper around facilities that work here.

### Sockets have the same store boundary

MariaDB's listener, accepted connections, and poll state also survive across
guest threads. A conventional Preview 2 socket resource in one store cannot
be dropped into another store's Preview 1 descriptor table. `HostSockets`
continues to supply that cross-thread handle ownership and the MySQL TCP
listener.

## What this branch keeps and fixes

The runner keeps the required host bridge:

| Area | Why it remains |
| --- | --- |
| `HostFiles` | Shared file descriptors, host sync, host file locks, and preopen-only path resolution across guest threads |
| `HostSockets` | Shared listener and connection handles across guest threads |
| `wasi.thread-spawn` host function | Shared-memory MariaDB pthread startup |
| Imported shared memory | MariaDB lock manager, transactions, and thread state |

Two changes are valid independently of the migration boundary:

- The source-build script had a malformed Perl delimiter in an MTR expected
  result rewrite. A clean build stopped before compilation. The rewrite now
  uses a delimiter that matches the literal slash in `delete/update`.
- Host `EDQUOT` now maps to the guest's `ENOSPC` error. A quota failure should
  say disk space is unavailable, not masquerade as MariaDB error 122.
- `guest_abi.rs` owns the repeated raw-pointer copies, bounds checks, and
  Preview 1 errno conversion used by both bridges. It removes 256 duplicate
  runner lines (2,752 to 2,496) without touching the required cross-thread
  descriptor ownership.

## Validation

The retained bridge passed the following on this Linux x86_64 workspace:

- Fresh MariaDB WASI source build after the Perl rewrite.
- `cargo fmt --check`, `cargo clippy --all-targets --features dev-fixture -- -D warnings`,
  `cargo test --features dev-fixture`, and the development fixture verification.
- Strict durability recovery: run-directory lock, InnoDB host file lock,
  host sync calls, 12 committed rows after `SIGKILL`, and one uncommitted row
  rolled back after restart.
- 57/57 transaction-nuance MTR cases.
- 191/191 WordPress-focused MTR cases when the MTR `OUT_DIR` is on the
  repository filesystem. The same `main.func_in` case fails under this
  workspace's quota-limited `/tmp` after its Aria temporary file reaches about
  140 MiB; it passes unchanged outside that filesystem.
- WordPress-shaped SQL smoke: InnoDB WordPress tables and indexes, UTF-8
  collation, a 1 MiB post body, transactions, procedures, and functions.
- A strict 60k-query workload: four concurrent clients logged 64,012 query
  commands and 3,004 commits in 169 seconds.

## What would make a real migration possible

Do not delete this bridge until all of these are true:

1. The WASI toolchain can build MariaDB's shared-memory pthread model as a
   Preview 2 component.
2. Wasmtime's component runtime supports the component thread intrinsics and
   imported shared memory that model requires.
3. File and socket resources can survive the new-store-per-thread topology,
   or the runtime provides a thread model that does not create isolated
   descriptor tables.
4. The clean build, strict durability recovery, 57-case transaction profile,
   191-case WordPress profile, and WordPress SQL smoke all pass with the
   bridge removal proved by tests.

Until then, calling the runner "Preview 2" would be dishonest. The useful
part of Preview 2 is already underneath the Preview 1 adapter. The remaining
code exists because MariaDB needs behavior that the component stack does not
yet provide.
