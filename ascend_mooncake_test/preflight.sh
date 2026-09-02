#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker

[[ -d "${MODEL_HOST_PATH}" ]] || die "Model directory does not exist: ${MODEL_HOST_PATH}"
[[ -d /usr/local/Ascend/driver ]] || die "Host driver directory is missing: /usr/local/Ascend/driver"
[[ -s /etc/hccn.conf ]] || die "Mooncake Ascend Direct requires a non-empty host /etc/hccn.conf"
validate_required_home_mounts
docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1 || \
  die "Runtime image not found: ${RUNTIME_IMAGE}; run ./build-image.sh"

command -v npu-smi >/dev/null 2>&1 || die "npu-smi is not available on the host"
log "Host NPU summary"
npu-smi info -l

required_max=$((NPU_COUNT_PER_ROLE - 1))
if [[ "${DEPLOY_MODE}" == "single" ]]; then
  required_max=$((NPU_COUNT_PER_ROLE * 2 - 1))
fi
for ((i = 0; i <= required_max; i++)); do
  [[ -e "/dev/davinci${i}" ]] || die "Required device missing: /dev/davinci${i}"
done

log "Host HCCN configuration: /etc/hccn.conf"
hccn_tool_bin=$(command -v hccn_tool 2>/dev/null || true)
if [[ -z "${hccn_tool_bin}" && -x /usr/local/Ascend/driver/tools/hccn_tool ]]; then
  hccn_tool_bin=/usr/local/Ascend/driver/tools/hccn_tool
fi
if [[ -n "${hccn_tool_bin}" ]]; then
  for ((i = 0; i <= required_max; i++)); do
    log "NPU ${i} HCCN IP"
    if ! "${hccn_tool_bin}" -i "${i}" -ip -g; then
      log "WARNING: hccn_tool failed for NPU ${i}; verify /etc/hccn.conf and the NPU network manually"
    fi
  done
else
  log "WARNING: hccn_tool is unavailable in PATH and the host driver tools directory; using /etc/hccn.conf as the network source"
fi

mkdir -p "${LOG_DIR}"

log "Checking SGLang, torch_npu and Mooncake packages inside the runtime image"
docker run --rm --network host --ipc host \
  --volume /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  --volume /etc/hccn.conf:/etc/hccn.conf:ro \
  --entrypoint bash "${RUNTIME_IMAGE}" -lc '
set -Eeuo pipefail
source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
python3 - <<"PY"
import importlib.metadata as md
import sglang
import torch
import torch_npu
from mooncake.engine import TransferEngine

print("sglang:", getattr(sglang, "__version__", "unknown"))
print("torch:", torch.__version__)
print("torch_npu:", torch_npu.__version__)
print("mooncake-transfer-engine-npu:", md.version("mooncake-transfer-engine-npu"))
print("Mooncake TransferEngine import: OK", TransferEngine)
PY
'

if [[ "${DEPLOY_MODE}" == "split" ]]; then
  local_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)
  log "Split-node mode: allow bidirectional TCP between ${PREFILL_IP} and ${DECODE_IP}"
  log "Required fixed ports: ${PREFILL_HTTP_PORT}, ${DECODE_HTTP_PORT}, ${PREFILL_BOOTSTRAP_PORT}"
  log "Ascend Direct ranges start at ${PREFILL_ASCEND_BASE_PORT} / ${DECODE_ASCEND_BASE_PORT}; host ephemeral range: ${local_range:-unknown}"
fi

log "Preflight passed"
