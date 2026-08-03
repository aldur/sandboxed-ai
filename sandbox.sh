#!/usr/bin/env bash
# Sandbox local AI tools with macOS seatbelt (sandbox-exec).
#
# Layout: constants → sandbox helpers → Hugging Face downloads → model
# resolution (GGUF, MLX) → one cmd_* per subcommand, each ending in
# `exec sandbox-exec` with every grant spelled out → dispatch.
#
# Subcommand → seatbelt profile (all import common.sb; the servers also
# import net-tcp.sb or net-unix.sb, chosen by --socket):
#   llama-server → llama-server.sb    mlx-server → mlx-server.sb
#   pi           → pi.sb              llm        → llm.sb
#
# sandbox-exec -D values are literal strings consumed by (param ...) in the
# profiles — they parameterize path/address filters, never profile code.
set -euo pipefail

# ${var,,}, associative arrays, namerefs, and empty arrays under `set -u`
# need a modern bash (nix and homebrew both ship 5.x).
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
  { printf 'error: bash >= 4.4 required (found %s)\n' "$BASH_VERSION" >&2; exit 1; }
# For the delimited quant-label match in select_gguf_files.
shopt -s extglob

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)"

# Program name shown in usage/messages. The Nix wrapper sets SANDBOXED_AI_PROG
# so it reads `sandboxed-ai`; run directly it falls back to the script basename.
# ($0 itself must stay the real path — SCRIPT_DIR above depends on it.)
PROG="${SANDBOXED_AI_PROG:-${0##*/}}"

# ── Defaults ──────────────────────────────────────────────
# PORT is fixed: the servers bind it and the clients dial it, so there is
# nothing to communicate between runs.
#
# Everything this script owns — models, caches, scratch, each tool's home —
# lives under STATE_DIR, per user and deliberately outside any workspace: a
# client sandbox gets write access to its workspace, and must not be able to
# reach what another sandbox trusts (server caches, model weights). The only
# path taken from the caller is the workspace itself (pi's -w, default $PWD).
# ($HOME here is the real one; subcommands re-root HOME only later. TMPDIR
# stays unexported; each subcommand exports it for its sandboxed process.)
PORT=8080
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sandboxed-ai"
CACHE_DIR="$STATE_DIR/cache"
TMPDIR="$STATE_DIR/tmp"
# Weights are large and often belong on another volume; SANDBOXED_AI_MODELS
# relocates them. Give it a real path, not a symlink: seatbelt matches
# resolved paths, so a link would not match the granted MODEL_DIR.
MODELS_DIR="${SANDBOXED_AI_MODELS:-$STATE_DIR/models}"
readonly SCRIPT_DIR PROG PORT STATE_DIR CACHE_DIR MODELS_DIR

# ── Output & usage ────────────────────────────────────────
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
# Prints to stdout; callers whose stdout is captured redirect to stderr.
info() { printf '  %-14s %s\n' "$1" "$2"; }

# Read the non-empty lines of $1 into the array named by $2.
split_lines() {
  local -n _lines="$2"
  _lines=()
  local line
  while IFS= read -r line; do [[ -n "$line" ]] && _lines+=("$line"); done <<<"$1"
}

usage() {
  cat >&2 <<EOF
Usage: $PROG <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  mlx-server    Start mlx_lm.server (sandboxed)
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

pi options:
  -w, --workspace DIR   Workspace directory (default: current directory)
  Additional args are passed through to pi.

llm options:
  All args are passed through to llm (use its -m to pick a model; the
  default model is preset to "llama-server").

Environment:
  XDG_STATE_HOME     Parent of the per-user dir holding models, caches and
                     each tool's home (default: ~/.local/state)
  SANDBOXED_AI_MODELS
                     Model directory, for weights on another volume
                     (default: \$XDG_STATE_HOME/sandboxed-ai/models)
  SANDBOXED_AI_PROG  Program name shown in this help (set by the Nix wrapper)
  MODEL              Model spec (overridden by --model)
  MMPROJ             Projector spec (overridden by --mmproj)
  LLAMA_SERVER, MLX_SERVER, MLX_VLM_SERVER, PI, LLM
                     Explicit binary paths (fallback: PATH lookup)
  PI_LLAMA_DIR       Dir holding the pi llama-cpp plugin's index.ts
                     (set by the Nix wrapper; required for the pi command)
  NIX_SSL_CERT_FILE  CA bundle granted read-only to the mlx sandbox
  LLAMA_API_KEY, OPENAI_API_KEY
                     Client API keys; local servers accept the "dummy" default
EOF
  exit 1
}

