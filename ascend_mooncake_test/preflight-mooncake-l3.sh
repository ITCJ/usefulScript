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

[[ "${DEPLOY_MODE}" == "split" ]] || die "Set DEPLOY_MODE=split"
[[ "${ENABLE_MOONCAKE_L3}" == "1" ]] || die "Set ENABLE_MOONCAKE_L3=1"
[[ "${MOONCAKE_STORE_PROTOCOL}" == "tcp" ]] || \
  die "The baseline L3 deployment supports MOONCAKE_STORE_PROTOCOL=tcp only"
[[ "${MOONCAKE_MASTER_PORT}" == "50051" ]] || \
  die "Mooncake 0.3.11.post1 master script currently expects MOONCAKE_MASTER_PORT=50051"
[[ "${HICACHE_L2_GB_PER_RANK}" -ge 1 ]] || die "HICACHE_L2_GB_PER_RANK must be at least 1"
[[ "${MOONCAKE_STORE_GB}" -ge 1 ]] || die "MOONCAKE_STORE_GB must be at least 1"

available_kb=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
required_gb=$((MOONCAKE_STORE_GB + HICACHE_L2_GB_PER_RANK * TP_SIZE + MOONCAKE_L3_HOST_RESERVE_GB))
required_kb=$((required_gb * 1024 * 1024))
log "Host DRAM check: available=$((available_kb / 1024 / 1024))GB required_baseline=${required_gb}GB"
((available_kb >= required_kb)) || \
  die "Insufficient Host DRAM for Store + TP L2 pools + reserve"

L3_IMPORT_DOCKER_ARGS=(--rm --entrypoint bash)
[[ -d /usr/local/Ascend/driver ]] && \
  L3_IMPORT_DOCKER_ARGS+=(--volume /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro)
[[ -d /usr/local/Ascend/add-ons ]] && \
  L3_IMPORT_DOCKER_ARGS+=(--volume /usr/local/Ascend/add-ons:/usr/local/Ascend/add-ons:ro)

docker run "${L3_IMPORT_DOCKER_ARGS[@]}" "${RUNTIME_IMAGE}" -lc '
set -e
source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
command -v mooncake_master
JEMALLOC_SO=$(find /usr/lib /lib -name libjemalloc.so.2 -print -quit)
test -n "${JEMALLOC_SO}"
LD_PRELOAD="${JEMALLOC_SO}" python3 - <<"PY"
from mooncake.store import MooncakeDistributedStore, MooncakeHostMemAllocator
print("Mooncake L3 components import: OK")
PY
'

if [[ "${ROLE}" == "decode" ]]; then
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_MASTER_PORT}" 5 || \
    die "Master is not reachable; start it on the Prefill node first"
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_METADATA_PORT}" 5 || \
    die "Metadata service is not reachable"
fi

log "Mooncake L3 preflight passed for ${ROLE}"
