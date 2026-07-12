//! Cross-platform lifecycle supervisor for a local Wasmtime MariaDB instance.
//!
//! The server itself is a Wasmtime process because MariaDB can create guest
//! threads that outlive its TCP listener. This executable owns the ordinary
//! local-development contract around that process: a guarded data directory,
//! a loopback endpoint, explicit stop requests, and a best-effort MariaDB
//! shutdown before a stuck host is terminated.

use std::env;
use std::error::Error;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, ExitStatus, Stdio};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use clap::Parser;
use serde::{Deserialize, Serialize};

const DATA_FORMAT_VERSION: u32 = 1;
const MARIADB_SERIES: &str = "11.4";
const MANIFEST_STATE_INITIALIZING: &str = "initializing";
const MANIFEST_STATE_READY: &str = "ready";
const MANIFEST_FILE: &str = ".wasmtime-mariadb-run.json";
const ENDPOINT_FILE: &str = ".wasmtime-mariadb-endpoint.json";
const STOP_FILE: &str = ".wasmtime-mariadb.stop";
const LOCK_FILE: &str = ".wasmtime-mariadb.lock";
const READY_POLL_INTERVAL: Duration = Duration::from_millis(100);
const SHUTDOWN_GRACE_PERIOD: Duration = Duration::from_secs(12);

type Result<T> = std::result::Result<T, Box<dyn Error>>;

/// Starts a local server or writes a stop request for an existing supervisor.
#[derive(Clone, Debug, Parser)]
#[command(
    version,
    about = "Supervise a local MariaDB server running in Wasmtime"
)]
struct Cli {
    /// Wasmtime MariaDB runner to launch. Defaults to a sibling release binary.
    #[arg(long, value_name = "PATH")]
    bin: Option<PathBuf>,

    /// Directory holding data, temporary files, metadata, and the process lock.
    #[arg(long, value_name = "PATH")]
    run_dir: Option<PathBuf>,

    /// Loopback TCP port, or `auto` to allocate an available port.
    #[arg(long, value_name = "PORT")]
    port: Option<String>,

    /// Loopback address for the local TCP listener.
    #[arg(long, value_name = "IP")]
    bind_address: Option<IpAddr>,

    /// Use strict or relaxed InnoDB durability. Strict is the default.
    #[arg(long, value_name = "MODE")]
    durability: Option<String>,

    /// File receiving the Wasmtime host PID while the server is running.
    #[arg(long, value_name = "PATH")]
    host_pid_file: Option<PathBuf>,

    /// Write a manifest for an existing complete data directory exactly once.
    #[arg(long)]
    adopt_existing_data: bool,

    /// Skip the constrained local system-table bootstrap. Reserved for MTR.
    #[arg(long)]
    skip_system_tables_init: bool,

    /// Do not add `--skip-grant-tables`. Reserved for the external MTR harness.
    #[arg(long)]
    no_skip_grant_tables: bool,

    /// Ask a running supervisor for this run directory to stop, then exit.
    #[arg(long, value_name = "PATH")]
    stop_run_dir: Option<PathBuf>,

    /// Extra arguments passed to the embedded MariaDB server after `--`.
    #[arg(
        value_name = "MARIADBD_ARG",
        trailing_var_arg = true,
        allow_hyphen_values = true
    )]
    guest_args: Vec<String>,
}

/// Stable metadata that guards a MariaDB data directory from accidental reuse.
#[derive(Clone, Debug, Deserialize, Serialize)]
struct RunManifest {
    format_version: u32,
    runner: String,
    runner_version: String,
    mariadb_series: String,
    instance_id: String,
    created_unix_seconds: u64,
    state: String,
}

/// Distinguishes immediate terminal interrupts from controlled stop requests.
#[derive(Clone, Copy, Eq, PartialEq)]
enum StopMode {
    Interrupt,
    Requested,
}

/// The discovery record consumed by local development tools such as Studio.
#[derive(Clone, Debug, Serialize)]
struct Endpoint {
    format_version: u32,
    instance_id: String,
    host: String,
    port: u16,
    pid: u32,
    state: &'static str,
}

/// Fully resolved settings used for one child Wasmtime process.
struct RunConfig {
    bin: PathBuf,
    run_dir: PathBuf,
    data_dir: PathBuf,
    system_tables_source: PathBuf,
    system_tables_init: PathBuf,
    runtime_log: PathBuf,
    host_pid_file: Option<PathBuf>,
    bind_address: IpAddr,
    port: u16,
    durability: Durability,
    skip_grant_tables: bool,
    skip_system_tables_init: bool,
    runner_args: Vec<String>,
    guest_args: Vec<String>,
    manifest: RunManifest,
}

