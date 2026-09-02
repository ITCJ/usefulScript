#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command curl

ROUTER_TEST_IP=${ROUTER_TEST_IP:-127.0.0.1}
url="http://${ROUTER_TEST_IP}:${ROUTER_PORT}"

log "Checking router health"
curl --fail --show-error --silent "${url}/health" >/dev/null

log "Sending a deterministic generation request through the PD router"
curl --fail --show-error --silent \
  --header 'Content-Type: application/json' \
  --data '{
    "text": "The capital of France is",
    "sampling_params": {"temperature": 0, "max_new_tokens": 16}
  }' \
  "${url}/generate"
echo

log "Smoke test completed"
