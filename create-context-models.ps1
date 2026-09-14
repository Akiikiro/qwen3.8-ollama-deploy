param(
    [string]$HostUrl = "127.0.0.1:11435",
    [string]$BaseModel = "qwen3.8-27b-iq3s"
)

$ErrorActionPreference = "Stop"

$profiles = @(
    @{
        Name    = "qwen3.8-27b-iq3s-40k"
        Context = 40960
    },
    @{
        Name    = "qwen3.8-27b-iq3s-48k"
        Context = 49152
    },
    @{
        Name    = "qwen3.8-27b-iq3s-64k"
        Context = 65536
    },
    @{
        Name    = "qwen3.8-27b-iq3s-96k"
        Context = 98304
    },
    @{
        Name    = "qwen3.8-27b-iq3s-128k"
        Context = 131072
    },
    @{
        Name    = "qwen3.8-27b-iq3s-130k"
        Context = 133120
    },
    @{
        Name    = "qwen3.8-27b-iq3s-132k"
        Context = 135168
    },
    @{
        Name    = "qwen3.8-27b-iq3s-134k"
        Context = 137216
    },
    @{
        Name    = "qwen3.8-27b-iq3s-144k"
        Context = 147456
    },
    @{
        Name    = "qwen3.8-27b-iq3s-160k"
        Context = 163840
    },
    @{
        Name    = "qwen3.8-27b-iq3s-192k"
        Context = 196608
    },
    @{
        Name    = "qwen3.8-27b-iq3s-224k"
        Context = 229376
    },
    @{
        Name    = "qwen3.8-27b-iq3s-256k"
        Context = 262144
    }
)

$oldHost = $env:OLLAMA_HOST

try {
    $env:OLLAMA_HOST = $HostUrl

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " Ollama Context Profile Creator"
    Write-Host "=========================================="
    Write-Host "Endpoint:   $HostUrl"
    Write-Host "Base model: $BaseModel"
    Write-Host ""

    # --------------------------------------------------------
    # 1. Confirm Ollama server is reachable
    # --------------------------------------------------------

    Write-Host "[1/3] Checking Ollama server..."

    try {
        $null = Invoke-RestMethod `
            -Uri "http://$HostUrl/api/tags" `
            -Method Get `
            -TimeoutSec 10
    }
    catch {
        throw "Cannot reach Ollama at http://$HostUrl"
    }

    Write-Host "[PASS] Ollama is reachable."
    Write-Host ""

    # --------------------------------------------------------
    # 2. Confirm base model exists
    # --------------------------------------------------------

    Write-Host "[2/3] Checking base model..."

    $modelList = & ollama list

    if ($LASTEXITCODE -ne 0) {
        throw "ollama list failed."
    }

    $baseFound = $false

    foreach ($line in $modelList) {
        if ($line -match "^$([regex]::Escape($BaseModel))(?::latest)?\s") {
            $baseFound = $true
            break
        }
    }

    if (-not $baseFound) {
        Write-Host ""
        Write-Host "Available models:"
        $modelList | ForEach-Object {
            Write-Host "  $_"
        }

        throw "Base model '$BaseModel' was not found on $HostUrl."
    }

    Write-Host "[PASS] Base model exists."
    Write-Host ""

    # --------------------------------------------------------
    # 3. Create context profiles
    # --------------------------------------------------------

    Write-Host "[3/3] Creating context profiles..."
    Write-Host ""

    foreach ($profile in $profiles) {

        $modelName = $profile.Name
        $context   = $profile.Context

        Write-Host "------------------------------------------"
        Write-Host "Model:   $modelName"
        Write-Host "Context: $context"
        Write-Host "------------------------------------------"

        $modelfile = @"
FROM $BaseModel

PARAMETER num_ctx $context
PARAMETER num_predict 7168
"@

        $tempFile = Join-Path `
            $env:TEMP `
            "ollama-context-$context-$([guid]::NewGuid().ToString('N')).Modelfile"

        try {
            Set-Content `
                -LiteralPath $tempFile `
                -Value $modelfile `
                -Encoding UTF8

            & ollama create $modelName -f $tempFile

            if ($LASTEXITCODE -ne 0) {
                throw "ollama create failed for $modelName"
            }

            Write-Host "[PASS] Created $modelName"
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force
            }
        }

        Write-Host ""
    }

    Write-Host "=========================================="
    Write-Host " Creation complete"
    Write-Host "=========================================="
    Write-Host ""

    & ollama list
}
finally {
    if ($null -eq $oldHost) {
        Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
    }
    else {
        $env:OLLAMA_HOST = $oldHost
    }
}
