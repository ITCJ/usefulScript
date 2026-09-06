#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker
require_command timeout

[[ "${ENABLE_MOONCAKE_L3:-0}" == "1" ]] || die "Set ENABLE_MOONCAKE_L3=1 first"
[[ "${DEPLOY_MODE}" == "split" ]] || die "Mooncake L3 two-node scripts require DEPLOY_MODE=split"
[[ "${MOONCAKE_MASTER_IP}" == "${PREFILL_IP}" ]] || \
  die "This deployment expects MOONCAKE_MASTER_IP to equal PREFILL_IP"
if command -v ip >/dev/null 2>&1; then
  ip addr show | grep -Fq "${MOONCAKE_MASTER_IP}" || \
    die "MOONCAKE_MASTER_IP is not assigned to this Prefill host: ${MOONCAKE_MASTER_IP}"
fi

name=$(role_name mooncake-master)
mkdir -p "${LOG_DIR}"
docker rm -f "${name}" >/dev/null 2>&1 || true
build_mooncake_service_docker_args "${name}"

log "Starting Mooncake Master at ${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}"
docker run "${MOONCAKE_SERVICE_DOCKER_ARGS[@]}" \
  --env "MOONCAKE_METADATA_PORT=${MOONCAKE_METADATA_PORT}" \
  --env "MOONCAKE_EVICTION_HIGH_WATERMARK=${MOONCAKE_EVICTION_HIGH_WATERMARK}" \
  "${RUNTIME_IMAGE}" \
  bash /opt/sglang-mooncake-deploy/mooncake-service-entrypoint.sh master

if ! wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_MASTER_PORT}" "${MOONCAKE_SERVICE_START_TIMEOUT}"; then
  docker logs --tail 200 "${name}" >&2 || true
  die "Mooncake Master port ${MOONCAKE_MASTER_PORT} did not become ready"
fi
if ! wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_METADATA_PORT}" "${MOONCAKE_SERVICE_START_TIMEOUT}"; then
  docker logs --tail 200 "${name}" >&2 || true
  die "Mooncake metadata port ${MOONCAKE_METADATA_PORT} did not become ready"
fi

log "Mooncake Master is ready: ${name}"