/// The only two supported InnoDB durability modes for the local runner.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Durability {
    Strict,
    Relaxed,
}

impl FromStr for Durability {
    type Err = String;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "strict" => Ok(Self::Strict),
            "relaxed" => Ok(Self::Relaxed),
            _ => Err(format!(
                "DURABILITY must be strict or relaxed, got: {value}"
            )),
        }
    }
}

impl Durability {
    /// Returns MariaDB arguments that make the requested durability explicit.
    fn mariadb_args(self) -> &'static [&'static str] {
        match self {
            Self::Strict => &["--innodb-flush-log-at-trx-commit=1"],
            Self::Relaxed => &["--debug-no-sync", "--innodb-flush-log-at-trx-commit=2"],
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    if let Some(run_dir) = cli.stop_run_dir {
        write_stop_request(&run_dir)?;
        return Ok(());
    }

    let config = build_config(&cli)?;
    supervise(config)
}

/// Resolves environment and command-line settings before creating a child.
fn build_config(cli: &Cli) -> Result<RunConfig> {
    let bin = resolve_binary(cli.bin.as_deref())?;
    let run_dir = resolve_run_dir(cli.run_dir.as_deref())?;
    ensure_private_directory(&run_dir)?;
    let run_dir = fs::canonicalize(&run_dir)?;
    let data_dir = run_dir.join("data");
    let tmp_dir = run_dir.join("tmp");
    ensure_private_directory(&data_dir)?;
    ensure_private_directory(&tmp_dir)?;

    let bind_address = cli
        .bind_address
        .or_else(|| env_value("BIND_ADDRESS").and_then(|value| value.parse().ok()))
        .unwrap_or(IpAddr::from([127, 0, 0, 1]));
    if !bind_address.is_loopback() && !env_flag("ALLOW_NONLOCAL_BIND") {
        return Err(format!(
            "refusing non-loopback BIND_ADDRESS={bind_address}; set ALLOW_NONLOCAL_BIND=1 only when you understand that the local runner has no normal authentication"
        )
        .into());
    }

    let port_spec = cli
        .port
        .clone()
        .or_else(|| env_value("PORT"))
        .unwrap_or_else(|| "3307".to_owned());
    let port = parse_port(&port_spec, bind_address)?;
    let durability_value = cli
        .durability
        .clone()
        .or_else(|| env_value("DURABILITY"))
        .unwrap_or_else(|| "strict".to_owned());
    let durability = durability_value
        .as_str()
        .parse::<Durability>()
        .map_err(io::Error::other)?;
    let skip_system_tables_init =
        cli.skip_system_tables_init || env_flag("SKIP_SYSTEM_TABLES_INIT");

    reject_relaxed_strict_conflict(durability, &cli.guest_args)?;
    validate_data_directory(&data_dir, skip_system_tables_init)?;
    let runner_version = runner_version(&bin)?;
    let manifest = prepare_manifest(
        &run_dir,
        &data_dir,
        &runner_version,
        cli.adopt_existing_data || env_flag("ADOPT_EXISTING_DATA"),
    )?;
    let system_tables_source = resolve_system_tables_source(&bin)?;

    Ok(RunConfig {
        bin,
        data_dir,
        system_tables_init: run_dir.join("mariadb-system-tables.sql"),
        runtime_log: run_dir.join("mariadbd-runtime.err"),
        host_pid_file: cli
            .host_pid_file
            .clone()
            .or_else(|| env_value("HOST_PID_FILE").map(PathBuf::from))
            .map(make_absolute),
        run_dir,
        system_tables_source,
        bind_address,
        port,
        durability,
        skip_grant_tables: !cli.no_skip_grant_tables && skip_grant_tables_from_env(),
        skip_system_tables_init,
        runner_args: parse_runner_args(env_value("RUNNER_ARGS"))?,
        guest_args: cli.guest_args.clone(),
        manifest,
    })
}

/// Launches the runner and turns Ctrl-C or a stop request into a clean stop.
fn supervise(mut config: RunConfig) -> Result<()> {
    fs::copy(&config.system_tables_source, &config.system_tables_init)?;
    let log_offset = config
        .runtime_log
        .metadata()
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    write_endpoint(&config, 0, "starting")?;
    fs::remove_file(stop_path(&config.run_dir)).ok();

    // Install this before the child exists so direct signal delivery still
    // removes endpoint metadata and terminates a child that remains alive.
    let stop_requested = Arc::new(AtomicBool::new(false));
    install_ctrlc_handler(stop_requested.clone())?;

    let mut child = spawn_runner(&config)?;
    if let Some(path) = &config.host_pid_file {
        write_pid_file(path, child.id())?;
    }
    write_endpoint(&config, child.id(), "starting")?;

    let follower_stop = Arc::new(AtomicBool::new(false));
    let follower = follow_runtime_log(
        config.runtime_log.clone(),
        log_offset,
        follower_stop.clone(),
    );

    let mut ready = false;
    let mut intentional_stop = false;
    let mut lifecycle_error = None;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }

        if stop_requested.load(Ordering::Relaxed) || stop_path(&config.run_dir).exists() {
            intentional_stop = true;
            let stop_mode = if stop_requested.load(Ordering::Relaxed) {
                StopMode::Interrupt
            } else {
                StopMode::Requested
            };
            fs::remove_file(stop_path(&config.run_dir)).ok();
            break stop_child(&mut child, config.bind_address, config.port, stop_mode)?;
        }

        if !ready && mysql_ping(config.bind_address, config.port).is_ok() {
            if config.manifest.state != MANIFEST_STATE_READY {
                config.manifest.state = MANIFEST_STATE_READY.to_owned();
                if let Err(err) = write_manifest(&config) {
                    lifecycle_error = Some(format!(
                        "failed to persist ready data-directory manifest: {err}"
                    ));
                    break terminate_child(&mut child)?;
                }
            }
            ready = true;
            write_endpoint(&config, child.id(), "ready")?;
            println!(
                "MariaDB ready on {}:{} (run directory: {})",
                config.bind_address,
                config.port,
                config.run_dir.display()
            );
        }
        thread::sleep(READY_POLL_INTERVAL);
    };

    follower_stop.store(true, Ordering::Relaxed);
    if let Some(follower) = follower {
        let _ = follower.join();
    }
    remove_pid_file(config.host_pid_file.as_deref());
    write_endpoint(&config, child.id(), "stopped")?;

    if let Some(error) = lifecycle_error {
        return Err(error.into());
    }
    if intentional_stop || status.success() {
        return Ok(());
    }
    Err(format!("MariaDB exited with status {status}").into())
}

