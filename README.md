# Sandbox local AI agents on macOS

This repository provides `sandbox-exec` profiles to run:

1. [`llama-server`][1]
1. [`mlx_lm.server`][5]
1. [MTPLX][6]
1. [TensorFold][7]
1. [`pi`][4]
1. [`simonw/llm`][3]

[sandbox.sh](./sandbox.sh) script takes care of setting up the sandbox
and configuring the tools.

See [this blog post][0] for background, more info, and Qwen3.5 test-runs.

## Sandboxing: how to

> [!TIP]
> If you use `nix`, you can just run `nix run github:aldur/sandboxed-ai
> llama-server` or `nix shell github:aldur/sandboxed-ai` to bring
> `sandboxed-ai`, `pi`, etc into PATH.

The [sandbox.sh](./sandbox.sh) script does the heavy lifting.

### `llama.cpp`

```bash
# Install llama.cpp, or use `nix develop`
brew install llama.cpp

# Sandbox it and run it
./sandbox.sh llama-server --model unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q8_K_XL

# Binds to localhost:8080
# Additional arguments go to `llama-server`
# --mmproj automatically handles the download of multimodal projector

# Draft models (`-hfd`/`--model-draft`) and chat template files use the
# same spec grammar:
./sandbox.sh llama-server \
  -hf ggml-org/Qwen3.8-27B-GGUF:Q4_K_M \
  -hfd ggml-org/Qwen3.8-27B-GGUF:Q4_0 \
  --jinja --chat-template-file froggeric/Qwen-Fixed-Chat-Templates:chat_template.jinja
```

The sandbox is default-deny and only allows access to the GPU and the models.
Network access is disabled for `llama-server`. Models, draft models, and
chat templates are downloaded through `curl` (outside of the sandbox) and
checksum-verified. The sandbox reads them read-only.

### `mlx-lm`

[MLX][5]'s `mlx_lm.server` exposes the an OpenAI-compatible API as well

```bash
# Install mlx_lm or use `nix develop`
brew install mlx-lm

# Sandbox it and run it
./sandbox.sh mlx-server --model mlx-community/Qwen3-8B-4bit

# Vision models are automatically detected and served with `mlx_vlm.server`.
```

### MTPLX

[MTPLX][6] serves MLX models, has built-in MTP support, and  speaks OpenAI and
Anthropic API.

```bash
# Install mtplx or use `nix develop`
brew install youssofal/mtplx/mtplx

# Sandbox it and run it
./sandbox.sh mtplx --model Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed

# Optional: calibrate the draft depth for your machine
./sandbox.sh mtplx tune --model Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed
```

The sandbox has the same posture of `mlx-lm`. The server runs offline and reads
the weights read-only. It binds `127.0.0.1:8080` by default; `--host
/path/llama.sock` serves on a UNIX domain socket instead. The sandbox denies
the fan-control helper that `tune` normally spawns, so tuning runs with a bit
more timing noise.

### TensorFold

[TensorFold][7] serves supported MLX model families through OpenAI-compatible
chat, completion, and Responses endpoints.

```bash
# The Nix wrapper includes TensorFold and its Metal-enabled dependencies.
nix run . -- tensorfold --model Vontra/Qwen3.8-27B-MLX-4bit

# Optional external draft model, downloaded and verified before sandboxing:
nix run . -- tensorfold --model Vontra/Qwen3.8-27B-MLX-4bit \
  --drafter z-lab/Qwen3.8-27B-DFlash2

# UNIX socket (supported by a patch):
nix run . -- tensorfold --model Vontra/Qwen3.8-27B-MLX-4bit \
  --host /tmp/tensorfold.sock
```

The server binds `127.0.0.1:8080` by default. Models and optional drafters are
read-only, outbound connections and subprocesses are denied. Conversation
snapshots are stored in TensorFold's cache. Update checks are disabled. The
`auto` drafter setting only sees this isolated cache; use `--drafter`
explicitly to add an external draft model. Get the served model ID from
`/v1/models`. The Nix build also provides `/props` and context metadata for the
`pi` plugin.

