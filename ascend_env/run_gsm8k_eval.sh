#!/usr/bin/env bash
set -euo pipefail

# Run GSM8K accuracy eval against an already running SGLang OpenAI-compatible server.
# Override variables from the environment, e.g.:
#   MODEL_PATH=/path/to/model NUM_EXAMPLES=1319 ./run_gsm8k_eval.sh

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

REPO_DIR=${REPO_DIR:-/Users/tcj/Sync/prj_hw/sglang-ascend}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-6699}
BASE_URL=${BASE_URL:-}
MODEL_PATH=${MODEL_PATH:-None}
NUM_EXAMPLES=${NUM_EXAMPLES:-200}
NUM_THREADS=${NUM_THREADS:-128}
NUM_SHOTS=${NUM_SHOTS:-5}
MAX_TOKENS=${MAX_TOKENS:-2048}
TEMPERATURE=${TEMPERATURE:-0.0}
TOP_P=${TOP_P:-1.0}
API=${API:-chat}
# Bundled from the official OpenAI GSM8K repository (MIT license):
# https://github.com/openai/grade-school-math
GSM8K_DATA_PATH=${GSM8K_DATA_PATH:-${SCRIPT_DIR}/gsm8k_test.jsonl}
OUTPUT_DIR=${OUTPUT_DIR:-${REPO_DIR}/benchmark_results}
LOG_FILE=${LOG_FILE:-${OUTPUT_DIR}/gsm8k_$(date +%Y%m%d_%H%M%S).log}

mkdir -p "${OUTPUT_DIR}"
cd "${REPO_DIR}"

export PYTHONPATH="${REPO_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"

cmd=(
  python3 -m sglang.test.run_eval
  --eval-name gsm8k
  --model "${MODEL_PATH}"
  --num-examples "${NUM_EXAMPLES}"
  --num-threads "${NUM_THREADS}"
  --num-shots "${NUM_SHOTS}"
  --max-tokens "${MAX_TOKENS}"
  --temperature "${TEMPERATURE}"
  --top-p "${TOP_P}"
  --api "${API}"
)

if [[ -n "${BASE_URL}" ]]; then
  cmd+=(--base-url "${BASE_URL}")
else
  cmd+=(--host "${HOST}" --port "${PORT}")
fi

if [[ -n "${GSM8K_DATA_PATH}" ]]; then
  cmd+=(--gsm8k-data-path "${GSM8K_DATA_PATH}")
fi

cmd+=("$@")

printf 'Running: '
printf '%q ' "${cmd[@]}"
printf '\nLog: %s\n' "${LOG_FILE}"

"${cmd[@]}" 2>&1 | tee "${LOG_FILE}"