/// Starts the Wasmtime runner with the same narrow guest contract as releases.
fn spawn_runner(config: &RunConfig) -> Result<Child> {
    let mut command = Command::new(&config.bin);
    command
        .arg("--no-inherit-env")
        .arg("--lock-file")
        .arg(config.run_dir.join(LOCK_FILE))
        .arg("--preopen")
        .arg(format!("{}=/tmp", config.run_dir.display()))
        .arg("--env")
        .arg("TMPDIR=/tmp/tmp")
        .arg("--env")
        .arg("HOME=/tmp")
        .args(&config.runner_args)
        .arg("--")
        .arg("--no-defaults")
        .arg("--console");

    if config.skip_grant_tables {
        command.arg("--skip-grant-tables");
    }
    command
        .arg("--skip-external-locking")
        .args(config.durability.mariadb_args())
        .arg("--skip-ssl")
        .arg("--basedir=/tmp")
        .arg("--datadir=/tmp/data")
        .arg("--tmpdir=/tmp/tmp");

    if !config.skip_system_tables_init {
        command.arg("--init-file=/tmp/mariadb-system-tables.sql");
    }
    command
        .arg("--log-error=/tmp/mariadbd-runtime.err")
        .arg(format!("--port={}", config.port))
        .arg(format!("--bind-address={}", config.bind_address))
        .arg("--skip-log-bin")
        .arg("--skip-slave-start")
        .arg("--default-storage-engine=InnoDB")
        .arg("--innodb-buffer-pool-size=16M")
        .arg("--innodb-buffer-pool-size-max=16M")
        .arg("--innodb-log-file-size=8M")
        .arg("--innodb-log-buffer-size=8M")
        .args(&config.guest_args)
        .args(config.durability.mariadb_args())
        .current_dir(&config.data_dir)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    command.spawn().map_err(|err| {
        format!(
            "failed to start Wasmtime MariaDB runner {}: {err}",
            config.bin.display()
        )
        .into()
    })
}

