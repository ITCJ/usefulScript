#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

COMPARE_DIR="${COMPARE_DIR:-${1:-}}"
CONFIG="${CONFIG:-eager_bs1}"
ITER="${ITER:-1}"
PHASE="${PHASE:-decode}"
CALL_ID="${CALL_ID:-22}"
LAYER="${LAYER:-6}"
RANK="${RANK:-0}"

if [[ -z "${COMPARE_DIR}" ]]; then
  echo "Usage: COMPARE_DIR=/path/to/compare_dir $0" >&2
  echo "   or: $0 /path/to/compare_dir" >&2
  exit 2
fi

BASE_DUMP="${COMPARE_DIR}/base/${CONFIG}/iter_${ITER}/tensor_dump"
OURS_DUMP="${COMPARE_DIR}/ours/${CONFIG}/iter_${ITER}/tensor_dump"

python3 "${SCRIPT_DIR}/compare_layer_flow.py" \
  "${BASE_DUMP}" "${OURS_DUMP}" \
  --phase "${PHASE}" \
  --call "${CALL_ID}" \
  --layer "${LAYER}" \
  --rank "${RANK}"
