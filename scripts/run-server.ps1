param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$MariaDBArgs
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ($env:SUPERVISOR) {
    $Supervisor = $env:SUPERVISOR
} elseif ($env:BIN -and (Test-Path (Join-Path (Split-Path -Parent (Resolve-Path $env:BIN)) 'wasmtime-mariadb-supervisor.exe'))) {
    $Supervisor = Join-Path (Split-Path -Parent (Resolve-Path $env:BIN)) 'wasmtime-mariadb-supervisor.exe'
} elseif (Test-Path (Join-Path $Root 'wasmtime-mariadb-supervisor.exe')) {
    $Supervisor = Join-Path $Root 'wasmtime-mariadb-supervisor.exe'
} else {
    $Supervisor = Join-Path $Root 'target/release/wasmtime-mariadb-supervisor.exe'
}

if (-not (Test-Path $Supervisor)) {
    throw "MariaDB supervisor not found: $Supervisor. Build with MARIADBD_WASM=/path/to/mariadbd cargo build --release."
}

# The supervisor treats everything after -- as an embedded mariadbd argument.
& $Supervisor -- @MariaDBArgs
exit $LASTEXITCODE
