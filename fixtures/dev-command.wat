(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasmtime_mariadb_sockets" "socket"
    (func $socket (param i32 i32 i32) (result i32)))
  (import "wasmtime_mariadb_sockets" "close"
    (func $close (param i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "wasmtime-mariadb dev fixture\n")
  (func $_start (export "_start")
    (local $fd i32)
    (local.set $fd
      (call $socket
        (i32.const 2)
        (i32.const 1)
        (i32.const 0)))
    (if (i32.ge_s (local.get $fd) (i32.const 0))
      (then
        (drop (call $close (local.get $fd)))))
    (i32.store (i32.const 0) (i32.const 8))
    (i32.store (i32.const 4) (i32.const 28))
    (drop
      (call $fd_write
        (i32.const 1)
        (i32.const 0)
        (i32.const 1)
        (i32.const 40)))))
