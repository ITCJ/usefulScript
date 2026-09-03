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

npu_smi_bin=$(find_npu_smi || true)
[[ -n "${npu_smi_bin}" ]] || die "npu-smi is not available in PATH, /usr/local/bin, or /usr/local/sbin"
log "Host NPU summary"
"${npu_smi_bin}" info -l

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

log "Checking NPU visibility, npu-smi, libibverbs, SGLang, torch_npu and Mooncake inside the runtime image"
PREFLIGHT_DOCKER_ARGS=(
  --rm
  --network host
  --ipc host
  --shm-size "${SHM_SIZE}"
  --user 0:0
  --ulimit memlock=-1:-1
  --cap-add IPC_LOCK
  --security-opt seccomp=unconfined
)
if [[ "${USE_PRIVILEGED}" == "1" ]]; then
  PREFLIGHT_DOCKER_ARGS+=(--privileged)
fi
for common_device in /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc; do
  [[ -e "${common_device}" ]] && PREFLIGHT_DOCKER_ARGS+=(--device "${common_device}")
done
for ((i = 0; i <= required_max; i++)); do
  PREFLIGHT_DOCKER_ARGS+=(--device "/dev/davinci${i}")
done
PREFLIGHT_DOCKER_ARGS+=(
  --volume /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro
  --volume /etc/hccn.conf:/etc/hccn.conf:ro
)
[[ -d /usr/local/Ascend/firmware ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro)
[[ -d /usr/local/Ascend/add-ons ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /usr/local/Ascend/add-ons:/usr/local/Ascend/add-ons:ro)
[[ -d /usr/local/dcmi ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /usr/local/dcmi:/usr/local/dcmi:ro)
[[ -d /usr/local/sbin ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /usr/local/sbin:/usr/local/sbin:ro)
if [[ "${npu_smi_bin}" != /usr/local/sbin/* ]]; then
  PREFLIGHT_DOCKER_ARGS+=(--volume "${npu_smi_bin}:${npu_smi_bin}:ro")
fi
[[ -f /etc/ascend_install.info ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /etc/ascend_install.info:/etc/ascend_install.info:ro)
[[ -d /var/queue_schedule ]] && \
  PREFLIGHT_DOCKER_ARGS+=(--volume /var/queue_schedule:/var/queue_schedule)

docker run "${PREFLIGHT_DOCKER_ARGS[@]}" \
  --env "EXPECTED_NPU_COUNT=$((required_max + 1))" \
  --entrypoint bash "${RUNTIME_IMAGE}" -lc '
set -Eeuo pipefail
source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true

NPU_SMI_BIN=$(command -v npu-smi 2>/dev/null || true)
if [[ -z "${NPU_SMI_BIN}" && -x /usr/local/bin/npu-smi ]]; then
  NPU_SMI_BIN=/usr/local/bin/npu-smi
fi
if [[ -z "${NPU_SMI_BIN}" && -x /usr/local/sbin/npu-smi ]]; then
  NPU_SMI_BIN=/usr/local/sbin/npu-smi
fi
[[ -n "${NPU_SMI_BIN}" ]] || { echo "npu-smi is not visible inside the container" >&2; exit 1; }
"${NPU_SMI_BIN}" info -l

ldconfig -p | grep -F "libibverbs.so.1" >/dev/null || {
  echo "libibverbs.so.1 is missing inside the runtime image; rebuild it with ./build-image.sh" >&2
  exit 1
}
ldconfig -p | grep -F "libjemalloc.so.2" >/dev/null || {
  echo "libjemalloc.so.2 is missing inside the runtime image; rebuild it with ./build-image.sh" >&2
  exit 1
}

# Jemalloc must be loaded before Python imports torch_npu/Mooncake on aarch64.
JEMALLOC_SO=$(ldconfig -p | sed -n "/libjemalloc\\.so\\.2/{s/.*=>[[:space:]]*//;p;q;}")
[[ -n "${JEMALLOC_SO}" ]] || { echo "Unable to resolve libjemalloc.so.2" >&2; exit 1; }
export LD_PRELOAD="${JEMALLOC_SO}${LD_PRELOAD:+:${LD_PRELOAD}}"
echo "Using jemalloc preload: ${JEMALLOC_SO}"

python3 -u -X faulthandler - <<"PY"
import ctypes
import importlib.metadata as md
import os
import sglang
import torch
import torch_npu
from mooncake.engine import TransferEngine

ctypes.CDLL("libibverbs.so.1")
expected = int(os.environ["EXPECTED_NPU_COUNT"])
actual = torch.npu.device_count()
jemalloc_loaded = any(
    "libjemalloc.so.2" in line for line in open("/proc/self/maps", encoding="utf-8")
)
print("sglang:", getattr(sglang, "__version__", "unknown"))
print("torch:", torch.__version__)
print("torch_npu:", torch_npu.__version__)
print("torch.npu.device_count:", actual)
print("mooncake-transfer-engine-npu:", md.version("mooncake-transfer-engine-npu"))
print("libibverbs.so.1 load: OK")
print("libjemalloc.so.2 preloaded:", jemalloc_loaded)
print("Mooncake TransferEngine import: OK", TransferEngine)
if not jemalloc_loaded:
    raise RuntimeError("libjemalloc.so.2 was not preloaded before Python startup")
if actual < expected:
    raise RuntimeError(f"Expected at least {expected} visible NPUs, but torch_npu found {actual}")
PY
'

if [[ "${DEPLOY_MODE}" == "split" ]]; then
  local_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)
  log "Split-node mode: allow bidirectional TCP between ${PREFILL_IP} and ${DECODE_IP}"
  log "Required fixed ports: ${PREFILL_HTTP_PORT}, ${DECODE_HTTP_PORT}, ${PREFILL_BOOTSTRAP_PORT}"
  log "Ascend Direct ranges start at ${PREFILL_ASCEND_BASE_PORT} / ${DECODE_ASCEND_BASE_PORT}; host ephemeral range: ${local_range:-unknown}"
fi

log "Preflight passed"
