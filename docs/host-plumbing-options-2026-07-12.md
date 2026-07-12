# Keeping MariaDB host plumbing small, 2026-07-12

## Decision

Do not migrate this MariaDB build to WASI Preview 2 or another runtime now.
Keep the Wasmtime runner and its shared file and socket bridges for the next
release.

There is no maintained non-Wasmer library that can be placed under the current
Wasmtime runner and take over the hard parts: shared-memory pthread startup,
file and socket descriptor ownership across guest instances, TCP listener
creation, durable sync, and InnoDB record locking.

Two projects are worth knowing about:

1. WAMR is the closest semantic match. It owns WASI threads, shares its WASI
   context with child instances, and provides a POSIX socket extension. It
   cannot load the current MariaDB module because that module uses the current
   WebAssembly exception-handling proposal while WAMR implements only the old
   legacy exception proposal. A port would also require a MariaDB rebuild
   against WAMR's incompatible socket ABI and one small locking extension.
2. Wazero plus wasi-go can plausibly become a Go runner in the future. It
   supports core threads and current exception handling, but supplies no
   `wasi.thread-spawn` implementation. Its own thread example manually creates
   child instances and depends on wasi-libc TLS internals. wasi-go's Unix
   `System` explicitly is not safe for concurrent use. That is a runner rewrite
   and a concurrency fork, not a library substitution.

Neither reduces the work or risk for the current release.

## The actual contract

The module is not an ordinary command-line Wasm program. Inspection of the
embedded `mariadbd.wasm` found all of the following:

- One imported shared memory: minimum 2,048 pages and maximum 16,384 pages.
- `wasi.thread-spawn` plus an exported `wasi_thread_start` entry point.
- Fifteen custom TCP socket imports and twelve custom file imports.
- Current exception-handling instructions including `try_table`,
  `catch_all_ref`, and `throw_ref`.
- Standard Preview 1 imports for the ordinary process and filesystem calls.

The runner starts a host thread for each guest pthread, creates a fresh
Wasmtime store and module instance for it, and attaches the same imported
shared memory. The guest intentionally shares open data, log, DDL, listener,
and connection descriptors across those instances. See
[`src/main.rs`](../src/main.rs),
[`src/host_files.rs`](../src/host_files.rs), and
[`src/host_sockets.rs`](../src/host_sockets.rs).

That is why a stock per-store `WasiP1Ctx` cannot replace `HostFiles` or
`HostSockets`: a descriptor opened in one store is absent in the next one. The
direct experiment is documented in
[`wasi-preview2-boundary-2026-07-12.md`](wasi-preview2-boundary-2026-07-12.md).
It made InnoDB and DDL writes fail with bad file descriptors.

The present custom Rust runner is 2,496 lines:

| Area | Lines | What it owns |
| --- | ---: | --- |
| `src/main.rs` | 505 | Wasmtime setup, shared memory, guest pthread startup, process lock |
| `src/host_files.rs` | 767 | Shared descriptors, preopen path mapping, sync, InnoDB file lock |
| `src/host_sockets.rs` | 973 | Shared listener and client descriptors, TCP, poll, options |
| `src/guest_abi.rs` | 251 | Checked guest-memory access and errno translation |

The file/socket bridge and guest ABI are 1,991 lines. They exist for a real
runtime contract, not because ordinary filesystem or socket APIs were missed.

## What WASI Preview 2 changes

Preview 2 is a component ABI, not a drop-in implementation of Preview 1.
It gives normal components modular `wasi:filesystem`, `wasi:sockets`, I/O,
polling, clocks, and process interfaces. It is a major improvement for
single-instance programs. The WASI project calls Preview 2 stable, and calls
Preview 3 the current preview with component-model async support.

That does not solve this server today:

1. The existing guest is a Preview 1 core module with shared memory and the
   ad-hoc core-Wasm `wasi.thread-spawn` ABI. It is not a Preview 2 component.
2. The Component Model cannot faithfully express the current wasi-threads
   proposal. The WASI maintainers state this directly: it requires engine
   integration that the Component Model cannot provide.
3. A Preview 2 resource is owned by its component instance. It does not turn a
   descriptor in one fresh Wasmtime store into a descriptor usable in another.
4. Preview 2 does not provide the POSIX `F_SETLK` record lock InnoDB uses.
5. Locally, component encoding rejected MariaDB's imported `env::memory`.
   That imported memory is precisely how fresh guest instances share the
   database state.

