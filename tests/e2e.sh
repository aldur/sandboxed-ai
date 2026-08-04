#!/usr/bin/env bash
# End-to-end tests: every sandbox.sh subcommand is started through its real
# seatbelt profile and exercised over the wire, plus negative probes
# asserting the sandbox denies what it must deny.
#
# Needs an Apple-silicon Mac (seatbelt + Metal) with the project toolchain
# on PATH (the devshell provides it: `nix develop --command tests/e2e.sh`).
# Small test models are downloaded from Hugging Face on first run and cached
# in the regular models directory; override with:
#   TEST_GGUF_MODEL (default bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M)
#   TEST_MLX_MODEL  (default mlx-community/SmolLM-135M-Instruct-4bit)
#
# Generation asserts on transport (HTTP 200, a completion comes back), not
# on model output: the 135M test models are too small to follow
# instructions reliably, and the sandboxes are what is under test.
set -uo pipefail

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
  { printf 'error: bash >= 4.4 required (found %s)\n' "$BASH_VERSION" >&2; exit 1; }

ROOT="$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)"
SANDBOX="$ROOT/sandbox.sh"
PORT=8080
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sandboxed-ai"

TEST_GGUF_MODEL="${TEST_GGUF_MODEL:-bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M}"
TEST_MLX_MODEL="${TEST_MLX_MODEL:-mlx-community/SmolLM-135M-Instruct-4bit}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sandboxed-ai-e2e.XXXXXX")"
# Sockets and the pi workspace live under the real home: seatbelt matches
# resolved paths and /tmp is a symlink into /private/tmp, which the
# profiles' verbatim path params would not match.
SCRATCH="$HOME/.sandboxed-ai-e2e.$$"
mkdir -p "$SCRATCH"

PASS=0 FAIL=0 SKIP=0
ok() { printf 'ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
  printf 'FAIL - %s\n' "$1"
  [[ -n "${2:-}" && -f "${2:-}" ]] && sed 's/^/       /' < <(tail -5 "$2")
  FAIL=$((FAIL + 1))
}
skip() { printf 'skip - %s (%s)\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

# ── Server lifecycle ──────────────────────────────────────
# sandbox.sh ends in exec, so $! is the server process itself. Only the
# tracked PID is ever killed — never pkill by name, the machine may run
# real servers.
SERVER_PID=""
start_server() { # $1 log-name, rest: sandbox.sh args
  local log="$WORK/$1.log"
  shift
  "$SANDBOX" "$@" >"$log" 2>&1 &
  SERVER_PID=$!
}
stop_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  kill -9 "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
cleanup() {
  stop_server
  rm -rf "$WORK" "$SCRATCH"
}
trap cleanup EXIT

# Poll $1 (a curl argv fragment, e.g. a URL or --unix-socket pair) until it
# answers HTTP 200 or the server dies. $2 is the timeout in seconds.
wait_http() {
  local timeout="${2:-120}" i code
  for ((i = 0; i < timeout; i += 2)); do
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 $1 2>/dev/null)" &&
      [[ "$code" == 200 ]] && return 0
    sleep 2
  done
  return 1
}

# POST a minimal chat completion via curl args $1, assert HTTP 200 and a
# choices payload. Writes the response to $2 for the failure report.
chat_ok() {
  local out="$2"
  curl -s --max-time 120 $1 \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}' \
    >"$out" 2>&1 || return 1
  grep -q '"choices"' "$out"
}

# ── Direct-profile probes ─────────────────────────────────
# The per-user darwin dirs and profile params, mirroring sandbox.sh.
DARWIN_TMP="$(realpath "$(getconf DARWIN_USER_TEMP_DIR)")"
DARWIN_CACHE="$(realpath "$(getconf DARWIN_USER_CACHE_DIR)")"
PKG_STORE="${TEST_PKG_STORE:-/nix}"

# Run /bin/sh -c "$1" under pi.sb (the one profile that permits a shell),
# with the workspace at $SCRATCH/ws. Grants mirror cmd_pi.
pi_sh() {
  mkdir -p "$SCRATCH/ws" "$STATE_DIR/pi" "$STATE_DIR/tmp"
  sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D CLIENT_SB="$ROOT/profiles/client.sb" \
    -D PKG_STORE="$PKG_STORE" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_USER_CACHE_DIR="$DARWIN_CACHE" \
    -D WORKSPACE="$SCRATCH/ws" \
    -D PI_DIR="$STATE_DIR/pi" \
    -D PI_LLAMA_DIR="$STATE_DIR/pi" \
    -D TMPDIR="$STATE_DIR/tmp" \
    -D TTY_DEV="${PROBE_TTY:-/dev/null}" \
    -D NET_ADDR="localhost:$PORT" \
    -f "$ROOT/profiles/pi.sb" /bin/sh -c "$1" 2>/dev/null
}

