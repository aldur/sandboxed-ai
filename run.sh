#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────
PORT=8080
STATE_DIR="$SCRIPT_DIR/.opencode"
CACHE_DIR="$STATE_DIR/cache"
TMPDIR="$STATE_DIR/tmp"
MODELS_DIR="$STATE_DIR/models"

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
  llm       Run llm CLI (uses local llama-server)

llama options:
  --model SPEC          Local path or HF ref (org/repo:file.gguf)
                        Omit filename to list available GGUF files
  --ctx-size N          Context size (default: 32768)
  --temp N              Temperature (default: 0.6)
  --top-p N             Top-p / nucleus sampling (default: 0.95)
  --top-k N             Top-k sampling (default: 20)
  --min-p N             Min-p sampling (default: 0)
  --presence-penalty N  Presence penalty (default: 0)

opencode options:
  -w, --workspace DIR   Workspace directory (default: script dir)
  Additional args are passed through to opencode.

Environment:
  MODEL             Model spec (overridden by --model)
  LLAMA_SERVER      Explicit path to llama-server binary (fallback: PATH)
EOF
  exit 1
}

# Resolve a model spec to a local GGUF file path.
# Accepts:
#   /path/to/model.gguf   → local file, used directly
#   org/repo:file.gguf     → downloaded from Hugging Face if not cached
#   org/repo               → lists available GGUF files in the repo
resolve_model() {
  local spec="$1"

  # Local file path
  if [[ -f "$spec" ]]; then
    printf '%s' "$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
    return
  fi

  # HF reference
  if [[ "$spec" == */* && "$spec" != /* ]]; then
    if [[ "$spec" == *:* ]]; then
      local repo="${spec%%:*}"
      local file="${spec#*:}"
      local target="$MODELS_DIR/$repo/$file"

      if [[ -f "$target" ]]; then
        printf '%s' "$target"
        return
      fi

      info "download:" "https://huggingface.co/$repo → $file"
      mkdir -p "$(dirname "$target")"
      curl -L -C - --progress-bar \
        -o "$target" \
        "https://huggingface.co/$repo/resolve/main/$file" ||
        die "failed to download $repo/$file"

      printf '%s' "$target"
      return
    else
      info "fetching:" "file list for $spec"
      local files
      files="$(curl -sf "https://huggingface.co/api/models/$spec" |
        grep -o '"rfilename":"[^"]*\.gguf"' |
        sed 's/"rfilename":"//;s/"//' |
        sort)" ||
        die "failed to fetch file list for $spec"

      if [[ -z "$files" ]]; then
        die "no GGUF files found in $spec"
      fi

      printf 'Available GGUF files in %s:\n' "$spec" >&2
      printf '  %s\n' $files >&2
      printf '\nUse: --model %s:<filename>\n' "$spec" >&2
      exit 1
    fi
  fi

  die "model not found: $spec (use a local path or org/repo:file.gguf)"
}

# Locate an executable.
# Priority: explicit env var > PATH lookup
resolve_binary() {
  local env_val="$1" name="$2"

  if [[ -n "$env_val" ]]; then
    [[ -x "$env_val" ]] || die "$name not executable: $env_val"
    printf '%s' "$(cd "$(dirname "$env_val")" && pwd)/$(basename "$env_val")"
    return
  fi

  local path
  if path="$(command -v "$name" 2>/dev/null)"; then
    printf '%s' "$path"
    return
  fi

  die "$name not found on PATH. Install it or set ${name^^} env var."
}

# Detect the package store prefix from a binary path.
# Returns /nix for Nix, /opt/homebrew for Homebrew.
pkg_store_for() {
  local bin="$1"
  case "$bin" in
  /nix/*) printf '/nix' ;;
  /opt/homebrew/*) printf '/opt/homebrew' ;;
  *) die "cannot determine package store for: $bin" ;;
  esac
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
    *) die "unknown llama option: $1" ;;
    esac
  done

  [[ -n "${MODEL:-}" ]] || die "no model specified — use --model or set MODEL env var"

  local model_path
  model_path="$(resolve_model "$MODEL")"

  local llama_server
  llama_server="$(resolve_binary "${LLAMA_SERVER:-}" "llama-server")"

  local model_dir
  model_dir="$(dirname "$model_path")"

  local alias
  alias="$(basename "$model_dir")"

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  write_llama_state "$alias"

  printf 'Starting llama-server:\n'
  info "binary:" "$llama_server"
  info "model:" "$model_path"
  info "alias:" "$alias"
  info "ctx-size:" "$ctx_size"
  info "sampling:" "temp=$temp top_p=$top_p top_k=$top_k min_p=$min_p"
  info "cache-dir:" "$CACHE_DIR"
  info "port:" "$PORT"
  printf '\n'

  # cd to an allowed dir so llama-server's getcwd() succeeds inside the sandbox
  cd "$CACHE_DIR"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$llama_server")" \
    -D LLAMA_SERVER="$llama_server" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$llama_server" \
    --model "$model_path" \
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

  local opencode_bin
  opencode_bin="$(resolve_binary "${OPENCODE:-}" "opencode")"

  ulimit -n 2147483646

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$opencode_bin")" \
    -D WORKSPACE="$workspace" \
    -D OPENCODE_DIR="$STATE_DIR" \
    -f "$SCRIPT_DIR/opencode.sb" \
    "$opencode_bin" "$@"
}

cmd_llm() {
  export LLM_USER_PATH="$STATE_DIR/llm"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
  mkdir -p "$LLM_USER_PATH" "$TMPDIR"
  export TMPDIR

  local llm_bin
  llm_bin="$(resolve_binary "${LLM:-}" "llm")"

  # Default to llama-server model if no -m flag given
  local has_model=false
  for arg in "$@"; do
    [[ "$arg" == "-m" || "$arg" == "--model" ]] && has_model=true
  done

  local model_args=()
  if [[ "$has_model" == false ]]; then
    model_args=(-m llama-server)
  fi

  cd "$LLM_USER_PATH"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$llm_bin")" \
    -D LLM_USER_PATH="$LLM_USER_PATH" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llm.sb" \
    "$llm_bin" "${model_args[@]}" --no-log "$@"
}

# ── Main ──────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

cmd="$1"
shift
case "$cmd" in
llama) cmd_llama "$@" ;;
opencode) cmd_opencode "$@" ;;
llm) cmd_llm "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
