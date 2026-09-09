#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
# lib.sh enables nounset. This diagnostic script validates values explicitly,
# then avoids nounset-related failures in older Bash arithmetic loops.
set +u
require_command docker
require_command seq

[[ "${NPU_COUNT_PER_ROLE:-}" =~ ^[0-9]+$ ]] || \
  die "NPU_COUNT_PER_ROLE must be a positive integer, got: ${NPU_COUNT_PER_ROLE:-unset}"
((NPU_COUNT_PER_ROLE > 0)) || die "NPU_COUNT_PER_ROLE must be greater than zero"

[[ -d "${MODEL_HOST_PATH}" ]] || die "Model directory does not exist: ${MODEL_HOST_PATH}"
[[ -d /usr/local/Ascend/driver ]] || die "Host driver directory is missing: /usr/local/Ascend/driver"
[[ -s /etc/hccn.conf ]] || die "Mooncake Ascend Direct requires a non-empty host /etc/hccn.conf"
validate_required_home_mounts
docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1 || \
  die "Runtime image not found: ${RUNTIME_IMAGE}; run ./build-image.sh"

npu_smi_bin=$(find_npu_smi || true)
[[ -n "${npu_smi_bin}" ]] || die "npu-smi is not available in PATH, /usr/local/bin, or /usr/local/sbin"
log "Host NPU summary"
if "${npu_smi_bin}" info -l; then
  log "Host npu-smi summary completed successfully"
else
  npu_smi_rc=$?
  log "WARNING: host npu-smi printed its summary but returned rc=${npu_smi_rc}; continuing with device-node and torch_npu validation"
fi

expected_device_count=${NPU_COUNT_PER_ROLE}
if [[ "${DEPLOY_MODE}" == "single" ]]; then
  expected_device_count=$((NPU_COUNT_PER_ROLE * 2))
fi
required_max=$((expected_device_count - 1))
log "Host device check: expecting ${expected_device_count} davinci devices (/dev/davinci0..${required_max})"
for i in $(seq 0 "${required_max}"); do
  [[ -e "/dev/davinci${i}" ]] || die "Required device missing: /dev/davinci${i}"
done

log "Host HCCN configuration: /etc/hccn.conf"
hccn_tool_bin=$(command -v hccn_tool 2>/dev/null || true)
if [[ -z "${hccn_tool_bin}" && -x /usr/local/Ascend/driver/tools/hccn_tool ]]; then
  hccn_tool_bin=/usr/local/Ascend/driver/tools/hccn_tool
fi
if [[ -n "${hccn_tool_bin}" ]]; then
  for i in $(seq 0 "${required_max}"); do
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
for i in $(seq 0 "${required_max}"); do
  PREFLIGHT_DOCKER_ARGS+=(--device "/dev/davinci${i}")
done
PREFLIGHT_DOCKER_ARGS+=(
  --volume /usr/local/Ascend/driver:/usr/local/Ascend/driver
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
PREFLIGHT_DOCKER_ARGS+=(
  --volume "${SCRIPT_DIR}:/opt/sglang-mooncake-deploy:ro"
  --env "ASCEND_RT_VISIBLE_DEVICES=$(seq -s, 0 "${required_max}")"
)

docker run "${PREFLIGHT_DOCKER_ARGS[@]}" \
  --env "EXPECTED_NPU_COUNT=${expected_device_count}" \
  --env "PD_TRANSFER_BACKEND=${PD_TRANSFER_BACKEND}" \
  --env "ASCEND_MF_STORE_URL=${ASCEND_MF_STORE_URL:-}" \
  --env "ASCEND_MF_TRANSFER_PROTOCOL=${ASCEND_MF_TRANSFER_PROTOCOL:-}" \
  --entrypoint bash "${RUNTIME_IMAGE}" \
  /opt/sglang-mooncake-deploy/check-runtime-components.sh

if [[ "${DEPLOY_MODE}" == "split" ]]; then
  local_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)
  log "Split-node mode: allow bidirectional TCP between ${PREFILL_IP} and ${DECODE_IP}"
  log "Required fixed ports: ${PREFILL_HTTP_PORT}, ${DECODE_HTTP_PORT}, ${PREFILL_BOOTSTRAP_PORT}"
  log "Ascend Direct ranges start at ${PREFILL_ASCEND_BASE_PORT} / ${DECODE_ASCEND_BASE_PORT}; host ephemeral range: ${local_range:-unknown}"
fi

log "Preflight passed"
