#!/usr/bin/env bash
set -Eeuo pipefail

# Sweep bench_serving max-concurrency from 1 to 32.
# num-prompts is kept equal to the current concurrency.

DATASET_PATH="${DATASET_PATH:-/home/tcj/script/ShareGPT_V3_unfiltered_cleaned_split.json}"
BACKEND="${BACKEND:-sglang}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
DATASET_NAME="${DATASET_NAME:-random}"
RANDOM_OUTPUT_LEN="${RANDOM_OUTPUT_LEN:-100}"
RANDOM_RANGE_RATIO="${RANDOM_RANGE_RATIO:-1}"
START_CONCURRENCY="${START_CONCURRENCY:-1}"
END_CONCURRENCY="${END_CONCURRENCY:-32}"
SERVER_LOG="${SERVER_LOG:-/home/tcj/sglang-ascend/32k4k16bs.spkv.log}"
LOG_DIR="${LOG_DIR:-/home/tcj/sglang-ascend/bench_serving_sweep_logs}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"

mkdir -p "${LOG_DIR}"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${RUN_LOG:-${LOG_DIR}/bench_serving_concurrency_sweep_${RUN_TS}.log}"
RESULT_DIR="${RESULT_DIR:-${LOG_DIR}/results_${RUN_TS}}"
mkdir -p "${RESULT_DIR}"

exec > >(tee -a "${RUN_LOG}") 2>&1

echo "[$(date '+%F %T')] bench_serving concurrency sweep started"
echo "dataset_path=${DATASET_PATH}"
echo "backend=${BACKEND}"
echo "host=${HOST}"
echo "port=${PORT}"
echo "concurrency=${START_CONCURRENCY}..${END_CONCURRENCY}"
echo "server_log=${SERVER_LOG}"
echo "run_log=${RUN_LOG}"
echo "result_dir=${RESULT_DIR}"

for concurrency in $(seq "${START_CONCURRENCY}" "${END_CONCURRENCY}"); do
  num_prompts="${concurrency}"
  output_file="${RESULT_DIR}/bench_serving_c${concurrency}_p${num_prompts}.jsonl"
  marker="===== BENCH_SERVING_SWEEP $(date '+%F %T') concurrency=${concurrency} num_prompts=${num_prompts} ====="

  echo
  echo "${marker}"
  echo "${marker}" >> "${SERVER_LOG}"

  set +e
  python -m sglang.bench_serving \
    --dataset-path "${DATASET_PATH}" \
    --backend "${BACKEND}" \
    --host "${HOST}" \
    --port "${PORT}" \
    --max-concurrency "${concurrency}" \
    --dataset-name "${DATASET_NAME}" \
    --random-output-len "${RANDOM_OUTPUT_LEN}" \
    --num-prompts "${num_prompts}" \
    --random-range-ratio "${RANDOM_RANGE_RATIO}" \
    --output-file "${output_file}"
  status=$?
  set -e
  echo "[$(date '+%F %T')] concurrency=${concurrency} num_prompts=${num_prompts} exit_status=${status} output_file=${output_file}"

  if [[ "${status}" -ne 0 && "${CONTINUE_ON_ERROR}" != "1" ]]; then
    echo "Stop on failure. Set CONTINUE_ON_ERROR=1 to keep sweeping after failures."
    exit "${status}"
  fi
done

echo
echo "[$(date '+%F %T')] bench_serving concurrency sweep finished"
echo "run_log=${RUN_LOG}"
echo "result_dir=${RESULT_DIR}"
