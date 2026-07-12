param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version,
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$AssetSuffix,
    [Parameter(Position = 2)]
    [string]$Binary = 'target/release/wasmtime-mariadb.exe',
    [Parameter(Position = 3)]
    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Binary = Join-Path $Root $Binary
$Supervisor = Join-Path (Split-Path -Parent $Binary) 'wasmtime-mariadb-supervisor.exe'
if (-not (Test-Path $Binary)) {
    throw "runner binary not found: $Binary"
}
if (-not (Test-Path $Supervisor)) {
    throw "supervisor binary not found: $Supervisor"
}

$OutDir = Join-Path $Root $OutDir
$Name = "wasmtime-mariadb-$Version-$AssetSuffix"
$PackageDir = Join-Path $OutDir $Name
$Archive = Join-Path $OutDir "wasmtime-mariadb-$AssetSuffix.zip"
Remove-Item -Recurse -Force $PackageDir -ErrorAction SilentlyContinue
Remove-Item -Force $Archive -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $PackageDir 'scripts') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PackageDir 'docs') | Out-Null

Copy-Item $Binary $PackageDir
Copy-Item $Supervisor $PackageDir
Copy-Item (Join-Path $Root 'README.md') $PackageDir
Copy-Item (Join-Path $Root 'docs/*.md') (Join-Path $PackageDir 'docs')
Copy-Item (Join-Path $Root 'scripts/bench-tcp.py') (Join-Path $PackageDir 'scripts')
Copy-Item (Join-Path $Root 'scripts/mariadb-system-tables.sql') (Join-Path $PackageDir 'scripts')
Copy-Item (Join-Path $Root 'scripts/run-server.ps1') (Join-Path $PackageDir 'scripts')
Copy-Item (Join-Path $Root 'scripts/stop-server.ps1') (Join-Path $PackageDir 'scripts')
Copy-Item (Join-Path $Root 'scripts/test-supervisor-lifecycle.py') (Join-Path $PackageDir 'scripts')

Compress-Archive -Path $PackageDir -DestinationPath $Archive -CompressionLevel Optimal
Get-Item $Archive | Select-Object Name, Length
