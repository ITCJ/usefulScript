#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

echo "===== Mooncake L3 topology ====="
echo "master=${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}"
echo "metadata=${MOONCAKE_MASTER_IP}:${MOONCAKE_METADATA_PORT}"
echo "prefill_store=${PREFILL_IP}:${MOONCAKE_STORE_PORT} contribution=${MOONCAKE_STORE_GB}GB"
echo "decode_store=${DECODE_IP}:${MOONCAKE_STORE_PORT} contribution=${MOONCAKE_STORE_GB}GB"
echo "total_l3=$((MOONCAKE_STORE_GB * 2))GB"
echo "l2_per_rank=${HICACHE_L2_GB_PER_RANK}GB approximate_l2_per_host=$((HICACHE_L2_GB_PER_RANK * TP_SIZE))GB"

for endpoint in \
  "${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}" \
  "${MOONCAKE_MASTER_IP}:${MOONCAKE_METADATA_PORT}" \
  "${PREFILL_IP}:${MOONCAKE_STORE_PORT}" \
  "${DECODE_IP}:${MOONCAKE_STORE_PORT}"; do
  host=${endpoint%:*}
  port=${endpoint##*:}
  if wait_tcp_endpoint "${host}" "${port}" 2; then
    echo "READY ${endpoint}"
  else
    echo "DOWN  ${endpoint}"
  fi
done

echo "===== Local containers ====="
docker ps -a --filter "name=${CONTAINER_PREFIX}" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

for name in \
  "$(role_name mooncake-master)" \
  "$(role_name mooncake-store)" \
  "$(role_name prefill)" \
  "$(role_name decode)"; do
  if docker inspect "${name}" >/dev/null 2>&1; then
    echo "===== ${name} last logs ====="
    docker logs --tail 30 "${name}" 2>&1 || true
  fi
done
