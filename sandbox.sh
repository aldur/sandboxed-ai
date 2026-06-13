#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────
PORT=8080
# Apple-containers vmnet bridge gateway (host as seen from a container).
GATEWAY_IP=192.168.64.1
STATE_DIR="$SCRIPT_DIR/.opencode"
CACHE_DIR="$STATE_DIR/cache"
TMPDIR="$STATE_DIR/tmp"
MODELS_DIR="$SCRIPT_DIR/models"

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
  llama-server  Start the llama-server (sandboxed)
  opencode  Start opencode (sandboxed)
  llm           Run llm CLI (sandboxed)

llama-server options:
  --model SPEC          Local path, HF file (org/repo:file.gguf), or
                        HF quant (org/repo:Q4_K_M). Omit the part after ':'
                        to list available GGUF files.
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
EOF
  exit 1
}

# Strip a GGUF split suffix (-00001-of-00003.gguf) or a plain .gguf extension,
# yielding a key shared by every shard of one quant.
strip_shard() {
  local f="$1"
  if [[ "$f" =~ ^(.*)-[0-9]+-of-[0-9]+\.gguf$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "${f%.gguf}"
  fi
}

# Choose the GGUF file(s) for a selection within a repo's listing.
# Prints the chosen rfilename(s), newline-separated, to stdout.
# On a missing or ambiguous selection, explains on stderr and returns 1.
#   $1 repo, $2 selection (file.gguf or QUANT), remaining args: GGUF rfilenames
select_gguf_files() {
  local repo="$1" sel="$2"
  shift 2
  local -a all=("$@")
  local -a want=()
  local f

  if [[ "$sel" == *.gguf ]]; then
    # Explicit filename: pull in sibling shards if it is part of a split set.
    local key
    key="$(strip_shard "$sel")"
    for f in "${all[@]}"; do
      [[ "$(strip_shard "$f")" == "$key" ]] && want+=("$f")
    done
    # Trust the literal name if the listing did not surface it.
    [[ ${#want[@]} -gt 0 ]] || want=("$sel")
  else
    # Quant label: case-insensitive substring match against the listing.
    [[ ${#all[@]} -gt 0 ]] || {
      printf "error: cannot resolve quant '%s': no GGUF listing for %s\n" "$sel" "$repo" >&2
      return 1
    }

    local sel_lc="${sel,,}"
    local -a matches=()
    for f in "${all[@]}"; do
      local base="${f##*/}"
      [[ "${base,,}" == *"$sel_lc"* ]] && matches+=("$f")
    done
    [[ ${#matches[@]} -gt 0 ]] || {
      printf "error: no GGUF matching quant '%s' in %s. Available:\n" "$sel" "$repo" >&2
      printf '%s\n' "${all[@]}" | LC_ALL=C sort | sed 's/^/  /' >&2
      return 1
    }

    # Collapse shards: group matches by quant key.
    local -A keyset=()
    for f in "${matches[@]}"; do keyset["$(strip_shard "$f")"]=1; done

    local chosen=""
    if [[ ${#keyset[@]} -eq 1 ]]; then
      for chosen in "${!keyset[@]}"; do :; done
    else
      # Tie-break: prefer the single quant whose name ends with the label
      # (e.g. 'Q6_K' over 'Q6_K_XL').
      local k
      local -a ends=()
      for k in "${!keyset[@]}"; do
        local kb="${k##*/}"
        [[ "${kb,,}" == *"$sel_lc" ]] && ends+=("$k")
      done
      if [[ ${#ends[@]} -eq 1 ]]; then
        chosen="${ends[0]}"
      else
        printf "error: quant '%s' is ambiguous in %s; matches:\n" "$sel" "$repo" >&2
        printf '%s\n' "${!keyset[@]}" | sed 's#.*/##' | LC_ALL=C sort | sed 's/^/  /' >&2
        printf 'specify a more precise quant or the full filename.\n' >&2
        return 1
      fi
    fi

    for f in "${matches[@]}"; do
      [[ "$(strip_shard "$f")" == "$chosen" ]] && want+=("$f")
    done
  fi

  printf '%s\n' "${want[@]}" | LC_ALL=C sort
}

# Download a single GGUF file from HF into target (resumable), verifying its
# magic bytes. Reuses a valid cached copy. All output goes to stderr.
hf_download() {
  local repo="$1" file="$2" target="$3"
  local magic

  if [[ -f "$target" ]]; then
    # NOTE: Not smart enough to detect truncated downloads.
    magic="$(head -c 4 "$target")" || true
    if [[ "$magic" == "GGUF" ]]; then
      info "cached:" "$file" >&2
      return
    fi
    rm -f "$target"
    info "removed:" "invalid cached file, re-downloading" >&2
  fi

  local url="https://huggingface.co/$repo/resolve/main/$file"
  local http_code
  http_code="$(curl -sfI -o /dev/null -w '%{http_code}' "$url")" || http_code="000"
  [[ "$http_code" == 200 || "$http_code" == 302 ]] ||
    die "file not found on HF (HTTP $http_code): $repo/$file"

  info "download:" "$file" >&2
  mkdir -p "$(dirname "$target")"
  curl -L -C - --progress-bar -o "$target" "$url" ||
    die "failed to download $repo/$file"

  magic="$(head -c 4 "$target")" || true
  [[ "$magic" == "GGUF" ]] || {
    rm -f "$target"
    die "downloaded file is not a valid GGUF: $repo/$file"
  }
}

# Resolve a model spec to a local GGUF file path, downloading from HF as needed.
# Accepts:
#   /path/to/model.gguf    → local file, used directly
#   org/repo:file.gguf     → that exact file (plus sibling shards if split)
#   org/repo:QUANT         → file matching the quant label (e.g. Q4_K_M, UD-Q8_K_XL)
#   org/repo               → lists available GGUF files in the repo
# Split models: all shards are fetched and the first shard's path is returned;
# llama-server loads the rest from the same directory.
resolve_model() {
  local spec="$1"

  # Local file path
  if [[ -f "$spec" ]]; then
    printf '%s' "$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
    return
  fi

  # Must look like an HF ref: org/repo[...], not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "model not found: $spec (use a local path, org/repo:file.gguf, or org/repo:QUANT)"

  local repo sel
  if [[ "$spec" == *:* ]]; then
    repo="${spec%%:*}"
    sel="${spec#*:}"
  else
    repo="$spec"
    sel=""
  fi

  # GGUF files available in the repo (rfilenames, may include subfolders).
  local listing
  listing="$(curl -sf "https://huggingface.co/api/models/$repo" |
    grep -o '"rfilename":"[^"]*\.gguf"' |
    sed 's/"rfilename":"//;s/"//')" || listing=""

  # Bare repo (no selection): list available files and exit.
  if [[ -z "$sel" ]]; then
    [[ -n "$listing" ]] || die "no GGUF files found in $repo"
    printf 'Available GGUF files in %s:\n' "$repo" >&2
    printf '%s\n' "$listing" | LC_ALL=C sort | sed 's/^/  /' >&2
    printf '\nUse: --model %s:<filename>  or  --model %s:<QUANT>\n' "$repo" "$repo" >&2
    exit 1
  fi

  local -a all=()
  local line
  while IFS= read -r line; do [[ -n "$line" ]] && all+=("$line"); done <<<"$listing"

  info "resolving:" "$repo:$sel" >&2
  local files_out
  files_out="$(select_gguf_files "$repo" "$sel" "${all[@]}")" || exit 1

  local -a want=()
  while IFS= read -r line; do [[ -n "$line" ]] && want+=("$line"); done <<<"$files_out"
  [[ ${#want[@]} -gt 1 ]] && info "split:" "${#want[@]} shards" >&2

  local f target first=""
  for f in "${want[@]}"; do
    target="$MODELS_DIR/$repo/$f"
    hf_download "$repo" "$f" "$target"
    [[ -z "$first" ]] && first="$target"
  done

  printf '%s' "$first"
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
  *)
    echo "cannot determine package store for: $bin" >&2
    printf ""
    ;;
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
  # Extract --model, pass everything else through to llama-server
  local extra_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
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

  printf 'Starting sandboxed llama-server:\n'
  info "binary:" "$llama_server"
  info "model:" "$model_path"
  info "alias:" "$alias"
  info "port:" "$PORT"
  info "extra:" "${extra_args[*]:-none}"
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
    -D BIND_ADDR="*:$PORT" \
    -D LOOPBACK_ADDR="localhost:$PORT" \
    -D GATEWAY_ADDR="$GATEWAY_IP:$PORT" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$llama_server" \
    --model "$model_path" \
    --alias "$alias" \
    --port "$PORT" \
    "${extra_args[@]}"
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

  # cd to an allowed dir so opencode's getcwd() succeeds inside the sandbox
  cd "$workspace"

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

  # Default to llama-server model if no -m flag given
  echo "llama-server" >$LLM_USER_PATH/default_model.txt

  local llm_bin
  llm_bin="$(resolve_binary "${LLM:-}" "llm")"

  cd "$LLM_USER_PATH"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$llm_bin")" \
    -D LLM_USER_PATH="$LLM_USER_PATH" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llm.sb" \
    "$llm_bin" "${model_args[@]}" "$@"
}

# ── Main ──────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

cmd="$1"
shift
case "$cmd" in
llama-server) cmd_llama "$@" ;;
opencode) cmd_opencode "$@" ;;
llm) cmd_llm "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
