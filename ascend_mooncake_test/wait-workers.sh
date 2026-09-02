#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command curl

WAIT_TIMEOUT=${WAIT_TIMEOUT:-1800}
deadline=$((SECONDS + WAIT_TIMEOUT))

wait_one() {
  local name=$1 url=$2
  log "Waiting for ${name}: ${url}"
  until curl --fail --silent --max-time 3 "${url}/health" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "Timed out waiting for ${name}; inspect docker logs $(role_name "${name}")"
    sleep 5
  done
  log "${name} is healthy"
}

wait_one prefill "http://${PREFILL_IP}:${PREFILL_HTTP_PORT}"
wait_one decode "http://${DECODE_IP}:${DECODE_HTTP_PORT}"