/// Ends a child according to the caller's requested lifecycle semantics.
fn stop_child(child: &mut Child, host: IpAddr, port: u16, mode: StopMode) -> Result<ExitStatus> {
    if mode == StopMode::Interrupt {
        eprintln!("interrupt received; terminating the Wasmtime host");
        return terminate_child(child);
    }

    match mysql_shutdown(host, port) {
        Ok(()) => eprintln!("requested MariaDB protocol shutdown"),
        Err(err) => eprintln!(
            "MariaDB protocol shutdown unavailable; falling back to host termination: {err}"
        ),
    }

    let deadline = Instant::now() + SHUTDOWN_GRACE_PERIOD;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        thread::sleep(READY_POLL_INTERVAL);
    }

    if mysql_ping(host, port).is_err() {
        eprintln!(
            "MariaDB stopped accepting connections but the Wasmtime host did not exit; terminating it"
        );
    } else {
        eprintln!("MariaDB host did not exit after protocol shutdown; terminating it");
    }
    terminate_child(child)
}

/// Terminates a remaining child and tolerates the narrow race where it just exited.
fn terminate_child(child: &mut Child) -> Result<ExitStatus> {
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    match child.kill() {
        Ok(()) => Ok(child.wait()?),
        Err(err) if err.kind() == io::ErrorKind::InvalidInput => Ok(child.wait()?),
        Err(err) => Err(err.into()),
    }
}

/// Writes a portable stop signal that the owning supervisor polls for.
fn write_stop_request(run_dir: &Path) -> Result<()> {
    let run_dir = make_absolute(run_dir.to_path_buf());
    if !run_dir.is_dir() {
        return Err(format!("run directory does not exist: {}", run_dir.display()).into());
    }
    write_atomic(&stop_path(&run_dir), b"stop\n")?;
    println!("stop requested for {}", run_dir.display());
    Ok(())
}

/// Creates or validates the compatibility record for one data directory.
fn prepare_manifest(
    run_dir: &Path,
    data_dir: &Path,
    runner_version: &str,
    adopt_existing_data: bool,
) -> Result<RunManifest> {
    let path = run_dir.join(MANIFEST_FILE);
    if path.exists() {
        let manifest: RunManifest = serde_json::from_slice(&fs::read(&path)?)?;
        validate_manifest(&manifest, runner_version)?;
        return Ok(manifest);
    }

    let has_data = data_dir.join("ibdata1").exists();
    if has_data && !adopt_existing_data {
        return Err(format!(
            "refusing to open existing MariaDB data without {}. Set ADOPT_EXISTING_DATA=1 or pass --adopt-existing-data only after confirming it belongs to this local runner: {}",
            MANIFEST_FILE,
            data_dir.display()
        )
        .into());
    }

    let manifest = RunManifest {
        format_version: DATA_FORMAT_VERSION,
        runner: "wasmtime-mariadb".to_owned(),
        runner_version: runner_version.to_owned(),
        mariadb_series: MARIADB_SERIES.to_owned(),
        instance_id: new_instance_id(),
        created_unix_seconds: unix_seconds(),
        state: MANIFEST_STATE_INITIALIZING.to_owned(),
    };
    write_json_atomic(&path, &manifest)?;
    restrict_file_permissions(&path)?;
    Ok(manifest)
}

/// Rejects data written by an incompatible runner or MariaDB series.
fn validate_manifest(manifest: &RunManifest, runner_version: &str) -> Result<()> {
    if manifest.format_version != DATA_FORMAT_VERSION {
        return Err(format!(
            "unsupported run-directory format {} in {}; this runner supports {}",
            manifest.format_version, MANIFEST_FILE, DATA_FORMAT_VERSION
        )
        .into());
    }
    if manifest.runner != "wasmtime-mariadb" {
        return Err(format!("{} was not created by wasmtime-mariadb", MANIFEST_FILE).into());
    }
    if manifest.mariadb_series != MARIADB_SERIES {
        return Err(format!(
            "MariaDB data directory targets {} but this runner embeds {}",
            manifest.mariadb_series, MARIADB_SERIES
        )
        .into());
    }
    if manifest.state != MANIFEST_STATE_READY {
        return Err(format!(
            "{} records an interrupted initialization; remove this disposable run directory or recover it with a compatible MariaDB installation",
            MANIFEST_FILE
        )
        .into());
    }
    if version_is_newer(&manifest.runner_version, runner_version) {
        return Err(format!(
            "refusing runner downgrade: data directory was last adopted by {}, current runner is {}",
            manifest.runner_version, runner_version
        )
        .into());
    }
    Ok(())
}

/// Promotes an initialized directory only after a real MySQL protocol ping succeeds.
fn write_manifest(config: &RunConfig) -> Result<()> {
    let path = config.run_dir.join(MANIFEST_FILE);
    write_json_atomic(&path, &config.manifest)?;
    restrict_file_permissions(&path)
}

