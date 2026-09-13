# Copy this file to config.ps1 to persist local overrides. Command-line
# arguments passed to the deployment scripts take precedence.
$ModelDir = Join-Path $PSScriptRoot "ollama-models"
$ModelUrl = "https://www.modelscope.ai/models/unsloth/Qwen3.8-27B-GGUF/resolve/master/Qwen3.8-27B-UD-IQ3_S.gguf?view=false"
$ModelFile = "Qwen3.8-27B-UD-IQ3_S.gguf"
$Port = 11435
$DefaultContext = "128k"
$ModelName96K = "qwen3.8-27b-iq3s-96k"
$ModelName128K = "qwen3.8-27b-iq3s-128k"
