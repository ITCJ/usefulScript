#!/usr/bin/env bash
set -Eeuo pipefail

# Simple GSM8K accuracy sanity test against an already running SGLang server.
# This follows the SGLang template:
#   python -m sglang.test.few_shot_gsm8k --host 127.0.0.1 --port 30000 --num-questions 200 --num-shots 5

REPO_DIR="${REPO_DIR:-/home/tcj/sglang-ascend}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
NUM_QUESTIONS="${NUM_QUESTIONS:-200}"
NUM_SHOTS="${NUM_SHOTS:-5}"
PARALLEL="${PARALLEL:-128}"
MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-512}"
TEMPERATURE="${TEMPERATURE:-0.0}"
DATA_PATH="${DATA_PATH:-}"
LOG_DIR="${LOG_DIR:-${REPO_DIR}/gsm8k_eval_logs}"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/gsm8k_accuracy_$(date +%Y%m%d_%H%M%S).log}"

cd "${REPO_DIR}"
export PYTHONPATH="${REPO_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}"

cmd=(
  python -m sglang.test.few_shot_gsm8k
  --host "${HOST}"
  --port "${PORT}"
  --num-questions "${NUM_QUESTIONS}"
  --num-shots "${NUM_SHOTS}"
  --parallel "${PARALLEL}"
  --max-new-tokens "${MAX_NEW_TOKENS}"
  --temperature "${TEMPERATURE}"
)

if [[ -n "${DATA_PATH}" ]]; then
  cmd+=(--data-path "${DATA_PATH}")
fi

cmd+=("$@")

echo "[$(date '+%F %T')] Starting GSM8K accuracy test"
echo "repo_dir=${REPO_DIR}"
echo "host=${HOST}"
echo "port=${PORT}"
echo "num_questions=${NUM_QUESTIONS}"
echo "num_shots=${NUM_SHOTS}"
echo "parallel=${PARALLEL}"
echo "log_file=${LOG_FILE}"
printf 'Running: '
printf '%q ' "${cmd[@]}"
printf '\n'

"${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}"