/// Detects interrupted first boot before MariaDB attempts unsafe recovery.
fn validate_data_directory(data_dir: &Path, skip_system_tables_init: bool) -> Result<()> {
    if skip_system_tables_init || !data_dir.join("ibdata1").exists() {
        return Ok(());
    }

    let mysql = data_dir.join("mysql");
    if mysql.join("servers.frm").exists() && mysql.join("time_zone_leap_second.frm").exists() {
        return Ok(());
    }
    Err(format!(
        "MariaDB data directory is incomplete: {}. It contains InnoDB files but not the completed local system-table bootstrap. Remove only this disposable run directory, or recover it with a compatible MariaDB installation.",
        data_dir.display()
    )
    .into())
}

/// Records the endpoint without exposing it outside the local run directory.
fn write_endpoint(config: &RunConfig, pid: u32, state: &'static str) -> Result<()> {
    let endpoint = Endpoint {
        format_version: 1,
        instance_id: config.manifest.instance_id.clone(),
        host: config.bind_address.to_string(),
        port: config.port,
        pid,
        state,
    };
    let path = config.run_dir.join(ENDPOINT_FILE);
    write_json_atomic(&path, &endpoint)?;
    restrict_file_permissions(&path)?;
    Ok(())
}

/// Polls the MariaDB runtime log so a foreground server remains observable.
fn follow_runtime_log(
    path: PathBuf,
    start_offset: u64,
    stop: Arc<AtomicBool>,
) -> Option<thread::JoinHandle<()>> {
    Some(thread::spawn(move || {
        let mut offset = start_offset;
        while !stop.load(Ordering::Relaxed) {
            if let Ok(mut file) = File::open(&path)
                && file.seek(SeekFrom::Start(offset)).is_ok()
            {
                let mut bytes = Vec::new();
                if file.read_to_end(&mut bytes).is_ok() && !bytes.is_empty() {
                    offset += bytes.len() as u64;
                    eprint!("{}", String::from_utf8_lossy(&bytes));
                }
            }
            thread::sleep(Duration::from_millis(200));
        }
    }))
}

/// Installs a minimal signal handler that lets the polling loop stop safely.
fn install_ctrlc_handler(stop_requested: Arc<AtomicBool>) -> Result<()> {
    ctrlc::set_handler(move || {
        stop_requested.store(true, Ordering::Relaxed);
    })
    .map_err(|err| format!("failed to install Ctrl-C handler: {err}").into())
}

/// Confirms that a local MySQL listener completed its no-password handshake.
fn mysql_ping(host: IpAddr, port: u16) -> io::Result<()> {
    let mut stream = mysql_connect(host, port)?;
    write_packet(&mut stream, b"\x0e", 0)?;
    let packet = read_packet(&mut stream)?;
    if packet.first() == Some(&0) {
        Ok(())
    } else {
        Err(mysql_packet_error(&packet))
    }
}

/// Requests MariaDB's own shutdown path before the host fallback is used.
fn mysql_shutdown(host: IpAddr, port: u16) -> io::Result<()> {
    let mut stream = mysql_connect(host, port)?;
    write_packet(&mut stream, b"\x08", 0)?;
    match read_packet(&mut stream) {
        Ok(packet) if packet.first() == Some(&0) => Ok(()),
        Ok(packet) if packet.first() == Some(&0xff) => Err(mysql_packet_error(&packet)),
        Ok(_) => Ok(()),
        Err(err)
            if matches!(
                err.kind(),
                io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::UnexpectedEof
            ) =>
        {
            Ok(())
        }
        Err(err) => Err(err),
    }
}

/// Performs the minimal no-password MySQL protocol handshake used by releases.
fn mysql_connect(host: IpAddr, port: u16) -> io::Result<TcpStream> {
    let address = SocketAddr::new(host, port);
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;

    let greeting = read_packet(&mut stream)?;
    let server_capabilities = mysql_server_capabilities(&greeting)?;
    let client_capabilities = mysql_client_capabilities() & server_capabilities;
    let mut response = Vec::with_capacity(64);
    response.extend_from_slice(&client_capabilities.to_le_bytes());
    response.extend_from_slice(&(16_u32 * 1024 * 1024).to_le_bytes());
    response.push(0x21);
    response.extend_from_slice(&[0; 23]);
    response.extend_from_slice(b"root\0");
    response.push(0);
    if client_capabilities & MYSQL_CLIENT_PLUGIN_AUTH != 0 {
        response.extend_from_slice(b"caching_sha2_password\0");
    }
    response.push(0);
    write_packet(&mut stream, &response, 1)?;

    let packet = read_packet(&mut stream)?;
    match packet.first() {
        Some(0) => Ok(stream),
        Some(0x01) => {
            let packet = read_packet(&mut stream)?;
            if packet.first() == Some(&0) {
                Ok(stream)
            } else {
                Err(mysql_packet_error(&packet))
            }
        }
        _ => Err(mysql_packet_error(&packet)),
    }
}

