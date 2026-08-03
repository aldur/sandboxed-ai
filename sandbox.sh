#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Program name shown in usage/messages. The Nix wrapper sets SANDBOXED_AI_PROG
# so it reads `sandboxed-ai`; run directly it falls back to the script basename.
# ($0 itself must stay the real path — SCRIPT_DIR above depends on it.)
PROG="${SANDBOXED_AI_PROG:-$(basename "$0")}"

# Seatbelt profiles (*.sb) sit next to this script — in the repo when run as
# ./sandbox.sh, in the Nix store when run as the bundled `sandboxed-ai`. State,
# however, must be writable, so it is rooted at the directory you run from
# (the store copy is read-only). Override the latter with SANDBOXED_AI_HOME.
PROJECT_DIR="${SANDBOXED_AI_HOME:-$PWD}"

# ── Defaults ──────────────────────────────────────────────
PORT=8080
STATE_DIR="$PROJECT_DIR/.opencode"
CACHE_DIR="$STATE_DIR/cache"
TMPDIR="$STATE_DIR/tmp"
MODELS_DIR="$PROJECT_DIR/models"

# ── Helpers ───────────────────────────────────────────────
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
info() { printf '  %-14s %s\n' "$1" "$2"; }

usage() {
  cat >&2 <<EOF
Usage: $PROG <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  mlx-server    Start mlx_lm.server (sandboxed)
  opencode  Start opencode (sandboxed)
  pi            Start pi (pi-coding-agent) with the llama-cpp plugin (sandboxed)
  llm           Run llm CLI (sandboxed)

llama-server options:
  --model SPEC          Local path, HF file (org/repo:file.gguf), or
                        HF quant (org/repo:Q4_K_M). Omit the part after ':'
                        to list available GGUF files.
  --mmproj SPEC         Multimodal projector for vision models, same spec
                        grammar. Quant labels match only mmproj-*.gguf files.
  All other flags are passed through to llama-server.

mlx-server options:
  --model SPEC          Local model directory or HF repo of an MLX model
                        (e.g. mlx-community/Qwen3-8B-4bit). Vision models
                        (config.json with a vision tower) are served with
                        mlx_vlm.server, text models with mlx_lm.server.
  All other flags are passed through to the server.

opencode options:
  -w, --workspace DIR   Workspace directory (default: script dir)
  Additional args are passed through to opencode.

pi options:
  -w, --workspace DIR   Workspace directory (default: project dir)
  Additional args are passed through to pi.

llm options:
  -m, --model MODEL     Model name (default: llama-server)
  Additional args are passed through to llm.

Environment:
  MODEL             Model spec (overridden by --model)
  MMPROJ            Projector spec (overridden by --mmproj)
  LLAMA_SERVER      Explicit path to llama-server binary (fallback: PATH)
  MLX_SERVER        Explicit path to mlx_lm.server binary (fallback: PATH)
  MLX_VLM_SERVER    Explicit path to mlx_vlm.server binary (fallback: PATH)
  PI                Explicit path to pi binary (fallback: PATH)
  PI_LLAMA_DIR      Dir holding the pi llama-cpp plugin's index.ts
                    (set by the Nix wrapper; required for the pi command)
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
#   $1 repo, $2 selection (file.gguf or QUANT), $3 kind, remaining: rfilenames
# Kind scopes *quant-label* matching to one half of a vision repo: 'model'
# ignores multimodal projectors (mmproj-*.gguf), 'mmproj' considers only
# them. Explicit filenames bypass the filter — that's how a projector is
# named directly.
select_gguf_files() {
  local repo="$1" sel="$2" kind="$3"
  shift 3
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
    # The label must appear delimited by [-_.] (or an edge) in the basename:
    # 'F16' matches '…-F16.gguf' and 'mmproj-F16.gguf' but not '…-BF16.gguf',
    # which a bare substring test would quietly pick once projectors stop
    # rivalling it into the ambiguity error.
    local sel_re
    sel_re="$(printf '%s' "$sel_lc" | sed 's/[^[:alnum:]]/[&]/g')"
    local -a matches=()
    for f in "${all[@]}"; do
      local base="${f##*/}" base_lc
      base_lc="${base,,}"
      case "$kind" in
      mmproj) [[ "$base_lc" == mmproj* ]] || continue ;;
      *) [[ "$base_lc" == mmproj* ]] && continue ;;
      esac
      [[ "$base_lc" =~ (^|[-_.])$sel_re([-_.]|$) ]] && matches+=("$f")
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

