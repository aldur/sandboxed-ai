#!/usr/bin/env bash
# Sandbox local AI tools with macOS seatbelt (sandbox-exec).
#
# Layout: constants → sandbox helpers → Hugging Face downloads → model
# resolution (GGUF, MLX) → one cmd_* per subcommand, each ending in
# `exec env -i … sandbox-exec` with every grant spelled out → dispatch.
# The environment is an allowlist, not an inheritance: see sandbox_env.
#
# Subcommand → seatbelt profile (all import common.sb; the servers also
# import net-tcp.sb or net-unix.sb, chosen by a .sock --host):
#   llama-server → llama-server.sb    mlx-server → mlx-server.sb
#   pi           → pi.sb              llm        → llm.sb
#
# sandbox-exec -D values are literal strings consumed by (param ...) in the
# profiles — they parameterize path/address filters, never profile code.
set -euo pipefail

# ${var,,}, associative arrays, namerefs, and empty arrays under `set -u`
# need a modern bash (nix and homebrew both ship 5.x).
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
  {
    printf 'error: bash >= 4.4 required (found %s)\n' "$BASH_VERSION" >&2
    exit 1
  }
SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"

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
# Parent of the per-server cache dirs (Metal PSO cache, HF hub cache);
# each server appends its own name. Sharing one would let either server
# rewrite what the other loads on its next start — the same channel the
# per-subcommand scratch dirs below close, one trust level up.
CACHE_DIR="$STATE_DIR/cache"
# Parent of the per-subcommand scratch dirs; each cmd_* appends its own name
# before exporting it. One shared scratch would be a read-write channel
# between the sandboxes — pi could drop files where llm or a server reads
# them, which is exactly what the isolation above is meant to prevent.
TMPDIR="$STATE_DIR/tmp"
# Weights are large and often belong on another volume; SANDBOXED_AI_MODELS
# relocates them. Give it a real path, not a symlink: seatbelt matches
# resolved paths, so a link would not match the granted MODEL_DIR.
MODELS_DIR="${SANDBOXED_AI_MODELS:-$STATE_DIR/models}"

# The binary that enforces every profile in this repo, by absolute path.
# Never resolved through PATH: PATH is inherited from the caller (and passed
# on through the env allowlist), so a writable entry ahead of /usr/bin —
# ~/.local/bin, a stray ./node_modules/.bin — would let a stub take its
# place and run the tool with no sandbox at all, under a banner that says
# "Starting sandboxed …". The model binaries go through resolve_binary for
# the same reason; this one cannot afford even that much indirection.
# The invoking user's home, resolved before any subcommand re-roots HOME.
# common.sb grants path-traversal metadata on this rather than all of
# /Users: on a shared machine the other users' trees are none of our
# business, and everything this script owns lives under here.
HOME_DIR="$(realpath "$HOME" 2>/dev/null || printf '%s' "$HOME")"
# ...and its parent as a bare literal: sqlite stats every ancestor of the
# database it opens, so /Users must be stat-able even though nothing needs
# to look inside it.
HOME_PARENT="${HOME_DIR%/*}"
[[ -n "$HOME_PARENT" ]] || HOME_PARENT=/

SANDBOX_EXEC=/usr/bin/sandbox-exec
# The other macOS system tools this script runs before any sandbox
# exists, pinned by absolute path for the SANDBOX_EXEC reason above: a
# PATH stub would run them as the real user. All ship with macOS under
# SIP-protected paths.
GETCONF=/usr/bin/getconf
LSOF=/usr/sbin/lsof
TTY=/usr/bin/tty
# PORT stays writable: the server subcommands take --port.
readonly SCRIPT_DIR PROFILES_DIR PROG STATE_DIR MODELS_DIR HOME_DIR HOME_PARENT SANDBOX_EXEC GETCONF LSOF TTY

# ── Output & usage ────────────────────────────────────────
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
# Prints to stdout; callers whose stdout is captured redirect to stderr.
info() { printf '  %-14s %s\n' "$1" "$2"; }

[[ -x "$SANDBOX_EXEC" ]] ||
  die "$SANDBOX_EXEC not found or not executable — seatbelt is required"

# Shared Hugging Face download and resolution machinery (also sourced by
# sandbox-linux.sh). It uses die, info, MODELS_DIR and hf_curl from this
# file.
. "$SCRIPT_DIR/hf.sh"

