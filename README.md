# qwen3.8-ollama-deploy

This is an independent, one-click Windows deployment project for the tuned Qwen3.8-27B IQ3_S Ollama profiles. It has no application or web-service dependencies. It is intended for Windows with an NVIDIA GPU and current NVIDIA drivers. The measurements that informed these profiles were made on an RTX 5070 Ti with 16GB VRAM; other GPUs, drivers, and Ollama versions can behave differently.

The installer detects or installs Ollama, checks the NVIDIA GPU, downloads the GGUF safely, imports it as the `qwen3.8-27b-iq3s` base model, creates the selected context model from that base, starts the configured server, and verifies a non-thinking generation request.

By default, deployment data is kept under the repository root with the raw GGUF in `models\Qwen3.8-27B-UD-IQ3_S.gguf` and Ollama's `blobs` and `manifests` under `ollama-models\`.

This deployment is isolated from the normal Windows Ollama service. It starts its own server on port 11435 and gives only that process `OLLAMA_KV_CACHE_TYPE=q4_0`, `OLLAMA_FLASH_ATTENTION=1`, and the repository-local `OLLAMA_MODELS` path. The user's normal server on port 11434, its environment, and its models are not changed.

## Quick start

Open PowerShell in this directory and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

If your execution policy already permits scripts, you can use the normal PowerShell form:

```powershell
.\install.ps1
```

The default is the 128K context profile:

- Model tag: `qwen3.8-27b-iq3s-128k`
- Configured `num_ctx`: 131,072
- KV cache: q4_0
- Flash Attention: enabled
- Endpoint: `http://127.0.0.1:11435` locally; Ollama listens on `0.0.0.0:11435`

To install the optional 96K context profile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Context 96k
```

To put the Ollama model store on another drive:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ModelDir "D:\ollama-models" `
  -Port 11436 `
  -Context 96k
```

`-ModelDir` overrides only the Ollama model store; the raw GGUF remains under this repository's `models\` directory. `-ModelUrl` can override the download URL. To keep local defaults, copy `config.example.ps1` to `config.ps1` and edit the copy. Command-line arguments take precedence. No credentials are required or stored.

The download is large. The installer first checks `models\Qwen3.8-27B-UD-IQ3_S.gguf`. If it is present and non-empty, the download is skipped. Otherwise, the installer writes `models\Qwen3.8-27B-UD-IQ3_S.gguf.part` and renames it only after a successful, non-empty download. Rerunning the installer reuses existing model data; it does not reinstall Ollama or redownload the GGUF unnecessarily.

By default it downloads `Qwen3.8-27B-UD-IQ3_S.gguf` from the unsloth Qwen3.8-27B-GGUF ModelScope repository specified in `config.example.ps1`.

## Later operation

For the default port 11435:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-ollama.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop-ollama.ps1
```

If you installed with a custom -Port, pass the same -Port to start, verify, and stop. For example, for port 11436:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-ollama.ps1 -Port 11436
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Port 11436
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop-ollama.ps1 -Port 11436
```

Verify the 96K tag with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Context 96k
```

The one-click installer supports the 96K and 128K profiles. After the base model has been installed, `create-context-models.ps1` can create the full profile set on the isolated server:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\create-context-models.ps1
```

| Profile | Model tag | `num_ctx` |
| --- | --- | ---: |
| 40K | `qwen3.8-27b-iq3s-40k` | 40,960 |
| 48K | `qwen3.8-27b-iq3s-48k` | 49,152 |
| 64K | `qwen3.8-27b-iq3s-64k` | 65,536 |
| 96K | `qwen3.8-27b-iq3s-96k` | 98,304 |
| 128K | `qwen3.8-27b-iq3s-128k` | 131,072 |
| 130K | `qwen3.8-27b-iq3s-130k` | 133,120 |
| 132K | `qwen3.8-27b-iq3s-132k` | 135,168 |
| 134K | `qwen3.8-27b-iq3s-134k` | 137,216 |
| 144K | `qwen3.8-27b-iq3s-144k` | 147,456 |
| 160K | `qwen3.8-27b-iq3s-160k` | 163,840 |
| 192K | `qwen3.8-27b-iq3s-192k` | 196,608 |
| 224K | `qwen3.8-27b-iq3s-224k` | 229,376 |
| 256K | `qwen3.8-27b-iq3s-256k` | 262,144 |

To check how a profile actually loads, pass its model tag to `check-ollama-model.ps1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\check-ollama-model.ps1 qwen3.8-27b-iq3s-128k
```

