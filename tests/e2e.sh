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

# ── Toolchain ─────────────────────────────────────────────
# Resolved from the flake, not from PATH: an ambient devshell can be stale
# (a cached one shipped an mlx-lm without the unix-socket patch, which
# silently turned that test into a skip), and the point of the suite is to
# test what this repo builds. sandbox.sh takes each as an env override.
# An explicit override still wins, and without nix we fall back to PATH.
flake_bin() { # $1 flake attr, $2 binary name, $3 override var name
  local attr="$1" name="$2" var="$3" out
  if [[ -n "${!var:-}" ]]; then
    printf '%s' "${!var}"
    return
  fi
  if command -v nix >/dev/null &&
    out="$(nix build --no-link --print-out-paths "$ROOT#$attr" 2>/dev/null)" &&
    [[ -x "$out/bin/$name" ]]; then
    printf '%s' "$out/bin/$name"
    return
  fi
  command -v "$name" 2>/dev/null || true
}

echo "# resolving the toolchain from the flake (this builds on first run)…"
LLAMA_SERVER="$(flake_bin llama-cpp llama-server LLAMA_SERVER)"
MLX_SERVER="$(flake_bin mlx-lm mlx_lm.server MLX_SERVER)"
MLX_VLM_SERVER="$(flake_bin mlx-vlm mlx_vlm.server MLX_VLM_SERVER)"
LLM="$(flake_bin llm llm LLM)"
PI="$(flake_bin pi pi PI)"
export LLAMA_SERVER MLX_SERVER MLX_VLM_SERVER LLM PI
if [[ -z "${PI_LLAMA_DIR:-}" ]] && command -v nix >/dev/null; then
  PI_LLAMA_DIR="$(nix build --no-link --print-out-paths "$ROOT#pi-llama" 2>/dev/null)" || PI_LLAMA_DIR=""
  export PI_LLAMA_DIR
fi

