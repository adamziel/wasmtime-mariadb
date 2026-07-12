use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;

#[cfg(unix)]
use rustix::fs::{FlockOperation, flock};

use clap::Parser;
use wasmtime::error::Context as _;
use wasmtime::{
    Config, Engine, ExternType, Linker, Memory, Module, Result, SharedMemory, Store, bail,
};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::{DirPerms, FilePerms, I32Exit, WasiCtxBuilder};

mod guest_abi;
mod host_files;
mod host_sockets;

const MARIADBD_WASM: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/mariadbd.wasm"));
const MARIADBD_WASM_SOURCE: &str = env!("EMBEDDED_MARIADBD_WASM_SOURCE");

pub(crate) struct AppState {
    wasi: WasiP1Ctx,
    files: host_files::HostFiles,
    sockets: host_sockets::HostSockets,
    network_allowed: bool,
}

struct RuntimeEnv {
    engine: Engine,
    module: Module,
    cli: Cli,
    files: host_files::HostFiles,
    sockets: host_sockets::HostSockets,
    memories: Vec<ImportedSharedMemory>,
    next_thread_id: AtomicI32,
}

/// Holds the host advisory lock for a standard MariaDB data directory.
struct DataDirLock {
    _file: File,
}

#[derive(Clone)]
struct ImportedSharedMemory {
    module: String,
    name: String,
    memory: SharedMemory,
}

#[derive(Clone, Parser, Debug)]
#[command(
    version,
    about = "Run an embedded MariaDB WASI module through Wasmtime"
)]
struct Cli {
    #[arg(long, help = "Print the path or fixture used at compile time")]
    show_embedded_source: bool,

    #[arg(
        long,
        help = "Do not preopen the current host directory as guest path '.'"
    )]
    no_default_preopen: bool,

    #[arg(long, help = "Do not inherit host environment variables")]
    no_inherit_env: bool,

    #[arg(long, help = "Do not grant WASI network access")]
    no_network: bool,

    #[arg(
        long,
        value_name = "PATH",
        help = "Acquire an exclusive host advisory lock for the runner lifetime"
    )]
    lock_file: Option<PathBuf>,

    #[arg(
        long = "preopen",
        value_name = "HOST=GUEST",
        help = "Preopen a host directory at a guest path"
    )]
    preopens: Vec<Preopen>,

    #[arg(
        long = "env",
        value_name = "KEY=VALUE",
        help = "Add or override one guest environment variable"
    )]
    env: Vec<EnvPair>,

    #[arg(
        value_name = "MARIADBD_ARG",
        trailing_var_arg = true,
        allow_hyphen_values = true,
        help = "Arguments passed to the embedded mariadbd module after a '--' separator"
    )]
    guest_args: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Preopen {
    host: PathBuf,
    guest: String,
}

