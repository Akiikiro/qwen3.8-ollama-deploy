[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot "config.ps1"
if (-not (Test-Path -LiteralPath $configPath)) {
    $configPath = Join-Path $scriptRoot "config.example.ps1"
}
$requestedPort = $Port
. $configPath
if ($requestedPort -gt 0) { $Port = $requestedPort }
if ($Port -lt 1 -or $Port -gt 65535) { throw "Configured Port must be between 1 and 65535." }
$pidFile = Join-Path $scriptRoot ".ollama-server-$Port.pid"

if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-Host "No deployment-managed Ollama PID file exists for port $Port. No process was stopped."
    exit 0
}

$serverPid = 0
if (-not ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$serverPid))) {
    throw "The deployment PID file is invalid: $pidFile. Remove it after confirming no managed Ollama server is running."
}

$process = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
if (-not $process) {
    Remove-Item -LiteralPath $pidFile -Force
    Write-Host "The recorded Ollama process $serverPid is no longer running. Removed the stale PID file."
    exit 0
}
if ($process.ProcessName -notmatch '^ollama(?: app)?$') {
    throw "PID $serverPid now belongs to '$($process.ProcessName)', not Ollama. It was not stopped. Remove the stale PID file manually after checking the process."
}
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $serverPid } | Select-Object -First 1
if (-not $listener) {
    throw "Recorded PID $serverPid is an Ollama process, but it is not the listener on configured port $Port. It was not stopped because its identity cannot be confirmed."
}

Stop-Process -Id $serverPid
$deadline = [DateTime]::UtcNow.AddSeconds(15)
while ((Get-Process -Id $serverPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 250
}
if (Get-Process -Id $serverPid -ErrorAction SilentlyContinue) {
    throw "Asked Ollama PID $serverPid to stop, but it did not exit within 15 seconds. Inspect it in Task Manager before taking further action."
}
Remove-Item -LiteralPath $pidFile -Force
Write-Host "Stopped deployment-managed Ollama server PID $serverPid on port $Port."
