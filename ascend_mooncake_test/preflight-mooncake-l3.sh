#!/usr/bin/env bash
set -Eeo pipefail

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

for required_name in \
  ENABLE_MOONCAKE_L3 \
  MOONCAKE_MASTER_IP \
  MOONCAKE_MASTER_PORT \
  MOONCAKE_METADATA_PORT \
  MOONCAKE_STORE_PORT \
  MOONCAKE_STORE_GB \
  MOONCAKE_STORE_PROTOCOL \
  HICACHE_L2_GB_PER_RANK \
  TP_SIZE \
  MOONCAKE_L3_HOST_RESERVE_GB; do
  [[ -n "${!required_name:-}" ]] || die "Missing L3 configuration: ${required_name}"
done

for numeric_name in \
  MOONCAKE_MASTER_PORT \
  MOONCAKE_METADATA_PORT \
  MOONCAKE_STORE_PORT \
  MOONCAKE_STORE_GB \
  HICACHE_L2_GB_PER_RANK \
  TP_SIZE \
  MOONCAKE_L3_HOST_RESERVE_GB; do
  numeric_value=${!numeric_name}
  [[ "${numeric_value}" =~ ^[0-9]+$ ]] || \
    die "${numeric_name} must be a non-negative integer, got: ${numeric_value}"
done

[[ "${DEPLOY_MODE}" == "split" ]] || die "Set DEPLOY_MODE=split"
[[ "${ENABLE_MOONCAKE_L3}" == "1" ]] || die "Set ENABLE_MOONCAKE_L3=1"
[[ "${MOONCAKE_STORE_PROTOCOL}" == "tcp" ]] || \
  die "The baseline L3 deployment supports MOONCAKE_STORE_PROTOCOL=tcp only"
[[ "${MOONCAKE_MASTER_PORT}" == "50051" ]] || \
  die "Mooncake 0.3.11.post1 master script currently expects MOONCAKE_MASTER_PORT=50051"
[[ "${HICACHE_L2_GB_PER_RANK}" -ge 1 ]] || die "HICACHE_L2_GB_PER_RANK must be at least 1"
[[ "${MOONCAKE_STORE_GB}" -ge 1 ]] || die "MOONCAKE_STORE_GB must be at least 1"

log "L3 check phase 1/3: validating Host DRAM"
available_kb=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB.*/\1/p' /proc/meminfo)
[[ "${available_kb}" =~ ^[0-9]+$ ]] || die "Failed to parse MemAvailable from /proc/meminfo"
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

log "L3 check phase 2/3: validating Mooncake Master/Store components"
docker run "${L3_IMPORT_DOCKER_ARGS[@]}" "${RUNTIME_IMAGE}" -lc '
set -eo pipefail
# Avoid sourcing vendor set_env.sh in checks: some releases enable nounset and
# reference optional variables such as $n. The required runtime paths are
# supplied explicitly instead.
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"
command -v mooncake_master
JEMALLOC_SO=$(find /usr/lib /lib -name libjemalloc.so.2 -print -quit)
test -n "${JEMALLOC_SO}"
LD_PRELOAD="${JEMALLOC_SO}" python3 - <<"PY"
from mooncake.store import MooncakeDistributedStore, MooncakeHostMemAllocator
print("Mooncake L3 components import: OK")
PY
'

if [[ "${ROLE}" == "decode" ]]; then
  log "L3 check phase 3/3: validating remote Master/Metadata connectivity"
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_MASTER_PORT}" 5 || \
    die "Master is not reachable; start it on the Prefill node first"
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_METADATA_PORT}" 5 || \
    die "Metadata service is not reachable"
fi

if [[ "${ROLE}" == "prefill" ]]; then
  log "L3 check phase 3/3: Master will be started locally after preflight"
fi

log "Mooncake L3 preflight passed for ${ROLE}"
