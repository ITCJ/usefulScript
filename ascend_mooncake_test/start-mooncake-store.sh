#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
[[ "${ROLE}" == "prefill" || "${ROLE}" == "decode" ]] || {
  echo "Usage: $0 prefill|decode" >&2
  exit 2
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker
require_command timeout

[[ "${ENABLE_MOONCAKE_L3:-0}" == "1" ]] || die "Set ENABLE_MOONCAKE_L3=1 first"
if [[ "${ROLE}" == "prefill" ]]; then
  LOCAL_IP=${PREFILL_IP}
else
  LOCAL_IP=${DECODE_IP}
fi
if command -v ip >/dev/null 2>&1; then
  ip addr show | grep -Fq "${LOCAL_IP}" || \
    die "Store local IP is not assigned to this host: ${LOCAL_IP}"
fi

wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_MASTER_PORT}" 10 || \
  die "Mooncake Master is unreachable at ${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}"
wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_METADATA_PORT}" 10 || \
  die "Mooncake metadata service is unreachable at ${MOONCAKE_MASTER_IP}:${MOONCAKE_METADATA_PORT}"

name=$(role_name mooncake-store)
mkdir -p "${LOG_DIR}"
docker rm -f "${name}" >/dev/null 2>&1 || true
build_mooncake_service_docker_args "${name}"

log "Starting ${ROLE} Mooncake Store: ${MOONCAKE_STORE_GB}GB DRAM at ${LOCAL_IP}"
docker run "${MOONCAKE_SERVICE_DOCKER_ARGS[@]}" \
  --env "MOONCAKE_LOCAL_HOSTNAME=${LOCAL_IP}" \
  --env "MOONCAKE_TE_META_DATA_SERVER=http://${MOONCAKE_MASTER_IP}:${MOONCAKE_METADATA_PORT}/metadata" \
  --env "MOONCAKE_MASTER=${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}" \
  --env "MOONCAKE_PROTOCOL=${MOONCAKE_STORE_PROTOCOL}" \
  --env "MOONCAKE_DEVICE=${MOONCAKE_STORE_DEVICE:-}" \
  --env "MOONCAKE_GLOBAL_SEGMENT_SIZE=${MOONCAKE_STORE_GB}gb" \
  --env "MOONCAKE_LOCAL_BUFFER_SIZE=0" \
  --env "MOONCAKE_STORE_PORT=${MOONCAKE_STORE_PORT}" \
  "${RUNTIME_IMAGE}" \
  bash /opt/sglang-mooncake-deploy/mooncake-service-entrypoint.sh store "${ROLE}"

if ! wait_tcp_endpoint "${LOCAL_IP}" "${MOONCAKE_STORE_PORT}" "${MOONCAKE_SERVICE_START_TIMEOUT}"; then
  docker logs --tail 200 "${name}" >&2 || true
  die "Mooncake Store port ${LOCAL_IP}:${MOONCAKE_STORE_PORT} did not become ready"
fi

log "Mooncake Store is ready: ${name}, contribution=${MOONCAKE_STORE_GB}GB"