The check unloads the model, triggers a clean non-thinking generation, and inspects only the new isolated-server log entries. It reports the loaded context, full or partial GPU layer offload, CUDA and host model buffers, CPU/CUDA KV-cache placement, K/V cache types with an explicit q4_0 result, Flash Attention detection, GPU memory planning, and runner size/VRAM. These results depend on the log format emitted by the installed Ollama version; missing evidence is reported as not found, not confirmed, or unknown.

The start script records the PID it launches and refuses to start a duplicate server. The stop script stops only that recorded Ollama process when its identity can be confirmed. It does not kill every Ollama process on the machine.

Managed server output is written to `logs/ollama-<port>.stdout.log` and `logs/ollama-<port>.stderr.log`. These local runtime files are excluded from Git.

## Use the isolated deployment

After `start-ollama.ps1` starts the isolated server on port 11435, point commands in the current PowerShell session at that server with:

```powershell
$env:OLLAMA_HOST="127.0.0.1:11435"
ollama list
ollama ps
ollama run qwen3.8-27b-iq3s-128k
```

Use `qwen3.8-27b-iq3s-96k` in the last command if that context model was installed. This session-local environment variable changes only where those CLI commands connect; it does not persistently modify Windows.

To switch the CLI back to the normal Ollama server in the current PowerShell session, remove the override:

```powershell
Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
```

Because `OLLAMA_HOST` is session-local, closing that PowerShell session also clears the override.

## What each setting means

- **Configured `num_ctx`** is the maximum context capacity stored in the Ollama model profile: 98,304 for 96K or 131,072 for 128K. It does not mean every request fills that capacity.
- **Actual populated context** is the number of prompt tokens actually processed. The benchmarks showed that decode throughput declines and TTFT grows as this actual amount grows.
- **q4_0 KV cache** reduces memory used to store attention history. It is set with the Ollama server environment variable `OLLAMA_KV_CACHE_TYPE=q4_0`.
- **Flash Attention** selects Ollama's optimized attention implementation. It is enabled at server startup with `OLLAMA_FLASH_ATTENTION=1`.
- **`think:false`** disables thinking for an individual API request. It is deliberately not a server or Modelfile parameter. Clients must include it in each request that should not use thinking.

The q4_0 KV cache and Flash Attention are server-level settings. `num_ctx` and `num_predict 7168` are stored in the selected Ollama model profile. The server listens on all interfaces through `OLLAMA_HOST=0.0.0.0:11435` by default; local examples use `127.0.0.1` to connect.

## Context recommendation

The installer uses 128K by default. Choose 96K when requests fit within it and additional GPU headroom is preferred. On the RTX 5070 Ti 16GB benchmark machine, 96K retained 1,834 MiB of projected GPU headroom versus 1,098 MiB for 128K.

At equal populated-context points, the measurements did **not** show a material performance difference between the 96K and 128K profiles; 128K should not be described as inherently slower. Its memory configuration was, however, close to Ollama's recorded fit reserve threshold on the benchmark machine: the projected 1,098 MiB remaining was only 74 MiB above the recorded 1,024 MiB reserve.

## Troubleshooting

### Ollama is already running

The standalone deployment uses port 11435 to avoid conflicting with the normal Windows Ollama service on its default port 11434. If port 11435 is already occupied, the installer does not silently reuse an Ollama server it did not start because its model storage and server settings cannot be confirmed. Stop the other instance or pass another port consistently to install, start, and verify. A server on a different port can coexist.

### Port 11435 is occupied

The start script reports the owning PID and process name. Stop that application or choose another port, for example `-Port 11436`. It will not replace or kill an unrelated listener.

### Model download was interrupted

A failed or interrupted download leaves its `.part` file in place. On the next installation attempt, the installer reports and removes that stale file before downloading again. The final `.gguf` name is used only after a successful, non-empty download.

### Insufficient disk space

Free enough space under the repository for the GGUF download and in the Ollama model store for imported model data. A disk-full download fails without promoting the partial file. `-ModelDir` can place only the Ollama model store on a larger drive.

### Insufficient VRAM

Close other GPU-heavy applications and try 96K. GPUs different from the measured RTX 5070 Ti 16GB may use CPU fallback or fail to load. The 128K profile has less headroom and was close to the recorded fit reserve threshold.

### Server is not reachable

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-ollama.ps1`, confirm the endpoint it prints, then run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1`. Check the deployment-local files under `logs/`, Task Manager, port selection, and the NVIDIA driver if startup fails.

### Windows Firewall or LAN access

`0.0.0.0` allows Ollama to listen on network interfaces, but Windows Firewall may still block inbound traffic. Add a narrowly scoped inbound rule for the configured TCP port only if LAN clients need access. Do not expose an unauthenticated Ollama endpoint to untrusted networks or the public internet.
