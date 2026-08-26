#!/usr/bin/env bash
# Canary for the mtplx KV cache. Run it against a live server before
# you start a long agent session. It sends two chat turns through the
# unix socket, back to back. Turn 2 must reuse the cache from turn 1.
# The turns are small, so the whole check takes a few minutes.
# Usage: tests/mtplx-canary.sh [socket-path]
set -euo pipefail

SOCK="${1:-/private/tmp/llama/llama.sock}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

req() { # $1: payload file, $2: output file
  # -q must come first: it stops curl from reading ~/.curlrc.
  curl -q -sf --unix-socket "$SOCK" -H 'Content-Type: application/json' \
    --max-time 900 -d @"$1" http://localhost/v1/chat/completions >"$2"
}

# Turn 1: a prompt with ~9k tokens of filler, past the cache threshold.
python3 - "$WORK" <<'EOF'
import json, sys
work = sys.argv[1]
filler = "A quick brown fox jumps over one lazy dog again and again. " * 700
msgs = [{"role": "user", "content": filler + "\nSay READY."}]
json.dump({"messages": msgs, "max_tokens": 40}, open(f"{work}/turn1.json", "w"))
EOF

t0=$(date +%s)
req "$WORK/turn1.json" "$WORK/resp1.json"
t1=$(date +%s)

# Turn 2: the same history plus the real reply and one new user line.
# The real reply matters. It makes the prompt extend the stored tokens.
python3 - "$WORK" <<'EOF'
import json, sys
work = sys.argv[1]
turn1 = json.load(open(f"{work}/turn1.json"))
resp1 = json.load(open(f"{work}/resp1.json"))
reply = ((resp1.get("choices") or [{}])[0].get("message") or {})
content = str(reply.get("content") or "").strip() or "READY."
msgs = turn1["messages"] + [
    {"role": "assistant", "content": content},
    {"role": "user", "content": "Turn 1 is done. Say OK."},
]
json.dump({"messages": msgs, "max_tokens": 40}, open(f"{work}/turn2.json", "w"))
EOF

t2=$(date +%s)
req "$WORK/turn2.json" "$WORK/resp2.json"
t3=$(date +%s)

# Verdict: turn 2 must report a session cache hit.
python3 - "$WORK" "$((t1 - t0))" "$((t3 - t2))" <<'EOF'
import json, sys
work, s1, s2 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
stats = json.load(open(f"{work}/resp2.json")).get("mtplx_stats") or {}
hit = bool(stats.get("session_cache_hit"))
print(f"turn1: {s1}s  turn2: {s2}s  cache_hit: {hit}  "
      f"restore_mode: {stats.get('session_restore_mode')}")
sys.exit(0 if hit else 1)
EOF

echo "canary PASS: the server reuses the KV cache across turns"
