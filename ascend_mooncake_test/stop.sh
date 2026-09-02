#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

for role in router decode prefill; do
  name=$(role_name "${role}")
  if docker inspect "${name}" >/dev/null 2>&1; then
    log "Stopping ${name}"
    docker rm -f "${name}" >/dev/null
  fi
done