# ── Preflight ─────────────────────────────────────────────
[[ -x "$SANDBOX" ]] || { echo "error: $SANDBOX not executable" >&2; exit 1; }
if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null; then
  echo "error: port $PORT is already in use — stop that server first" >&2
  exit 1
fi

echo "# models: $TEST_GGUF_MODEL / $TEST_MLX_MODEL"
echo "# work:   $WORK"

# ── llama-server: TCP ─────────────────────────────────────
# Credential-shaped variables the caller's shell might hold: the sandboxed
# process must not inherit them (probed below via ps once it is up).
CANARY="sandboxed-ai-canary-$$"
export AWS_SECRET_ACCESS_KEY="$CANARY" GITHUB_TOKEN="$CANARY" HF_TOKEN="$CANARY"

start_server llama-tcp llama-server --model "$TEST_GGUF_MODEL"
if wait_http "http://127.0.0.1:$PORT/health" 180; then
  ok "llama-server (tcp) becomes healthy"
  if chat_ok "http://127.0.0.1:$PORT/v1/chat/completions" "$WORK/llama-tcp-chat.json"; then
    ok "llama-server (tcp) serves a completion"
  else
    fail "llama-server (tcp) serves a completion" "$WORK/llama-tcp-chat.json"
  fi
else
  fail "llama-server (tcp) becomes healthy" "$WORK/llama-tcp.log"
fi

# ── Environment allowlist ─────────────────────────────────
# sandbox.sh re-execs through `env -i` with a fixed allowlist, so the
# caller's credentials never reach the process the sandbox assumes may go
# rogue. `ps -Eww` prints another process's environment (same user).
if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
  ps -Eww -p "$SERVER_PID" >"$WORK/server-env.txt" 2>&1
  if grep -q 'TMPDIR=' "$WORK/server-env.txt"; then
    if grep -q "$CANARY" "$WORK/server-env.txt"; then
      fail "env: caller credentials do not reach the sandbox" "$WORK/server-env.txt"
    else
      ok "env: caller credentials do not reach the sandbox"
    fi
  else
    # No TMPDIR means ps showed no environment at all — the absence of the
    # canary would prove nothing.
    skip "env: caller credentials do not reach the sandbox" "ps -E shows no environment"
  fi
else
  skip "env: caller credentials do not reach the sandbox" "server not running"
fi

# ── llm client against the running server ─────────────────
if command -v llm >/dev/null; then
  if "$SANDBOX" llm 'Say OK' >"$WORK/llm.out" 2>&1 && [[ -s "$WORK/llm.out" ]]; then
    ok "llm answers through its sandbox"
  else
    fail "llm answers through its sandbox" "$WORK/llm.out"
  fi
else
  skip "llm answers through its sandbox" "llm not on PATH"
fi

# ── pi against the running server ─────────────────────────
# PI_LLAMA_DIR comes from the caller or from the flake (the devshell does
# not export it; the nix-built wrapper bakes it in).
if [[ -z "${PI_LLAMA_DIR:-}" ]] && command -v nix >/dev/null; then
  PI_LLAMA_DIR="$(nix build --no-link --print-out-paths "$ROOT#pi-llama" 2>/dev/null)" || PI_LLAMA_DIR=""
  export PI_LLAMA_DIR
fi
if [[ -n "${PI_LLAMA_DIR:-}" ]] && command -v pi >/dev/null; then
  mkdir -p "$SCRATCH/ws"
  if "$SANDBOX" pi -w "$SCRATCH/ws" -p 'Say OK' >"$WORK/pi.out" 2>&1 &&
    [[ -s "$WORK/pi.out" ]]; then
    ok "pi answers through its sandbox"
  else
    fail "pi answers through its sandbox" "$WORK/pi.out"
  fi
else
  skip "pi answers through its sandbox" "pi or PI_LLAMA_DIR unavailable"
fi

# ── Sandbox denial probes (pi.sb, server still up) ────────
if pi_sh "echo canary > '$SCRATCH/ws/probe' && cat '$SCRATCH/ws/probe'" >/dev/null; then
  ok "probe: workspace is writable"
else
  fail "probe: workspace is writable"
fi

