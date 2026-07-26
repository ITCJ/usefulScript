#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

COMPARE_DIR="${COMPARE_DIR:-${1:-}}"
CONFIG="${CONFIG:-eager_bs1}"
ITER="${ITER:-1}"
PHASE="${PHASE:-decode}"
CALL_ID="${CALL_ID:-22}"
LAYER="${LAYER:-6}"
RANK="${RANK:-12}"
DEVICE="${DEVICE:-npu:0}"
REPEATS="${REPEATS:-3}"
RTOL="${RTOL:-1e-5}"
ATOL="${ATOL:-1e-8}"
MODEL_CONFIG="${MODEL_CONFIG:-/home/tcj/DeepSeek-V3.2-Exp-w8a8/config.json}"

if [[ -z "${COMPARE_DIR}" ]]; then
  echo "Usage: $0 /path/to/compare_dir" >&2
  echo "   or: COMPARE_DIR=/path/to/compare_dir $0" >&2
  exit 2
fi

BASE_DUMP="${COMPARE_DIR}/base/${CONFIG}/iter_${ITER}/tensor_dump"
OURS_DUMP="${COMPARE_DIR}/ours/${CONFIG}/iter_${ITER}/tensor_dump"
RANK_DIR="rank_$(printf '%03d' "${RANK}")"
LAYER_DIR="layer_$(printf '%03d' "${LAYER}")"
CALL_DIR="call_$(printf '%05d' "${CALL_ID}")"
RELATIVE_DIR="${RANK_DIR}/sparse_attention/${PHASE}/${LAYER_DIR}/${CALL_DIR}"

BASE_INPUT="${BASE_DUMP}/${RELATIVE_DIR}/operator_inputs.pt"
BASE_OUTPUT="${BASE_DUMP}/${RELATIVE_DIR}/operator_output.pt"
OURS_INPUT="${OURS_DUMP}/${RELATIVE_DIR}/operator_inputs.pt"
OURS_OUTPUT="${OURS_DUMP}/${RELATIVE_DIR}/operator_output.pt"

for path in "${BASE_INPUT}" "${BASE_OUTPUT}" "${OURS_INPUT}" "${OURS_OUTPUT}"; do
  if [[ ! -f "${path}" ]]; then
    echo "Missing PT dump: ${path}" >&2
    exit 1
  fi
done

ARGS=(
  --baseline-input "${BASE_INPUT}"
  --baseline-output "${BASE_OUTPUT}"
  --ours-input "${OURS_INPUT}"
  --ours-output "${OURS_OUTPUT}"
  --device "${DEVICE}"
  --repeats "${REPEATS}"
  --rtol "${RTOL}"
  --atol "${ATOL}"
)

if [[ -n "${SCALE:-}" ]]; then
  ARGS+=(--scale "${SCALE}")
elif [[ -n "${MODEL_CONFIG}" ]]; then
  if [[ ! -f "${MODEL_CONFIG}" ]]; then
    echo "Missing model config: ${MODEL_CONFIG}" >&2
    echo "Set MODEL_CONFIG=/path/to/config.json or SCALE=<exact_scale>." >&2
    exit 1
  fi
  ARGS+=(--model-config "${MODEL_CONFIG}")
fi

echo "compare_dir=${COMPARE_DIR}"
echo "rank=${RANK} layer=${LAYER} phase=${PHASE} call=${CALL_ID}"
echo "baseline_input=${BASE_INPUT}"
echo "ours_input=${OURS_INPUT}"

python3 "${SCRIPT_DIR}/replay_sparse_attention_kernels.py" "${ARGS[@]}"
