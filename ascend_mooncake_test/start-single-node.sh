#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

[[ "${DEPLOY_MODE}" == "single" ]] || die "start-single-node.sh requires DEPLOY_MODE=single"

"${SCRIPT_DIR}/start-role.sh" prefill
"${SCRIPT_DIR}/start-role.sh" decode

log "Workers are loading the model. Start the router after both /health endpoints are ready:"
log "  ${SCRIPT_DIR}/wait-workers.sh && ${SCRIPT_DIR}/start-router.sh"
