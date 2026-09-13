[CmdletBinding()]
param(
    [string]$ModelDir,
    [string]$ModelUrl,
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
$requestedModelUrl = $ModelUrl
$requestedPort = $Port
$requestedContext = $Context
. $configPath
if ($requestedModelDir) { $ModelDir = $requestedModelDir }
if ($requestedModelUrl) { $ModelUrl = $requestedModelUrl }
if ($requestedPort -gt 0) { $Port = $requestedPort }
if ($requestedContext) { $Context = $requestedContext } else { $Context = $DefaultContext }
if (-not $Context) { $Context = "128k" }
if ($Port -lt 1 -or $Port -gt 65535) { throw "Configured Port must be between 1 and 65535." }
$ModelDir = [IO.Path]::GetFullPath($ModelDir)
$ggufDir = Join-Path $scriptRoot "models"
$ggufPath = Join-Path $ggufDir $ModelFile
$partPath = "$ggufPath.part"
$baseModelName = "qwen3.8-27b-iq3s"

function Find-OllamaExecutable {
    $command = Get-Command ollama -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
        (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
    )
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

Write-Host "[1/6] Checking Ollama..."
$ollamaPath = Find-OllamaExecutable
if (-not $ollamaPath) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "Ollama is missing and Windows Package Manager (winget) is unavailable. Install Ollama from https://ollama.com/download/windows, reopen PowerShell, and rerun this script."
    }
    Write-Host "Ollama is not installed. Installing Ollama.Ollama with winget..."
    & $winget.Source install --id Ollama.Ollama --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install Ollama (exit code $LASTEXITCODE). Install it from https://ollama.com/download/windows, then rerun this script."
    }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
    $ollamaPath = Find-OllamaExecutable
    if (-not $ollamaPath) {
        throw "Ollama installation completed, but ollama.exe is not available in this PowerShell session. Open a new PowerShell window and rerun .\install.ps1."
    }
}
Write-Host "Ollama: $ollamaPath"

Write-Host "[2/6] Checking NVIDIA GPU..."
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
$nvidiaSmiPath = if ($nvidiaSmi) { $nvidiaSmi.Source } else { $null }
if (-not $nvidiaSmi) {
    $standardNvidiaSmi = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path -LiteralPath $standardNvidiaSmi) {
        $nvidiaSmiPath = $standardNvidiaSmi
    }
}
if (-not $nvidiaSmiPath) {
    throw "No NVIDIA driver tool (nvidia-smi) was found. Install a compatible NVIDIA GPU and current NVIDIA driver before deploying this model."
}
$gpuNames = & $nvidiaSmiPath --query-gpu=name --format=csv,noheader 2>$null
if ($LASTEXITCODE -ne 0 -or -not $gpuNames) {
    throw "nvidia-smi could not detect a compatible NVIDIA GPU. Check the GPU and driver installation."
}
$gpuNames | ForEach-Object { Write-Host "Detected NVIDIA GPU: $($_.Trim())" }

Write-Host "[3/6] Preparing GGUF..."
if (Test-Path -LiteralPath $ggufPath) {
    if ((Get-Item -LiteralPath $ggufPath).Length -le 0) {
        throw "The existing GGUF is empty: $ggufPath. Remove it and rerun the installer."
    }
    Write-Host "GGUF already exists, skipping download: $ggufPath"
} else {
    New-Item -ItemType Directory -Path $ggufDir -Force | Out-Null
    if (Test-Path -LiteralPath $partPath) {
        Write-Warning "Removing stale incomplete download: $partPath"
        Remove-Item -LiteralPath $partPath -Force
    }
    Write-Host "Downloading $ModelFile"
    Write-Host "Temporary file: $partPath"
    try {
        Add-Type -AssemblyName System.Net.Http
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $handler.MaxAutomaticRedirections = 10
        $httpClient = New-Object System.Net.Http.HttpClient -ArgumentList $handler
        $httpClient.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) WindowsPowerShell/5.1")
        $httpClient.DefaultRequestHeaders.Accept.ParseAdd("application/octet-stream")
        $httpClient.DefaultRequestHeaders.Accept.ParseAdd("*/*")
        $response = $null
        $inputStream = $null
        $outputStream = $null
        $finalHttpStatus = $null
        $finalHttpReason = $null
        $resolvedRequestUri = $null
        try {
            $response = $httpClient.GetAsync($ModelUrl, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $finalHttpStatus = [int]$response.StatusCode
            $finalHttpReason = $response.ReasonPhrase
            if ($null -ne $response.RequestMessage -and $null -ne $response.RequestMessage.RequestUri) {
                $resolvedRequestUri = $response.RequestMessage.RequestUri.AbsoluteUri
            }
            $response.EnsureSuccessStatusCode() | Out-Null
            $totalBytes = $response.Content.Headers.ContentLength
            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [IO.File]::Open($partPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $buffer = New-Object byte[] 1048576
            $downloadedBytes = [int64]0
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $lastProgressUpdate = [TimeSpan]::Zero

            while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $bytesRead)
                $downloadedBytes += $bytesRead
                if (($stopwatch.Elapsed - $lastProgressUpdate).TotalMilliseconds -ge 500) {
                    $downloadedGiB = $downloadedBytes / 1GB
                    $averageMiBPerSecond = ($downloadedBytes / 1MB) / [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
                    if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                        $totalGiB = $totalBytes / 1GB
                        $percentComplete = [Math]::Min(100, ($downloadedBytes / $totalBytes) * 100)
                        $status = "{0:N2} / {1:N2} GiB  ({2:N1}%)  {3:N1} MiB/s" -f $downloadedGiB, $totalGiB, $percentComplete, $averageMiBPerSecond
                        Write-Progress -Activity "Downloading $ModelFile" -Status $status -PercentComplete $percentComplete
                    } else {
                        $status = "{0:N2} GiB downloaded  {1:N1} MiB/s" -f $downloadedGiB, $averageMiBPerSecond
                        Write-Progress -Activity "Downloading $ModelFile" -Status $status
                    }
                    Write-Host "`r$status" -NoNewline
                    $lastProgressUpdate = $stopwatch.Elapsed
                }
            }
            $outputStream.Flush()
            $stopwatch.Stop()
            Write-Progress -Activity "Downloading $ModelFile" -Completed
            $finalGiB = $downloadedBytes / 1GB
            $finalAverageMiBPerSecond = ($downloadedBytes / 1MB) / [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
            if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                if ($downloadedBytes -ne $totalBytes) {
                    throw "Download ended after $downloadedBytes of $totalBytes bytes."
                }
                Write-Host ("`r{0:N2} / {1:N2} GiB  (100.0%)  {2:N1} MiB/s" -f $finalGiB, ($totalBytes / 1GB), $finalAverageMiBPerSecond)
            } else {
                Write-Host ("`r{0:N2} GiB downloaded  {1:N1} MiB/s" -f $finalGiB, $finalAverageMiBPerSecond)
            }
        } finally {
            if ($null -ne $outputStream) { $outputStream.Dispose() }
            if ($null -ne $inputStream) { $inputStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $httpClient) { $httpClient.Dispose() }
            if ($null -ne $handler) { $handler.Dispose() }
        }
    } catch {
        Write-Progress -Activity "Downloading $ModelFile" -Completed
        $httpFailureDetails = ""
        if ($null -ne $finalHttpStatus) {
            $httpFailureDetails += " Final HTTP status: $finalHttpStatus"
            if (-not [string]::IsNullOrWhiteSpace($finalHttpReason)) {
                $httpFailureDetails += " ($finalHttpReason)"
            }
            $httpFailureDetails += "."
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedRequestUri)) {
            $httpFailureDetails += " Resolved request URI: $resolvedRequestUri."
        }
        throw "GGUF download failed.$httpFailureDetails The incomplete file remains at '$partPath'. Check network access, the URL, and free disk space. $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $partPath) -or (Get-Item -LiteralPath $partPath).Length -le 0) {
        throw "GGUF download did not produce a non-empty file. The .part file was not promoted to the final GGUF."
    }
    Move-Item -LiteralPath $partPath -Destination $ggufPath
    Write-Host "Download complete: $ggufPath"
}

