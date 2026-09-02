#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:?role is required}
shift

source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
source /usr/local/Ascend/nnal/atb/set_env.sh 2>/dev/null || true

export ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true
export ASCEND_NPU_PHY_ID=-1
export PYTORCH_NPU_ALLOC_CONF=${PYTORCH_NPU_ALLOC_CONF:-expandable_segments:True}
export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=${SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT:-600}
export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=${SGLANG_DISAGGREGATION_WAITING_TIMEOUT:-600}

# Do not pass --disaggregation-ib-device: Ascend Direct installs its own
# transport and does not use the CUDA/RDMA HCA-selection path.
exec > >(tee "/logs/${ROLE}.log") 2>&1
exec python3 -m sglang.launch_server "$@"
