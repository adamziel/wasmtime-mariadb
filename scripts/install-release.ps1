param(
    [string]$Version = 'latest'
)

$ErrorActionPreference = 'Stop'
$Repo = if ($env:REPO) { $env:REPO } else { 'adamziel/wasmtime-mariadb' }
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'unsupported platform: 32-bit Windows'
}

$AssetSuffix = 'windows-x86_64'
$Archive = "wasmtime-mariadb-$AssetSuffix.zip"
$BaseUrl = if ($Version -eq 'latest') {
    "https://github.com/$Repo/releases/latest/download"
} else {
    "https://github.com/$Repo/releases/download/$Version"
}

Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $Archive
Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS" -OutFile 'SHA256SUMS'
$Expected = (Get-Content 'SHA256SUMS' | Where-Object { $_ -match "\s\s$([regex]::Escape($Archive))$" } | Select-Object -First 1).Split()[0]
if (-not $Expected) {
    throw "checksum for $Archive not found in SHA256SUMS"
}
$Actual = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
if ($Actual -ne $Expected.ToLowerInvariant()) {
    throw "checksum mismatch for $Archive"
}

$Staging = "$Archive.extract-$PID"
Remove-Item -Recurse -Force $Staging -ErrorAction SilentlyContinue
Expand-Archive -Path $Archive -DestinationPath $Staging
$Extracted = @(Get-ChildItem -Directory $Staging)
if ($Extracted.Count -ne 1) {
    throw "expected one release directory in $Archive"
}
$ReleaseDir = $Extracted[0].Name
if (Test-Path $ReleaseDir) {
    throw "refusing to overwrite existing release directory: $ReleaseDir"
}
Move-Item $Extracted[0].FullName $ReleaseDir
Remove-Item -Recurse -Force $Staging

Write-Host "Downloaded and verified $Archive."
Write-Host "Extracted to: $ReleaseDir"
Write-Host ''
Write-Host 'Run MariaDB in a separate step:'
Write-Host "  cd `"$((Get-Location).Path)\$ReleaseDir`"; `$env:PORT = '3307'; .\scripts\run-server.ps1"
Write-Host ''
Write-Host 'After it reports ready, connect from another PowerShell window:'
Write-Host '  mysql --protocol=TCP -h127.0.0.1 -P3307 -uroot --skip-ssl'
