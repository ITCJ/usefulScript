#!/usr/bin/env bash
set -Eeuo pipefail

# AIME 2026 uses EvalScope because sglang.test.run_eval currently registers
# AIME25 but not AIME26. Server lifecycle/sweep/branch logic is shared with
# run_gsm8k_eval.sh so fixes stay consistent between both benchmarks.
# aime26_test.jsonl mirrors math-ai/aime26/aime2026.jsonl (Apache-2.0).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

export EVAL_NAME=aime26
export BENCHMARK_LABEL=AIME26
export ENTRYPOINT_NAME=run_aime26_eval.sh
export MODEL_PATH="${MODEL_PATH:-/home/tcj/DeepSeek-V3.2-Exp-w8a8}"
export LOG_DIR="${LOG_DIR:-/home/tcj/aime26_eval_logs}"
export AIME26_DATA_PATH="${AIME26_DATA_PATH:-${SCRIPT_DIR}/aime26_test.jsonl}"

# AIME26 has short input prompts. Keep the output budget below start.sh's
# default 40K total context; override both MAX_TOKENS and CONTEXT_LENGTH when
# intentionally testing longer reasoning traces.
export MAX_TOKENS="${MAX_TOKENS:-32768}"

exec "${SCRIPT_DIR}/run_gsm8k_eval.sh" "$@"
