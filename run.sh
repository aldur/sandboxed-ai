#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────
PORT=8080
STATE_DIR="$SCRIPT_DIR/.opencode"
CACHE_DIR="$STATE_DIR/cache"
TMPDIR="$STATE_DIR/tmp"

# ── Helpers ───────────────────────────────────────────────
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
info() { printf '  %-14s %s\n' "$1" "$2"; }

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  llama     Start the llama-server (sandboxed)
  opencode  Start opencode (sandboxed)

llama options:
  --model PATH          Path to GGUF model file (required, or set MODEL env var)
  --ctx-size N          Context size (default: 32768)
  --temp N              Temperature (default: 0.6)
  --top-p N             Top-p / nucleus sampling (default: 0.95)
  --top-k N             Top-k sampling (default: 20)
  --min-p N             Min-p sampling (default: 0)
  --presence-penalty N  Presence penalty (default: 0)
  --port N              Listen port (default: 8080)

opencode options:
  -w, --workspace DIR   Workspace directory (default: script dir)
  Additional args are passed through to opencode.

Environment:
  MODEL             GGUF model path (overridden by --model)
  LLAMA_SERVER      Explicit path to llama-server binary (non-Nix fallback)
EOF
  exit 1
}

# Derive a model alias from the GGUF file path.
# Uses the parent directory name (e.g. .../Qwen3.5-35B-A3B-GGUF/foo.gguf -> Qwen3.5-35B-A3B-GGUF)
model_alias() {
  basename "$(dirname "$1")"
}

# Locate the llama-server binary.
# Priority: LLAMA_SERVER env > nix build
resolve_llama_server() {
  if [[ -n "${LLAMA_SERVER:-}" ]]; then
    [[ -x "$LLAMA_SERVER" ]] || die "LLAMA_SERVER not executable: $LLAMA_SERVER"
    printf '%s' "$LLAMA_SERVER"
    return
  fi

  if command -v nix &>/dev/null; then
    local store_path
    if store_path="$(nix build "${SCRIPT_DIR}#llama-cpp" --no-link --print-out-paths 2>/dev/null)"; then
      printf '%s/bin/llama-server' "$store_path"
      return
    fi
  fi

  die "llama-server not found. Install via 'nix build' or set LLAMA_SERVER."
}

# Write llama-server state so cmd_opencode can generate a matching config.
write_llama_state() {
  local alias="$1"
  mkdir -p "$STATE_DIR"
  cat >"$STATE_DIR/llama-state" <<EOF
LLAMA_ALIAS=$alias
LLAMA_PORT=$PORT
EOF
}

# Generate opencode.json in the given directory from llama-server state.
generate_opencode_config() {
  local target_dir="$1"
  local state_file="$STATE_DIR/llama-state"

  [[ -f "$state_file" ]] || die "no llama-server state found — start llama first"

  local LLAMA_ALIAS LLAMA_PORT
  # shellcheck source=/dev/null
  source "$state_file"

  cat >"$target_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llama/$LLAMA_ALIAS",
  "provider": {
    "llama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://127.0.0.1:$LLAMA_PORT/v1",
        "apiKey": "dummy"
      },
      "models": {
        "$LLAMA_ALIAS": {
          "name": "$LLAMA_ALIAS",
          "tool_call": true
        }
      }
    }
  },
  "autoupdate": false
}
EOF
}

# ── Subcommands ───────────────────────────────────────────
cmd_llama() {
  local ctx_size=32768
  local temp=0.6
  local top_p=0.95
  local top_k=20
  local min_p=0
  local presence_penalty=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --ctx-size)
      ctx_size="$2"
      shift 2
      ;;
    --temp | --temperature)
      temp="$2"
      shift 2
      ;;
    --top-p)
      top_p="$2"
      shift 2
      ;;
    --top-k)
      top_k="$2"
      shift 2
      ;;
    --min-p)
      min_p="$2"
      shift 2
      ;;
    --presence-penalty)
      presence_penalty="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    *) die "unknown llama option: $1" ;;
    esac
  done

  [[ -n "${MODEL:-}" ]] || die "no model specified — use --model PATH or set MODEL env var"
  [[ -f "$MODEL" ]] || die "model not found: $MODEL"

  local llama_server
  llama_server="$(resolve_llama_server)"

  local model_dir
  model_dir="$(dirname "$MODEL")"

  local alias
  alias="$(model_alias "$MODEL")"

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  write_llama_state "$alias"

  printf 'Starting llama-server:\n'
  info "binary:" "$llama_server"
  info "model:" "$MODEL"
  info "alias:" "$alias"
  info "ctx-size:" "$ctx_size"
  info "sampling:" "temp=$temp top_p=$top_p top_k=$top_k min_p=$min_p"
  info "cache-dir:" "$CACHE_DIR"
  info "port:" "$PORT"
  printf '\n'

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D LLAMA_SERVER="$llama_server" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$llama_server" \
    --model "$MODEL" \
    --ctx-size "$ctx_size" \
    --temp "$temp" \
    --top-p "$top_p" \
    --top-k "$top_k" \
    --min-p "$min_p" \
    --presence_penalty "$presence_penalty" \
    --alias "$alias" \
    --port "$PORT"
}

cmd_opencode() {
  local workspace="$SCRIPT_DIR"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -w | --workspace)
      workspace="$2"
      shift 2
      ;;
    *) break ;;
    esac
  done

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  export XDG_CONFIG_HOME="$STATE_DIR/config"
  export XDG_STATE_HOME="$STATE_DIR/state"
  export XDG_DATA_HOME="$STATE_DIR/data"
  export XDG_CACHE_HOME="$CACHE_DIR"
  export OPENCODE_DISABLE_MODELS_FETCH=1
  export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
  export OPENCODE_DISABLE_TERMINAL_TITLE=1

  generate_opencode_config "$workspace"

  ulimit -n 2147483646

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D WORKSPACE="$workspace" \
    -D OPENCODE_DIR="$STATE_DIR" \
    -D GITCONFIG="$HOME/.gitconfig" \
    -D GIT_CONFIG_ALT="$HOME/.config/git/config" \
    -D SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
    -f "$SCRIPT_DIR/opencode.sb" \
    opencode "$@"
}

# ── Main ──────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

cmd="$1"
shift
case "$cmd" in
llama) cmd_llama "$@" ;;
opencode) cmd_opencode "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