TensorFold supports specific architectures and quantization formats. The Nix
package includes its vision, grammar, and SSD-streaming dependencies:

- `--vision` enables image understanding for supported Qwen3.5/3.8 dense
  checkpoints that include their vision weights. Send images as inline data
  URLs; the sandbox blocks remote image downloads.
- `response_format` enables JSON or JSON Schema constraints. `guided_regex`,
  `guided_choice`, `guided_grammar`, and `structured_outputs` are also supported.
- `--ssd-experts GIB` streams expert weights for supported GLM-5.3-Flash and
  Qwen3.8 Flash Next checkpoints into a bounded GPU pool. The native extension
  is built with Nix and loaded from the read-only package store. The server
  needs no compiler or additional sandbox permissions. `--ple-on-ssd` supports
  Flash Next's file-backed n-gram tables as well.

```bash
nix run . -- tensorfold --model mlx-community/Qwen3.5-9B-4bit --vision
```

`--context`, `--no-thinking`, `--no-drafts`, and other serving options pass
through. Set `TENSORFOLD_MEMORY_LIMIT_GB` if the default memory budget cannot
fit your model. TensorFold's upstream model and GPU restrictions still apply.

### `pi`

```bash
# Install pi or use `nix develop`
brew install pi-coding-agent
pi install npm:pi-llama-cpp

# Run it in the sandbox
# Use `-w` to specify a workspace directory
./sandbox.sh pi
```

The sandbox prevents `pi` from reaching the internet and constrains writes
to the workspace (the current directory by default). See [this blog post][0]
for how to run un-sandboxed agents in a Linux VM that connect to the local
server instance.

## Usage