# Download one file from an HF repo into target (resumable). Reuses an
# existing non-empty copy. Unlike hf_download there is no content validation —
# MLX repos hold many file types (safetensors, json, tokenizer data).
# NOTE: Not smart enough to detect truncated downloads.
hf_download_raw() {
  local repo="$1" file="$2" target="$3"

  if [[ -s "$target" ]]; then
    info "cached:" "$file" >&2
    return
  fi

  info "download:" "$file" >&2
  mkdir -p "$(dirname "$target")"
  curl -sfL -C - --progress-bar -o "$target" \
    "https://huggingface.co/$repo/resolve/main/$file" ||
    die "failed to download $repo/$file"
}

# Resolve an MLX model spec to a local model directory, downloading from HF as
# needed. Accepts:
#   /path/to/model-dir     → local directory, used directly
#   org/repo               → full repo download (an MLX model is a directory:
#                            config.json, tokenizer files, *.safetensors)
resolve_mlx_model() {
  local spec="$1"

  # Local directory
  if [[ -d "$spec" ]]; then
    [[ -f "$spec/config.json" ]] ||
      die "not an MLX model directory (no config.json): $spec"
    printf '%s' "$(cd "$spec" && pwd)"
    return
  fi

  # Must look like an HF ref: org/repo, not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "model not found: $spec (use a local directory or org/repo)"

  local target_dir="$MODELS_DIR/$spec"

  # A finished earlier download is a complete snapshot of the repo (the
  # marker is written only once every file has landed), so resolve it
  # locally — no HF round-trip, works offline. Delete the marker (or the
  # directory) to re-sync with upstream.
  if [[ -f "$target_dir/.download-complete" ]]; then
    info "cached:" "$spec" >&2
    printf '%s' "$target_dir"
    return
  fi

  # All files in the repo (rfilenames, may include subfolders).
  local listing
  listing="$(curl -sf "https://huggingface.co/api/models/$spec" |
    grep -o '"rfilename":"[^"]*"' |
    sed 's/"rfilename":"//;s/"//')" || listing=""

  # Offline fallback for a download that predates the marker: a local copy
  # with a config.json is plausibly complete — use it (the server fails
  # loudly on missing weights), but don't mark it: the next online run
  # verifies against the real listing first.
  if [[ -z "$listing" ]]; then
    if [[ -f "$target_dir/config.json" ]]; then
      info "offline:" "cannot list $spec on HF; using local copy" >&2
      printf '%s' "$target_dir"
      return
    fi
    die "no files found on HF for $spec"
  fi

  info "resolving:" "$spec" >&2

  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # Skip repo metadata (dotfiles like .gitattributes, README, ...).
    case "$f" in
    .* | */.* | README.md | *.md) continue ;;
    esac
    hf_download_raw "$spec" "$f" "$target_dir/$f"
  done <<<"$listing"

  [[ -f "$target_dir/config.json" ]] ||
    die "not an MLX model repo (no config.json): $spec"

  touch "$target_dir/.download-complete"

  printf '%s' "$target_dir"
}

