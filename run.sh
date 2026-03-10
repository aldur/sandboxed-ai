#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── XDG / cache ───────────────────────────────────────────
export XDG_CONFIG_HOME="$SCRIPT_DIR/.opencode/config"
export XDG_STATE_HOME="$SCRIPT_DIR/.opencode/state"
export XDG_DATA_HOME="$SCRIPT_DIR/.opencode/data"
export XDG_CACHE_HOME="/tmp/llama-cache"
mkdir -p "$XDG_CACHE_HOME"

# ── Paths ─────────────────────────────────────────────────
LLAMA_DIR="${LLAMA_SERVER_DIR:-$SCRIPT_DIR/llama-b8234}"
MODEL_DIR="$SCRIPT_DIR/unsloth"
CACHE_DIR="$XDG_CACHE_HOME"
PORT="${LLAMA_PORT:-8080}"
MODEL="$MODEL_DIR/Qwen3.5-35B-A3B-GGUF/unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-Q8_0.gguf"

# ── Command ───────────────────────────────────────────────
CMD="${1:-}"
WORKSPACE="$SCRIPT_DIR" # default

usage() {
  echo "Usage: $(basename "$0") <llama|opencode>" >&2
  exit 1
}

case "$CMD" in
llama)
  echo "llama-dir : $LLAMA_DIR"
  echo "model-dir : $MODEL_DIR"
  echo "cache-dir : $CACHE_DIR"
  echo "port      : $PORT"
  exec sandbox-exec \
    -D LLAMA_DIR="$LLAMA_DIR" \
    -D MODEL_DIR="$MODEL_DIR" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D SCRIPT_DIR="$SCRIPT_DIR" \
    -D PORT="$PORT" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$LLAMA_DIR/llama-server" \
    --model "$MODEL" \
    --ctx-size 32768 \
    --temp 0.6 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.00 \
    --presence_penalty 0.00 \
    --alias "unsloth/Qwen3.5-35B-A3B-GGUF" \
    --port "$PORT"
  ;;
opencode)
  shift
  # Check for -w/--workspace flag
  if [[ "${1:-}" == "-w" || "${1:-}" == "--workspace" ]]; then
    WORKSPACE="$2"
    shift 2
  fi
  export OPENCODE_DISABLE_MODELS_FETCH=1
  export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
  export OPENCODE_DISABLE_TERMINAL_TITLE=1
  ulimit -n 2147483646
  exec sandbox-exec \
    -D WORKSPACE="$WORKSPACE" \
    -D OPENCODE_DIR="$SCRIPT_DIR/.opencode" \
    -D GITCONFIG="$HOME/.gitconfig" \
    -D GIT_CONFIG_ALT="$HOME/.config/git/config" \
    -D SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
    -f "$SCRIPT_DIR/opencode.sb" \
    opencode "$@"
  ;;
*)
  usage
  ;;
esac