const MYSQL_CLIENT_LONG_PASSWORD: u32 = 0x0000_0001;
const MYSQL_CLIENT_LONG_FLAG: u32 = 0x0000_0004;
const MYSQL_CLIENT_PROTOCOL_41: u32 = 0x0000_0200;
const MYSQL_CLIENT_TRANSACTIONS: u32 = 0x0000_2000;
const MYSQL_CLIENT_SECURE_CONNECTION: u32 = 0x0000_8000;
const MYSQL_CLIENT_MULTI_STATEMENTS: u32 = 0x0001_0000;
const MYSQL_CLIENT_MULTI_RESULTS: u32 = 0x0002_0000;
const MYSQL_CLIENT_PLUGIN_AUTH: u32 = 0x0008_0000;
const MYSQL_CLIENT_CONNECT_ATTRS: u32 = 0x0010_0000;

/// Selects only protocol features needed by the minimal local control client.
fn mysql_client_capabilities() -> u32 {
    MYSQL_CLIENT_LONG_PASSWORD
        | MYSQL_CLIENT_LONG_FLAG
        | MYSQL_CLIENT_PROTOCOL_41
        | MYSQL_CLIENT_TRANSACTIONS
        | MYSQL_CLIENT_SECURE_CONNECTION
        | MYSQL_CLIENT_MULTI_STATEMENTS
        | MYSQL_CLIENT_MULTI_RESULTS
        | MYSQL_CLIENT_PLUGIN_AUTH
        | MYSQL_CLIENT_CONNECT_ATTRS
}

/// Extracts capability flags from a protocol-41 greeting packet.
fn mysql_server_capabilities(packet: &[u8]) -> io::Result<u32> {
    if packet.first().copied().unwrap_or_default() < 10 {
        return Err(io::Error::other("unexpected MySQL greeting protocol"));
    }
    let mut pos = 1;
    let Some(server_version_end) = packet[pos..].iter().position(|byte| *byte == 0) else {
        return Err(io::Error::other("truncated MySQL greeting server version"));
    };
    pos += server_version_end + 1;
    pos = pos
        .checked_add(4 + 8 + 1)
        .ok_or_else(|| io::Error::other("truncated MySQL greeting"))?;
    if packet.len() < pos + 2 {
        return Err(io::Error::other("truncated MySQL greeting capabilities"));
    }
    let lower = u16::from_le_bytes([packet[pos], packet[pos + 1]]) as u32;
    pos += 2;
    if packet.len() <= pos {
        return Ok(lower);
    }
    pos = pos
        .checked_add(1 + 2)
        .ok_or_else(|| io::Error::other("truncated MySQL greeting"))?;
    if packet.len() < pos + 2 {
        return Ok(lower);
    }
    let upper = u16::from_le_bytes([packet[pos], packet[pos + 1]]) as u32;
    Ok(lower | (upper << 16))
}

/// Reads one length-prefixed MySQL packet from a synchronous local stream.
fn read_packet(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    let length =
        usize::from(header[0]) | (usize::from(header[1]) << 8) | (usize::from(header[2]) << 16);
    let mut packet = vec![0; length];
    stream.read_exact(&mut packet)?;
    Ok(packet)
}

/// Writes one MySQL packet with an explicit sequence number.
fn write_packet(stream: &mut TcpStream, packet: &[u8], sequence: u8) -> io::Result<()> {
    if packet.len() > 0x00ff_ffff {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "MySQL control packet is too large",
        ));
    }
    let length = packet.len() as u32;
    let header = [
        length as u8,
        (length >> 8) as u8,
        (length >> 16) as u8,
        sequence,
    ];
    stream.write_all(&header)?;
    stream.write_all(packet)
}

