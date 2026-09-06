#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
[[ "${ROLE}" == "prefill" || "${ROLE}" == "decode" ]] || {
  echo "Usage: $0 prefill|decode" >&2
  exit 2
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"${SCRIPT_DIR}/preflight.sh"
"${SCRIPT_DIR}/preflight-mooncake-l3.sh" "${ROLE}"

if [[ "${ROLE}" == "prefill" ]]; then
  "${SCRIPT_DIR}/start-mooncake-master.sh"
fi

"${SCRIPT_DIR}/start-mooncake-store.sh" "${ROLE}"
"${SCRIPT_DIR}/start-role.sh" "${ROLE}"