# ── Sandboxed fetch ───────────────────────────────────────
# hf.sh reaches Hugging Face only through this function: curl inside its
# own seatbelt (hf-fetch.sb). It runs unsandboxed nowhere — a hostile
# response that exploits curl gets TLS out and MODELS_DIR, not the user
# account. -q comes first so ~/.curlrc cannot inject options, and the
# empty environment drops the proxy variables for the same reason.
#
# The CA bundle is passed explicitly (--cacert): under `env -i` curl
# cannot see SSL_CERT_FILE, and the profile grants exactly one bundle.
# First match wins: the nix-darwin bundle, a generic override, then the
# system one — present on every macOS.
hf_curl_init() {
  HF_CURL_BIN="$(resolve_binary "${CURL:-}" curl CURL)"
  case "$HF_CURL_BIN" in
  /usr/*) HF_CURL_STORE=/usr ;; # system curl: no package store
  *) HF_CURL_STORE="$(pkg_store_for "$HF_CURL_BIN")" ;;
  esac
  local ca
  HF_CA_FILE=""
  for ca in "${NIX_SSL_CERT_FILE:-}" "${SSL_CERT_FILE:-}" /etc/ssl/cert.pem; do
    [[ -n "$ca" && -f "$ca" ]] || continue
    HF_CA_FILE="$(realpath "$ca" 2>/dev/null)" && break
    HF_CA_FILE=""
  done
  [[ -n "$HF_CA_FILE" ]] ||
    die "no CA bundle found for the fetch sandbox (set NIX_SSL_CERT_FILE or SSL_CERT_FILE)"
}

# Transport policy for every fetch, shared with sandbox-linux.sh's hook:
# HTTPS only, redirects included (-L must never land on http:), a bounded
# connect, and a stall abort (< 1 KB/s for 60 s) instead of --max-time —
# a large model legitimately downloads for longer than any sane cap.
readonly -a HF_CURL_OPTS=(
  --proto '=https' --proto-redir '=https'
  --connect-timeout 30 --speed-limit 1024 --speed-time 60
)

hf_curl() {
  [[ -n "${HF_CURL_BIN:-}" ]] || hf_curl_init
  env -i "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D PKG_STORE="$HF_CURL_STORE" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH=/dev/null \
    -D STDERR_PATH=/dev/null \
    -D CURL="$HF_CURL_BIN" \
    -D MODELS_DIR="$MODELS_DIR" \
    -D CA_FILE="$HF_CA_FILE" \
    -f "$PROFILES_DIR/hf-fetch.sb" \
    "$HF_CURL_BIN" -q "${HF_CURL_OPTS[@]}" --cacert "$HF_CA_FILE" "$@"
}

usage() {
  cat >&2 <<EOF
Usage: $PROG <command> [options]

Commands:
  llama-server  Start the llama-server (sandboxed)
  llama-bench   Run llama-bench (sandboxed, no network)
  mlx-server    Start mlx_lm.server (sandboxed)
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
  LLAMA_SERVER, LLAMA_BENCH, MLX_SERVER, MLX_VLM_SERVER, PI, LLM, CURL
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

# Locate the executable for a command. $1 is an explicit override (from the
# env var named $3) and wins over the PATH lookup of $2. Prints an absolute,
# symlink-free path: the profiles grant exec on a literal path and seatbelt
# matches the resolved one, so a symlinked entry point (Homebrew keeps
# bin/* as links into Cellar, nix links python3 → python3.13) would be
# denied if the link path were granted instead.
resolve_binary() {
  local override="$1" name="$2" var="$3" bin

  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$name not executable: $override (from \$$var)"
    bin="$(abspath "$override")"
  else
    bin="$(command -v "$name")" ||
      die "$name not found on PATH. Install it or set $var."
  fi
  realpath "$bin" 2>/dev/null || printf '%s' "$bin"
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

# The per-user temp/cache dirs Apple frameworks (Metal, CoreFoundation)
# reach via confstr(_CS_DARWIN_USER_TEMP_DIR / _CS_DARWIN_USER_CACHE_DIR);
# TMPDIR cannot redirect them. common.sb grants exactly these two, keeping
# the rest of /private/var/folders — every other app's temp/cache state —
# out of reach. getconf prints them /var-prefixed with a trailing slash;
# seatbelt matches resolved paths, so realpath both resolves the /var
# symlink and normalizes the path. Sets DARWIN_USER_TEMP_DIR and
# DARWIN_USER_CACHE_DIR.
resolve_darwin_dirs() {
  DARWIN_USER_TEMP_DIR="$(realpath "$("$GETCONF" DARWIN_USER_TEMP_DIR)" 2>/dev/null)" ||
    die "cannot resolve DARWIN_USER_TEMP_DIR"
  local cache
  cache="$(realpath "$("$GETCONF" DARWIN_USER_CACHE_DIR)" 2>/dev/null)" ||
    die "cannot resolve DARWIN_USER_CACHE_DIR"
  # Only Metal's own namespaces are granted, not the whole cache: the other
  # ~200 directories there belong to unrelated applications. Created here
  # because the servers get no write access to the parent, so they could not
  # create them on a machine that has never run a Metal program.
  DARWIN_METAL_CACHE="$cache/com.apple.metal"
  DARWIN_METALFE_CACHE="$cache/com.apple.metalfe"
  mkdir -p "$DARWIN_METAL_CACHE" "$DARWIN_METALFE_CACHE"
}

# The interpreter named by $1's shebang, resolved and without its
# arguments. Empty when $1 is a real binary (or unreadable).
shebang_interp() {
  local line
  IFS= read -r line <"$1" 2>/dev/null || return 0
  [[ "$line" == '#!'* ]] || return 0
  line="${line#\#!}"
  line="${line#"${line%%[![:space:]]*}"}" # leading space after #!
  line="${line%%[[:space:]]*}"
  # Resolved: seatbelt matches the real path (nix links python3 → python3.13).
  realpath "$line" 2>/dev/null || printf '%s' "$line"
}

# Every file the mlx entry point must exec, so the profile can name them
# instead of allowing the whole package store (which under Homebrew is
# every binary in /opt/homebrew). Two shapes are covered:
#   nix:      bin/x (bash wrapper) → bash → bin/.x-wrapped → python3
#   homebrew: bin/x (python script)            → python3
# Sets MLX_INTERP, MLX_WRAPPED and MLX_WRAPPED_INTERP, each /dev/null when
# that link is absent — sandbox-exec errors on a parameter referenced but
# never passed, and /dev/null cannot be exec'd. Nothing deeper is needed:
# the profile denies process-fork, so the server cannot spawn anything
# beyond replacing itself along this chain.
resolve_mlx_exec() {
  local bin="$1"
  MLX_INTERP="$(shebang_interp "$bin")"
  MLX_WRAPPED="${bin%/*}/.${bin##*/}-wrapped"
  MLX_WRAPPED_INTERP=""
  if [[ -x "$MLX_WRAPPED" ]]; then
    MLX_WRAPPED_INTERP="$(shebang_interp "$MLX_WRAPPED")"
  else
    MLX_WRAPPED=""
  fi
  : "${MLX_INTERP:=/dev/null}"
  : "${MLX_WRAPPED:=/dev/null}"
  : "${MLX_WRAPPED_INTERP:=/dev/null}"
}