/// Converts a server error packet into a short host I/O error.
fn mysql_packet_error(packet: &[u8]) -> io::Error {
    if packet.first() == Some(&0xff) && packet.len() >= 3 {
        let code = u16::from_le_bytes([packet[1], packet[2]]);
        let message = if packet.len() > 9 {
            &packet[9..]
        } else {
            &packet[3..]
        };
        return io::Error::other(format!(
            "MySQL error {code}: {}",
            String::from_utf8_lossy(message)
        ));
    }
    io::Error::other("unexpected MySQL control response")
}

/// Picks a temporary loopback port for local tooling that requests `PORT=auto`.
fn parse_port(value: &str, bind_address: IpAddr) -> Result<u16> {
    if value == "auto" {
        let listener = TcpListener::bind(SocketAddr::new(bind_address, 0))?;
        return Ok(listener.local_addr()?.port());
    }
    let port = value
        .parse::<u16>()
        .map_err(|_| format!("PORT must be a number from 1 to 65535 or auto, got: {value}"))?;
    if port == 0 {
        return Err("PORT must not be zero; use PORT=auto to select a local port".into());
    }
    Ok(port)
}

/// Resolves a release sibling before falling back to a source-tree binary.
fn resolve_binary(cli_value: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = cli_value {
        return validate_executable(make_absolute(path.to_path_buf()));
    }
    if let Some(path) = env_value("BIN") {
        return validate_executable(make_absolute(PathBuf::from(path)));
    }
    let exe_suffix = env::consts::EXE_SUFFIX;
    let mut candidates = Vec::new();
    if let Ok(current) = env::current_exe()
        && let Some(parent) = current.parent()
    {
        candidates.push(parent.join(format!("wasmtime-mariadb{exe_suffix}")));
    }
    if let Ok(cwd) = env::current_dir() {
        candidates.push(cwd.join(format!("wasmtime-mariadb{exe_suffix}")));
        candidates.push(
            cwd.join("target")
                .join("release")
                .join(format!("wasmtime-mariadb{exe_suffix}")),
        );
    }
    for candidate in candidates {
        if candidate.is_file() {
            return validate_executable(candidate);
        }
    }
    Err("runner binary not found; pass --bin PATH or set BIN".into())
}

/// Finds the constrained local bootstrap shipped next to a release or source tree.
fn resolve_system_tables_source(bin: &Path) -> Result<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(parent) = bin.parent() {
        candidates.push(parent.join("scripts").join("mariadb-system-tables.sql"));
    }
    if let Ok(current) = env::current_exe()
        && let Some(parent) = current.parent()
    {
        candidates.push(parent.join("scripts").join("mariadb-system-tables.sql"));
    }
    candidates
        .push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts/mariadb-system-tables.sql"));
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| "MariaDB system-table bootstrap not found next to the runner".into())
}

/// Creates the default run directory relative to the caller's current directory.
fn resolve_run_dir(cli_value: Option<&Path>) -> Result<PathBuf> {
    let path = cli_value
        .map(Path::to_path_buf)
        .or_else(|| env_value("RUN_DIR").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("build/run"));
    Ok(make_absolute(path))
}

/// Parses the existing simple RUNNER_ARGS convention without inheriting the host environment.
fn parse_runner_args(value: Option<String>) -> Result<Vec<String>> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    if value.contains('\0') {
        return Err("RUNNER_ARGS must not contain a NUL byte".into());
    }
    Ok(value.split_whitespace().map(ToOwned::to_owned).collect())
}

/// Rejects an accidental request to weaken strict durability through extra args.
fn reject_relaxed_strict_conflict(durability: Durability, args: &[String]) -> Result<()> {
    if durability != Durability::Strict {
        return Ok(());
    }
    if args
        .iter()
        .any(|arg| arg == "--debug-no-sync" || arg.starts_with("--debug-no-sync="))
    {
        return Err(
            "DURABILITY=strict cannot be combined with --debug-no-sync; use DURABILITY=relaxed only for disposable benchmarks"
                .into(),
        );
    }
    Ok(())
}