```bash
Usage: sandbox.sh <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  llama-bench   Run llama-bench (sandboxed, no network)
  mlx-server    Start mlx_lm.server (sandboxed)
  tensorfold    Start TensorFold (sandboxed)
  mtplx         Start the MTPLX server (sandboxed); `mtplx tune` runs its
                draft-depth calibration (sandboxed, no network)
  pi            Start pi (pi-coding-agent) with the llama-cpp plugin (sandboxed)
  llm           Run llm CLI (sandboxed)

llama-server options:
  --model SPEC          Local path, HF file (org/repo:file.gguf), or
                        HF quant (org/repo:Q4_K_M). Omit the part after ':'
                        to list available GGUF files. llama-server's
                        -hf/-hfr/--hf-repo are accepted as aliases.
  --model-draft SPEC    Draft model for speculative decoding, same spec
                        grammar (aliases: -md, -hfd, -hfrd, --hf-repo-draft).
  --chat-template-file SPEC
                        Chat template: local path or HF file
                        (org/repo:file.jinja). Omit the part after ':' to
                        list the repo's .jinja files. Pair with --jinja.
  --mmproj SPEC         Multimodal projector for vision models, same spec
                        grammar. Quant labels match only mmproj-*.gguf files.
  --host ADDR           TCP address to bind (default 127.0.0.1), or a
                        UNIX domain socket when ADDR ends in .sock.
  --port PORT           TCP port to bind (default 8080).
  All other flags are passed through to llama-server.

llama-bench options:
  --model SPEC          Same spec grammar as llama-server (llama-bench's
                        own -m and the -hf aliases also work). The spec
                        resolves and downloads host-side; the bench then
                        runs with no network at all.
  All other flags are passed through to llama-bench (-p, -n, -b, -ub,
  -ngl, -fa, -ctk, -ctv, ...).

mlx-server options:
  --model SPEC          Local model directory or HF repo of an MLX model
                        (e.g. mlx-community/Qwen3-8B-4bit). Vision models
                        (config.json with a vision tower) are served with
                        mlx_vlm.server, text models with mlx_lm.server.
  --host ADDR           TCP address to bind (default 127.0.0.1), or a
                        UNIX domain socket when ADDR ends in .sock.
  --port PORT           TCP port to bind (default 8080).
  All other flags are passed through to the server.

tensorfold options:
  --model SPEC          Local directory or HF repo of a supported MLX model.
  --drafter SPEC        Local directory or HF repo; auto (default) or none.
                        Both model and drafter download before sandboxing.
  --host ADDR           TCP address (default 127.0.0.1), or a .sock path
                        with the Nix build's UNIX-socket patch.
  --port PORT           TCP port (default 8080).
  All other flags are passed through to `tensorfold serve`.

mtplx options:
  tune                  Leading word: run `mtplx tune` instead of serving.
                        Same sandbox, no network; the tuned draft depth
                        lands in the cache and every later serve uses it.
  --model SPEC          Local model directory or HF repo of an MTPLX-ready
                        MLX model (e.g. Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed).
                        The full repo downloads host-side; the server then
                        runs with no network at all.
  --host ADDR           TCP address to bind (default 127.0.0.1), or a
                        UNIX domain socket when ADDR ends in .sock.
  --port PORT           TCP port to bind (default 8080).
  All other flags are passed through to `mtplx serve` (or `mtplx tune`).

pi options:
  -w, --workspace DIR   Workspace directory (default: current directory)
  --port PORT           Port of the running server (default 8080)
  Additional args are passed through to pi.

llm options:
  --port PORT           Port of the running server (default 8080)
  All other args are passed through to llm (use its -m to pick a model;
  the default model is preset to the running server's).

Environment:
  XDG_STATE_HOME     Parent of the per-user dir holding models, caches and
                     each tool's home (default: ~/.local/state)
  SANDBOXED_AI_MODELS
                     Model directory, for weights on another volume
                     (default: $XDG_STATE_HOME/sandboxed-ai/models)
  SANDBOXED_AI_PROG  Program name shown in this help (set by the Nix wrapper)
  MODEL              Model spec (overridden by --model)
  MMPROJ             Projector spec (overridden by --mmproj)
  LLAMA_SERVER, LLAMA_BENCH, MLX_SERVER, MLX_VLM_SERVER, MTPLX, TENSORFOLD, PI, LLM, CURL
                     Explicit binary paths (fallback: PATH lookup)
  PI_LLAMA_DIR       Dir holding the pi llama-cpp plugin's index.ts
                     (set by the Nix wrapper; required for the pi command)
  MTPLX_SESSION_BANK_MAX_BYTES, MTPLX_SESSION_BANK_PER_SESSION_BYTES,
  MTPLX_SESSION_BANK_MAX_ENTRIES
                     mtplx session-cache budgets (wrapper defaults:
                     8G total, 4G per session; the server's auto
                     formula overcommits RAM on long contexts)
  MTPLX_POSTCOMMIT_FOREGROUND_GRACE_S
                     seconds the async KV commit can run before it
                     yields to a queued request (wrapper default: 120,
                     so agent loops keep their prompt cache)
  MTPLX_SESSION_POSTCOMMIT_MODE, MTPLX_POSTCOMMIT_CROSS_SESSION_YIELD
                     mtplx KV-commit policy overrides, passed through
  TENSORFOLD_MEMORY_LIMIT_GB
                     TensorFold process memory budget in GiB
  NIX_SSL_CERT_FILE  CA bundle granted read-only to the mlx sandbox
  LLAMA_API_KEY, OPENAI_API_KEY
                     Client API keys; local servers accept the "dummy" default
```

[0]: https://aldur.blog/articles/2026/03/12/sandboxing-local-models-on-macos
[1]: https://github.com/ggml-org/llama.cpp
[3]: https://github.com/simonw/llm
[4]: https://pi.dev/
[5]: https://github.com/ml-explore/mlx-lm
[6]: https://github.com/youssofal/MTPLX
[7]: https://github.com/ashhart/TensorFold