# The controlling terminal the client profiles grant read/write/ioctl on.
# Only this one: the /dev/ttys* nodes are all mode 0620 and owned by the
# invoking user, so a pattern grant would let a compromised client read
# input from — and write escape sequences into — every other terminal
# session open on the machine. Sets TTY_DEV; /dev/null means "not a
# terminal" (the profile references the param unconditionally and
# sandbox-exec errors on a never-passed one), which also covers a
# non-interactive run where there is no ctty to grant.
resolve_tty() {
  TTY_DEV="$("$TTY" 2>/dev/null)" && [[ "$TTY_DEV" == /dev/* ]] || TTY_DEV="/dev/null"
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
# Default is TCP on $PORT (net-tcp.sb); a .sock --host selects net-unix.sb
# with the socket path as the filter — each personality grants nothing of
# the other's surface. The path must end in .sock (all three servers key
# UNIX-socket mode off that suffix on --host) and is normalized here, to
# absolute with symlinks resolved (seatbelt matches resolved paths).
# True when some process holds $1 open, i.e. it is a live socket rather
# than a leftover. Conservative: with no lsof, nothing is reported in use.
socket_in_use() {
  [[ -x "$LSOF" ]] || return 1
  [[ -n "$("$LSOF" -t -- "$1" 2>/dev/null)" ]]
}

select_net() {
  NET_SB="$PROFILES_DIR/net-tcp.sb"
  NET_TARGET="*:$PORT"

  local sock="${1:-}"
  [[ -n "$sock" ]] || return 0
  [[ "$sock" == *.sock ]] || die "socket path must end in .sock: $sock"
  [[ "$sock" == /* ]] || sock="$PWD/$sock"
  # -m 700 (applied only to a directory we create) and umask 077 below keep
  # the socket owner-only: the servers authenticate nobody, and on macOS
  # connecting to a UNIX socket needs write permission on it, so anything
  # group- or world-writable is an open door to the model. Without the
  # umask the mode is whatever the caller's happens to be — 0755 under the
  # usual 022, but 0775 under 002.
  # ${sock%/*} is empty for a path directly under / ("/x.sock").
  local dir="${sock%/*}"
  [[ -n "$dir" ]] || dir=/
  mkdir -m 700 -p "$dir" # the profile grants only the socket path itself

  # Resolve symlinks: on macOS /tmp really is /private/tmp, and seatbelt
  # compares against the resolved path. The profile grant and the server's
  # --host both need the real one, or bind() gets denied.
  dir="$(realpath "$dir" 2>/dev/null || (cd "$dir" && pwd -P))"
  sock="$dir/${sock##*/}"

  # A stale socket file would make bind() fail, so it has to go — but this
  # runs unsandboxed with full user privileges on a path the caller typed,
  # so only ever unlink a socket, and never one something is listening on:
  # a fat-fingered --host /opt/homebrew/var/run/mysqld/mysqld.sock must
  # not take out a live database.
  if [[ -e "$sock" || -L "$sock" ]]; then
    [[ -S "$sock" ]] ||
      die "socket path exists and is not a socket: $sock"
    ! socket_in_use "$sock" ||
      die "socket path is already served by another process: $sock"
    rm -f "$sock"
  fi
  umask 077
  NET_SB="$PROFILES_DIR/net-unix.sb"
  NET_TARGET="$sock"
}

# ── Subcommands ───────────────────────────────────────────
# Each cmd_* cds into a directory its profile grants read on: getcwd() is
# subject to the sandbox, and Python raises EPERM from it (rich computes
# os.getcwd() at import) anywhere else. That directory is what tmux reports
# as the pane's path while the tool runs. Each ends in `exec sandbox-exec` with every grant
# spelled out at the call site — keep it that way: the full parameter set of
# every sandbox must stay auditable where it is used. The -D blocks share a
# fixed order: COMMON_SB, SERVER_SB/CLIENT_SB, NET_*, PKG_STORE,
# DARWIN_USER_*, per-command params, -f, argv.

# The files stdout and stderr point at, when they are regular files. A
# sandboxed process inherits those descriptors, and Node stats and reopens
# them while starting up: with the path unreachable it aborts before
# running any code. Nothing is resolvable through /dev/fd on macOS, so ask
# lsof, and only when the descriptor is a file at all — a pipe or a
# terminal needs none of this. /dev/null stands in for "not a file", since
# the profiles reference the parameters unconditionally.
resolve_stdio() {
  STDOUT_PATH=/dev/null
  STDERR_PATH=/dev/null
  [[ -x "$LSOF" ]] || return 0
  local fd var path
  for fd in 1 2; do
    [[ -f "/dev/fd/$fd" ]] || continue
    path="$("$LSOF" -a -d "$fd" -p $$ -Fn 2>/dev/null | grep '^n' | cut -c2- | head -1)" || continue
    [[ -n "$path" && "$path" == /* ]] || continue
    var="STDOUT_PATH"
    [[ "$fd" == 2 ]] && var="STDERR_PATH"
    printf -v "$var" '%s' "$path"
  done
  return 0
}

# die unless the option $1 is followed by a value.
need_arg() { [[ $# -ge 2 ]] || die "$1 requires an argument"; }

# Variables every sandboxed tool gets: where to find programs, and enough
# terminal/locale context to render output. None carry credentials.
readonly -a ENV_BASE=(PATH TERM TERM_PROGRAM COLORTERM LANG LC_ALL LC_CTYPE TZ NO_COLOR)

# Build the `env -i` prefix for a sandboxed exec into the array named by
# $1, passing through only the variables named in the remaining arguments
# (unset ones are skipped).
#
# The sandboxed process is the one assumed to go rogue, so it must not
# inherit the caller's environment wholesale: a shell that exports
# GITHUB_TOKEN, AWS_*, HF_TOKEN or similar would otherwise hand those
# straight to it — the seatbelt blocks the network, but a client can still
# write them into its workspace and a server can echo them back over the
# completion API. An allowlist also drops the interpreter knobs
# (PYTHONPATH, PYTHONSTARTUP, NODE_OPTIONS, DYLD_*) that would otherwise
# steer the Python and Node runtimes inside the sandbox.
sandbox_env() {
  local -n _env="$1"
  shift
  _env=(env -i)
  local var
  for var in "${ENV_BASE[@]}" "$@"; do
    [[ -n "${!var:-}" ]] && _env+=("$var=${!var}")
  done
  return 0
}

# Canonical form of $1 for comparison, unresolved if it does not exist yet.
canon() { realpath "$1" 2>/dev/null || printf '%s' "${1%/}"; }

# True when $1 and $2 are the same directory or one contains the other.
# Both must already be canonical; the trailing slashes stop /foo/bar from
# looking like it sits inside /foo/ba.
paths_overlap() {
  local a="${1%/}/" b="${2%/}/"
  [[ "$a" == "$b"* || "$b" == "$a"* ]]
}

# Consume leading -w/--workspace DIR (last wins); sets WORKSPACE and ARGS
# (the remaining args, passed through to the wrapped tool).
#
# The workspace is the one path this script takes from the caller, and the
# agent gets read+write over all of it — so it is canonicalized like every
# other path (seatbelt matches resolved paths, so a relative or symlinked
# -w would grant nothing and leave pi running in a directory it cannot
# touch) and then checked for what it must not be:
#   /            — read/write over the whole filesystem
#   $HOME        — and note STATE_DIR lives under it by default, so `cd ~ &&
#                  … pi` would otherwise hand the agent the model cache,
#                  the digest sidecars and the .download-complete markers
#                  that resolve_mlx_model trusts on the next start
#   an ancestor or descendant of STATE_DIR / MODELS_DIR — same reasoning,
#                  for a relocated state or models dir
parse_workspace() {
  WORKSPACE="$PWD"
  while [[ "${1:-}" == "-w" || "${1:-}" == "--workspace" ]]; do
    need_arg "$@"
    WORKSPACE="$2"
    shift 2
  done
  ARGS=("$@")

  [[ -d "$WORKSPACE" ]] || die "workspace is not a directory: $WORKSPACE"
  WORKSPACE="$(realpath "$WORKSPACE")" ||
    die "cannot resolve workspace: $WORKSPACE"

  [[ "$WORKSPACE" != "/" ]] ||
    die "refusing to run with / as the workspace — use -w to pick a project directory"
  [[ "$WORKSPACE" != "$(canon "$HOME")" ]] ||
    die "refusing to run with your home directory as the workspace — use -w to pick a project directory"

  local guarded name
  for name in STATE_DIR MODELS_DIR; do
    guarded="$(canon "${!name}")"
    ! paths_overlap "$WORKSPACE" "$guarded" ||
      die "workspace overlaps $name ($guarded): the agent would be able to rewrite the model cache it is served from — use -w to pick a project directory"
  done
}

cmd_llama() {
  # Consumes --model/--mmproj/--host and the draft/template flags below;
  # everything else passes through.
  # MODEL/MMPROJ are intentionally global: the flags override the env vars.
  local -a extra_args=()
  local socket="" want_help="" host_arg="" tcp_host="" port_arg=""
  local draft_spec="" template_spec=""
  [[ $# -gt 0 ]] || want_help=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
    # -hf/-hfr/--hf-repo are llama-server's own HF flags. The sandbox
    # denies network, so the server must never see them: consume them and
    # resolve the spec host-side, like --model.
    --model | -hf | -hfr | --hf-repo)
      need_arg "$@"
      MODEL="$2"
      shift 2
      ;;
    # The draft model (speculative decoding) is a second GGUF the server
    # reads. Consumed for the same reason: resolved host-side, granted
    # read-only, and passed on as a local --model-draft.
    -hfd | -hfrd | --hf-repo-draft | -md | --model-draft)
      need_arg "$@"
      draft_spec="$2"
      shift 2
      ;;
    # A chat template is a single jinja file, local or from HF.
    --chat-template-file)
      need_arg "$@"
      template_spec="$2"
      shift 2
      ;;
    --mmproj)
      need_arg "$@"
      MMPROJ="$2"
      shift 2
      ;;
    --host | --host=*)
      # Same rule the servers use: a path ending in .sock means "serve on
      # that unix socket", anything else is a TCP address.
      host_arg="${1#--host}"
      host_arg="${host_arg#=}"
      if [[ -n "$host_arg" ]]; then
        shift
      else
        need_arg "$@"
        host_arg="$2"
        shift 2
      fi
      if [[ "$host_arg" == *.sock ]]; then
        socket="$host_arg"
      else
        tcp_host="$host_arg"
      fi
      ;;
    --port | --port=*)
      # Consumed rather than passed through: the sandbox grant has to name
      # the same port the server binds.
      port_arg="${1#--port}"
      port_arg="${port_arg#=}"
      if [[ -n "$port_arg" ]]; then
        shift
      else
        need_arg "$@"
        port_arg="$2"
        shift 2
      fi
      [[ "$port_arg" =~ ^[0-9]+$ ]] || die "not a port number: $port_arg"
      PORT="$port_arg"
      ;;
    -h | --help)
      want_help=1
      extra_args+=("$1")
      shift
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
    esac
  done
  local help_only=""
  if [[ -z "${MODEL:-}" ]]; then
    [[ -n "$want_help" ]] || die "no model specified — use --model or set MODEL env var"
    help_only=1
  fi
  # Before the download: a bad --host should not cost a 17 GB fetch first.
  select_net "$socket"

  local model_path="" model_dir=/dev/null model_alias="" llama_server pkg_store
  if [[ -z "$help_only" ]]; then
    model_path="$(resolve_model "$MODEL")"
    model_dir="${model_path%/*}"
    model_alias="${model_dir##*/}"
  fi
  llama_server="$(resolve_binary "${LLAMA_SERVER:-}" llama-server LLAMA_SERVER)"
  pkg_store="$(pkg_store_for "$llama_server")"

  # A vision model is served from two GGUFs: the model plus a multimodal
  # projector (mmproj-*.gguf). llama-server only auto-fetches the projector
  # on its own `-hf` path, never for a local --model, so it must be resolved
  # and passed explicitly here. Quant labels resolve against projector files
  # only (see select_gguf_files); explicit filenames also work.
  local mmproj_path="" mmproj_dir=""
  if [[ -z "$help_only" && -n "${MMPROJ:-}" ]]; then
    mmproj_path="$(resolve_model "$MMPROJ" mmproj)"
    mmproj_dir="${mmproj_path%/*}"
  fi

  # The draft model resolves with the full spec grammar (quant labels
  # included); the chat template is always an explicit file.
  local draft_path="" draft_dir=""
  if [[ -z "$help_only" && -n "$draft_spec" ]]; then
    draft_path="$(resolve_model "$draft_spec")"
    draft_dir="${draft_path%/*}"
  fi
  local template_path=""
  if [[ -z "$help_only" && -n "$template_spec" ]]; then
    template_path="$(resolve_hf_file "$template_spec" '\.jinja' 'chat template')"
  fi

  TMPDIR="$TMPDIR/llama-server"
  CACHE_DIR="$CACHE_DIR/llama-server"
  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  # Root ~-relative lookups inside the writable cache: the real HOME is
  # not granted, and under the env allowlist below nothing else defines it.
  export HOME="$CACHE_DIR"
  resolve_darwin_dirs
  resolve_stdio

  local -a server_args=()
  if [[ -n "$help_only" ]]; then
    server_args=(--help)
    extra_args=()
  else
    server_args=(--model "$model_path" --alias "$model_alias" --port "$PORT")
    [[ -n "$mmproj_path" ]] && server_args+=(--mmproj "$mmproj_path")
    [[ -n "$draft_path" ]] && server_args+=(--model-draft "$draft_path")
    [[ -n "$template_path" ]] && server_args+=(--chat-template-file "$template_path")
    if [[ -n "$socket" ]]; then
      server_args+=(--host "$NET_TARGET")
    elif [[ -n "$tcp_host" ]]; then
      server_args+=(--host "$tcp_host")
    fi

    printf 'Starting sandboxed llama-server:\n'
    info "binary:" "$llama_server"
    info "model:" "$model_path"
    [[ -n "$mmproj_path" ]] && info "mmproj:" "$mmproj_path"
    [[ -n "$draft_path" ]] && info "draft:" "$draft_path"
    [[ -n "$template_path" ]] && info "template:" "$template_path"
    info "alias:" "$model_alias"
    if [[ -n "$socket" ]]; then
      info "socket:" "$NET_TARGET"
    else
      info "port:" "$PORT"
    fi
    info "extra:" "${extra_args[*]:-none}"
    printf '\n'
  fi

  cd "$CACHE_DIR"

  # MMPROJ_DIR falls back to MODEL_DIR when no projector is given:
  # sandbox-exec errors out on profile parameters that were never passed.
  local -a sbx_env
  sandbox_env sbx_env HOME TMPDIR
  exec "${sbx_env[@]}" "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D SERVER_SB="$PROFILES_DIR/server.sb" \
    -D NET_SB="$NET_SB" \
    -D NET_TARGET="$NET_TARGET" \
    -D PKG_STORE="$pkg_store" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH="$STDOUT_PATH" \
    -D STDERR_PATH="$STDERR_PATH" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_USER_TEMP_DIR" \
    -D DARWIN_METAL_CACHE="$DARWIN_METAL_CACHE" \
    -D DARWIN_METALFE_CACHE="$DARWIN_METALFE_CACHE" \
    -D LLAMA_SERVER="$llama_server" \
    -D MODEL_DIR="$model_dir" \
    -D MMPROJ_DIR="${mmproj_dir:-$model_dir}" \
    -D DRAFT_DIR="${draft_dir:-$model_dir}" \
    -D CHAT_TEMPLATE_FILE="${template_path:-/dev/null}" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$PROFILES_DIR/llama-server.sb" \
    "$llama_server" "${server_args[@]}" "${extra_args[@]}"
}

cmd_bench() {
  # Consumes the model flags (llama-bench's own -m plus the -hf aliases),
  # resolved host-side as in cmd_llama; everything else passes through.
  local -a extra_args=()
  local want_help=""
  [[ $# -gt 0 ]] || want_help=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -m | --model | -hf | -hfr | --hf-repo)
      need_arg "$@"
      MODEL="$2"
      shift 2
      ;;
    -h | --help)
      want_help=1
      extra_args+=("$1")
      shift
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
    esac
  done
  local help_only=""
  if [[ -z "${MODEL:-}" ]]; then
    [[ -n "$want_help" ]] || die "no model specified — use --model or set MODEL env var"
    help_only=1
  fi

  local model_path="" model_dir=/dev/null llama_bench pkg_store
  [[ -n "$help_only" ]] || {
    model_path="$(resolve_model "$MODEL")"
    model_dir="${model_path%/*}"
  }
  llama_bench="$(resolve_binary "${LLAMA_BENCH:-}" llama-bench LLAMA_BENCH)"
  pkg_store="$(pkg_store_for "$llama_bench")"

  # Own scratch and Metal cache, not llama-server's — see CACHE_DIR above
  # on why the sandboxes must not share a writable path.
  TMPDIR="$TMPDIR/llama-bench"
  CACHE_DIR="$CACHE_DIR/llama-bench"
  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  # Root ~-relative lookups inside the writable cache, as in cmd_llama.
  export HOME="$CACHE_DIR"
  resolve_darwin_dirs
  resolve_stdio

  local -a bench_args=()
  if [[ -n "$help_only" ]]; then
    bench_args=(--help)
    extra_args=()
  else
    bench_args=(-m "$model_path")
    printf 'Starting sandboxed llama-bench:\n'
    info "binary:" "$llama_bench"
    info "model:" "$model_path"
    info "extra:" "${extra_args[*]:-none}"
    printf '\n'
  fi

  cd "$CACHE_DIR"

  # No NET_TARGET: net-none.sb consumes none (see its header).
  local -a sbx_env
  sandbox_env sbx_env HOME TMPDIR
  exec "${sbx_env[@]}" "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D SERVER_SB="$PROFILES_DIR/server.sb" \
    -D NET_SB="$PROFILES_DIR/net-none.sb" \
    -D PKG_STORE="$pkg_store" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH="$STDOUT_PATH" \
    -D STDERR_PATH="$STDERR_PATH" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_USER_TEMP_DIR" \
    -D DARWIN_METAL_CACHE="$DARWIN_METAL_CACHE" \
    -D DARWIN_METALFE_CACHE="$DARWIN_METALFE_CACHE" \
    -D LLAMA_BENCH="$llama_bench" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$PROFILES_DIR/llama-bench.sb" \
    "$llama_bench" "${bench_args[@]}" "${extra_args[@]}"
}

cmd_mlx() {
  # Consumes --model/--host; everything else passes through.
  # MODEL is intentionally global: the flag overrides the env var.
  local -a extra_args=()
  local socket="" want_help="" host_arg="" tcp_host="" port_arg=""
  [[ $# -gt 0 ]] || want_help=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --model)
      need_arg "$@"
      MODEL="$2"
      shift 2
      ;;
    --host | --host=*)
      # Same as in cmd_llama: .sock means a unix socket, otherwise TCP.
      host_arg="${1#--host}"
      host_arg="${host_arg#=}"
      if [[ -n "$host_arg" ]]; then
        shift
      else
        need_arg "$@"
        host_arg="$2"
        shift 2
      fi
      if [[ "$host_arg" == *.sock ]]; then
        socket="$host_arg"
      else
        tcp_host="$host_arg"
      fi
      ;;
    --port | --port=*)
      # Consumed rather than passed through, as in cmd_llama.
      port_arg="${1#--port}"
      port_arg="${port_arg#=}"
      if [[ -n "$port_arg" ]]; then
        shift
      else
        need_arg "$@"
        port_arg="$2"
        shift 2
      fi
      [[ "$port_arg" =~ ^[0-9]+$ ]] || die "not a port number: $port_arg"
      PORT="$port_arg"
      ;;
    -h | --help)
      # Recorded, not consumed: with a model this passes through to the
      # running server's --help; without one it selects help-only mode.
      want_help=1
      extra_args+=("$1")
      shift
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
    esac
  done
  # Help without a model: run the server's own --help under the normal
  # sandbox with nothing to serve — MODEL_DIR becomes /dev/null, which the
  # profile can reference but which grants no file (the TTY_DEV/CA_FILE
  # convention). With a model, --help still resolves it first and passes
  # through, which the download-integrity e2e test relies on.
  local help_only=""
  if [[ -z "${MODEL:-}" ]]; then
    [[ -n "$want_help" ]] || die "no model specified — use --model or set MODEL env var"
    help_only=1
  fi
  # Before the download: a bad --host should not cost a full repo fetch.
  select_net "$socket"

  local model_dir=/dev/null
  [[ -n "$help_only" ]] || model_dir="$(resolve_mlx_model "$MODEL")"

  TMPDIR="$TMPDIR/mlx-server"
  CACHE_DIR="$CACHE_DIR/mlx-server"
  mkdir -p "$CACHE_DIR" "$TMPDIR"
  export TMPDIR
  # Root ~-relative state (HF hub cache scans etc.) inside the writable
  # cache. The hub/ subdir must exist even when empty: /v1/models scans it
  # and 500s (CacheNotFound) when it's missing.
  export HOME="$CACHE_DIR/mlx-home"
  export HF_HOME="$HOME/huggingface"
  # Emptied before seeding: /v1/models lists whatever is in this cache, and
  # the sandbox grants MODEL_DIR for the served model alone. Anything else
  # listed is a model a client can ask for and the server may not open.
  rm -rf "$HF_HOME/hub"
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
  if [[ -z "$help_only" && ! -d "$MODEL" ]]; then
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
  if [[ -n "$help_only" ]]; then
    # No config.json to inspect: show the text server's help. (Vision
    # models are served by mlx_vlm.server, whose flags differ.)
    mlx_server="$(resolve_binary "${MLX_SERVER:-}" mlx_lm.server MLX_SERVER)"
  elif grep -q '"vision_config"' "$model_dir/config.json"; then
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
  resolve_darwin_dirs
  resolve_stdio
  resolve_mlx_exec "$mlx_server"

  local -a server_args=()
  if [[ -n "$help_only" ]]; then
    server_args=(--help)
    extra_args=()
  else
    printf 'Starting sandboxed %s:\n' "${mlx_server##*/}"
    info "binary:" "$mlx_server"
    info "model:" "$serve_ref"
    info "model id:" "$model_id"
    if [[ -n "$socket" ]]; then
      info "socket:" "$NET_TARGET"
    else
      info "port:" "$PORT"
    fi
    info "extra:" "${extra_args[*]:-none}"
    printf '\n'

    # Unless the caller picked a TCP address, pin mlx_vlm.server to
    # loopback (it defaults to 0.0.0.0; mlx_lm.server already defaults to
    # 127.0.0.1). Both patched servers adopt llama-server's convention of
    # a UNIX socket when --host ends in .sock.
    # Extra args come last so they can override.
    server_args=(--model "$serve_ref" --port "$PORT")
    if [[ -n "$socket" ]]; then
      server_args+=(--host "$NET_TARGET")
    else
      server_args+=(--host "${tcp_host:-127.0.0.1}")
    fi
  fi

  cd "$CACHE_DIR"

  # NIX_SSL_CERT_FILE: nixpkgs' certifi opens it verbatim (see
  # resolve_ca_file); the profile grants read on exactly that path.
  local -a sbx_env
  sandbox_env sbx_env HOME TMPDIR HF_HOME HF_HUB_OFFLINE PYTHONNOUSERSITE NIX_SSL_CERT_FILE
  exec "${sbx_env[@]}" "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D SERVER_SB="$PROFILES_DIR/server.sb" \
    -D NET_SB="$NET_SB" \
    -D NET_TARGET="$NET_TARGET" \
    -D PKG_STORE="$pkg_store" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH="$STDOUT_PATH" \
    -D STDERR_PATH="$STDERR_PATH" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_USER_TEMP_DIR" \
    -D DARWIN_METAL_CACHE="$DARWIN_METAL_CACHE" \
    -D DARWIN_METALFE_CACHE="$DARWIN_METALFE_CACHE" \
    -D CA_FILE="$CA_FILE" \
    -D MLX_SERVER="$mlx_server" \
    -D MLX_INTERP="$MLX_INTERP" \
    -D MLX_WRAPPED="$MLX_WRAPPED" \
    -D MLX_WRAPPED_INTERP="$MLX_WRAPPED_INTERP" \
    -D MODEL_DIR="$model_dir" \
    -D CACHE_DIR="$CACHE_DIR" \
    -D TMPDIR="$TMPDIR" \
    -f "$PROFILES_DIR/mlx-server.sb" \
    "$mlx_server" "${server_args[@]}" "${extra_args[@]}"
}

cmd_pi() {
  parse_workspace "$@"

  # pi keeps its state under ~/.pi, so root HOME inside the project dir to
  # keep writable state local (and out of the read-only store / real HOME).
  local pi_home="$STATE_DIR/pi"
  TMPDIR="$TMPDIR/pi"
  mkdir -p "$pi_home" "$TMPDIR"
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
  resolve_tty
  resolve_stdio

  printf 'Starting sandboxed pi:\n'
  info "binary:" "$pi_bin"
  info "plugin:" "$plugin"
  info "server:" "$LLAMA_BASE_URL"
  info "workspace:" "$WORKSPACE"
  printf '\n'

  # Node-based TUIs open many fds; raise the limit to the macOS maximum.
  ulimit -n 2147483646

  cd "$WORKSPACE"

  local -a sbx_env
  sandbox_env sbx_env HOME TMPDIR LLAMA_BASE_URL LLAMA_API_KEY PI_OFFLINE
  exec "${sbx_env[@]}" "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D CLIENT_SB="$PROFILES_DIR/client.sb" \
    -D PKG_STORE="$pkg_store" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH="$STDOUT_PATH" \
    -D STDERR_PATH="$STDERR_PATH" \
    -D WORKSPACE="$WORKSPACE" \
    -D PI_DIR="$pi_home" \
    -D PI_LLAMA_DIR="$PI_LLAMA_DIR" \
    -D TTY_DEV="$TTY_DEV" \
    -D TMPDIR="$TMPDIR" \
    -D NET_ADDR="localhost:$PORT" \
    -f "$PROFILES_DIR/pi.sb" \
    "$pi_bin" -e "$plugin" "${ARGS[@]}"
}

cmd_llm() {
  export LLM_USER_PATH="$STATE_DIR/llm"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
  # Root ~-relative lookups inside llm's own state dir: the real HOME is
  # not granted, and under the env allowlist below nothing else defines it.
  export HOME="$LLM_USER_PATH"
  TMPDIR="$TMPDIR/llm"
  mkdir -p "$LLM_USER_PATH" "$TMPDIR"
  export TMPDIR

  # Preset the default model to the llm-llama-server plugin's model name;
  # llm itself handles -m to pick another.
  printf 'llama-server\n' >"$LLM_USER_PATH/default_model.txt"

  local llm_bin pkg_store
  llm_bin="$(resolve_binary "${LLM:-}" llm LLM)"
  pkg_store="$(pkg_store_for "$llm_bin")"
  resolve_tty
  resolve_stdio

  cd "$LLM_USER_PATH"

  local -a sbx_env
  sandbox_env sbx_env HOME TMPDIR LLM_USER_PATH OPENAI_API_KEY
  exec "${sbx_env[@]}" "$SANDBOX_EXEC" \
    -D COMMON_SB="$PROFILES_DIR/common.sb" \
    -D CLIENT_SB="$PROFILES_DIR/client.sb" \
    -D PKG_STORE="$pkg_store" \
    -D HOME_DIR="$HOME_DIR" \
    -D HOME_PARENT="$HOME_PARENT" \
    -D STDOUT_PATH="$STDOUT_PATH" \
    -D STDERR_PATH="$STDERR_PATH" \
    -D LLM_USER_PATH="$LLM_USER_PATH" \
    -D TMPDIR="$TMPDIR" \
    -D TTY_DEV="$TTY_DEV" \
    -D NET_ADDR="localhost:$PORT" \
    -f "$PROFILES_DIR/llm.sb" \
    "$llm_bin" "$@"
}

# ── Main ──────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

cmd="$1"
shift
case "$cmd" in
llama-server) cmd_llama "$@" ;;
llama-bench) cmd_bench "$@" ;;
mlx-server) cmd_mlx "$@" ;;
pi) cmd_pi "$@" ;;
llm) cmd_llm "$@" ;;
-h | --help | help) usage ;;
*) die "unknown command: $cmd" ;;
esac