/// Extracts the embedded runner's version without loading the MariaDB module.
fn runner_version(bin: &Path) -> Result<String> {
    let output = Command::new(bin).arg("--version").output().map_err(|err| {
        format!(
            "failed to read runner version from {}: {err}",
            bin.display()
        )
    })?;
    if !output.status.success() {
        return Err(format!("runner --version failed for {}", bin.display()).into());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    Ok(text
        .split_whitespace()
        .nth(1)
        .unwrap_or("unknown")
        .trim()
        .to_owned())
}

/// Ensures callers cannot accidentally run a directory or missing binary.
fn validate_executable(path: PathBuf) -> Result<PathBuf> {
    if !path.is_file() {
        return Err(format!("runner binary not found: {}", path.display()).into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if path.metadata()?.permissions().mode() & 0o111 == 0 {
            return Err(format!("runner binary is not executable: {}", path.display()).into());
        }
    }
    Ok(path)
}

/// Applies owner-only permissions where the operating system exposes POSIX modes.
fn ensure_private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Applies owner-only permissions to metadata that reveals a local endpoint.
fn restrict_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// Writes JSON through a temporary file so an interrupted update is detectable.
fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    write_atomic(path, &bytes)
}

/// Writes a replacement file and synchronizes it before it becomes visible.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("path has no parent: {}", path.display()))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("metadata"),
        std::process::id()
    ));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }

    #[cfg(windows)]
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(&temporary, path)?;

    #[cfg(unix)]
    File::open(parent)?.sync_all()?;
    Ok(())
}

/// Writes the process identifier expected by MTR and external local tooling.
fn write_pid_file(path: &Path, pid: u32) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_atomic(path, format!("{pid}\n").as_bytes())
}

/// Removes stale process metadata after the child has exited.
fn remove_pid_file(path: Option<&Path>) {
    if let Some(path) = path {
        fs::remove_file(path).ok();
    }
}

/// Returns a process-specific path used by the supervisor stop command.
fn stop_path(run_dir: &Path) -> PathBuf {
    run_dir.join(STOP_FILE)
}

/// Converts a possibly relative user path to an absolute host path.
fn make_absolute(path: PathBuf) -> PathBuf {
    if path.is_absolute() {
        path
    } else {
        env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

/// Reads an optional nonempty environment variable without inheriting it into the guest.
fn env_value(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.is_empty())
}

/// Reads the conventional `1`/`true` local-runner feature flags.
fn env_flag(name: &str) -> bool {
    matches!(
        env_value(name).as_deref(),
        Some("1" | "true" | "TRUE" | "yes" | "YES")
    )
}

/// Preserves the release helper's explicit `SKIP_GRANT_TABLES=0` escape hatch.
fn skip_grant_tables_from_env() -> bool {
    !matches!(env_value("SKIP_GRANT_TABLES").as_deref(), Some("0"))
}

/// Produces stable-enough local metadata without claiming it is a secret token.
fn new_instance_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{:x}-{:x}", std::process::id(), nanos)
}

/// Returns wall-clock seconds only for metadata and diagnostics.
fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Compares plain numeric release versions and deliberately ignores unknown forms.
fn version_is_newer(recorded: &str, current: &str) -> bool {
    let Some(recorded) = parse_version(recorded) else {
        return false;
    };
    let Some(current) = parse_version(current) else {
        return false;
    };
    recorded > current
}

/// Parses the numeric prefix of a semantic version into a comparable tuple.
fn parse_version(value: &str) -> Option<Vec<u64>> {
    let value = value.trim_start_matches('v').split(['-', '+']).next()?;
    let parts = value
        .split('.')
        .map(str::parse::<u64>)
        .collect::<std::result::Result<Vec<_>, _>>()
        .ok()?;
    (!parts.is_empty()).then_some(parts)
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
    fn parses_explicit_and_auto_ports() {
        assert_eq!(
            parse_port("3307", IpAddr::from([127, 0, 0, 1])).unwrap(),
            3307
        );
        assert!(parse_port("auto", IpAddr::from([127, 0, 0, 1])).unwrap() > 0);
        assert!(parse_port("0", IpAddr::from([127, 0, 0, 1])).is_err());
    }

    #[test]
    fn prevents_runner_downgrades() {
        assert!(version_is_newer("0.2.0", "0.1.11"));
        assert!(!version_is_newer("0.1.11", "0.2.0"));
        assert!(!version_is_newer("unknown", "0.1.11"));
    }

    #[test]
    fn rejects_relaxed_strict_conflict() {
        assert!(
            reject_relaxed_strict_conflict(Durability::Strict, &["--debug-no-sync".to_owned()])
                .is_err()
        );
    }

    #[test]
    fn rejects_interrupted_initialization_manifest() {
        let manifest = RunManifest {
            format_version: DATA_FORMAT_VERSION,
            runner: "wasmtime-mariadb".to_owned(),
            runner_version: "0.1.11".to_owned(),
            mariadb_series: MARIADB_SERIES.to_owned(),
            instance_id: "test".to_owned(),
            created_unix_seconds: 0,
            state: MANIFEST_STATE_INITIALIZING.to_owned(),
        };
        assert!(validate_manifest(&manifest, "0.1.11").is_err());
    }
}
