[CmdletBinding()]
param(
    [string]$ModelDir,
    [ValidateRange(0, 65535)]
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot "config.ps1"
if (-not (Test-Path -LiteralPath $configPath)) {
    $configPath = Join-Path $scriptRoot "config.example.ps1"
}

$requestedModelDir = $ModelDir
$requestedPort = $Port
. $configPath
if ($requestedModelDir) { $ModelDir = $requestedModelDir }
if ($requestedPort -gt 0) { $Port = $requestedPort }
if ($Port -lt 1 -or $Port -gt 65535) { throw "Configured Port must be between 1 and 65535." }
$ModelDir = [IO.Path]::GetFullPath($ModelDir)
$endpoint = "http://127.0.0.1:$Port"
$pidFile = Join-Path $scriptRoot ".ollama-server-$Port.pid"
$logDir = Join-Path $scriptRoot "logs"
$stdoutLog = Join-Path $logDir "ollama-$Port.stdout.log"
$stderrLog = Join-Path $logDir "ollama-$Port.stderr.log"

Write-Warning "OLLAMA_HOST=0.0.0.0:$Port exposes Ollama on this machine's network interfaces. Configure Windows Firewall to allow only the networks and clients that should reach it."

function Test-OllamaApi {
    try {
        $null = Invoke-RestMethod -Uri "$endpoint/api/tags" -Method Get -TimeoutSec 3
        return $true
    } catch {
        return $false
    }
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $ownerName = if ($owner) { $owner.ProcessName } else { "unknown process" }
    $recordedPid = 0
    $managedListener = (Test-Path -LiteralPath $pidFile) -and
        ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$recordedPid)) -and
        ($recordedPid -eq $listener.OwningProcess) -and
        ($null -ne $owner) -and
        ($owner.ProcessName -match '^ollama(?: app)?$')
    if ($managedListener -and (Test-OllamaApi)) {
        Write-Host "Deployment-managed Ollama is already reachable at $endpoint (PID $recordedPid, $ownerName)."
        Write-Host "Logs: $stdoutLog and $stderrLog"
        exit 0
    }
    if (Test-OllamaApi) {
        throw "Port $Port is occupied by an Ollama API (PID $($listener.OwningProcess), $ownerName), but it was not started by this deployment. Its q4_0 KV and Flash Attention settings cannot be confirmed. Stop it or choose another -Port."
    }
    throw "Port $Port is already in use by PID $($listener.OwningProcess) ($ownerName), but it is not a reachable Ollama API. Stop that process or choose another -Port."
}

$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
$ollamaPath = if ($ollamaCommand) { $ollamaCommand.Source } else { $null }
if (-not $ollamaPath) {
    $ollamaPath = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
        (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ollamaPath) {
    throw "Ollama is not installed or is not on PATH. Run .\install.ps1 first."
}

New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$savedHost = $env:OLLAMA_HOST
$savedFlash = $env:OLLAMA_FLASH_ATTENTION
$savedKv = $env:OLLAMA_KV_CACHE_TYPE
$savedModels = $env:OLLAMA_MODELS
try {
    $env:OLLAMA_HOST = "0.0.0.0:$Port"
    $env:OLLAMA_FLASH_ATTENTION = "1"
    $env:OLLAMA_KV_CACHE_TYPE = "q4_0"
    $env:OLLAMA_MODELS = $ModelDir
    $startArguments = @{
        FilePath = $ollamaPath
        ArgumentList = "serve"
        WindowStyle = "Hidden"
        PassThru = $true
        RedirectStandardOutput = $stdoutLog
        RedirectStandardError = $stderrLog
    }
    $process = Start-Process @startArguments
} finally {
    $env:OLLAMA_HOST = $savedHost
    $env:OLLAMA_FLASH_ATTENTION = $savedFlash
    $env:OLLAMA_KV_CACHE_TYPE = $savedKv
    $env:OLLAMA_MODELS = $savedModels
}

Set-Content -LiteralPath $pidFile -Value $process.Id -Encoding ASCII
$deadline = [DateTime]::UtcNow.AddSeconds(60)
while ([DateTime]::UtcNow -lt $deadline) {
    if ($process.HasExited) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        throw "Ollama exited before its HTTP API became ready (exit code $($process.ExitCode)). Inspect '$stdoutLog' and '$stderrLog'."
    }
    if (Test-OllamaApi) {
        Write-Host "Ollama started (PID $($process.Id))."
        Write-Host "Endpoint: $endpoint"
        Write-Host "Logs: $stdoutLog and $stderrLog"
        exit 0
    }
    Start-Sleep -Milliseconds 500
}

Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
throw "Ollama did not become reachable at $endpoint within 60 seconds. Check Windows Firewall, port availability, '$stdoutLog', and '$stderrLog'."
