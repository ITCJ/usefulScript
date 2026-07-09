#!/usr/bin/env bash
set -Eeuo pipefail

# Sweep bench_serving max-concurrency from 1 to 32.
# num-prompts is kept equal to the current concurrency.

DATASET_PATH="${DATASET_PATH:-/home/tcj/script/ShareGPT_V3_unfiltered_cleaned_split.json}"
BACKEND="${BACKEND:-sglang}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
DATASET_NAME="${DATASET_NAME:-random}"
RANDOM_INPUT_LEN="${RANDOM_INPUT_LEN:-32768}"
RANDOM_OUTPUT_LEN="${RANDOM_OUTPUT_LEN:-500}"
RANDOM_RANGE_RATIO="${RANDOM_RANGE_RATIO:-1}"
START_CONCURRENCY="${START_CONCURRENCY:-1}"
END_CONCURRENCY="${END_CONCURRENCY:-32}"
LOG_DIR="${LOG_DIR:-/home/tcj/sglang-ascend/bench_serving_sweep_logs}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"
READY_CHECK_TIMEOUT_SEC="${READY_CHECK_TIMEOUT_SEC:-6000}"
RESTART_SERVER_EACH_RUN="${RESTART_SERVER_EACH_RUN:-0}"
SERVER_START_SCRIPT="${SERVER_START_SCRIPT:-/home/tcj/script/start.sh}"
SERVER_RESTART_SLEEP_SEC="${SERVER_RESTART_SLEEP_SEC:-5}"
SERVER_READY_PATH="${SERVER_READY_PATH:-/v1/models}"

mkdir -p "${LOG_DIR}"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RUN_DIR:-${LOG_DIR}/sweep_${RUN_TS}}"
mkdir -p "${RUN_DIR}"

echo "[$(date '+%F %T')] bench_serving concurrency sweep started"
echo "dataset_path=${DATASET_PATH}"
echo "backend=${BACKEND}"
echo "host=${HOST}"
echo "port=${PORT}"
echo "concurrency=${START_CONCURRENCY}..${END_CONCURRENCY}"
echo "random_input_len=${RANDOM_INPUT_LEN}"
echo "random_output_len=${RANDOM_OUTPUT_LEN}"
echo "ready_check_timeout_sec=${READY_CHECK_TIMEOUT_SEC}"
echo "restart_server_each_run=${RESTART_SERVER_EACH_RUN}"
echo "server_start_script=${SERVER_START_SCRIPT}"
echo "server_ready_path=${SERVER_READY_PATH}"
echo "run_dir=${RUN_DIR}"

log_msg() {
  local message="$*"
  if [[ -n "${BENCH_LOG:-}" ]]; then
    echo "${message}" | tee -a "${BENCH_LOG}"
  else
    echo "${message}"
  fi
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

restart_server_if_needed() {
  local concurrency="$1"
  local server_log="$2"

  if [[ "${RESTART_SERVER_EACH_RUN}" != "1" ]]; then
    echo "RESTART_SERVER_EACH_RUN=0; this script did not capture a per-case server log." > "${server_log}"
    return 0
  fi

  log_msg "[$(date '+%F %T')] restarting SGLang server before concurrency=${concurrency}"
  log_msg "server_log=${server_log}"

  pkill -f "sglang.*launch_server" || true
  pkill -f "sglang::" || true
  sleep "${SERVER_RESTART_SLEEP_SEC}"

  if [[ ! -x "${SERVER_START_SCRIPT}" ]]; then
    log_msg "Server start script is not executable: ${SERVER_START_SCRIPT}"
    return 1
  fi

  nohup "${SERVER_START_SCRIPT}" > "${server_log}" 2>&1 &
  log_msg "[$(date '+%F %T')] start script launched with pid=$!"
  wait_for_server_ready
}

for concurrency in $(seq "${START_CONCURRENCY}" "${END_CONCURRENCY}"); do
  num_prompts="${concurrency}"
  case_dir="${RUN_DIR}/c${concurrency}_p${num_prompts}"
  BENCH_LOG="${case_dir}/bench.log"
  server_log="${case_dir}/server.log"
  output_file="${case_dir}/result.jsonl"
  marker="===== BENCH_SERVING_SWEEP $(date '+%F %T') concurrency=${concurrency} num_prompts=${num_prompts} ====="

  mkdir -p "${case_dir}"
  : > "${BENCH_LOG}"

  log_msg ""
  log_msg "case_dir=${case_dir}"
  restart_server_if_needed "${concurrency}" "${server_log}"

  log_msg "${marker}"

  set +e
  python -m sglang.bench_serving \
    --dataset-path "${DATASET_PATH}" \
    --backend "${BACKEND}" \
    --host "${HOST}" \
    --port "${PORT}" \
    --max-concurrency "${concurrency}" \
    --dataset-name "${DATASET_NAME}" \
    --random-input-len "${RANDOM_INPUT_LEN}" \
    --random-output-len "${RANDOM_OUTPUT_LEN}" \
    --num-prompts "${num_prompts}" \
    --random-range-ratio "${RANDOM_RANGE_RATIO}" \
    --ready-check-timeout-sec "${READY_CHECK_TIMEOUT_SEC}" \
    --output-file "${output_file}" \
    2>&1 | tee -a "${BENCH_LOG}"
  status=${PIPESTATUS[0]}
  set -e
  log_msg "[$(date '+%F %T')] concurrency=${concurrency} num_prompts=${num_prompts} exit_status=${status} output_file=${output_file}"

  if [[ "${status}" -ne 0 && "${CONTINUE_ON_ERROR}" != "1" ]]; then
    log_msg "Stop on failure. Set CONTINUE_ON_ERROR=1 to keep sweeping after failures."
    exit "${status}"
  fi
done

echo
echo "[$(date '+%F %T')] bench_serving concurrency sweep finished"
echo "run_dir=${RUN_DIR}"