# Resolve a model spec to a local GGUF file path, downloading from HF as needed.
# Accepts:
#   /path/to/model.gguf    → local file, used directly
#   org/repo:file.gguf     → that exact file (plus sibling shards if split)
#   org/repo:QUANT         → file matching the quant label (e.g. Q4_K_M, UD-Q8_K_XL)
#   org/repo               → lists available GGUF files in the repo
# Split models: all shards are fetched and the first shard's path is returned;
# llama-server loads the rest from the same directory.
# $2 (default 'model') scopes quant matching — see select_gguf_files.
resolve_model() {
  local spec="$1" kind="${2:-model}"

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

  # Offline fallback: resolve against the GGUFs already downloaded for this
  # repo, so a quant spec keeps working without network once fetched.
  # (hf_download then finds them cached; a quant that only exists upstream
  # still dies at download, as it must.)
  if [[ -z "$listing" && -d "$MODELS_DIR/$repo" ]]; then
    listing="$(cd "$MODELS_DIR/$repo" && find . -name '*.gguf' | sed 's|^\./||')"
    [[ -n "$listing" ]] && info "offline:" "resolving against local files for $repo" >&2
  fi

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
  files_out="$(select_gguf_files "$repo" "$sel" "$kind" "${all[@]}")" || exit 1

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

# Write server state so cmd_opencode can generate a matching config.
# $2 is the model id clients must send on the wire; it defaults to the alias
# (llama-server serves under --alias) but differs for mlx_lm.server, which
# only maps the literal "default_model" to its --model.
write_llama_state() {
  local alias="$1" model_id="${2:-$1}"
  mkdir -p "$STATE_DIR"
  cat >"$STATE_DIR/llama-state" <<EOF
LLAMA_ALIAS=$alias
LLAMA_PORT=$PORT
LLAMA_MODEL_ID=$model_id
EOF
}

# Generate opencode.json in the given directory from llama-server state.
generate_opencode_config() {
  local target_dir="$1"
  local state_file="$STATE_DIR/llama-state"

  [[ -f "$state_file" ]] || die "no llama-server state found — start llama first"

  local LLAMA_ALIAS LLAMA_PORT LLAMA_MODEL_ID
  # shellcheck source=/dev/null
  source "$state_file"
  # State written before the model-id field existed defaults to the alias.
  LLAMA_MODEL_ID="${LLAMA_MODEL_ID:-$LLAMA_ALIAS}"

  cat >"$target_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llama/$LLAMA_MODEL_ID",
  "provider": {
    "llama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://127.0.0.1:$LLAMA_PORT/v1",
        "apiKey": "dummy"
      },
      "models": {
        "$LLAMA_MODEL_ID": {
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
  # Extract --model/--mmproj, pass everything else through to llama-server
  local extra_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --mmproj)
      MMPROJ="$2"
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

  # A vision model is served from two GGUFs: the model plus a multimodal
  # projector (mmproj-*.gguf). llama-server only auto-fetches the projector
  # on its own `-hf` path, never for a local --model, so it must be resolved
  # and passed explicitly here. Quant labels resolve against projector files
  # only (see select_gguf_files); explicit filenames also work.
  local mmproj_path="" mmproj_dir=""
  if [[ -n "${MMPROJ:-}" ]]; then
    mmproj_path="$(resolve_model "$MMPROJ" mmproj)"
    mmproj_dir="$(dirname "$mmproj_path")"
  fi

  local llama_server
  llama_server="$(resolve_binary "${LLAMA_SERVER:-}" "llama-server")"

  local model_dir
  model_dir="$(dirname "$model_path")"

  local alias
  alias="$(basename "$model_dir")"

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  write_llama_state "$alias"

  local -a server_args=(--model "$model_path" --alias "$alias" --port "$PORT")
  [[ -n "$mmproj_path" ]] && server_args+=(--mmproj "$mmproj_path")

  printf 'Starting sandboxed llama-server:\n'
  info "binary:" "$llama_server"
  info "model:" "$model_path"
  [[ -n "$mmproj_path" ]] && info "mmproj:" "$mmproj_path"
  info "alias:" "$alias"
  info "port:" "$PORT"
  info "extra:" "${extra_args[*]:-none}"
  printf '\n'

  # cd to an allowed dir so llama-server's getcwd() succeeds inside the sandbox
  cd "$CACHE_DIR"

  # MMPROJ_DIR falls back to MODEL_DIR when no projector is given:
  # sandbox-exec errors out on profile parameters that were never passed.
  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$llama_server")" \
    -D LLAMA_SERVER="$llama_server" \
    -D MODEL_DIR="$model_dir" \
    -D MMPROJ_DIR="${mmproj_dir:-$model_dir}" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -D NET_ADDR="*:$PORT" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$llama_server" "${server_args[@]}" "${extra_args[@]}"
}

# Seed an HF hub cache entry for a side-loaded repo download. The mlx
# servers list (/v1/models) and resolve models through huggingface_hub's
# cache, so a symlinked cache entry makes them treat the download as if it
# came from the hub — offline: clients can auto-discover the model and
# address it by its repo id. Layout:
#   hub/models--{org}--{name}/refs/main           → pseudo revision
#   hub/models--{org}--{name}/snapshots/<rev>/<f> → models/<repo>/<f>
seed_hf_cache() {
  local repo="$1" model_dir="$2"
  local entry="$HF_HOME/hub/models--${repo//\//--}"
  # Content-addressing is irrelevant locally, but the ref must name an
  # existing snapshot directory and look like a commit hash.
  local rev="0000000000000000000000000000000000000000"

  rm -rf "$entry"
  mkdir -p "$entry/refs" "$entry/snapshots/$rev"
  printf '%s' "$rev" >"$entry/refs/main"

  local f rel
  while IFS= read -r f; do
    rel="${f#"$model_dir/"}"
    mkdir -p "$entry/snapshots/$rev/$(dirname "$rel")"
    ln -s "$f" "$entry/snapshots/$rev/$rel"
  done < <(find "$model_dir" -type f ! -name '.*')
}

cmd_mlx() {
  # Extract --model, pass everything else through to mlx_lm.server
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

  local model_dir
  model_dir="$(resolve_mlx_model "$MODEL")"

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  # Root ~-relative state (HF hub cache scans etc.) inside the writable cache.
  # The hub/ subdir must exist even when empty: /v1/models scans it and 500s
  # (CacheNotFound) when it's missing.
  export HOME="$CACHE_DIR/mlx-home"
  export HF_HOME="$HOME/huggingface"
  mkdir -p "$HF_HOME/hub"
  # The model is fully local and the sandbox denies outbound network anyway;
  # keep huggingface_hub from even trying.
  export HF_HUB_OFFLINE=1

  # Serve by repo id when the spec is an HF repo: the seeded cache entry
  # lets both servers resolve that id offline and list it on /v1/models, so
  # clients can auto-discover the model and address it by name. A local
  # directory spec has no repo id and is served by path instead.
  local serve_ref="$model_dir"
  if [[ ! -d "$MODEL" ]]; then
    seed_hf_cache "$MODEL" "$model_dir"
    serve_ref="$MODEL"
  fi

  # A config.json carrying a vision tower marks a VLM. mlx_lm.server is
  # text-only, so those go to mlx-vlm's OpenAI-compatible server instead.
  # Unlike llama.cpp there is no separate projector file: the full-repo
  # download above already includes the vision weights.
  local mlx_server model_id
  if grep -q '"vision_config"' "$model_dir/config.json"; then
    mlx_server="$(resolve_binary "${MLX_VLM_SERVER:-}" "mlx_vlm.server")"
    # mlx_vlm.server loads whatever the request's `model` field names and
    # keys its cache on that string (--model merely pre-warms it), so the
    # wire id must equal what the server was started with.
    model_id="$serve_ref"
  else
    mlx_server="$(resolve_binary "${MLX_SERVER:-}" "mlx_lm.server")"
    # mlx_lm.server maps the literal "default_model" to its --model; with a
    # seeded cache the repo id resolves too — to the same loaded instance —
    # so prefer it on the wire. A path-served model keeps "default_model".
    model_id="$serve_ref"
    [[ "$serve_ref" == "$model_dir" ]] && model_id="default_model"
  fi

  local alias
  alias="$(basename "$model_dir")"

  write_llama_state "$alias" "$model_id"

  printf 'Starting sandboxed %s:\n' "$(basename "$mlx_server")"
  info "binary:" "$mlx_server"
  info "model:" "$serve_ref"
  info "alias:" "$alias"
  info "port:" "$PORT"
  info "extra:" "${extra_args[*]:-none}"
  printf '\n'

  local ca_file="/dev/null"
  if [[ -n "${NIX_SSL_CERT_FILE:-}" && "$NIX_SSL_CERT_FILE" != "/no-cert-file.crt" ]]; then
    ca_file="$(realpath "$NIX_SSL_CERT_FILE" 2>/dev/null || echo /dev/null)"
    [[ "$ca_file" != "/dev/null" ]] && export NIX_SSL_CERT_FILE="$ca_file"
  fi

  # cd to an allowed dir so the server's getcwd() succeeds inside the sandbox
  cd "$CACHE_DIR"

  # --host pins mlx_vlm.server to loopback (it defaults to 0.0.0.0;
  # mlx_lm.server already defaults to 127.0.0.1). Both take --model/--port;
  # extra args come last so they can override.
  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$mlx_server")" \
    -D CA_FILE="$ca_file" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -D NET_ADDR="*:$PORT" \
    -f "$SCRIPT_DIR/mlx-server.sb" \
    "$mlx_server" \
    --model "$serve_ref" \
    --host 127.0.0.1 \
    --port "$PORT" \
    "${extra_args[@]}"
}

cmd_opencode() {
  local workspace="$PROJECT_DIR"

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

cmd_pi() {
  local workspace="$PROJECT_DIR"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -w | --workspace)
      workspace="$2"
      shift 2
      ;;
    *) break ;;
    esac
  done

  # The llama-cpp plugin (huggingface/pi-llama) is loaded for the session via
  # `pi -e <dir>/index.ts`. The Nix wrapper points PI_LLAMA_DIR at the pinned
  # store copy; outside Nix, set it to a checkout of the repo.
  local plugin="${PI_LLAMA_DIR:-}/index.ts"
  [[ -n "${PI_LLAMA_DIR:-}" && -f "$plugin" ]] ||
    die "pi llama-cpp plugin not found — set PI_LLAMA_DIR to a dir containing index.ts"

  # The plugin discovers the server from LLAMA_BASE_URL. Reuse the port the
  # llama-server subcommand recorded so it matches a running instance.
  local llama_port="$PORT"
  if [[ -f "$STATE_DIR/llama-state" ]]; then
    local LLAMA_ALIAS LLAMA_PORT
    # shellcheck source=/dev/null
    source "$STATE_DIR/llama-state"
    llama_port="$LLAMA_PORT"
  fi

  # pi keeps its state under ~/.pi, so root HOME inside the project dir to keep
  # writable state local (and out of the read-only store / the real HOME).
  local pi_home="$STATE_DIR/pi"
  mkdir -p "$pi_home" "$CACHE_DIR" "$TMPDIR"
  export HOME="$pi_home"
  export TMPDIR
  export LLAMA_BASE_URL="http://127.0.0.1:$llama_port/v1"
  export LLAMA_API_KEY="${LLAMA_API_KEY:-dummy}"

  # pi probes tmux keyboard setup by spawning `tmux`; the sandbox denies the
  # exec and the spawn throws synchronously, crashing pi on startup. The probe
  # is gated on $TMUX, so hide it — tmux-native features can't work sandboxed.
  unset TMUX
  # Read-only store install behind a network-restricted sandbox: skip pi's
  # startup network ops (self-update / version check / tool fetch), which can
  # only fail here. Does not affect the llama-cpp plugin's model discovery,
  # which talks to LLAMA_BASE_URL independently of this flag.
  export PI_OFFLINE=1

  local pi_bin
  pi_bin="$(resolve_binary "${PI:-}" "pi")"

  printf 'Starting sandboxed pi:\n'
  info "binary:" "$pi_bin"
  info "plugin:" "$plugin"
  info "server:" "$LLAMA_BASE_URL"
  info "workspace:" "$workspace"
  printf '\n'

  ulimit -n 2147483646

  # cd to an allowed dir so pi's getcwd() succeeds inside the sandbox
  cd "$workspace"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$pi_bin")" \
    -D WORKSPACE="$workspace" \
    -D PI_DIR="$pi_home" \
    -D PI_LLAMA_DIR="$PI_LLAMA_DIR" \
    -D NET_ADDR="localhost:$llama_port" \
    -f "$SCRIPT_DIR/pi.sb" \
    "$pi_bin" -e "$plugin" "$@"
}

cmd_llm() {
  export LLM_USER_PATH="$STATE_DIR/llm"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
  mkdir -p "$LLM_USER_PATH" "$TMPDIR"
  export TMPDIR

  # Default to llama-server model if no -m flag given
  echo "llama-server" >"$LLM_USER_PATH/default_model.txt"

  local llm_bin
  llm_bin="$(resolve_binary "${LLM:-}" "llm")"

  cd "$LLM_USER_PATH"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$(pkg_store_for "$llm_bin")" \
    -D LLM_USER_PATH="$LLM_USER_PATH" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llm.sb" \
    "$llm_bin" "$@"
}

# ── Main ──────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

cmd="$1"
shift
case "$cmd" in
llama-server) cmd_llama "$@" ;;
mlx-server) cmd_mlx "$@" ;;
opencode) cmd_opencode "$@" ;;
pi) cmd_pi "$@" ;;
llm) cmd_llm "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