if pi_sh "cat '$DARWIN_TMP'/../0/* 2>/dev/null || ls '${DARWIN_TMP%/T}/0'"; then
  fail "probe: sibling /private/var/folders dirs are denied"
else
  ok "probe: sibling /private/var/folders dirs are denied"
fi

echo canary >"$SCRATCH/canary"
if pi_sh "cat '$SCRATCH/canary'"; then
  fail "probe: files outside the workspace are denied"
else
  ok "probe: files outside the workspace are denied"
fi

if pi_sh "exec 3<>/dev/tcp/1.1.1.1/80"; then
  fail "probe: outbound network beyond the server is denied"
else
  ok "probe: outbound network beyond the server is denied"
fi

if pi_sh "exec 3<>/dev/tcp/127.0.0.1/$PORT"; then
  ok "probe: outbound to the llama-server port is allowed"
else
  fail "probe: outbound to the llama-server port is allowed"
fi

# The TTY grant names one controlling terminal, so every *other* terminal
# on the machine must be out of reach: otherwise a compromised client could
# read input from — and write escape sequences into — the sessions you have
# open elsewhere. Probes a terminal that is not the one granted above.
OTHER_TTY=""
for t in /dev/ttys00[0-9]; do
  [[ -e "$t" && "$t" != "${PROBE_TTY:-}" ]] && { OTHER_TTY="$t"; break; }
done
if [[ -n "$OTHER_TTY" ]]; then
  if pi_sh ": < '$OTHER_TTY'"; then
    fail "probe: other terminals are denied ($OTHER_TTY readable)"
  else
    ok "probe: other terminals are denied"
  fi
  if pi_sh ": > '$OTHER_TTY'"; then
    fail "probe: other terminals are not writable ($OTHER_TTY writable)"
  else
    ok "probe: other terminals are not writable"
  fi
else
  skip "probe: other terminals are denied" "no /dev/ttys00* present"
fi

stop_server

# ── llama-server: UNIX socket ─────────────────────────────
SOCK="$SCRATCH/llama.sock"
start_server llama-sock llama-server --model "$TEST_GGUF_MODEL" --socket "$SOCK"
if wait_http "--unix-socket $SOCK http://localhost/health" 180; then
  ok "llama-server (unix socket) becomes healthy"
  if chat_ok "--unix-socket $SOCK http://localhost/v1/chat/completions" "$WORK/llama-sock-chat.json"; then
    ok "llama-server (unix socket) serves a completion"
  else
    fail "llama-server (unix socket) serves a completion" "$WORK/llama-sock-chat.json"
  fi
else
  fail "llama-server (unix socket) becomes healthy" "$WORK/llama-sock.log"
fi
stop_server

# ── mlx-server: TCP ───────────────────────────────────────
if command -v mlx_lm.server >/dev/null; then
  start_server mlx-tcp mlx-server --model "$TEST_MLX_MODEL"
  if wait_http "http://127.0.0.1:$PORT/v1/models" 180; then
    ok "mlx-server (tcp) becomes healthy"
    if chat_ok "http://127.0.0.1:$PORT/v1/chat/completions" "$WORK/mlx-tcp-chat.json"; then
      ok "mlx-server (tcp) serves a completion"
    else
      fail "mlx-server (tcp) serves a completion" "$WORK/mlx-tcp-chat.json"
    fi
  else
    fail "mlx-server (tcp) becomes healthy" "$WORK/mlx-tcp.log"
  fi
  stop_server
else
  skip "mlx-server (tcp)" "mlx_lm.server not on PATH"
fi

# ── mlx-server: UNIX socket (needs the patched mlx-lm) ────
mlx_patched() {
  local bin site
  bin="$(command -v mlx_lm.server)" || return 1
  site="$(cd -P -- "$(dirname -- "$bin")/.." && pwd)"
  grep -rq 'endswith(".sock")' "$site"/lib/python*/site-packages/mlx_lm/server.py 2>/dev/null
}
if command -v mlx_lm.server >/dev/null && mlx_patched; then
  SOCK="$SCRATCH/mlx.sock"
  start_server mlx-sock mlx-server --model "$TEST_MLX_MODEL" --socket "$SOCK"
  if wait_http "--unix-socket $SOCK http://localhost/v1/models" 180; then
    ok "mlx-server (unix socket) becomes healthy"
    if chat_ok "--unix-socket $SOCK http://localhost/v1/chat/completions" "$WORK/mlx-sock-chat.json"; then
      ok "mlx-server (unix socket) serves a completion"
    else
      fail "mlx-server (unix socket) serves a completion" "$WORK/mlx-sock-chat.json"
    fi
  else
    fail "mlx-server (unix socket) becomes healthy" "$WORK/mlx-sock.log"
  fi
  stop_server
