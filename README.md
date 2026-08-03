# Sandbox local AI agents on macOS

This repository provides `sandbox-exec` profiles to run:

1. [`llama-server`][1]
1. [`mlx_lm.server`][5]
1. [`pi`][4]
1. [`opencode`][2]
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
```

The sandbox is default-deny and only allows access to the GPU and the models.
Network access is disabled for `llama-server`. Models are downloaded through
`curl` (outside of the sandbox).

### `mlx-lm`

[MLX][5]'s' `mlx_lm.server` exposes the an OpenAI-compatible API as well

```bash
# Install mlx_lm or use `nix develop`
brew install mlx-lm

# Sandbox it and run it
./sandbox.sh mlx-server --model mlx-community/Qwen3-8B-4bit

# Vision models are automatically detected and served with `mlx_vlm.server`.
```

### `pi` and `opencode`

```bash
# Install opencode or use `nix develop`
brew install opencode pi-coding-agent

# Run it in the sandbox
# Use `-w` to specify a workspace directory
./sandbox.sh opencode

# Same for `pi`
brew install pi-coding-agent
pi install npm:pi-llama-cpp
./sandbox.sh pi
```

The sandbox prevents `opencode` and `pi` from reaching the internet and
constraints writes to the workspace (the script directory by default). See
[this blog post][0] for how to run un-sandboxed `opencode` in a Linux VM that
connects to the local instance of `llama-server`.

## Usage

```bash
Usage: sandbox.sh <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  mlx-server    Start mlx_lm.server (sandboxed)
  opencode      Start opencode (sandboxed)
  pi            Start pi (pi-coding-agent) with the llama-cpp plugin (sandboxed)
  llm           Run llm CLI (sandboxed)

llama-server options:
  --model SPEC          Local path, HF file (org/repo:file.gguf), or
                        HF quant (org/repo:Q4_K_M). Omit the part after ':'
                        to list available GGUF files.
  --mmproj SPEC         Multimodal projector for vision models, same spec
                        grammar. Quant labels match only mmproj-*.gguf files.
  --socket PATH         Serve on a UNIX domain socket (path must end in
                        .sock) instead of TCP.
  All other flags are passed through to llama-server.

mlx-server options:
  --model SPEC          Local model directory or HF repo of an MLX model
                        (e.g. mlx-community/Qwen3-8B-4bit). Vision models
                        (config.json with a vision tower) are served with
                        mlx_vlm.server, text models with mlx_lm.server.
  --socket PATH         Serve on a UNIX domain socket (path must end in
                        .sock) instead of TCP.
  All other flags are passed through to the server.

opencode options:
  -w, --workspace DIR   Workspace directory (default: current directory)
  Additional args are passed through to opencode.

pi options:
  -w, --workspace DIR   Workspace directory (default: current directory)
  Additional args are passed through to pi.

llm options:
  All args are passed through to llm (use its -m to pick a model; the
  default model is preset to "llama-server").

Environment:
  SANDBOXED_AI_HOME  Root for writable state and models (default: current dir)
  SANDBOXED_AI_PROG  Program name shown in this help (set by the Nix wrapper)
  MODEL              Model spec (overridden by --model)
  MMPROJ             Projector spec (overridden by --mmproj)
  LLAMA_SERVER, MLX_SERVER, MLX_VLM_SERVER, OPENCODE, PI, LLM
                     Explicit binary paths (fallback: PATH lookup)
  PI_LLAMA_DIR       Dir holding the pi llama-cpp plugin's index.ts
                     (set by the Nix wrapper; required for the pi command)
  NIX_SSL_CERT_FILE  CA bundle granted read-only to the mlx sandbox
  LLAMA_API_KEY, OPENAI_API_KEY
                     Client API keys; local servers accept the "dummy" default
```

[0]: https://aldur.blog/articles/2026/03/12/sandboxing-local-models-on-macos
[1]: https://github.com/ggml-org/llama.cpp
[2]: https://opencode.ai/
[3]: https://github.com/simonw/llm
[4]: https://pi.dev/
[5]: https://github.com/ml-explore/mlx-lm
