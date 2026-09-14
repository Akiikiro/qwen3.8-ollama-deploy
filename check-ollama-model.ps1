param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Model,

    [string]$HostUrl = "127.0.0.1:11435",

    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $ScriptDir "logs\ollama-11435.stderr.log"
}

Write-Host ""
Write-Host "=========================================="
Write-Host " Ollama Model Load Check"
Write-Host "=========================================="
Write-Host "Model:    $Model"
Write-Host "Endpoint: http://$HostUrl"
Write-Host "Log:      $LogPath"
Write-Host ""

# ------------------------------------------------------------
# Check server
# ------------------------------------------------------------

Write-Host "[1/5] Checking Ollama server..."

try {
    $null = Invoke-RestMethod `
        -Uri "http://$HostUrl/api/tags" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Write-Host ""
    Write-Host "[FAIL] Cannot reach Ollama at http://$HostUrl"
    Write-Host ""
    exit 1
}

Write-Host "[PASS] Ollama server reachable."
Write-Host ""

# ------------------------------------------------------------
# Check log
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Host "[FAIL] Log file not found:"
    Write-Host "       $LogPath"
    exit 1
}

# ------------------------------------------------------------
# Temporarily point Ollama CLI to 11435
# ------------------------------------------------------------

$oldHost = $env:OLLAMA_HOST

try {

    $env:OLLAMA_HOST = $HostUrl

    # --------------------------------------------------------
    # Stop model first
    # --------------------------------------------------------

    Write-Host "[2/5] Unloading existing model..."

    # Important:
    # Do NOT redirect Ollama stderr to $null.
    # Ollama on Windows may fail with:
    # "failed to get console mode for stderr"
    & ollama stop $Model

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] ollama stop returned exit code $LASTEXITCODE"
    }

    Start-Sleep -Seconds 2

    # --------------------------------------------------------
    # Record log position AFTER unloading
    # --------------------------------------------------------

    $startLine = (Get-Content -LiteralPath $LogPath).Count

    Write-Host "Start:    line $($startLine + 1)"
    Write-Host ""

    # --------------------------------------------------------
    # Trigger clean model load
    # --------------------------------------------------------

    Write-Host "[3/5] Triggering model load..."

    $body = @{
        model  = $Model
        prompt = "Reply with the single word ready."
        stream = $false
        think  = $false

        options = @{
            temperature = 0
            num_predict = 1
        }
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod `
            -Uri "http://$HostUrl/api/generate" `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 600
    }
    catch {
        Write-Host ""
        Write-Host "[FAIL] Model load request failed."
        Write-Host $_
        exit 1
    }

    Write-Host "[PASS] Model responded."
    Write-Host ""

    # Give Ollama a moment to flush logs
    Start-Sleep -Seconds 2

    # --------------------------------------------------------
    # Read only new log lines
    # --------------------------------------------------------

    Write-Host "[4/5] Reading new log entries..."

    $allLines = Get-Content -LiteralPath $LogPath

    if ($allLines.Count -le $startLine) {
        Write-Host ""
        Write-Host "[WARN] No new log lines found."
        exit 0
    }

    $newLines = $allLines | Select-Object -Skip $startLine

    # Store line number + text
    $entries = @()

    for ($i = 0; $i -lt $newLines.Count; $i++) {
        $entries += [PSCustomObject]@{
            Line = $startLine + $i + 1
            Text = $newLines[$i]
        }
    }

    # --------------------------------------------------------
    # Extract important information
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[5/5] Load summary"
    Write-Host ""
    Write-Host "=========================================="
    Write-Host " Summary"
    Write-Host "=========================================="

    # Context
    $contextLine = $entries |
        Where-Object {
            $_.Text -match 'llama_context:\s+n_ctx\s*='
        } |
        Select-Object -Last 1

    if ($contextLine) {
        if ($contextLine.Text -match 'n_ctx\s*=\s*(\d+)') {
            Write-Host ("Context:              {0}" -f $Matches[1])
        }
        else {
            Write-Host "Context:"
            Write-Host "  $($contextLine.Text)"
        }
    }
    else {
        Write-Host "Context:              not found"
    }


    # --------------------------------------------------------
    # GPU layer offload
    # --------------------------------------------------------

    $offloadingLines = $entries |
        Where-Object {
            $_.Text -match 'load_tensors:\s+offloading'
        }

    $offloadedLine = $entries |
        Where-Object {
            $_.Text -match 'load_tensors:\s+offloaded'
        } |
        Select-Object -Last 1

    if ($offloadedLine) {
        if ($offloadedLine.Text -match 'offloaded\s+(\d+)\/(\d+)\s+layers') {

            $gpuLayers = [int]$Matches[1]
            $totalLayers = [int]$Matches[2]

            Write-Host ("GPU layer offload:    {0}/{1}" -f $gpuLayers, $totalLayers)

            if ($gpuLayers -eq $totalLayers) {
                Write-Host "Offload status:       FULL GPU"
            }
            else {
                Write-Host ("Offload status:       PARTIAL GPU ({0} not offloaded)" -f ($totalLayers - $gpuLayers))
            }
        }
        else {
            Write-Host "GPU layer offload:"
            Write-Host "  $($offloadedLine.Text)"
        }
    }
    else {
        Write-Host "GPU layer offload:    not found"
    }


    # --------------------------------------------------------
    # Model buffers
    # --------------------------------------------------------

    $cudaModel = $entries |
        Where-Object {
            $_.Text -match 'CUDA\d+\s+model buffer size'
        } |
        Select-Object -Last 1

    $hostModel = $entries |
        Where-Object {
            $_.Text -match 'CUDA_Host\s+model buffer size'
        } |
        Select-Object -Last 1

    if ($cudaModel -and $cudaModel.Text -match 'buffer size\s*=\s*([0-9.]+)\s*MiB') {
        Write-Host ("CUDA model buffer:    {0} MiB" -f $Matches[1])
    }
    else {
        Write-Host "CUDA model buffer:    not found"
    }

    if ($hostModel -and $hostModel.Text -match 'buffer size\s*=\s*([0-9.]+)\s*MiB') {
        Write-Host ("CUDA Host buffer:     {0} MiB" -f $Matches[1])
    }
    else {
        Write-Host "CUDA Host buffer:     not found"
    }


    # --------------------------------------------------------
    # KV cache placement
    # --------------------------------------------------------

    $cpuKV = $entries |
        Where-Object {
            $_.Text -match 'CPU\s+KV buffer size'
        } |
        Select-Object -Last 1

    $cudaKV = $entries |
        Where-Object {
            $_.Text -match 'CUDA\d+\s+KV buffer size'
        } |
        Select-Object -Last 1

    if ($cpuKV -and $cpuKV.Text -match 'buffer size\s*=\s*([0-9.]+)\s*MiB') {
        Write-Host ("CPU KV buffer:        {0} MiB" -f $Matches[1])
    }
    else {
        Write-Host "CPU KV buffer:        none reported"
    }

    if ($cudaKV -and $cudaKV.Text -match 'buffer size\s*=\s*([0-9.]+)\s*MiB') {
        Write-Host ("CUDA KV buffer:       {0} MiB" -f $Matches[1])
    }
    else {
        Write-Host "CUDA KV buffer:       not found"
    }


    # --------------------------------------------------------
    # KV cache type
    # --------------------------------------------------------

    $kvDetail = $entries |
        Where-Object {
            $_.Text -match 'llama_kv_cache:\s+size\s*='
        } |
        Select-Object -Last 1

    $kType = $null
    $vType = $null

    if ($kvDetail) {

        if ($kvDetail.Text -match 'K\s+\(([^)]+)\)') {
            $kType = $Matches[1]
        }

        if ($kvDetail.Text -match 'V\s+\(([^)]+)\)') {
            $vType = $Matches[1]
        }

        if ($kType -or $vType) {
            Write-Host ("KV cache type:        K={0}, V={1}" -f $kType, $vType)
        }
        else {
            Write-Host "KV cache type:        unable to parse"
        }
    }
    else {
        Write-Host "KV cache type:        not found"
    }


    # Explicit q4_0 check
    if ($kType -eq "q4_0" -and $vType -eq "q4_0") {
        Write-Host "KV q4_0 status:       PASS"
    }
    elseif ($kType -or $vType) {
        Write-Host "KV q4_0 status:       FAIL"
    }
    else {
        Write-Host "KV q4_0 status:       UNKNOWN"
    }


    # --------------------------------------------------------
    # Flash Attention
    # --------------------------------------------------------

    $flashLine = $entries |
        Where-Object {
            $_.Text -match 'Flash Attention enabled' -or
            $_.Text -match 'flash_attn\s*=\s*enabled'
        } |
        Select-Object -Last 1

    if ($flashLine) {
        Write-Host "Flash Attention:      ENABLED"
    }
    else {
        Write-Host "Flash Attention:      not confirmed"
    }


    # --------------------------------------------------------
    # GPU memory planning
    # --------------------------------------------------------

    $availableLine = $entries |
        Where-Object {
            $_.Text -match 'available.*MiB' -or
            $_.Text -match 'free.*MiB'
        } |
        Select-Object -Last 1

    $projectedLine = $entries |
        Where-Object {
            $_.Text -match 'projected.*MiB'
        } |
        Select-Object -Last 1

    $leaveLine = $entries |
        Where-Object {
            $_.Text -match 'will leave.*MiB'
        } |
        Select-Object -Last 1

    Write-Host ""
    Write-Host "GPU memory planning:"

    if ($availableLine) {
        Write-Host "  Available:"
        Write-Host "    $($availableLine.Text)"
    }
    else {
        Write-Host "  Available:           not found"
    }

    if ($projectedLine) {
        Write-Host "  Projected:"
        Write-Host "    $($projectedLine.Text)"
    }
    else {
        Write-Host "  Projected:           not found"
    }

    if ($leaveLine) {
        Write-Host "  Remaining:"
        Write-Host "    $($leaveLine.Text)"
    }
    else {
        Write-Host "  Remaining:           not found"
    }


    # --------------------------------------------------------
    # Runner size / VRAM
    # --------------------------------------------------------

    $runnerLine = $entries |
        Where-Object {
            $_.Text -match 'runner\.size=' -and
            $_.Text -match 'runner\.vram='
        } |
        Select-Object -Last 1

    if ($runnerLine) {
        Write-Host ""
        Write-Host "Runner:"
        Write-Host "  $($runnerLine.Text)"
    }


    # --------------------------------------------------------
    # Full KV line
    # --------------------------------------------------------

    if ($kvDetail) {
        Write-Host ""
        Write-Host "KV detail:"
        Write-Host "  $($kvDetail.Text)"
    }


    # --------------------------------------------------------
    # Relevant raw log lines
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " Relevant raw log lines"
    Write-Host "=========================================="
    Write-Host ""

    $patterns = @(
        'runner args',
        'llama_context:\s+n_ctx',
        'load_tensors:\s+offloading',
        'load_tensors:\s+offloaded',
        'CUDA\d+\s+model buffer size',
        'CUDA_Host\s+model buffer size',
        'CPU\s+KV buffer size',
        'CUDA\d+\s+KV buffer size',
        'llama_kv_cache:\s+size',
        'Flash Attention enabled',
        'flash_attn\s*=\s*enabled',
        'available.*MiB',
        'free.*MiB',
        'projected.*MiB',
        'will leave.*MiB',
        'runner\.size=',
        'runner\.vram='
    )

    foreach ($entry in $entries) {

        $matched = $false

        foreach ($pattern in $patterns) {
            if ($entry.Text -match $pattern) {
                $matched = $true
                break
            }
        }

        if ($matched) {
            Write-Host ("{0}: {1}" -f $entry.Line, $entry.Text)
        }
    }

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " Done"
    Write-Host "=========================================="
    Write-Host ""
}
finally {

    # Restore caller's original OLLAMA_HOST
    if ($null -eq $oldHost) {
        Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
    }
    else {
        $env:OLLAMA_HOST = $oldHost
    }
}
