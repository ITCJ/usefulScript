#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

COMPARE_DIR="${COMPARE_DIR:-${1:-}}"
CONFIG="${CONFIG:-eager_bs1}"
ITER="${ITER:-1}"
PHASE="${PHASE:-decode}"
CALL_ID="${CALL_ID:-22}"
LAYER="${LAYER:-6}"
RTOL="${RTOL:-1e-5}"
ATOL="${ATOL:-1e-8}"

if [[ -z "${COMPARE_DIR}" ]]; then
  echo "Usage: COMPARE_DIR=/path/to/compare_dir $0" >&2
  echo "   or: $0 /path/to/compare_dir" >&2
  exit 2
fi

BASE_DUMP="${COMPARE_DIR}/base/${CONFIG}/iter_${ITER}/tensor_dump"
OURS_DUMP="${COMPARE_DIR}/ours/${CONFIG}/iter_${ITER}/tensor_dump"
LAYER_DIR="layer_$(printf '%03d' "${LAYER}")"
CALL_DIR="call_$(printf '%05d' "${CALL_ID}")"
OVERALL_STATUS=0

compare_checkpoint() {
  local title="$1"
  local stage="$2"
  local checkpoint="$3"
  local expression="$4"
  local pattern
  local status

  pattern="rank_*/${stage}/${PHASE}/${LAYER_DIR}/${CALL_DIR}/${checkpoint}.pt"

  echo
  echo "===== ${title} ====="
  set +e
  python3 "${SCRIPT_DIR}/compare_pt_tensors.py" \
    "${BASE_DUMP}" \
    "${OURS_DUMP}" \
    "${expression}" \
    --glob "${pattern}" \
    --rtol "${RTOL}" \
    --atol "${ATOL}"
  status=$?
  set -e

  if [[ "${status}" -eq 2 ]]; then
    OVERALL_STATUS=2
  elif [[ "${status}" -ne 0 && "${OVERALL_STATUS}" -eq 0 ]]; then
    OVERALL_STATUS=1
  fi
}

compare_checkpoint \
  "layer attention input: hidden_states_after_comm_pre_attn" \
  "layer_flow" "attention_input" \
  "hidden_states_after_comm_pre_attn.flatten()"
compare_checkpoint \
  "prepare_mlp residual input: residual_after_input_ln" \
  "layer_flow" "attention_input" \
  "residual_after_input_ln.flatten()"
compare_checkpoint \
  "sparse attention output" \
  "mla_post_attention" "operator_output" \
  "attention_output.flatten()"
compare_checkpoint \
  "w_vc batch matmul output" \
  "mla_post_attention" "operator_output" \
  "attn_bmm_output.flatten()"
compare_checkpoint \
  "o_proj output before TP all-reduce" \
  "mla_post_attention" "operator_output" \
  "o_proj_output.flatten()"
compare_checkpoint \
  "attention module return value" \
  "layer_flow" "attention_module_output" \
  "hidden_states_after_attn.flatten()"
compare_checkpoint \
  "prepare_mlp output: hidden_states_mlp_input" \
  "layer_flow" "mlp_input" \
  "hidden_states_mlp_input.flatten()"
compare_checkpoint \
  "prepare_mlp output: residual_after_comm_pre_mlp" \
  "layer_flow" "mlp_input" \
  "residual_after_comm_pre_mlp.flatten()"

exit "${OVERALL_STATUS}"