impl FromStr for Preopen {
    type Err = String;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        let (host, guest) = value
            .split_once('=')
            .ok_or_else(|| "expected HOST=GUEST".to_owned())?;
        if host.is_empty() {
            return Err("host path cannot be empty".to_owned());
        }
        if guest.is_empty() {
            return Err("guest path cannot be empty".to_owned());
        }
        Ok(Self {
            host: PathBuf::from(host),
            guest: guest.to_owned(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct EnvPair {
    key: String,
    value: String,
}

impl FromStr for EnvPair {
    type Err = String;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        let (key, env_value) = value
            .split_once('=')
            .ok_or_else(|| "expected KEY=VALUE".to_owned())?;
        if key.is_empty() {
            return Err("environment key cannot be empty".to_owned());
        }
        Ok(Self {
            key: key.to_owned(),
            value: env_value.to_owned(),
        })
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            if let Some(exit) = err.downcast_ref::<I32Exit>() {
                return exit_code_from_i32(exit.0);
            }
            eprintln!("error: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    if cli.show_embedded_source {
        println!("{MARIADBD_WASM_SOURCE}");
        return Ok(());
    }

    let _data_dir_lock = acquire_data_dir_lock(cli.lock_file.as_deref())?;

    let mut config = Config::new();
    config.wasm_threads(true);
    config.wasm_exceptions(true);
    config.shared_memory(true);

    let engine = Engine::new(&config).context("failed to create Wasmtime engine")?;
    let module = Module::from_binary(&engine, MARIADBD_WASM)
        .context("failed to compile embedded mariadbd WebAssembly module")?;

    let mut linker = build_base_linker(&engine)?;

    let wasi = build_wasi(&cli)?;
    let network_allowed = !cli.no_network;
    let files = host_files::HostFiles::new(&cli).context("failed to configure host file table")?;
    let sockets = host_sockets::HostSockets::new();
    let state = AppState {
        wasi,
        files: files.clone(),
        sockets: sockets.clone(),
        network_allowed,
    };
    let mut store = Store::new(&engine, state);
    let memories = define_imported_memories(&engine, &module, &mut linker, &mut store)
        .context("failed to define imported memories")?;
    let runtime = Arc::new(RuntimeEnv {
        engine: engine.clone(),
        module: module.clone(),
        cli: cli.clone(),
        files,
        sockets,
        memories,
        next_thread_id: AtomicI32::new(1),
    });
    define_wasi_thread_spawn(&mut linker, runtime)
        .context("failed to define WASI thread spawn import")?;
    linker
        .define_unknown_imports_as_traps(&module)
        .context("failed to define trap handlers for unsupported imports")?;
    let instance = linker
        .instantiate(&mut store, &module)
        .context("failed to instantiate embedded mariadbd module")?;
    let start = instance
        .get_typed_func::<(), ()>(&mut store, "_start")
        .context("embedded module does not export a WASI _start function")?;

    start
        .call(&mut store, ())
        .context("embedded mariadbd module trapped")?;
    Ok(())
}

fn acquire_data_dir_lock(path: Option<&Path>) -> Result<Option<DataDirLock>> {
    let Some(path) = path else {
        return Ok(None);
    };

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .with_context(|| {
            format!(
                "failed to open MariaDB data-directory lock {}",
                path.display()
            )
        })?;

    #[cfg(unix)]
    {
        if let Err(err) = flock(&file, FlockOperation::NonBlockingLockExclusive) {
            let errno = err.raw_os_error();
            if errno == libc::EAGAIN || errno == libc::EWOULDBLOCK {
                bail!(
                    "MariaDB data directory is already in use; another wasmtime-mariadb runner holds {}",
                    path.display()
                );
            }
            return Err(std::io::Error::from(err)).with_context(|| {
                format!(
                    "failed to acquire MariaDB data-directory lock {}",
                    path.display()
                )
            });
        }
        Ok(Some(DataDirLock { _file: file }))
    }

    #[cfg(not(unix))]
    {
        drop(file);
        bail!(
            "--lock-file is currently supported only on Unix hosts: {}",
            path.display()
        );
    }
}

fn build_base_linker(engine: &Engine) -> Result<Linker<AppState>> {
    let mut linker = Linker::<AppState>::new(engine);
    p1::add_to_linker_sync(&mut linker, |state| &mut state.wasi)
        .context("failed to link WASIp1 imports")?;
    host_files::add_to_linker(&mut linker).context("failed to link host file imports")?;
    host_sockets::add_to_linker(&mut linker).context("failed to link host socket imports")?;
    Ok(linker)
}

fn build_wasi(cli: &Cli) -> Result<WasiP1Ctx> {
    let mut builder = WasiCtxBuilder::new();
    builder.inherit_stdio();
    builder.allow_blocking_current_thread(true);

    if !cli.no_inherit_env {
        builder.inherit_env();
    }

    for EnvPair { key, value } in &cli.env {
        builder.env(key, value);
    }

    let mut args = Vec::with_capacity(cli.guest_args.len() + 1);
    args.push("mariadbd".to_owned());
    args.extend(cli.guest_args.iter().cloned());
    builder.args(&args);

    if !cli.no_default_preopen {
        let cwd = std::env::current_dir().context("failed to read current directory")?;
        preopen_dir(&mut builder, cwd, ".")?;
        builder.initial_cwd(".");
    }

    for preopen in &cli.preopens {
        preopen_dir(&mut builder, preopen.host.clone(), &preopen.guest)?;
    }

    if !cli.no_network {
        builder
            .inherit_network()
            .allow_ip_name_lookup(true)
            .allow_tcp(true)
            .allow_udp(true);
    }

    Ok(builder.build_p1())
}

fn define_imported_memories(
    engine: &Engine,
    module: &Module,
    linker: &mut Linker<AppState>,
    store: &mut Store<AppState>,
) -> Result<Vec<ImportedSharedMemory>> {
    let mut seen = HashSet::new();
    let mut memories = Vec::new();

    for import in module.imports() {
        let ExternType::Memory(memory_ty) = import.ty() else {
            continue;
        };

        let key = (import.module().to_owned(), import.name().to_owned());
        if !seen.insert(key.clone()) {
            continue;
        }

        if memory_ty.is_shared() {
            let memory = SharedMemory::new(engine, memory_ty)
                .with_context(|| format!("failed to create shared memory {}::{}", key.0, key.1))?;
            linker.define(&mut *store, &key.0, &key.1, memory.clone())?;
            memories.push(ImportedSharedMemory {
                module: key.0,
                name: key.1,
                memory,
            });
        } else {
            let memory = Memory::new(&mut *store, memory_ty)
                .with_context(|| format!("failed to create memory {}::{}", key.0, key.1))?;
            linker.define(&mut *store, &key.0, &key.1, memory)?;
        }
    }

    Ok(memories)
}

fn define_shared_memories(
    linker: &mut Linker<AppState>,
    store: &mut Store<AppState>,
    memories: &[ImportedSharedMemory],
) -> Result<()> {
    for memory in memories {
        linker.define(
            &mut *store,
            &memory.module,
            &memory.name,
            memory.memory.clone(),
        )?;
    }
    Ok(())
}

fn define_wasi_thread_spawn(linker: &mut Linker<AppState>, runtime: Arc<RuntimeEnv>) -> Result<()> {
    linker.func_wrap("wasi", "thread-spawn", move |start_arg: i32| -> i32 {
        spawn_wasi_thread(runtime.clone(), start_arg)
    })?;
    Ok(())
}

fn spawn_wasi_thread(runtime: Arc<RuntimeEnv>, start_arg: i32) -> i32 {
    let thread_id = runtime.next_thread_id.fetch_add(1, Ordering::Relaxed);
    if thread_id <= 0 {
        return -libc::EAGAIN;
    }

    match thread::Builder::new()
        .name(format!("wasi-thread-{thread_id}"))
        .spawn(move || {
            if let Err(err) = run_wasi_thread(runtime, thread_id, start_arg) {
                let details = format!("{err:#}");
                if !details.contains("wasmtime_mariadb_pthread_exit") {
                    eprintln!("error: WASI thread {thread_id} failed: {details}");
                }
            }
        }) {
        Ok(_) => thread_id,
        Err(_) => -libc::EAGAIN,
    }
}

fn run_wasi_thread(runtime: Arc<RuntimeEnv>, thread_id: i32, start_arg: i32) -> Result<()> {
    let mut linker = build_base_linker(&runtime.engine)?;
    let wasi = build_wasi(&runtime.cli)?;
    let state = AppState {
        wasi,
        files: runtime.files.clone(),
        sockets: runtime.sockets.clone(),
        network_allowed: !runtime.cli.no_network,
    };
    let mut store = Store::new(&runtime.engine, state);
    define_shared_memories(&mut linker, &mut store, &runtime.memories)
        .context("failed to define shared memories for WASI thread")?;
    define_wasi_thread_spawn(&mut linker, runtime.clone())
        .context("failed to define nested WASI thread spawn import")?;
    linker
        .define_unknown_imports_as_traps(&runtime.module)
        .context("failed to define trap handlers for WASI thread")?;

    let instance = linker
        .instantiate(&mut store, &runtime.module)
        .context("failed to instantiate WASI thread module")?;
    let thread_start = instance
        .get_typed_func::<(i32, i32), ()>(&mut store, "wasi_thread_start")
        .context("module does not export wasi_thread_start(thread_id, start_arg)")?;

    match thread_start.call(&mut store, (thread_id, start_arg)) {
        Ok(()) => Ok(()),
        Err(err) if err.downcast_ref::<I32Exit>().is_some() => Ok(()),
        Err(err) => Err(err).context("WASI thread trapped"),
    }
}

fn preopen_dir(builder: &mut WasiCtxBuilder, host: PathBuf, guest: &str) -> Result<()> {
    if !host.is_dir() {
        bail!("preopen host path is not a directory: {}", host.display());
    }
    builder
        .preopened_dir(host.clone(), guest, DirPerms::all(), FilePerms::all())
        .with_context(|| format!("failed to preopen {} as {guest}", host.display()))?;
    Ok(())
}

fn exit_code_from_i32(status: i32) -> ExitCode {
    if status == 0 {
        return ExitCode::SUCCESS;
    }
    match u8::try_from(status) {
        Ok(code) if code != 0 => ExitCode::from(code),
        _ => ExitCode::FAILURE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn clap_config_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn parses_preopen() {
        let parsed = Preopen::from_str("/tmp/mariadb=/data").unwrap();
        assert_eq!(parsed.host, PathBuf::from("/tmp/mariadb"));
        assert_eq!(parsed.guest, "/data");
    }

    #[test]
    fn parses_env_pair() {
        let parsed = EnvPair::from_str("MYSQL_HOME=/data").unwrap();
        assert_eq!(parsed.key, "MYSQL_HOME");
        assert_eq!(parsed.value, "/data");
    }

    #[test]
    fn rejects_empty_preopen_guest() {
        assert!(Preopen::from_str("/tmp/mariadb=").is_err());
    }

    #[test]
    fn parses_lock_file() {
        let cli = Cli::try_parse_from([
            "wasmtime-mariadb",
            "--lock-file",
            "/tmp/mariadb.lock",
            "--",
            "--no-defaults",
        ])
        .unwrap();
        assert_eq!(cli.lock_file, Some(PathBuf::from("/tmp/mariadb.lock")));
        assert_eq!(cli.guest_args, ["--no-defaults"]);
    }
}
