#!/usr/bin/env bash
set -euo pipefail

# Run SGLang serving benchmark against an already running server.
# Override any variable below from the environment, e.g.:
#   MODEL_PATH=/path/to/model NUM_PROMPTS=1000 ./run_sglang_benchmark.sh

REPO_DIR=${REPO_DIR:-/Users/tcj/Sync/prj_hw/sglang-ascend}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-6699}
BACKEND=${BACKEND:-sglang}
MODEL_PATH=${MODEL_PATH:-None}
DATASET_NAME=${DATASET_NAME:-random}
NUM_PROMPTS=${NUM_PROMPTS:-300}
RANDOM_INPUT=${RANDOM_INPUT:-1024}
RANDOM_OUTPUT=${RANDOM_OUTPUT:-128}
RANDOM_RANGE_RATIO=${RANDOM_RANGE_RATIO:-1.0}
REQUEST_RATE=${REQUEST_RATE:-inf}
WARMUP_REQUESTS=${WARMUP_REQUESTS:-10}
OUTPUT_DIR=${OUTPUT_DIR:-${REPO_DIR}/benchmark_results}
OUTPUT_FILE=${OUTPUT_FILE:-${OUTPUT_DIR}/bench_serving_$(date +%Y%m%d_%H%M%S).jsonl}

mkdir -p "${OUTPUT_DIR}"
cd "${REPO_DIR}"

export PYTHONPATH="${REPO_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}"

python3 -m sglang.bench_serving \
  --backend "${BACKEND}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --model "${MODEL_PATH}" \
  --dataset-name "${DATASET_NAME}" \
  --num-prompts "${NUM_PROMPTS}" \
  --random-input-len "${RANDOM_INPUT}" \
  --random-output-len "${RANDOM_OUTPUT}" \
  --random-range-ratio "${RANDOM_RANGE_RATIO}" \
  --request-rate "${REQUEST_RATE}" \
  --warmup-requests "${WARMUP_REQUESTS}" \
  --output-file "${OUTPUT_FILE}" \
  "$@"

echo "Benchmark result: ${OUTPUT_FILE}"
