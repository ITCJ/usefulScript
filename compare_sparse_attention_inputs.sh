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
RTOL="${RTOL:-1e-5}"
ATOL="${ATOL:-1e-8}"
MAX_DIFF_ROWS="${MAX_DIFF_ROWS:-10}"

if [[ -z "${COMPARE_DIR}" ]]; then
  echo "Usage: COMPARE_DIR=/path/to/compare_dir $0" >&2
  echo "   or: $0 /path/to/compare_dir" >&2
  exit 2
fi

BASE_DUMP="${COMPARE_DIR}/base/${CONFIG}/iter_${ITER}/tensor_dump"
OURS_DUMP="${COMPARE_DIR}/ours/${CONFIG}/iter_${ITER}/tensor_dump"
RANK_DIR="rank_$(printf '%03d' "${RANK}")"
LAYER_DIR="layer_$(printf '%03d' "${LAYER}")"
CALL_DIR="call_$(printf '%05d' "${CALL_ID}")"
RELATIVE_PT="sparse_attention/${PHASE}/${LAYER_DIR}/${CALL_DIR}/operator_inputs.pt"
BASE_PT="${BASE_DUMP}/${RANK_DIR}/${RELATIVE_PT}"
OURS_PT="${OURS_DUMP}/${RANK_DIR}/${RELATIVE_PT}"

TENSORS=(
  'query.flatten()'
  'query_rope.flatten()'
  'topk_indices.flatten()'
  'last_query_topk_indices.flatten()'
  'last_query_topk_valid_mask.flatten()'
  'selected_key_last_query.flatten()'
  'selected_key_rope_last_query.flatten()'
)

echo "baseline=${BASE_PT}"
echo "ours=${OURS_PT}"
echo "rank=${RANK} layer=${LAYER} phase=${PHASE} call=${CALL_ID}"
echo "Note: sparse_indices is intentionally not compared because ours remaps token IDs."

for tensor in "${TENSORS[@]}"; do
  echo
  echo "===== ${tensor} ====="
  python3 "${SCRIPT_DIR}/inspect_pt_tensor.py" \
    "${BASE_PT}" \
    "${tensor}" \
    --compare \
    "${OURS_PT}" \
    "${tensor}" \
    --rtol "${RTOL}" \
    --atol "${ATOL}" \
    --max-diff-rows "${MAX_DIFF_ROWS}"
done

echo
echo "===== semantic metadata validation ====="
python3 "${SCRIPT_DIR}/validate_sparse_attention_metadata.py" \
  "${BASE_PT}" \
  "${OURS_PT}"
