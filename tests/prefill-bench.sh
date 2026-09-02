#!/usr/bin/env bash
# Prefill benchmark with llama-bench. It compares the KV cache type and
# the micro-batch size at two context depths. Use it to pick the
# fastest prompt-processing flags for a long prompt.
# Each KV type runs as one llama-bench call, because -ctk and -ctv
# lists form a cross product inside llama-bench.
# The depth run fills the context first, then it times the prompt.
# Since b10717 Metal dequantizes a quantized KV cache to f16 before
# flash attention, but only for large batches. So the KV type and the
# micro-batch size interact. Test them together.
# A large depth makes each run slow. Keep the matrix small.
# Usage: tests/prefill-bench.sh [model-spec]
# Env: KV_TYPES (default "f16 q8_0"), UBATCH (default 512,2048),
#      DEPTHS (default 0,16384), PROMPT (default 4096), REPS (default 2)
set -euo pipefail

MODEL="${1:-unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL}"
KV_TYPES="${KV_TYPES:-f16 q8_0}"
UBATCH="${UBATCH:-512,2048}"
DEPTHS="${DEPTHS:-0,16384}"
PROMPT="${PROMPT:-4096}"
REPS="${REPS:-2}"

for kv in $KV_TYPES; do
  printf '\n== KV cache %s ==\n' "$kv"
  # --load-mode mlock: mmap runs give ±50%% noise on macOS.
  sandboxed-ai llama-bench --model "$MODEL" \
    -ngl 99 -fa 1 --load-mode mlock \
    -ctk "$kv" -ctv "$kv" \
    -b 4096 -ub "$UBATCH" \
    -p "$PROMPT" -n 0 -d "$DEPTHS" -r "$REPS" -o md
done
