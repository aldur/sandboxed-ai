#!/usr/bin/env bash
# Real Metal inference through TensorFold's runtime sandbox. Run directly,
# or set TEST_TENSORFOLD_MODEL when running tests/e2e.sh. No tiny supported
# checkpoint exists, so inference is opt-in; CLI/package checks always run.
set -euo pipefail
ROOT="$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)"
SANDBOX="${TEST_SANDBOX:-$ROOT/sandbox.sh}"
if [[ -z "${TENSORFOLD:-}" ]]; then
  TENSORFOLD="$(nix build "path:$ROOT#tensorfold" --no-link --print-out-paths)/bin/tensorfold"
fi
export TENSORFOLD
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tensorfold-e2e.XXXXXX")"
WORK="$(realpath "$WORK")"
PORT="${TEST_TENSORFOLD_PORT:-18088}"
SERVER_PID=""
stop_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  for ((i=0; i<20; i++)); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}
cleanup() {
  local status=$?
  stop_server
  if ((status)); then
    tail -40 "$WORK"/*.log >&2 || true
    printf 'TensorFold test logs: %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
# This must work without a model, downloads, or inherited Python settings.
env -u MODEL "$SANDBOX" tensorfold --help >"$WORK/help.log" 2>&1
grep -q 'tensorfold serve' "$WORK/help.log"
echo 'ok   - TensorFold help runs inside its sandbox'
# Resolve both local directories (including spaces) before passing help to
# the real CLI. This catches wrapper argument and profile-parameter errors
# without requiring two large checkpoints just to exercise the resolver.
mkdir -p "$WORK/model path" "$WORK/draft path"
printf '{}\n' >"$WORK/model path/config.json"
printf '{}\n' >"$WORK/draft path/config.json"
"$SANDBOX" tensorfold serve --model="$WORK/model path" \
  --drafter="$WORK/draft path" --port="$PORT" --help >"$WORK/paths.log" 2>&1
grep -q 'tensorfold serve' "$WORK/paths.log"
if "$SANDBOX" tensorfold --port 70000 >"$WORK/bad-port.log" 2>&1; then
  echo 'FAIL - TensorFold accepted an invalid port' >&2
  exit 1
fi
grep -q 'port out of range' "$WORK/bad-port.log"
echo 'ok   - TensorFold resolves local model/draft paths and validates its port'
# The small SSD fixture exercises the real native extension and GPU/file
# pipeline even on CI, independently of the opt-in large language model.
SSD_CHECK="$(nix build "path:$ROOT#tensorfold-ssd-check" --no-link --print-out-paths)/bin/tensorfold-ssd-check"
"$SSD_CHECK" --prepare "$WORK/ssd-model" >"$WORK/ssd-prepare.log" 2>&1
TENSORFOLD="$SSD_CHECK" "$SANDBOX" tensorfold --model "$WORK/ssd-model" >"$WORK/ssd.log" 2>&1
cat "$WORK/ssd.log"

if [[ -z "${TEST_TENSORFOLD_MODEL:-}" ]]; then
  echo 'skip - TensorFold inference (set TEST_TENSORFOLD_MODEL to a supported checkpoint)'
  exit 0
fi
# The script owns only its children; refuse an occupied port before launch.
python3 - "$PORT" <<'PY'
import socket, sys
with socket.socket() as s:
    s.bind(('127.0.0.1', int(sys.argv[1])))
PY
args=(tensorfold --model "$TEST_TENSORFOLD_MODEL" --context 2048
      --max-tokens 32 --parallel 1 --no-thinking)
if [[ "${TEST_TENSORFOLD_VISION:-}" == 1 ]]; then
  args+=(--vision)
fi
if [[ -n "${TEST_TENSORFOLD_DRAFTER:-}" ]]; then
  args+=(--drafter "$TEST_TENSORFOLD_DRAFTER")
fi
for transport in tcp unix; do
  if [[ "$transport" == tcp ]]; then
    endpoint=(--port "$PORT")
    address="$PORT"
  else
    address="$WORK/server.sock"
    endpoint=(--host "$address")
  fi
  "$SANDBOX" "${args[@]}" "${endpoint[@]}" >"$WORK/$transport.log" 2>&1 &
  SERVER_PID=$!
  python3 "$ROOT/tests/tensorfold-api.py" "$transport" "$address" "$SERVER_PID"
  stop_server
done
