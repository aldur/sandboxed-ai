#!/usr/bin/env bash
# Decode benchmark against one running server. Start the server with
# the flags under test, then run this script. It sends the same
# request three times and prints the server's timing numbers. Compare
# the lines between server configurations. It works for llama-server
# and for mtplx.
# Notes: the prefill number is valid on run 1 only; later runs can
# hit the prompt cache. The decode number is valid on every run.
# Usage: tests/decode-bench.sh [socket-path] [label]
# Env: FILLER_REPEAT sets the prompt size (default 200, about 2.6k
# tokens; 1500 gives about 20k tokens for a prefill test).
set -euo pipefail

SOCK="${1:-/private/tmp/llama/llama.sock}"
LABEL="${2:-run}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILLER_REPEAT="${FILLER_REPEAT:-200}" python3 - >"$WORK/req.json" <<'EOF'
import json, os
filler = "A quick brown fox jumps over one lazy dog again and again. " * int(os.environ["FILLER_REPEAT"])
print(json.dumps({
    "messages": [{"role": "user",
                  "content": filler + "\nWrite a 300-word story about a fox."}],
    "max_tokens": 256,
    "temperature": 0,
}))
EOF

for i in 1 2 3; do
  # -q must come first: it stops curl from reading ~/.curlrc.
  curl -q -sf --unix-socket "$SOCK" -H 'Content-Type: application/json' \
    --max-time 900 -d @"$WORK/req.json" \
    http://localhost/v1/chat/completions >"$WORK/resp$i.json"
  python3 - "$WORK/resp$i.json" "$LABEL" "$i" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
label, run = sys.argv[2], sys.argv[3]
t = d.get("timings") or {}
if t:
    # llama-server reports its own timings in the response.
    print(f"{label} run {run}: "
          f"prefill {float(t.get('prompt_per_second') or 0):.1f} tok/s, "
          f"decode {float(t.get('predicted_per_second') or 0):.1f} tok/s")
else:
    # mtplx embeds its stats under mtplx_stats.
    s = d.get("mtplx_stats") or {}
    s = s.get("latest") or s
    print(f"{label} run {run}: decode {s.get('tok_s', 'n/a')} tok/s (mtplx)")
EOF
done