else
  skip "mlx-server (unix socket)" "mlx-lm build lacks the unix-socket patch — reload the devshell"
fi

# ── mlx exec grant names the entry point's chain only ─────
# The profile used to allow exec across the whole package store. It now
# names the entry point, its shebang interpreter and any wrapper
# indirection, so an unrelated binary from the same store must be refused.
MLX_BIN="$(command -v mlx_lm.server || true)"
# A real file, not a shell builtin, and unrelated to the mlx chain.
OTHER_BIN="$(realpath "$(command -v ls)" 2>/dev/null || true)"
if [[ -n "$MLX_BIN" && "$OTHER_BIN" == "$PKG_STORE"/* ]]; then
  mlx_wrapped="${MLX_BIN%/*}/.${MLX_BIN##*/}-wrapped"
  [[ -x "$mlx_wrapped" ]] || mlx_wrapped=/dev/null
  mkdir -p "$STATE_DIR/cache" "$STATE_DIR/tmp"
  if (cd "$STATE_DIR/cache" && sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D SERVER_SB="$ROOT/profiles/server.sb" \
    -D NET_SB="$ROOT/profiles/net-tcp.sb" \
    -D NET_TARGET="*:$PORT" \
    -D PKG_STORE="$PKG_STORE" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_USER_CACHE_DIR="$DARWIN_CACHE" \
    -D CA_FILE=/dev/null \
    -D MLX_SERVER="$MLX_BIN" \
    -D MLX_INTERP=/dev/null \
    -D MLX_WRAPPED="$mlx_wrapped" \
    -D MLX_WRAPPED_INTERP=/dev/null \
    -D MODEL_DIR="$STATE_DIR/models" \
    -D CACHE_DIR="$STATE_DIR/cache" \
    -D TMPDIR="$STATE_DIR/tmp" \
    -f "$ROOT/profiles/mlx-server.sb" \
    "$OTHER_BIN" >/dev/null 2>&1); then
    fail "probe: mlx sandbox refuses unrelated store binaries ($OTHER_BIN ran)"
  else
    ok "probe: mlx sandbox refuses unrelated store binaries"
  fi
else
  skip "probe: mlx sandbox refuses unrelated store binaries" "mlx_lm.server or a $PKG_STORE binary unavailable"
fi

# ── Regression: getfqdn must not SIGKILL the mlx sandbox ──
# Python's http.server resolves the bind address at startup; the reverse
# lookup once escalated into mDNSResponder and tripped the fatal
# network-outbound deny (fixed by the hosts-file grant + plain deny).
# Resolved: the profile grants exec on a literal path and seatbelt matches
# the real one (python3 is a symlink to python3.13 in nixpkgs).
PY="$(realpath "$(command -v python3)" 2>/dev/null || true)"
if [[ "$PY" == "$PKG_STORE"/* ]]; then
  mkdir -p "$STATE_DIR/cache" "$STATE_DIR/tmp"
  if (cd "$STATE_DIR/cache" && sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D SERVER_SB="$ROOT/profiles/server.sb" \
    -D NET_SB="$ROOT/profiles/net-tcp.sb" \
    -D NET_TARGET="*:$PORT" \
    -D PKG_STORE="$PKG_STORE" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_USER_CACHE_DIR="$DARWIN_CACHE" \
    -D CA_FILE=/dev/null \
    -D MLX_SERVER="$PY" \
    -D MLX_INTERP=/dev/null \
    -D MLX_WRAPPED=/dev/null \
    -D MLX_WRAPPED_INTERP=/dev/null \
    -D MODEL_DIR="$STATE_DIR/models" \
    -D CACHE_DIR="$STATE_DIR/cache" \
    -D TMPDIR="$STATE_DIR/tmp" \
    -f "$ROOT/profiles/mlx-server.sb" \
    "$PY" -I -c 'import socket; socket.getfqdn("127.0.0.1")' 2>/dev/null); then
    ok "probe: getfqdn survives under mlx-server.sb"
  else
    fail "probe: getfqdn survives under mlx-server.sb"
  fi
else
  skip "probe: getfqdn survives under mlx-server.sb" "no python3 in $PKG_STORE"
fi

# ── Summary ───────────────────────────────────────────────
echo
printf '# pass %d, fail %d, skip %d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