# ── Direct-profile probes ─────────────────────────────────
# The per-user darwin dirs and profile params, mirroring sandbox.sh.
DARWIN_TMP="$(realpath "$(getconf DARWIN_USER_TEMP_DIR)")"
DARWIN_CACHE="$(realpath "$(getconf DARWIN_USER_CACHE_DIR)")"
PKG_STORE="${TEST_PKG_STORE:-/nix}"
# Resolved: the profiles grant exec on literal paths and seatbelt matches
# the real one (python3 is a symlink to python3.13 in nixpkgs). Empty when
# the interpreter is not in the package store the profiles grant.
PY="$(realpath "$(command -v python3)" 2>/dev/null || true)"
[[ "$PY" == "$PKG_STORE"/* ]] || PY=""

# Run /bin/sh -c "$1" under pi.sb (the one profile that permits a shell),
# with the workspace at $SCRATCH/ws. Grants mirror cmd_pi.
pi_sh() {
  mkdir -p "$SCRATCH/ws" "$STATE_DIR/pi" "$STATE_DIR/tmp/pi"
  sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D CLIENT_SB="$ROOT/profiles/client.sb" \
    -D PKG_STORE="$PKG_STORE" \
    -D HOME_DIR="$HOME" \
    -D HOME_PARENT="$(dirname "$HOME")" \
    -D WORKSPACE="$SCRATCH/ws" \
    -D PI_DIR="$STATE_DIR/pi" \
    -D PI_LLAMA_DIR="$STATE_DIR/pi" \
    -D TMPDIR="$STATE_DIR/tmp/pi" \
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

# ── Working directory ─────────────────────────────────────
# getcwd() is subject to the sandbox, so the process must sit in a
# directory its profile grants — anywhere else and Python dies at import.
# It is also what tmux shows as the pane's path, so it should be the tool's
# own state, never somewhere surprising.
if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
  srv_cwd="$(lsof -a -d cwd -p "$SERVER_PID" -Fn 2>/dev/null | grep '^n' | cut -c2- | head -1)"
  if [[ "$srv_cwd" == "$STATE_DIR"/* ]]; then
    ok "the server runs in a directory its profile grants"
  else
    fail "the server runs in a directory its profile grants (got ${srv_cwd:-unknown})"
  fi
else
  skip "the server runs in a directory its profile grants" "server not running"
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

# ── Vision: a real image through both engines ─────────────
# Loading a projector proves nothing about decoding an image, so send one.
# The 256M models are weak, but "is there an answer, and did the server
# actually decode an image" is what the sandbox is on the hook for.
make_image() { # $1 output path
  "$PY" - "$1" <<'PYEOF'
import zlib, struct, base64, sys
W = H = 64
rows = b""
for y in range(H):
    rows += b"\x00" + b"".join(
        b"\xd0\x20\x20" if 16 <= x < 48 and 16 <= y < 48 else b"\xff\xff\xff"
        for x in range(W))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
open(sys.argv[1], "w").write(base64.b64encode(png).decode())
PYEOF
}

image_chat() { # $1 b64 file, $2 out file, $3 optional model id
  "$PY" - "$1" "$2" "${3:-}" <<'PYEOF'
import json, sys, urllib.request
b64, out, model = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
body = {"messages": [{"role": "user", "content": [
    {"type": "text", "text": "What color is the square?"},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}],
    "max_tokens": 20}
if model:
    body["model"] = model
req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
      data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=300))
    text = r["choices"][0]["message"]["content"]
    open(out, "w").write(text)
    sys.exit(0 if text.strip() else 1)
except Exception as e:
    open(out, "w").write("%s: %s" % (type(e).__name__, e))
    sys.exit(1)
PYEOF
}

if [[ -n "$PY" ]] && [[ -n "${TEST_VISION_MODEL:-}" || 1 ]]; then
  VISION_MODEL="${TEST_VISION_MODEL:-ggml-org/SmolVLM-256M-Instruct-GGUF:Q8_0}"
  make_image "$WORK/img.b64"
  stop_server
  # -lv 6 so the log records "image decoded": a text-only answer would
  # otherwise pass this test without the image ever being looked at.
  start_server llama-vision llama-server --model "$VISION_MODEL" --mmproj "$VISION_MODEL" -lv 6
  if wait_http "http://127.0.0.1:$PORT/health" 240; then
    if image_chat "$WORK/img.b64" "$WORK/vision-answer.txt" &&
      grep -q 'image decoded' "$WORK/llama-vision.log"; then
      ok "llama-server answers about an image ($(tr -d '\n' <"$WORK/vision-answer.txt" | cut -c1-40))"
    else
      fail "llama-server answers about an image" "$WORK/vision-answer.txt"
    fi
  else
    fail "llama-server answers about an image" "$WORK/llama-vision.log"
  fi
  stop_server
fi

# mlx-vlm, which is a different decoder path (Pillow rather than mtmd) and
# needs the patched build the flake produces.
MLX_VLM="$MLX_VLM_SERVER"
if [[ -n "$PY" && -n "$MLX_VLM" ]]; then
  MLX_VISION_MODEL="${TEST_MLX_VISION_MODEL:-mlx-community/SmolVLM-256M-Instruct-4bit}"
  start_server mlx-vision mlx-server --model "$MLX_VISION_MODEL"
  if wait_http "http://127.0.0.1:$PORT/v1/models" 300; then
    if image_chat "$WORK/img.b64" "$WORK/mlx-vision-answer.txt" "$MLX_VISION_MODEL"; then
      ok "mlx_vlm.server answers about an image ($(tr -d '\n' <"$WORK/mlx-vision-answer.txt" | cut -c1-40))"
    else
      fail "mlx_vlm.server answers about an image" "$WORK/mlx-vision-answer.txt"
    fi
  else
    fail "mlx_vlm.server answers about an image" "$WORK/mlx-vision.log"
  fi
  stop_server
else
  skip "mlx_vlm.server answers about an image" "mlx_vlm.server not available"
fi

# Restore the text server the later client tests talk to.
start_server llama-tcp llama-server --model "$TEST_GGUF_MODEL"
wait_http "http://127.0.0.1:$PORT/health" 180 || true

# ── Cold Metal cache (shader compilation) ─────────────────
# With a warm cache llama.cpp loads a precompiled Metal library and never
# reaches MTLCompilerService, so a missing XPC grant stays invisible until
# someone's first run on a fresh machine — which is what CI is. Opt in
# locally with SANDBOXED_AI_TEST_COLD_METAL=1: it clears the *user's*
# Metal cache, which other apps then recompile.
if [[ "${SANDBOXED_AI_TEST_COLD_METAL:-}" == 1 ]]; then
  stop_server
  rm -rf "$DARWIN_CACHE/com.apple.metal" "$DARWIN_CACHE/com.apple.metalfe" \
    "$STATE_DIR/cache/llama-server"
  start_server llama-cold llama-server --model "$TEST_GGUF_MODEL" -lv 6
  if wait_http "http://127.0.0.1:$PORT/health" 180 &&
    grep -q 'assigned to device MTL0' "$WORK/llama-cold.log"; then
    ok "llama-server compiles shaders from a cold Metal cache (on the GPU)"
  else
    fail "llama-server compiles shaders from a cold Metal cache (on the GPU)" "$WORK/llama-cold.log"
  fi
  stop_server
  start_server llama-tcp llama-server --model "$TEST_GGUF_MODEL"
  wait_http "http://127.0.0.1:$PORT/health" 180 || true
else
  skip "llama-server compiles shaders from a cold Metal cache" "set SANDBOXED_AI_TEST_COLD_METAL=1 (clears the user's Metal cache)"
fi

# ── llm client against the running server ─────────────────
if [[ -n "$LLM" ]]; then
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
if [[ -n "${PI_LLAMA_DIR:-}" && -n "$PI" ]]; then
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

# ── pi's interactive TUI (raw mode, on a real pty) ────────
# `pi -p` never enters raw mode, so it would not notice a missing terminal
# or input grant. Drive the full TUI on a pty instead and assert it renders
# and accepts a keystroke.
if [[ -n "$PY" && -n "${PI_LLAMA_DIR:-}" && -n "$PI" ]]; then
  mkdir -p "$SCRATCH/tui"
  if "$PY" - "$SANDBOX" "$SCRATCH/tui" >"$WORK/tui.log" 2>&1 <<'PYEOF'; then
import os, pty, select, sys, time, re
sandbox, ws = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(sandbox, [sandbox, "pi", "-w", ws])
out, deadline, sent = b"", time.time() + 30, False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try: chunk = os.read(fd, 65536)
        except OSError: break
        if not chunk: break
        out += chunk
    if not sent and len(out) > 200:
        time.sleep(2); os.write(fd, b"hello\r")
        time.sleep(3); os.write(fd, b"\x03\x03"); sent = True
try: os.kill(pid, 9)
except ProcessLookupError: pass
os.waitpid(pid, 0)
text = out.decode(errors="replace")
ansi = len(re.findall(r"\x1b\[[0-9;?]*[a-zA-Z]", text))
rawmode = bool(re.search(r"\x1b\[\?(1049|1006|25)", text))
denied = [l for l in text.splitlines() if "not permitted" in l or "EPERM" in l]
print("ansi=%d rawmode=%s denied=%s" % (ansi, rawmode, denied[:2]))
sys.exit(0 if ansi > 50 and rawmode and not denied else 1)
PYEOF
    ok "pi renders its TUI and takes input on a pty"
  else
    fail "pi renders its TUI and takes input on a pty" "$WORK/tui.log"
  fi
else
  skip "pi renders its TUI and takes input on a pty" "pi, PI_LLAMA_DIR or python3 unavailable"
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

# Raw mode is tcsetattr on the granted terminal, not a window-system
# capability: an agent that could reach WindowServer would be able to
# enumerate every on-screen window, with owner names and geometry.
if [[ -n "$PY" ]]; then
  cat >"$SCRATCH/ws/win.py" <<'PYEOF'
import ctypes
cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
r = cg.CGWindowListCopyWindowInfo(1 | 16, 0)
raise SystemExit(1 if r and cf.CFArrayGetCount(r) > 0 else 0)
PYEOF
  if pi_sh "'$PY' -I '$SCRATCH/ws/win.py'"; then
    ok "probe: the agent cannot enumerate on-screen windows"
  else
    fail "probe: the agent cannot enumerate on-screen windows"
  fi
else
  skip "probe: the agent cannot enumerate on-screen windows" "no python3 in $PKG_STORE"
fi

# The agent must not share writable state with the sandboxes that hold the
# GPU and the weights: not Apple's per-user Metal shader/PSO cache (which a
# server maps executable on its next start), and not another sandbox's
# scratch directory.
if pi_sh "ls '$DARWIN_CACHE/com.apple.metal' || : > '$DARWIN_CACHE/com.apple.metal/probe'"; then
  fail "probe: the agent cannot reach the Metal shader cache"
else
  ok "probe: the agent cannot reach the Metal shader cache"
fi

mkdir -p "$STATE_DIR/tmp/llama-server"
if pi_sh ": > '$STATE_DIR/tmp/llama-server/probe'"; then
  rm -f "$STATE_DIR/tmp/llama-server/probe"
  fail "probe: the agent cannot write another sandbox's scratch dir"
else
  ok "probe: the agent cannot write another sandbox's scratch dir"
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
  # The servers authenticate nobody, and on macOS connecting to a UNIX
  # socket needs write permission on it, so any group/other bit is an open
  # door. sandbox.sh sets umask 077 for socket mode; mlx-vlm additionally
  # binds its own socket because uvicorn would chmod a uds= path to 0666.
  # ls -l is the portable spelling: BSD and GNU stat disagree on -f/-c.
  sock_mode="$(ls -ld "$SOCK" | awk '{print $1}')"
  if [[ "$sock_mode" == ?rwx------ || "$sock_mode" == ?rw------- ]]; then
    ok "llama-server (unix socket) is owner-only ($sock_mode)"
  else
    fail "llama-server (unix socket) is owner-only (got $sock_mode)"
  fi
else
  fail "llama-server (unix socket) becomes healthy" "$WORK/llama-sock.log"
fi
stop_server

# ── mlx-server: TCP ───────────────────────────────────────
if [[ -n "$MLX_SERVER" ]]; then
  start_server mlx-tcp mlx-server --model "$TEST_MLX_MODEL"
  if wait_http "http://127.0.0.1:$PORT/v1/models" 180; then
    ok "mlx-server (tcp) becomes healthy"
    # /v1/models drives client auto-discovery, and the sandbox grants
    # MODEL_DIR for the served model only. Anything else listed here — an
    # entry left in the HF cache by an earlier run, say — is a model the
    # server will be denied when a client asks for it.
    listed="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/models" |
      "$PY" -c 'import sys,json; print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null)"
    if [[ "$listed" == "$TEST_MLX_MODEL" ]]; then
      ok "mlx-server advertises only the model it is serving"
    else
      fail "mlx-server advertises only the model it is serving (listed: ${listed:-none})"
    fi
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
# The unix-socket support is a patch this flake applies; if the resolved
# build lacks it, say so loudly rather than skipping quietly.
mlx_patched() {
  local site
  [[ -n "$MLX_SERVER" ]] || return 1
  site="$(cd -P -- "$(dirname -- "$MLX_SERVER")/.." && pwd)"
  grep -rq 'endswith(".sock")' "$site"/lib/python*/site-packages/mlx_lm/server.py 2>/dev/null
}
if [[ -n "$MLX_SERVER" ]] && mlx_patched; then
  SOCK="$SCRATCH/mlx.sock"
  start_server mlx-sock mlx-server --model "$TEST_MLX_MODEL" --socket "$SOCK"
  if wait_http "--unix-socket $SOCK http://localhost/v1/models" 180; then
    ok "mlx-server (unix socket) becomes healthy"
    if chat_ok "--unix-socket $SOCK http://localhost/v1/chat/completions" "$WORK/mlx-sock-chat.json"; then
      ok "mlx-server (unix socket) serves a completion"
    else
      fail "mlx-server (unix socket) serves a completion" "$WORK/mlx-sock-chat.json"
    fi
    # ls -l is the portable spelling: BSD and GNU stat disagree on -f/-c.
  sock_mode="$(ls -ld "$SOCK" | awk '{print $1}')"
    if [[ "$sock_mode" == ?rwx------ || "$sock_mode" == ?rw------- ]]; then
      ok "mlx-server (unix socket) is owner-only ($sock_mode)"
    else
      fail "mlx-server (unix socket) is owner-only (got $sock_mode)"
    fi
  else
    fail "mlx-server (unix socket) becomes healthy" "$WORK/mlx-sock.log"
  fi
  stop_server
else
  fail "mlx-server (unix socket): the resolved mlx-lm lacks the flake's unix-socket patch ($MLX_SERVER)"
fi

# ── `set -e` does not swallow the run ─────────────────────
# A helper whose last statement is a short-circuiting test returns 1, and a
# bare call under `set -euo pipefail` then kills the script with no
# message. Two shapes are at risk:
#   sandbox_env — the last allowlisted variable unset (NIX_SSL_CERT_FILE is
#     unset on a Homebrew install), which would abort after the banner
#   split_lines — an empty listing, which would swallow "cannot resolve
#     quant"
if [[ -n "$MLX_SERVER" ]]; then
  if env -u NIX_SSL_CERT_FILE "$SANDBOX" mlx-server --model "$TEST_MLX_MODEL" --help \
    >"$WORK/unset-env.log" 2>&1; then
    ok "startup: an unset allowlisted variable does not abort the run"
  else
    fail "startup: an unset allowlisted variable does not abort the run" "$WORK/unset-env.log"
  fi
else
  skip "startup: an unset allowlisted variable does not abort the run" "mlx_lm.server not on PATH"
fi

# The binary that enforces the sandbox must not come from PATH: a writable
# entry ahead of /usr/bin would otherwise run the tool unsandboxed, under a
# banner claiming otherwise. Plant a stub and check it is never reached.
mkdir -p "$SCRATCH/fakebin"
printf '#!/bin/sh\ntouch "%s/stub-ran"\n' "$SCRATCH" >"$SCRATCH/fakebin/sandbox-exec"
chmod +x "$SCRATCH/fakebin/sandbox-exec"
rm -f "$SCRATCH/stub-ran"
if [[ -n "$LLM" ]]; then
  PATH="$SCRATCH/fakebin:$PATH" "$SANDBOX" llm --version >"$WORK/hijack.log" 2>&1
  if [[ -e "$SCRATCH/stub-ran" ]]; then
    fail "startup: sandbox-exec is not taken from PATH" "$WORK/hijack.log"
  else
    ok "startup: sandbox-exec is not taken from PATH"
  fi
else
  skip "startup: sandbox-exec is not taken from PATH" "llm not on PATH"
fi

# The workspace is the one caller-supplied path the agent gets read+write
# over, so it is canonicalized and refused when it would contain the state
# it is served from — `cd ~ && … pi` would otherwise hand the agent the
# model cache, the digest sidecars and the completion markers.
ws_reject() { # $1 label, rest: sandbox.sh pi args
  local label="$1"
  shift
  if "$SANDBOX" pi "$@" -p hi >"$WORK/ws.log" 2>&1; then
    fail "workspace: $label is refused" "$WORK/ws.log"
  elif grep -q '^error: refusing to run\|^error: workspace overlaps' "$WORK/ws.log"; then
    ok "workspace: $label is refused"
  else
    fail "workspace: $label is refused (wrong error)" "$WORK/ws.log"
  fi
}
ws_reject "/" -w /
ws_reject "\$HOME" -w "$HOME"
ws_reject "the state dir" -w "$STATE_DIR"
ws_reject "an ancestor of the state dir" -w "$(dirname "$STATE_DIR")"

# ...and a real directory reached through a symlink still resolves, rather
# than granting a path seatbelt will never match.
mkdir -p "$SCRATCH/realws"
ln -sfn "$SCRATCH/realws" "$SCRATCH/linkws"
# Asserted on the startup banner, not the exit status: no server is running
# at this point, so pi itself exits non-zero either way.
"$SANDBOX" pi -w "$SCRATCH/linkws" -p hi >"$WORK/ws-link.log" 2>&1
if grep -q "workspace: *$SCRATCH/realws" "$WORK/ws-link.log"; then
  ok "workspace: a symlinked workspace is canonicalized"
else
  fail "workspace: a symlinked workspace is canonicalized" "$WORK/ws-link.log"
fi

# Model specs become local paths under the models dir, so a spec that walks
# out of it must be refused before anything is created — the HF URL
# normalizes ".." away at the host root, so the fetch itself would succeed.
spec_reject() { # $1 subcommand, $2 spec
  if "$SANDBOX" "$1" --model "$2" >"$WORK/spec.log" 2>&1; then
    fail "spec: '$2' is refused" "$WORK/spec.log"
  elif grep -q 'not a Hugging Face repo id\|invalid file selection' "$WORK/spec.log"; then
    ok "spec: '$2' is refused"
  else
    fail "spec: '$2' is refused (wrong error)" "$WORK/spec.log"
  fi
}
spec_reject llama-server '../../org/repo:file.gguf'
spec_reject llama-server 'org/repo:../../evil.gguf'
spec_reject mlx-server '../../org/repo'

# --socket runs unsandboxed with full privileges on a caller-typed path, so
# it must never unlink anything but a stale socket of ours.
printf 'important\n' >"$SCRATCH/notasocket.sock"
if "$SANDBOX" llama-server --model "$TEST_GGUF_MODEL" --socket "$SCRATCH/notasocket.sock" \
  >"$WORK/sock-file.log" 2>&1; then
  fail "socket: an existing non-socket file is refused" "$WORK/sock-file.log"
elif grep -q 'exists and is not a socket' "$WORK/sock-file.log" &&
  [[ "$(cat "$SCRATCH/notasocket.sock")" == important ]]; then
  ok "socket: an existing non-socket file is refused (and left intact)"
else
  fail "socket: an existing non-socket file is refused" "$WORK/sock-file.log"
fi

# A repo with no GGUF listing must reach its error message, not exit blank.
"$SANDBOX" llama-server --model no-such-org/no-such-repo-xyz:Q4_K_M >"$WORK/no-listing.log" 2>&1
if grep -q 'cannot resolve quant' "$WORK/no-listing.log"; then
  ok "startup: an unresolvable model reports why"
else
  fail "startup: an unresolvable model reports why" "$WORK/no-listing.log"
fi

# ── system.sb's wholesale grants stay re-armed ────────────
# system.sb (imported by common.sb) ends with a bare (allow sysctl-read)
# and an unfiltered process-info grant; common.sb denies both. Without
# those denies a sandboxed tool reads other processes' argv, which is
# where credentials live.
cat >"$SCRATCH/ws/leak.py" <<'PYEOF'
import ctypes, ctypes.util, sys
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
bad = []
# Values outside the allowlist must be refused.
for name in ("kern.uuid", "net.inet.ip.forwarding", "kern.boottime"):
    buf = ctypes.create_string_buffer(1024); n = ctypes.c_size_t(1024)
    if libc.sysctlbyname(name.encode(), buf, ctypes.byref(n), None, 0) == 0:
        bad.append("sysctl:" + name)
# Another process's argv (KERN_PROCARGS2 = 49) and executable path.
for pid in range(1, 400):
    mib = (ctypes.c_int * 3)(1, 49, pid)
    buf = ctypes.create_string_buffer(8192); n = ctypes.c_size_t(8192)
    if libc.sysctl(mib, 3, buf, ctypes.byref(n), None, 0) == 0 and n.value > 4:
        bad.append("argv:%d" % pid); break
path = ctypes.create_string_buffer(4096)
for pid in range(1, 400):
    if libc.proc_pidpath(pid, path, 4096) > 0:
        bad.append("pidpath:%d" % pid); break
print(" ".join(bad))
sys.exit(1 if bad else 0)
PYEOF
if [[ -n "$PY" ]]; then
  leak_out="$(pi_sh "'$PY' -I '$SCRATCH/ws/leak.py'")"
  leak_rc=$?
  if [[ $leak_rc -eq 0 ]]; then
    ok "probe: system.sb's blanket sysctl/process-info grants are re-armed"
  else
    fail "probe: system.sb's blanket sysctl/process-info grants are re-armed (leaked: ${leak_out:-python failed})"
  fi
else
  skip "probe: system.sb's blanket sysctl/process-info grants are re-armed" "no python3 in $PKG_STORE"
fi

# ── Download integrity ────────────────────────────────────
# Downloads are verified against the digests HF publishes (SHA-256 for LFS
# weights, git blob SHA-1 for the small files). Tamper with a cached file
# — config.json, whose contents decide which server binary gets exec'd —
# and re-resolving must notice and replace it. Cheap: 803 bytes.
MLX_CFG="$STATE_DIR/models/$TEST_MLX_MODEL/config.json"
if [[ -f "$MLX_CFG" && -n "$MLX_SERVER" ]]; then
  cfg_before="$(shasum -a 256 "$MLX_CFG" | cut -d' ' -f1)"
  printf '{"tampered":true}' >"$MLX_CFG"
  # Drop the completion marker and the sidecar, i.e. force a real re-check.
  rm -f "${MLX_CFG%/*}/.download-complete" "${MLX_CFG%/*}/.config.json.digest"
  "$SANDBOX" mlx-server --model "$TEST_MLX_MODEL" --help >"$WORK/integrity.log" 2>&1 || true
  cfg_after="$(shasum -a 256 "$MLX_CFG" | cut -d' ' -f1)"
  if [[ "$cfg_before" == "$cfg_after" ]]; then
    ok "integrity: a tampered cached file is detected and replaced"
  else
    fail "integrity: a tampered cached file is detected and replaced" "$WORK/integrity.log"
  fi
else
  skip "integrity: a tampered cached file is detected and replaced" "no cached MLX config.json"
fi

# ── mlx exec grant names the entry point's chain only ─────
# The profile names the entry point, its shebang interpreter and any
# wrapper indirection, so an unrelated binary from the same store must be
# refused.
MLX_BIN="$MLX_SERVER"
# A real file, not a shell builtin, and unrelated to the mlx chain.
OTHER_BIN="$(realpath "$(command -v ls)" 2>/dev/null || true)"
if [[ -n "$MLX_BIN" && "$OTHER_BIN" == "$PKG_STORE"/* ]]; then
  mlx_wrapped="${MLX_BIN%/*}/.${MLX_BIN##*/}-wrapped"
  [[ -x "$mlx_wrapped" ]] || mlx_wrapped=/dev/null
  mkdir -p "$STATE_DIR/cache/mlx-server" "$STATE_DIR/tmp/mlx-server"
  if (cd "$STATE_DIR/cache/mlx-server" && sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D SERVER_SB="$ROOT/profiles/server.sb" \
    -D NET_SB="$ROOT/profiles/net-tcp.sb" \
    -D NET_TARGET="*:$PORT" \
    -D PKG_STORE="$PKG_STORE" \
    -D HOME_DIR="$HOME" \
    -D HOME_PARENT="$(dirname "$HOME")" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_METAL_CACHE="$DARWIN_CACHE/com.apple.metal" \
    -D DARWIN_METALFE_CACHE="$DARWIN_CACHE/com.apple.metalfe" \
    -D CA_FILE=/dev/null \
    -D MLX_SERVER="$MLX_BIN" \
    -D MLX_INTERP=/dev/null \
    -D MLX_WRAPPED="$mlx_wrapped" \
    -D MLX_WRAPPED_INTERP=/dev/null \
    -D MODEL_DIR="$STATE_DIR/models" \
    -D CACHE_DIR="$STATE_DIR/cache/mlx-server" \
    -D TMPDIR="$STATE_DIR/tmp/mlx-server" \
    -f "$ROOT/profiles/mlx-server.sb" \
    "$OTHER_BIN" >/dev/null 2>&1); then
    fail "probe: mlx sandbox refuses unrelated store binaries ($OTHER_BIN ran)"
  else
    ok "probe: mlx sandbox refuses unrelated store binaries"
  fi
else
  skip "probe: mlx sandbox refuses unrelated store binaries" "mlx_lm.server or a $PKG_STORE binary unavailable"
fi

# ── The servers do not share cache state either ───────────
# Each server gets its own cache dir (Metal PSO cache, HF hub cache). One
# shared dir would let either rewrite what the other loads on its next
# start, in a process holding the GPU and the weights.
if [[ -n "$PY" ]]; then
  mkdir -p "$STATE_DIR/cache/mlx-server" "$STATE_DIR/cache/llama-server" "$STATE_DIR/tmp/mlx-server"
  if (cd "$STATE_DIR/cache/mlx-server" && sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D SERVER_SB="$ROOT/profiles/server.sb" \
    -D NET_SB="$ROOT/profiles/net-tcp.sb" \
    -D NET_TARGET="*:$PORT" \
    -D PKG_STORE="$PKG_STORE" \
    -D HOME_DIR="$HOME" \
    -D HOME_PARENT="$(dirname "$HOME")" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_METAL_CACHE="$DARWIN_CACHE/com.apple.metal" \
    -D DARWIN_METALFE_CACHE="$DARWIN_CACHE/com.apple.metalfe" \
    -D CA_FILE=/dev/null \
    -D MLX_SERVER="$PY" \
    -D MLX_INTERP=/dev/null \
    -D MLX_WRAPPED=/dev/null \
    -D MLX_WRAPPED_INTERP=/dev/null \
    -D MODEL_DIR="$STATE_DIR/models" \
    -D CACHE_DIR="$STATE_DIR/cache/mlx-server" \
    -D TMPDIR="$STATE_DIR/tmp/mlx-server" \
    -f "$ROOT/profiles/mlx-server.sb" \
    "$PY" -I -c "open('$STATE_DIR/cache/llama-server/probe','w').write('x')" 2>/dev/null); then
    rm -f "$STATE_DIR/cache/llama-server/probe"
    fail "probe: one server cannot write the other's cache"
  else
    ok "probe: one server cannot write the other's cache"
  fi
else
  skip "probe: one server cannot write the other's cache" "no python3 in $PKG_STORE"
fi

# ── Regression: getfqdn must not SIGKILL the mlx sandbox ──
# Python's http.server resolves the bind address at startup; the reverse
# lookup once escalated into mDNSResponder and tripped the fatal
# network-outbound deny (fixed by the hosts-file grant + plain deny).
if [[ -n "$PY" ]]; then
  mkdir -p "$STATE_DIR/cache/mlx-server" "$STATE_DIR/tmp/mlx-server"
  if (cd "$STATE_DIR/cache/mlx-server" && sandbox-exec \
    -D COMMON_SB="$ROOT/profiles/common.sb" \
    -D SERVER_SB="$ROOT/profiles/server.sb" \
    -D NET_SB="$ROOT/profiles/net-tcp.sb" \
    -D NET_TARGET="*:$PORT" \
    -D PKG_STORE="$PKG_STORE" \
    -D HOME_DIR="$HOME" \
    -D HOME_PARENT="$(dirname "$HOME")" \
    -D DARWIN_USER_TEMP_DIR="$DARWIN_TMP" \
    -D DARWIN_METAL_CACHE="$DARWIN_CACHE/com.apple.metal" \
    -D DARWIN_METALFE_CACHE="$DARWIN_CACHE/com.apple.metalfe" \
    -D CA_FILE=/dev/null \
    -D MLX_SERVER="$PY" \
    -D MLX_INTERP=/dev/null \
    -D MLX_WRAPPED=/dev/null \
    -D MLX_WRAPPED_INTERP=/dev/null \
    -D MODEL_DIR="$STATE_DIR/models" \
    -D CACHE_DIR="$STATE_DIR/cache/mlx-server" \
    -D TMPDIR="$STATE_DIR/tmp/mlx-server" \
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