The Component Model is adding concurrency in the Preview 3 line. Its own
milestone document lists cooperative threads as future work, not as a Preview
2 facility. That is useful direction, not a migration target for this build.

Wasmtime already gets some Preview 2 implementation reuse internally: its
Preview 1 adapter handles ordinary Preview 1 calls on top of its newer WASI
implementation. That reduces upstream duplication. It does not remove the
MariaDB-specific bridge.

References: [WASI overview](https://github.com/WebAssembly/WASI),
[Component Model milestones](https://github.com/WebAssembly/component-model),
and [the wasi-threads/component-model boundary](https://github.com/WebAssembly/WASI/issues/545).

## Candidate matrix

| Candidate | Handles current module | What it would remove | Blocking facts | Verdict |
| --- | --- | --- | --- | --- |
| Current Wasmtime runner | Yes, validated | Nothing architectural | The bridge remains required | Keep it |
| `wasmtime-wasi-threads` | Not safely | A little thread-spawn code | Requires cloneable store data, still creates a fresh store per guest thread, and exits the whole process on a guest-thread trap. Wasmtime 45 warns that `wasi-threads` is slated for removal in 47. | Reject |
| WAMR | No | Potentially most of the 1,991 bridge lines | Modern exception handling is unimplemented; current module fails to load. Socket ABI differs; lock extension remains. | Track, do not port now |
| Wazero + wasi-go | Not without a Go rewrite | Potentially standard P1 file/socket work | No `wasi.thread-spawn`; manual TLS setup; wasi-go Unix system is not concurrent-safe; socket ABI differs; record lock remains. | Feasibility spike only |
| uvwasi | No | None without writing a new runtime bridge | It is a P1 syscall library, not a Wasm runtime or wasi-threads host; it lacks the POSIX listener-creation surface needed here. | Reject |
| WasmEdge | No | None | The project says it is not yet thread-safe. | Reject |
| WASI-Virt and P1/P2 adapters | No | Nothing for this module | They virtualize or adapt component APIs; they do not provide MariaDB's shared-memory thread model. | Reject |
| Rustix and cap-std | Yes, as helpers | Some unsafe POSIX call glue | They do not own guest ABI calls, descriptor sharing, or pthread startup. | Use only for incremental cleanup |

WASIX is deliberately absent from the recommendation because it was excluded
for this project.

## The closest match: WAMR

[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime) is the only
non-Wasmer runtime found that implements all of the structural ideas this
server needs in one host:

- `WAMR_BUILD_LIB_WASI_THREADS` implements the same `wasi.thread-spawn` ABI
  used by wasi-libc. Its child module instance inherits the parent WASI
  context, including the descriptor table.
- Its libc-WASI descriptor table is protected by a read/write lock.
- Its socket extension offers `socket`, `bind`, `listen`, `accept`, `connect`,
  `send`, `recv`, `poll`, and socket options.
- It supports Darwin and arm64 in source.

That would eliminate the broadest category of custom plumbing. It is not a
drop-in replacement:

1. MariaDB uses the current exception-handling instructions. WAMR documents
   that exact proposal as unimplemented; it supports only legacy exception
   handling. The released WAMR 2.4.5 runtime confirmed that distinction and
   failed to load this `mariadbd.wasm` with a type mismatch.
2. WAMR's listener-creation functions are a nonstandard Preview 1 extension.
   Its documentation explicitly says runtime socket extensions are mutually
   incompatible. MariaDB's socket shim would have to be rebuilt against WAMR's
   ABI.
3. The standard/POSIX-like APIs WAMR owns do not replace the InnoDB
   `F_SETLK` contract. A small host extension would still be needed and must
   remain covered by the strict durability test.
4. WAMR publishes an Intel macOS binary in its latest release, not an arm64
   macOS binary. Its Darwin arm64 source configuration exists, but Studio
   would need to build and distribute that runtime itself.

Do not start this port until WAMR can execute the actual MariaDB module with
current exception handling. Rebuilding MariaDB first to avoid those
instructions is also a risky compiler/toolchain fork and does not remove the
socket and locking work.

References: [WAMR wasi-threads](https://github.com/bytecodeall/wasm-micro-runtime/blob/main/doc/pthread_impls.md),
[WAMR proposal support](https://github.com/bytecodeall/wasm-micro-runtime/blob/main/doc/stability_wasm_proposals.md),
and [WAMR socket compatibility](https://github.com/bytecodeall/wasm-micro-runtime/blob/main/doc/socket_api.md).

## The plausible future contender: Wazero plus wasi-go

[Wazero](https://github.com/wazero/wazero) is a Go runtime, not a Rust library.
Version 1.12 added current WebAssembly exception handling. It has an
experimental core-threads feature and an example running a
`wasm32-wasi-threads` module. It also tests macOS arm64.

The example is the warning label. Wazero says the embedding application must
instantiate a child module for every simultaneous thread, allocate a separate
stack, call `__wasm_init_tls`, write the wasi-libc pthread structure, and set
`__stack_pointer`. That deliberately depends on wasi-libc details. Wazero
does not implement `wasi.thread-spawn` or `wasi_thread_start` as a ready-made
host service.

[wasi-go](https://github.com/dispatchrun/wasi-go) supplies a serious Preview 1
filesystem, sync, polling, and socket implementation for Wazero. It is useful
code, but its Unix `System` has an explicit non-concurrency guarantee. Sharing
one instance between MariaDB child modules would race its descriptor table and
poll scratch state. Serializing every call behind one mutex would make blocking
polling and database concurrency wrong. Fixing it means maintaining a fork or
a new shared, correctly synchronized resource table.

This route would require all of the following before it can run MariaDB:

1. Implement `wasi.thread-spawn` with an equivalent child-instance lifecycle.
2. Use an imported shared-memory helper and preserve MariaDB's pthread/TLS
   behavior without relying on unstable wasi-libc layout details.
3. Make wasi-go's file and socket resources safe across concurrent child
   instances, including close-versus-poll behavior.
4. Rebuild the guest socket shim for the different socket extension.
5. Add and test the InnoDB lock operation.
6. Re-run all durability, transaction, WordPress, and 60k-query validation on
   macOS arm64 and Linux.

This is a valid research spike if moving the runner to Go is acceptable. It is
not a way to delete a few Rust files and keep the rest unchanged.

References: [Wazero 1.12 release](https://github.com/wazero/wazero/releases/tag/v1.12.0),
[Wazero's thread example](https://github.com/wazero/wazero/blob/v1.12.0/experimental/features_example_test.go),
and [wasi-go's Unix concurrency contract](https://github.com/dispatchrun/wasi-go/blob/main/systems/unix/system.go).

## Smaller improvements that are worth doing

The only low-risk deletion path is mechanical, not architectural:

- Replace direct `libc` calls in the Rust bridges with
  [Rustix](https://github.com/bytecodealliance/rustix) where its API exactly
  preserves the existing behavior. Rustix supplies `fsync`, `fdatasync`,
  `fcntl_lock`, sockets, and `poll` on Linux and macOS.
- Use [cap-std](https://github.com/bytecodealliance/cap-std) only where its
  preopened-directory model clarifies a path operation. Do not force it into
  the raw descriptor code merely to make the dependency graph prettier.
- Keep the current small, checked guest-memory layer. No host library can know
  the custom C socket/file ABI or safely marshal its pointers for us.

This can trim unsafe glue and improve portability. It cannot remove the shared
descriptor registries. Do it only with a focused diff and all existing tests;
do not create a large abstraction layer around two operating systems and call
that simplification.

## Required proof before replacing the runner

Any alternative has to pass the same things the current runner has already
passed, not merely start `mariadbd`:

1. Fresh system-table bootstrap and a real connection from `mysql` on macOS
   arm64 and Linux.
2. The strict `SIGKILL` durability test: committed InnoDB rows recover,
   uncommitted rows roll back, host sync calls occur, and the run lock works.
3. The 57 transaction-nuance MTR cases and the 191 WordPress-focused MTR
   cases.
4. The WordPress-shaped SQL smoke test.
5. The four-client 60k-query workload, including 3k commits, with no lost
   queries or hangs.

Until an alternative clears that bar, the 1,991 bridge lines are cheaper than
an unproven database runtime.

## Supporting sources

- [Wasmtime 45 release notes](https://github.com/bytecodealliance/wasmtime/releases/tag/v45.0.0)
- [uvwasi](https://github.com/nodejs/uvwasi)
- [WasmEdge thread-safety statement](https://github.com/WasmEdge/WasmEdge)
- [WASI-Virt](https://github.com/bytecodealliance/WASI-Virt)
