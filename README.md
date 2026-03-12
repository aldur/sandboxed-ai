# Sandbox local AI agents on macOS

This repository provides `sandbox-exec` profiles to run:

1. [`llama-server`][1]
1. [`opencode`][2]
1. [`simonw/llm`][3]

[sandbox.sh](./sandbox.sh) script takes care of setting up the sandbox
and configuring the tools.

See [this blog post][0] for background, more info, and Qwen3.5 test-runs.

## Sandboxing: how to

The [sandbox.sh](./sandbox.sh) script does the heavy lifting.

```bash
# Install llama.cpp, or use `nix develop`
brew install llama.cpp

# Sandbox it and run it
./sandbox.sh llama-server --model unsloth/Qwen3.5-9B-GGUF:Qwen3.5-9B-Q4_0.gguf

# Binds to localhost:8080
# Additional arguments go to `llama-server`
```

The sandbox is default-deny and only allows access to the GPU and the models.
Network access is disabled for `llama-server`. Models are downloaded through
`curl` (outside of the sandbox).

```bash
# Install opencode or use `nix develop`
brew install opencode

# Run it in the sandbox
# Use `-w` to specify a workspace directory
./sandbox.sh opencode
```

The sandbox prevents `opencode` from reaching the internet and constraints
writes to the workspace (the script directory by default). See [this blog
post][0] for how to run un-sandboxed `opencode` in a Linux VM that connects to
the local instance of `llama-server`.

## Usage

```bash
$ ./sandbox.sh
Usage: sandbox.sh <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  opencode  Start opencode (sandboxed)
  llm           Run llm CLI (sandboxed)

llama-server options:
  --model SPEC          Local path or HF ref (org/repo:file.gguf)
                        Omit filename to list available GGUF files
  All other flags are passed through to llama-server.

opencode options:
  -w, --workspace DIR   Workspace directory (default: script dir)
  Additional args are passed through to opencode.

llm options:
  -m, --model MODEL     Model name (default: llama-server)
  Additional args are passed through to llm.

Environment:
  MODEL             Model spec (overridden by --model)
  LLAMA_SERVER      Explicit path to llama-server binary (fallback: PATH)

```

[0]: https://aldur.blog/articles/2026/03/12/sandboxing-local-models-on-macos
[1]: https://github.com/ggml-org/llama.cpp
[2]: https://opencode.ai/
[3]: https://github.com/simonw/llm