# ── Sandbox helpers: exec targets & grants ────────────────
# Everything here produces a value handed to sandbox-exec as a -D parameter
# (or the binary that is exec'd), i.e. the security-relevant inputs.

# Absolute, physical (symlink-free) path of existing file $1.
abspath() {
  local dir
  dir="$(CDPATH='' cd -P -- "$(dirname -- "$1")" && pwd)" ||
    die "cannot resolve path: $1"
  printf '%s/%s' "$dir" "${1##*/}"
}

# Locate the executable for a command. $1 is an explicit override (from the
# env var named $3) and wins over the PATH lookup of $2. Prints an absolute
# path.
resolve_binary() {
  local override="$1" name="$2" var="$3"

  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$name not executable: $override (from \$$var)"
    abspath "$override"
    return
  fi
  command -v "$name" ||
    die "$name not found on PATH. Install it or set $var."
}

# Package store prefix of a binary: the subtree the profiles grant read +
# execute on (PKG_STORE). Fails closed on an unrecognized location.
pkg_store_for() {
  case "$1" in
  /nix/*) printf '/nix' ;;
  /opt/homebrew/*) printf '/opt/homebrew' ;;
  *) die "cannot determine package store for: $1" ;;
  esac
}

# The CA bundle the mlx profile grants read on: huggingface_hub builds an
# SSL context even in offline mode, and nixpkgs' certifi opens
# NIX_SSL_CERT_FILE verbatim (/no-cert-file.crt is its "unset" marker). On
# nix-darwin that path is a symlink chain the sandbox won't traverse, so
# resolve it and hand the real file to both the profile and (re-exported)
# certifi. Sets CA_FILE; /dev/null means "no bundle" — the profile
# references the param unconditionally and sandbox-exec errors on a
# never-passed one.
resolve_ca_file() {
  CA_FILE="/dev/null"
  local ca="${NIX_SSL_CERT_FILE:-/no-cert-file.crt}"
  [[ "$ca" != "/no-cert-file.crt" ]] || return 0
  ca="$(realpath "$ca" 2>/dev/null)" || return 0
  export NIX_SSL_CERT_FILE="$ca"
  CA_FILE="$ca"
}

# Network personality for the server sandboxes, as two mutable globals the
# exec blocks pass through: NET_SB is the profile snippet imported via
# (import (param "NET_SB")), NET_TARGET the one filter value it consumes.
# Default is TCP on $PORT (net-tcp.sb); a --socket path selects net-unix.sb
# with the socket path as the filter — each personality grants nothing of
# the other's surface. The path must end in .sock (all three servers key
# UNIX-socket mode off that suffix on --host) and is normalized here.
select_net() {
  NET_SB="$SCRIPT_DIR/net-tcp.sb"
  NET_TARGET="*:$PORT"

  local sock="${1:-}"
  [[ -n "$sock" ]] || return 0
  [[ "$sock" == *.sock ]] || die "--socket path must end in .sock: $sock"
  [[ "$sock" == /* ]] || sock="$PWD/$sock"
  mkdir -p "${sock%/*}" # the profile grants only the socket path itself
  rm -f "$sock"         # a stale socket file would make bind() fail
  NET_SB="$SCRIPT_DIR/net-unix.sb"
  NET_TARGET="$sock"
}

# ── Hugging Face downloads ────────────────────────────────
# Lifecycle: partial downloads are kept on purpose (curl -C - resumes them);
# neither helper detects a truncated file that stopped growing. Network
# failure and "no such repo" both yield an empty listing — callers treat the
# two alike and fall back to local files.

# rfilenames of an HF repo, one per line; $2 optionally narrows to a
# (grep-escaped) filename-suffix pattern. Empty output when offline or the
# repo is unknown.
hf_listing() {
  curl -sf "https://huggingface.co/api/models/$1" |
    grep -o "\"rfilename\":\"[^\"]*${2:-}\"" |
    sed 's/"rfilename":"//;s/"//'
}

# Download one GGUF file from HF into target (resumable), verifying its
# magic bytes. Reuses a valid cached copy. All output goes to stderr.
hf_download() {
  local repo="$1" file="$2" target="$3"
  local magic

  if [[ -f "$target" ]]; then
    magic="$(head -c 4 "$target")" || true # unreadable file == no magic
    if [[ "$magic" == "GGUF" ]]; then
      info "cached:" "$file" >&2
      return
    fi
    rm -f "$target"
    info "removed:" "invalid cached file, re-downloading" >&2
  fi

  local url="https://huggingface.co/$repo/resolve/main/$file"
  local http_code
  # HEAD probe for a clear error before the download starts.
  http_code="$(curl -sI -o /dev/null -w '%{http_code}' "$url")" || http_code="000"
  [[ "$http_code" == 200 || "$http_code" == 302 ]] ||
    die "file not found on HF (HTTP $http_code): $repo/$file"

  info "download:" "$file" >&2
  mkdir -p "${target%/*}"
  curl -L -C - --progress-bar -o "$target" "$url" ||
    die "failed to download $repo/$file"

  magic="$(head -c 4 "$target")" || true
  [[ "$magic" == "GGUF" ]] || {
    rm -f "$target"
    die "downloaded file is not a valid GGUF: $repo/$file"
  }
}

# Download one file from an HF repo into target (resumable). Reuses an
# existing non-empty copy. Unlike hf_download there is no content
# validation — MLX repos hold many file types (safetensors, json, tokenizer
# data).
hf_download_raw() {
  local repo="$1" file="$2" target="$3"

  if [[ -s "$target" ]]; then
    info "cached:" "$file" >&2
    return
  fi

  info "download:" "$file" >&2
  mkdir -p "${target%/*}"
  curl -sfL -C - --progress-bar -o "$target" \
    "https://huggingface.co/$repo/resolve/main/$file" ||
    die "failed to download $repo/$file"
}

# ── Model resolution: GGUF (llama-server) ─────────────────

# Strip a GGUF split suffix (-00001-of-00003.gguf) or a plain .gguf
# extension, yielding a key shared by every shard of one quant. Sets
# shard_key (caller-read; avoids a subshell in the selection loops).
strip_shard() {
  if [[ "$1" =~ ^(.*)-[0-9]+-of-[0-9]+\.gguf$ ]]; then
    shard_key="${BASH_REMATCH[1]}"
  else
    shard_key="${1%.gguf}"
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
  local f shard_key

  if [[ "$sel" == *.gguf ]]; then
    # Explicit filename: pull in sibling shards if it is part of a split set.
    local key
    strip_shard "$sel"
    key="$shard_key"
    for f in "${all[@]}"; do
      strip_shard "$f"
      [[ "$shard_key" == "$key" ]] && want+=("$f")
    done
    # Trust the literal name if the listing did not surface it.
    [[ ${#want[@]} -gt 0 ]] || want=("$sel")
  else
    # Quant label, matched case-insensitively against the listing.
    [[ ${#all[@]} -gt 0 ]] || {
      printf "error: cannot resolve quant '%s': no GGUF listing for %s\n" "$sel" "$repo" >&2
      return 1
    }

    local sel_lc="${sel,,}"
    local -a matches=()
    for f in "${all[@]}"; do
      local base_lc="${f##*/}"
      base_lc="${base_lc,,}"
      case "$kind" in
      mmproj) [[ "$base_lc" == mmproj* ]] || continue ;;
      *) [[ "$base_lc" == mmproj* ]] && continue ;;
      esac
      # The label must appear delimited by [-_.] or an edge: 'F16' matches
      # '…-F16.gguf' but not '…-BF16.gguf', which a bare substring test
      # would quietly pick. "$sel_lc" is quoted, so it matches literally;
      # the extglob alternations supply the optional delimited context.
      [[ "$base_lc" == @(|*[-_.])"$sel_lc"@(|[-_.]*) ]] && matches+=("$f")
    done
    [[ ${#matches[@]} -gt 0 ]] || {
      printf "error: no GGUF matching quant '%s' in %s. Available:\n" "$sel" "$repo" >&2
      printf '  %s\n' "${all[@]}" | LC_ALL=C sort >&2
      return 1
    }

    # Collapse shards: group matches by quant key.
    local -A keyset=()
    for f in "${matches[@]}"; do
      strip_shard "$f"
      keyset["$shard_key"]=1
    done

    local -a keys=("${!keyset[@]}")
    local k
    if [[ ${#keys[@]} -gt 1 ]]; then
      # Tie-break: prefer the single quant whose name ends with the label
      # (e.g. 'Q6_K' over 'Q6_K_XL').
      keys=()
      for k in "${!keyset[@]}"; do
        local kb="${k##*/}"
        [[ "${kb,,}" == *"$sel_lc" ]] && keys+=("$k")
      done
    fi
    if [[ ${#keys[@]} -ne 1 ]]; then
      printf "error: quant '%s' is ambiguous in %s; matches:\n" "$sel" "$repo" >&2
      local -a bases=()
      for k in "${!keyset[@]}"; do bases+=("${k##*/}"); done
      printf '  %s\n' "${bases[@]}" | LC_ALL=C sort >&2
      printf 'specify a more precise quant or the full filename.\n' >&2
      return 1
    fi
    local chosen="${keys[0]}"

    for f in "${matches[@]}"; do
      strip_shard "$f"
      [[ "$shard_key" == "$chosen" ]] && want+=("$f")
    done
  fi

  printf '%s\n' "${want[@]}" | LC_ALL=C sort
}

# Resolve a model spec to a local GGUF file path, downloading from HF as
# needed. Accepts:
#   /path/to/model.gguf    → local file, used directly
#   org/repo:file.gguf     → that exact file (plus sibling shards if split)
#   org/repo:QUANT         → file matching the quant label (e.g. Q4_K_M)
#   org/repo               → lists available GGUF files in the repo
# Split models: all shards are fetched and the first shard's path is
# returned; llama-server loads the rest from the same directory.
# $2 (default 'model') scopes quant matching — see select_gguf_files.
resolve_model() {
  local spec="$1" kind="${2:-model}"

  # Local file path
  if [[ -f "$spec" ]]; then
    abspath "$spec"
    return
  fi

  # Must look like an HF ref: org/repo[...], not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "model not found: $spec (use a local path, org/repo:file.gguf, or org/repo:QUANT)"

  local repo="$spec" sel=""
  if [[ "$spec" == *:* ]]; then
    repo="${spec%%:*}"
    sel="${spec#*:}"
  fi

  # GGUF files available in the repo (may include subfolders).
  local listing
  listing="$(hf_listing "$repo" '\.gguf')" || listing=""

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
    LC_ALL=C sort <<<"$listing" | sed 's/^/  /' >&2
    printf '\nUse: --model %s:<filename>  or  --model %s:<QUANT>\n' "$repo" "$repo" >&2
    exit 1
  fi

  local -a all=()
  split_lines "$listing" all

  info "resolving:" "$repo:$sel" >&2
  local files_out
  files_out="$(select_gguf_files "$repo" "$sel" "$kind" "${all[@]}")" || exit 1

  local -a want=()
  split_lines "$files_out" want
  [[ ${#want[@]} -gt 1 ]] && info "split:" "${#want[@]} shards" >&2

  local f target first=""
  for f in "${want[@]}"; do
    target="$MODELS_DIR/$repo/$f"
    hf_download "$repo" "$f" "$target"
    [[ -z "$first" ]] && first="$target"
  done

  printf '%s' "$first"
}

# ── Model resolution: MLX (mlx-server) ────────────────────

# Resolve an MLX model spec to a local model directory, downloading from HF
# as needed. Accepts:
#   /path/to/model-dir     → local directory, used directly
#   org/repo               → full repo download (an MLX model is a directory:
#                            config.json, tokenizer files, *.safetensors)
resolve_mlx_model() {
  local spec="$1"

  # Local directory
  if [[ -d "$spec" ]]; then
    [[ -f "$spec/config.json" ]] ||
      die "not an MLX model directory (no config.json): $spec"
    local dir
    dir="$(CDPATH='' cd -P -- "$spec" && pwd)" || die "cannot resolve path: $spec"
    printf '%s' "$dir"
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

  local listing
  listing="$(hf_listing "$spec")" || listing=""

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

# Seed an HF hub cache entry for a side-loaded repo download. The mlx
# servers list (/v1/models) and resolve models through huggingface_hub's
# cache, so a symlinked cache entry makes them treat the download as if it
# came from the hub — offline: clients can auto-discover the model and
# address it by its repo id. Rebuilt from scratch on every start. Layout:
#   hub/models--{org}--{name}/refs/main           → pseudo revision
#   hub/models--{org}--{name}/snapshots/<rev>/<f> → models/<repo>/<f>
seed_hf_cache() {
  local repo="$1" model_dir="$2"
  : "${HF_HOME:?seed_hf_cache requires HF_HOME}"
  local entry="$HF_HOME/hub/models--${repo//\//--}"
  # Content-addressing is irrelevant locally, but the ref must name an
  # existing snapshot directory and look like a commit hash.
  local rev="0000000000000000000000000000000000000000"

  rm -rf "$entry"
  mkdir -p "$entry/refs" "$entry/snapshots/$rev"
  printf '%s' "$rev" >"$entry/refs/main"

  local f rel dest
  while IFS= read -r -d '' f; do
    rel="${f#"$model_dir/"}"
    dest="$entry/snapshots/$rev/$rel"
    mkdir -p "${dest%/*}"
    ln -s "$f" "$dest"
  done < <(find "$model_dir" -type f ! -name '.*' -print0)
}

# ── Subcommands ───────────────────────────────────────────
# Each cmd_* cds into a sandbox-readable directory (the sandboxed process's
# getcwd() must resolve) and ends in `exec sandbox-exec` with every grant
# spelled out at the call site — keep it that way: the full parameter set of
# every sandbox must stay auditable where it is used. The -D blocks share a
# fixed order: COMMON_SB, NET_*, PKG_STORE, per-command params, -f, argv.

# die unless the option $1 is followed by a value.
need_arg() { [[ $# -ge 2 ]] || die "$1 requires an argument"; }

# Consume leading -w/--workspace DIR (last wins); sets WORKSPACE and ARGS
# (the remaining args, passed through to the wrapped tool).
parse_workspace() {
  WORKSPACE="$PWD"
  while [[ "${1:-}" == "-w" || "${1:-}" == "--workspace" ]]; do
    need_arg "$@"
    WORKSPACE="$2"
    shift 2
  done
  ARGS=("$@")
}

cmd_llama() {
  # Consumes --model/--mmproj/--socket; everything else passes through.
  # MODEL/MMPROJ are intentionally global: the flags override the env vars.
  local -a extra_args=()
  local socket=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model) need_arg "$@"; MODEL="$2"; shift 2 ;;
    --mmproj) need_arg "$@"; MMPROJ="$2"; shift 2 ;;
    --socket) need_arg "$@"; socket="$2"; shift 2 ;;
    *) extra_args+=("$1"); shift ;;
    esac
  done
  [[ -n "${MODEL:-}" ]] || die "no model specified — use --model or set MODEL env var"

  local model_path model_dir model_alias llama_server pkg_store
  model_path="$(resolve_model "$MODEL")"
  model_dir="${model_path%/*}"
  model_alias="${model_dir##*/}"
  llama_server="$(resolve_binary "${LLAMA_SERVER:-}" llama-server LLAMA_SERVER)"
  pkg_store="$(pkg_store_for "$llama_server")"

  # A vision model is served from two GGUFs: the model plus a multimodal
  # projector (mmproj-*.gguf). llama-server only auto-fetches the projector
  # on its own `-hf` path, never for a local --model, so it must be resolved
  # and passed explicitly here. Quant labels resolve against projector files
  # only (see select_gguf_files); explicit filenames also work.
  local mmproj_path="" mmproj_dir=""
  if [[ -n "${MMPROJ:-}" ]]; then
    mmproj_path="$(resolve_model "$MMPROJ" mmproj)"
    mmproj_dir="${mmproj_path%/*}"
  fi

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR

  local -a server_args=(--model "$model_path" --alias "$model_alias" --port "$PORT")
  [[ -n "$mmproj_path" ]] && server_args+=(--mmproj "$mmproj_path")
  select_net "$socket"
  [[ -n "$socket" ]] && server_args+=(--host "$NET_TARGET")

  printf 'Starting sandboxed llama-server:\n'
  info "binary:" "$llama_server"
  info "model:" "$model_path"
  [[ -n "$mmproj_path" ]] && info "mmproj:" "$mmproj_path"
  info "alias:" "$model_alias"
  info "port:" "$PORT"
  info "extra:" "${extra_args[*]:-none}"
  printf '\n'

  cd "$CACHE_DIR"

  # MMPROJ_DIR falls back to MODEL_DIR when no projector is given:
  # sandbox-exec errors out on profile parameters that were never passed.
  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D NET_SB="$NET_SB" \
    -D NET_TARGET="$NET_TARGET" \
    -D PKG_STORE="$pkg_store" \
    -D LLAMA_SERVER="$llama_server" \
    -D MODEL_DIR="$model_dir" \
    -D MMPROJ_DIR="${mmproj_dir:-$model_dir}" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/llama-server.sb" \
    "$llama_server" "${server_args[@]}" "${extra_args[@]}"
}

cmd_mlx() {
  # Consumes --model/--socket; everything else passes through.
  # MODEL is intentionally global: the flag overrides the env var.
  local -a extra_args=()
  local socket=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model) need_arg "$@"; MODEL="$2"; shift 2 ;;
    --socket) need_arg "$@"; socket="$2"; shift 2 ;;
    *) extra_args+=("$1"); shift ;;
    esac
  done
  [[ -n "${MODEL:-}" ]] || die "no model specified — use --model or set MODEL env var"

  local model_dir
  model_dir="$(resolve_mlx_model "$MODEL")"

  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  # Root ~-relative state (HF hub cache scans etc.) inside the writable
  # cache. The hub/ subdir must exist even when empty: /v1/models scans it
  # and 500s (CacheNotFound) when it's missing.
  export HOME="$CACHE_DIR/mlx-home"
  export HF_HOME="$HOME/huggingface"
  mkdir -p "$HF_HOME/hub"
  # The model is fully local and the sandbox denies outbound network anyway;
  # keep huggingface_hub from even trying.
  export HF_HUB_OFFLINE=1
  # Python auto-imports usercustomize from the user site directory under
  # $HOME. HOME is ours (above) and outside every client's grants, but the
  # server holds GPU and model access, so refuse user-site imports outright
  # rather than rely on the directory staying unwritable.
  export PYTHONNOUSERSITE=1

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
  # download above already includes the vision weights. Either way the wire
  # model id must equal what the server was started with (the servers key
  # their model cache on that string).
  # model_id is what clients must send in the OpenAI `model` field — the
  # servers key their model cache on that string. Reported below rather than
  # recorded: /v1/models serves it to clients that discover.
  local mlx_server model_id="$serve_ref"
  if grep -q '"vision_config"' "$model_dir/config.json"; then
    mlx_server="$(resolve_binary "${MLX_VLM_SERVER:-}" mlx_vlm.server MLX_VLM_SERVER)"
  else
    mlx_server="$(resolve_binary "${MLX_SERVER:-}" mlx_lm.server MLX_SERVER)"
    # mlx_lm.server only maps the literal "default_model" to its --model
    # when that is a path (a repo id resolves through the seeded cache).
    [[ "$serve_ref" == "$model_dir" ]] && model_id="default_model"
  fi

  local pkg_store
  pkg_store="$(pkg_store_for "$mlx_server")"
  resolve_ca_file

  printf 'Starting sandboxed %s:\n' "${mlx_server##*/}"
  info "binary:" "$mlx_server"
  info "model:" "$serve_ref"
  info "model id:" "$model_id"
  info "port:" "$PORT"
  info "extra:" "${extra_args[*]:-none}"
  printf '\n'

  # --host pins mlx_vlm.server to loopback (it defaults to 0.0.0.0;
  # mlx_lm.server already defaults to 127.0.0.1); both patched servers adopt
  # llama-server's convention of a UNIX socket when --host ends in .sock.
  # Extra args come last so they can override.
  local -a server_args=(--model "$serve_ref" --port "$PORT")
  select_net "$socket"
  if [[ -n "$socket" ]]; then
    server_args+=(--host "$NET_TARGET")
  else
    server_args+=(--host 127.0.0.1)
  fi

  cd "$CACHE_DIR"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D NET_SB="$NET_SB" \
    -D NET_TARGET="$NET_TARGET" \
    -D PKG_STORE="$pkg_store" \
    -D CA_FILE="$CA_FILE" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$SCRIPT_DIR/mlx-server.sb" \
    "$mlx_server" "${server_args[@]}" "${extra_args[@]}"
}

cmd_pi() {
  parse_workspace "$@"

  # pi keeps its state under ~/.pi, so root HOME inside the project dir to
  # keep writable state local (and out of the read-only store / real HOME).
  local pi_home="$STATE_DIR/pi"
  mkdir -p "$pi_home" "$CACHE_DIR" "$TMPDIR"
  export HOME="$pi_home"
  export TMPDIR

  # The llama-cpp plugin (huggingface/pi-llama) is loaded for the session
  # via `pi -e <dir>/index.ts`. The Nix wrapper points PI_LLAMA_DIR at the
  # pinned store copy; outside Nix, set it to a checkout of the repo. The
  # plugin discovers the server from LLAMA_BASE_URL.
  local plugin="${PI_LLAMA_DIR:-}/index.ts"
  [[ -n "${PI_LLAMA_DIR:-}" && -f "$plugin" ]] ||
    die "pi llama-cpp plugin not found — set PI_LLAMA_DIR to a dir containing index.ts"
  export LLAMA_BASE_URL="http://127.0.0.1:$PORT/v1"
  export LLAMA_API_KEY="${LLAMA_API_KEY:-dummy}"

  # pi probes tmux keyboard setup by spawning `tmux`; the sandbox denies the
  # exec and the spawn throws synchronously, crashing pi on startup. The
  # probe is gated on $TMUX, so hide it.
  unset TMUX
  # Read-only store install behind a network-restricted sandbox: skip pi's
  # startup network ops (self-update / version check / tool fetch), which
  # can only fail here. Does not affect the plugin's model discovery, which
  # talks to LLAMA_BASE_URL independently of this flag.
  export PI_OFFLINE=1

  local pi_bin pkg_store
  pi_bin="$(resolve_binary "${PI:-}" pi PI)"
  pkg_store="$(pkg_store_for "$pi_bin")"

  printf 'Starting sandboxed pi:\n'
  info "binary:" "$pi_bin"
  info "plugin:" "$plugin"
  info "server:" "$LLAMA_BASE_URL"
  info "workspace:" "$WORKSPACE"
  printf '\n'

  # Node-based TUIs open many fds; raise the limit to the macOS maximum.
  ulimit -n 2147483646

  cd "$WORKSPACE"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$pkg_store" \
    -D WORKSPACE="$WORKSPACE" \
    -D PI_DIR="$pi_home" \
    -D PI_LLAMA_DIR="$PI_LLAMA_DIR" \
    -D TMPDIR="$TMPDIR" \
    -D NET_ADDR="localhost:$PORT" \
    -f "$SCRIPT_DIR/pi.sb" \
    "$pi_bin" -e "$plugin" "${ARGS[@]}"
}

cmd_llm() {
  export LLM_USER_PATH="$STATE_DIR/llm"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
  mkdir -p "$LLM_USER_PATH" "$TMPDIR"
  export TMPDIR

  # Preset the default model to the llm-llama-server plugin's model name;
  # llm itself handles -m to pick another.
  printf 'llama-server\n' >"$LLM_USER_PATH/default_model.txt"

  local llm_bin pkg_store
  llm_bin="$(resolve_binary "${LLM:-}" llm LLM)"
  pkg_store="$(pkg_store_for "$llm_bin")"

  cd "$LLM_USER_PATH"

  exec sandbox-exec \
    -D COMMON_SB="$SCRIPT_DIR/common.sb" \
    -D PKG_STORE="$pkg_store" \
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
pi) cmd_pi "$@" ;;
llm) cmd_llm "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