Write-Host "[4/6] Starting configured Ollama server..."
& (Join-Path $scriptRoot "start-ollama.ps1") -ModelDir $ModelDir -Port $Port
if ($LASTEXITCODE -ne 0) { throw "Ollama startup failed with exit code $LASTEXITCODE." }

$modelName = if ($Context -eq "128k") { $ModelName128K } else { $ModelName96K }
$templateName = if ($Context -eq "128k") { "Modelfile.128k" } else { "Modelfile.96k" }
$templatePath = Join-Path $scriptRoot $templateName
$generatedBaseModelfile = Join-Path $ModelDir ".Modelfile.base.generated"
$escapedGgufPath = $ggufPath.Replace('\', '/')

Write-Host "[5/6] Creating base model and selected context model..."
$savedHost = $env:OLLAMA_HOST
$savedModels = $env:OLLAMA_MODELS
try {
    $env:OLLAMA_HOST = "127.0.0.1:$Port"
    $env:OLLAMA_MODELS = $ModelDir
    $tags = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -Method Get -TimeoutSec 10
    $baseTag = @($tags.models | Where-Object { $_.name -eq $baseModelName -or $_.name -eq "$baseModelName`:latest" })
    if ($baseTag.Count -eq 0) {
        Set-Content -LiteralPath $generatedBaseModelfile -Value ('FROM "' + $escapedGgufPath + '"') -Encoding UTF8
        Write-Host "Creating base model tag '$baseModelName' from $ModelFile..."
        & $ollamaPath create $baseModelName --file $generatedBaseModelfile
        if ($LASTEXITCODE -ne 0) { throw "ollama create failed with exit code $LASTEXITCODE." }
    } else {
        Write-Host "Base model tag '$baseModelName' already exists; creation skipped."
    }
    Write-Host "Creating context model tag '$modelName' from '$baseModelName'..."
    & $ollamaPath create $modelName --file $templatePath
    if ($LASTEXITCODE -ne 0) { throw "ollama create failed with exit code $LASTEXITCODE." }
} finally {
    $env:OLLAMA_HOST = $savedHost
    $env:OLLAMA_MODELS = $savedModels
    Remove-Item -LiteralPath $generatedBaseModelfile -Force -ErrorAction SilentlyContinue
}

Write-Host "[6/6] Verifying deployment..."
& (Join-Path $scriptRoot "verify.ps1") -ModelDir $ModelDir -Port $Port -Context $Context
if ($LASTEXITCODE -ne 0) { throw "Verification failed with exit code $LASTEXITCODE." }

Write-Host ""
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Model:" -ForegroundColor Green
Write-Host "  $modelName" -ForegroundColor Green
Write-Host ""
Write-Host "Endpoint:" -ForegroundColor Green
Write-Host "  http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host ""
Write-Host "To use this deployment with the Ollama CLI:" -ForegroundColor Green
Write-Host ""
Write-Host ('  $env:OLLAMA_HOST="127.0.0.1:' + $Port + '"') -ForegroundColor Green
Write-Host "  ollama run $modelName" -ForegroundColor Green
