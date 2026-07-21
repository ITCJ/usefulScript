#!/usr/bin/env bash
set -Eeuo pipefail

# Run GSM8K accuracy eval with optional per-run SGLang server restart.
# The run directory contains the paired eval log, server log, and run_eval artifacts.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

REPO_DIR="${REPO_DIR:-/home/tcj/sglang-ascend}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
BASE_URL="${BASE_URL:-}"
MODEL_PATH="${MODEL_PATH:-}"
NUM_EXAMPLES="${NUM_EXAMPLES:-200}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-1}"
NUM_THREADS="${NUM_THREADS:-${MAX_RUNNING_REQUESTS}}"
NUM_SHOTS="${NUM_SHOTS:-5}"
MAX_TOKENS="${MAX_TOKENS:-2048}"
TEMPERATURE="${TEMPERATURE:-0.0}"
TOP_P="${TOP_P:-1.0}"
API="${API:-chat}"
THINKING_MODE="${THINKING_MODE:-}"
GSM8K_DATA_PATH="${GSM8K_DATA_PATH:-${SCRIPT_DIR}/gsm8k_test.jsonl}"

LOG_DIR="${LOG_DIR:-/home/tcj/sglang-ascend/gsm8k_eval_logs}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RUN_DIR:-${LOG_DIR}/gsm8k_${RUN_TS}}"
EVAL_LOG="${RUN_DIR}/eval.log"
SERVER_LOG="${RUN_DIR}/server.log"

RESTART_SERVER="${RESTART_SERVER:-1}"
SERVER_START_SCRIPT="${SERVER_START_SCRIPT:-${SCRIPT_DIR}/start.sh}"
SERVER_STOP_TIMEOUT_SEC="${SERVER_STOP_TIMEOUT_SEC:-120}"
READY_CHECK_TIMEOUT_SEC="${READY_CHECK_TIMEOUT_SEC:-6000}"
SERVER_READY_PATH="${SERVER_READY_PATH:-/v1/models}"

TENSOR_DUMP="${TENSOR_DUMP:-0}"
TENSOR_DUMP_DIR="${TENSOR_DUMP_DIR:-${RUN_DIR}/tensor_dump}"
TENSOR_DUMP_LAYERS="${TENSOR_DUMP_LAYERS:-all}"
TENSOR_DUMP_LEVEL="${TENSOR_DUMP_LEVEL:-minimal}"
TENSOR_DUMP_START_CALL="${TENSOR_DUMP_START_CALL:-0}"
TENSOR_DUMP_MAX_CALLS="${TENSOR_DUMP_MAX_CALLS:-0}"

mkdir -p "${RUN_DIR}"
export MAX_RUNNING_REQUESTS

case "${TENSOR_DUMP}" in
  0)
    unset SGLANG_NPU_SPARSE_DEBUG_DIR
    ;;
  1)
    if [[ "${TENSOR_DUMP_LEVEL}" != "minimal" && "${TENSOR_DUMP_LEVEL}" != "full" ]]; then
      echo "Unsupported TENSOR_DUMP_LEVEL=${TENSOR_DUMP_LEVEL}; expected minimal or full" >&2
      exit 2
    fi
    if [[ ! "${TENSOR_DUMP_START_CALL}" =~ ^[0-9]+$ || ! "${TENSOR_DUMP_MAX_CALLS}" =~ ^[0-9]+$ ]]; then
      echo "TENSOR_DUMP_START_CALL and TENSOR_DUMP_MAX_CALLS must be non-negative integers" >&2
      exit 2
    fi
    mkdir -p "${TENSOR_DUMP_DIR}"
    export SGLANG_NPU_SPARSE_DEBUG_DIR="${TENSOR_DUMP_DIR}"
    export SGLANG_NPU_SPARSE_DEBUG_LAYERS="${TENSOR_DUMP_LAYERS}"
    export SGLANG_NPU_SPARSE_DEBUG_LEVEL="${TENSOR_DUMP_LEVEL}"
    export SGLANG_NPU_SPARSE_DEBUG_START_CALL="${TENSOR_DUMP_START_CALL}"
    export SGLANG_NPU_SPARSE_DEBUG_MAX_CALLS="${TENSOR_DUMP_MAX_CALLS}"
    ;;
  *)
    echo "Unsupported TENSOR_DUMP=${TENSOR_DUMP}; expected 0 or 1" >&2
    exit 2
    ;;
esac

log_msg() {
  echo "$*" | tee -a "${EVAL_LOG}"
}

wait_for_server_ready() {
  local url="http://${HOST}:${PORT}${SERVER_READY_PATH}"
  local start_time
  local elapsed

  start_time="$(date +%s)"
  log_msg "[$(date '+%F %T')] waiting up to ${READY_CHECK_TIMEOUT_SEC}s for ${url}"

  while true; do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      elapsed=$(( $(date +%s) - start_time ))
      log_msg "[$(date '+%F %T')] server ready after ${elapsed}s"
      return 0
    fi

    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= READY_CHECK_TIMEOUT_SEC )); then
      log_msg "[$(date '+%F %T')] server did not become ready within ${READY_CHECK_TIMEOUT_SEC}s"
      return 1
    fi

    sleep 2
  done
}

server_processes_still_running() {
  pgrep -f "sglang.*launch_server" >/dev/null 2>&1 || pgrep -f "sglang::" >/dev/null 2>&1
}

