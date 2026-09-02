#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker

mkdir -p "${LOG_DIR}"
name=$(role_name router)
docker rm -f "${name}" >/dev/null 2>&1 || true

log "Starting PD router on ${ROUTER_IP}:${ROUTER_PORT}"
docker run --detach \
  --init \
  --user 0:0 \
  --name "${name}" \
  --network host \
  --volume "${LOG_DIR}:/logs" \
  --entrypoint bash \
  "${RUNTIME_IMAGE}" -lc \
  "exec > >(tee /logs/router.log) 2>&1; \
   exec python3 -m sglang_router.launch_router \
    --pd-disaggregation \
    --prefill http://${PREFILL_IP}:${PREFILL_HTTP_PORT} ${PREFILL_BOOTSTRAP_PORT} \
    --decode http://${DECODE_IP}:${DECODE_HTTP_PORT} \
    --host ${ROUTER_IP} \
    --port ${ROUTER_PORT} \
    --health-check-interval-secs 10 \
    --mini-lb"

log "Router container started: ${name}"
