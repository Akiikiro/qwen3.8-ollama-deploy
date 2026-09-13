[CmdletBinding()]
param(
    [string]$ModelDir,
    [ValidateRange(0, 65535)]
    [int]$Port = 0,
    [ValidateSet("96k", "128k")]
    [string]$Context
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot "config.ps1"
if (-not (Test-Path -LiteralPath $configPath)) {
    $configPath = Join-Path $scriptRoot "config.example.ps1"
}
$requestedModelDir = $ModelDir
$requestedPort = $Port
$requestedContext = $Context
. $configPath
if ($requestedModelDir) { $ModelDir = $requestedModelDir }
if ($requestedPort -gt 0) { $Port = $requestedPort }
if ($requestedContext) { $Context = $requestedContext } else { $Context = $DefaultContext }
if (-not $Context) { $Context = "128k" }
if ($Port -lt 1 -or $Port -gt 65535) { throw "Configured Port must be between 1 and 65535." }
$ModelDir = [IO.Path]::GetFullPath($ModelDir)
$modelName = if ($Context -eq "128k") { $ModelName128K } else { $ModelName96K }
$configuredNumCtx = if ($Context -eq "128k") { 131072 } else { 98304 }
$endpoint = "http://127.0.0.1:$Port"
$ggufPath = Join-Path (Join-Path $scriptRoot "models") $ModelFile

function Pass([string]$message) { Write-Host "[PASS] $message" -ForegroundColor Green }
function Fail([string]$message) { throw "[FAIL] $message" }

try { $tags = Invoke-RestMethod -Uri "$endpoint/api/tags" -Method Get -TimeoutSec 10 } catch {
    Fail "Ollama is not reachable at $endpoint. Run .\start-ollama.ps1 -Port $Port and check Windows Firewall."
}
Pass "Ollama reachable"

$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
$nvidiaSmiPath = if ($nvidiaSmi) { $nvidiaSmi.Source } else { $null }
if (-not $nvidiaSmi) {
    $standardNvidiaSmi = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path -LiteralPath $standardNvidiaSmi) {
        $nvidiaSmiPath = $standardNvidiaSmi
    }
}
if (-not $nvidiaSmiPath) { Fail "NVIDIA GPU detection failed because nvidia-smi is unavailable." }
$gpuNames = & $nvidiaSmiPath --query-gpu=name --format=csv,noheader 2>$null
if ($LASTEXITCODE -ne 0 -or -not $gpuNames) { Fail "No compatible NVIDIA GPU was detected." }
Pass "NVIDIA GPU detected: $(($gpuNames | ForEach-Object { $_.Trim() }) -join ', ')"

if (-not (Test-Path -LiteralPath $ggufPath) -or (Get-Item -LiteralPath $ggufPath).Length -le 0) {
    Fail "GGUF is missing or empty: $ggufPath"
}
Pass "GGUF present"

$matchingTag = @($tags.models | Where-Object { $_.name -eq $modelName -or $_.name -eq "$modelName`:latest" })
if ($matchingTag.Count -eq 0) { Fail "Model tag '$modelName' does not exist. Rerun .\install.ps1 -Context $Context." }
Pass "Model tag exists"

$requestBody = @{
    model = $modelName
    prompt = "Reply with the single word ready."
    stream = $false
    think = $false
    options = @{ temperature = 0 }
} | ConvertTo-Json -Depth 4
try {
    $generation = Invoke-RestMethod -Uri "$endpoint/api/generate" -Method Post -ContentType "application/json" -Body $requestBody -TimeoutSec 600
} catch {
    Fail "Generation request failed: $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace([string]$generation.response)) { Fail "Generation returned an empty response." }
Pass "Generation request succeeded"

try { $running = Invoke-RestMethod -Uri "$endpoint/api/ps" -Method Get -TimeoutSec 10 } catch {
    Fail "Generation succeeded, but /api/ps could not be queried: $($_.Exception.Message)"
}
$runner = @($running.models | Where-Object { $_.name -eq $modelName -or $_.name -eq "$modelName`:latest" }) | Select-Object -First 1
if (-not $runner) { Fail "The model generated text but is not listed by /api/ps as a loaded runner." }
Pass "Runner loaded"

$hasRuntimeContext = ($runner.PSObject.Properties.Name -contains "context_length") -and ($null -ne $runner.context_length)
$runtimeContext = if ($hasRuntimeContext) { $runner.context_length } else { $null }
$sizeVram = $null
if ($runner.PSObject.Properties.Name -contains "size_vram") { $sizeVram = $runner.size_vram }
Write-Host ""
Write-Host "Runner reported by /api/ps:"
Write-Host "  Model: $($runner.name)"
Write-Host "  Configured context: $configuredNumCtx"
if ($hasRuntimeContext) {
    Write-Host "  Runtime context: $runtimeContext"
    if ([int64]$runtimeContext -eq $configuredNumCtx) {
        Pass "Runtime context matches configured context: $configuredNumCtx"
    } else {
        Write-Warning "Runtime context $runtimeContext differs from configured context $configuredNumCtx."
    }
} else {
    Write-Host "  Runtime context: not exposed by this Ollama /api/ps response"
    Write-Warning "Runtime context could not be compared because /api/ps did not expose context_length."
}
if ($null -ne $sizeVram) { Write-Host "  GPU/VRAM status: size_vram=$sizeVram bytes" } else { Write-Host "  GPU/VRAM status: not exposed by this Ollama /api/ps response" }

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollama) {
    $savedHost = $env:OLLAMA_HOST
    try {
        $env:OLLAMA_HOST = "127.0.0.1:$Port"
        Write-Host ""
        Write-Host "ollama ps:"
        & $ollama.Source ps
    } finally {
        $env:OLLAMA_HOST = $savedHost
    }
}
Write-Warning "ollama ps PROCESSOR percentages are runtime labels and must not be interpreted as exact model-layer offload percentages."

Write-Host ""
Write-Host "Endpoint:"
Write-Host $endpoint
Write-Host ""
Write-Host "Model:"
Write-Host $modelName
Write-Host ""
Write-Host "Configured context:"
Write-Host $configuredNumCtx
Write-Host ""
Write-Host "Runtime context (/api/ps):"
if ($hasRuntimeContext) { Write-Host $runtimeContext } else { Write-Host "not available" }
Write-Host ""
Write-Host "Configured KV Cache:"
Write-Host "q4_0 (server setting; not exposed by /api/ps and not runtime-verified here)"
Write-Host ""
Write-Host "Configured Flash Attention:"
Write-Host "enabled (server setting; not exposed by /api/ps and not runtime-verified here)"