wait_for_server_processes_gone() {
  local start_time
  local elapsed

  start_time="$(date +%s)"
  log_msg "[$(date '+%F %T')] waiting up to ${SERVER_STOP_TIMEOUT_SEC}s for old SGLang processes to exit"

  while server_processes_still_running; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= SERVER_STOP_TIMEOUT_SEC )); then
      log_msg "[$(date '+%F %T')] old SGLang processes still exist after ${SERVER_STOP_TIMEOUT_SEC}s"
      pgrep -af "sglang.*launch_server" | tee -a "${EVAL_LOG}" || true
      pgrep -af "sglang::" | tee -a "${EVAL_LOG}" || true
      return 1
    fi

    sleep 1
  done

  elapsed=$(( $(date +%s) - start_time ))
  log_msg "[$(date '+%F %T')] old SGLang processes exited after ${elapsed}s"
}

restart_server_if_needed() {
  if [[ "${RESTART_SERVER}" != "1" ]]; then
    echo "RESTART_SERVER=0; this script did not capture a server log." > "${SERVER_LOG}"
    return 0
  fi

  log_msg "[$(date '+%F %T')] restarting SGLang server"
  log_msg "server_log=${SERVER_LOG}"

  pkill -f "sglang.*launch_server" || true
  pkill -f "sglang::" || true
  wait_for_server_processes_gone

  if [[ ! -x "${SERVER_START_SCRIPT}" ]]; then
    log_msg "Server start script is not executable: ${SERVER_START_SCRIPT}"
    return 1
  fi

  nohup "${SERVER_START_SCRIPT}" > "${SERVER_LOG}" 2>&1 &
  log_msg "[$(date '+%F %T')] start script launched with pid=$!"
  wait_for_server_ready
}

log_msg "[$(date '+%F %T')] GSM8K eval started"
log_msg "repo_dir=${REPO_DIR}"
log_msg "host=${HOST}"
log_msg "port=${PORT}"
log_msg "run_dir=${RUN_DIR}"
log_msg "eval_log=${EVAL_LOG}"
log_msg "server_log=${SERVER_LOG}"
log_msg "restart_server=${RESTART_SERVER}"
log_msg "server_start_script=${SERVER_START_SCRIPT}"
log_msg "server_config_name=${SERVER_CONFIG_NAME:-}"
log_msg "cuda_graph_mode=${CUDA_GRAPH_MODE:-}"
log_msg "cuda_graph_bs=${CUDA_GRAPH_BS:-}"
log_msg "max_running_requests=${MAX_RUNNING_REQUESTS:-}"
log_msg "iteration=${ITERATION:-}"
log_msg "num_examples=${NUM_EXAMPLES}"
log_msg "num_threads=${NUM_THREADS}"
log_msg "num_shots=${NUM_SHOTS}"
log_msg "gsm8k_data_path=${GSM8K_DATA_PATH}"
log_msg "tensor_dump=${TENSOR_DUMP}"
log_msg "tensor_dump_dir=${TENSOR_DUMP_DIR}"
log_msg "tensor_dump_layers=${TENSOR_DUMP_LAYERS}"
log_msg "tensor_dump_level=${TENSOR_DUMP_LEVEL}"
log_msg "tensor_dump_start_call=${TENSOR_DUMP_START_CALL}"
log_msg "tensor_dump_max_calls=${TENSOR_DUMP_MAX_CALLS}"

restart_server_if_needed

cd "${REPO_DIR}"
export PYTHONPATH="${REPO_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"

cmd=(
  python3 -m sglang.test.run_eval
  --eval-name gsm8k
  --num-examples "${NUM_EXAMPLES}"
  --num-threads "${NUM_THREADS}"
  --num-shots "${NUM_SHOTS}"
  --max-tokens "${MAX_TOKENS}"
  --temperature "${TEMPERATURE}"
  --top-p "${TOP_P}"
  --api "${API}"
)

if [[ -n "${MODEL_PATH}" ]]; then
  cmd+=(--model "${MODEL_PATH}")
fi

if [[ -n "${BASE_URL}" ]]; then
  cmd+=(--base-url "${BASE_URL}")
else
  cmd+=(--host "${HOST}" --port "${PORT}")
fi

if [[ -n "${THINKING_MODE}" ]]; then
  cmd+=(--thinking-mode "${THINKING_MODE}")
fi

if [[ -n "${GSM8K_DATA_PATH}" ]]; then
  cmd+=(--gsm8k-data-path "${GSM8K_DATA_PATH}")
fi

cmd+=("$@")

log_msg "[$(date '+%F %T')] running GSM8K eval"
printf 'Running: ' | tee -a "${EVAL_LOG}"
printf '%q ' "${cmd[@]}" | tee -a "${EVAL_LOG}"
printf '\n' | tee -a "${EVAL_LOG}"

set +e
"${cmd[@]}" 2>&1 | tee -a "${EVAL_LOG}"
status=${PIPESTATUS[0]}
set -e

while IFS= read -r artifact; do
  if [[ -f "${artifact}" ]]; then
    mv -- "${artifact}" "${RUN_DIR}/"
  fi
done < <(sed -n \
  -e 's/^Writing report to //p' \
  -e 's/^Writing results to //p' \
  "${EVAL_LOG}")

log_msg "[$(date '+%F %T')] GSM8K eval exit_status=${status}"
log_msg "artifacts saved in: ${RUN_DIR}"
exit "${status}"
